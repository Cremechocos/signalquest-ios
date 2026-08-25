import Foundation
import os

/// Création d'un site pointé à la main.
///
/// Le cas qui justifie ce service : transformer une ou plusieurs **cellules
/// observées** en site cartographié. Ces cellules portent une identité radio
/// complète (eNB, PCI, TAC, bande, PLMN) mais seulement un centroïde estimé à
/// ~1 km ; le contributeur, lui, sait où est le pylône. On garde donc les
/// identifiants et on remplace la position.
protocol CustomSitesServicing: Sendable {
    func create(_ draft: CustomSiteDraft) async throws -> CustomSiteCreationResult
    func retryPending() async
}

/// Identité radio d'UN opérateur sur le site. Le backend accepte un tableau :
/// un même pylône peut porter les cellules de plusieurs opérateurs.
struct CustomSiteOperatorRadio: Codable, Equatable, Sendable {
    let `operator`: String
    var enb: String?
    var gnb: String?
    var cellId: String?
    var pci: Int?
    var tac: String?
    var earfcn: Int?
    var nrarfcn: Int?
    var band: Int?
    var mcc: Int?
    var mnc: Int?
    var technology: String?
}

struct CustomSiteDraft: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var name: String
    /// Constante du backend : PYLONE, TOIT, CHATEAU_EAU… Voir `ALLOWED_TYPES`.
    var type: String
    var description: String?
    /// Opérateur propriétaire de l'infrastructure.
    var infraOwnerOperator: String?
    /// Opérateurs hébergés. ⚠️ Le backend REJETTE une radio dont l'opérateur
    /// n'est pas listé ici — `normalized` s'en charge, ne pas l'appeler
    /// soi-même sur un brouillon assemblé à la main.
    var hostedOperators: [String]
    var operatorRadios: [CustomSiteOperatorRadio]
    /// Stable uniquement dans l'enveloppe envoyée. Les brouillons UI et ceux
    /// conservés sur disque gardent cette valeur à nil.
    var clientRequestId: String? = nil

    /// Bornes du backend, rejouées côté client pour éviter un aller-retour
    /// perdu sur un nom trop court.
    static let nameLengthRange = 2...120
    static let descriptionMaxLength = 500

    var isValid: Bool {
        guard Self.nameLengthRange.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) else { return false }
        guard latitude.isFinite, longitude.isFinite else { return false }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return false }
        return !type.isEmpty
    }

    /// Brouillon prêt à partir : nom rogné, description bornée, et surtout
    /// `hostedOperators` complété de tous les opérateurs porteurs d'une radio —
    /// sans quoi le backend les filtre en silence et le site arrive sans radio.
    func normalized() -> CustomSiteDraft {
        var copy = self
        copy.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLengthRange.upperBound))
        copy.description = description
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.descriptionMaxLength)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        var hosted = hostedOperators
        for radio in operatorRadios where !hosted.contains(radio.operator) {
            hosted.append(radio.operator)
        }
        if let owner = infraOwnerOperator, !hosted.contains(owner) { hosted.insert(owner, at: 0) }
        copy.hostedOperators = hosted
        return copy
    }
}

struct CustomSiteCreationResult: Decodable, Sendable {
    let id: String?
    let slug: String?
    let isPending: Bool

    enum CodingKeys: String, CodingKey { case id, slug, site }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // La réponse est tantôt le site lui-même, tantôt enveloppé dans `site`.
        if let nested = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .site) {
            id = nested.decodeFlexibleString(forKey: .id)
            slug = nested.decodeFlexibleString(forKey: .slug)
        } else {
            id = c.decodeFlexibleString(forKey: .id)
            slug = c.decodeFlexibleString(forKey: .slug)
        }
        isPending = false
    }

    private init(id: String?, slug: String?, isPending: Bool) {
        self.id = id
        self.slug = slug
        self.isPending = isPending
    }

    static let pending = CustomSiteCreationResult(id: nil, slug: nil, isPending: true)
}

actor CustomSitesService: CustomSitesServicing {
    private let api: APIClient
    private let currentUserId: @Sendable () -> String?
    private let outbox: CustomSiteOutboxStore
    private var inFlightRequestIds = Set<String>()
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "CustomSiteOutbox")

    init(
        api: APIClient,
        currentUserId: @escaping @Sendable () -> String?,
        outbox: CustomSiteOutboxStore = CustomSiteOutboxStore()
    ) {
        self.api = api
        self.currentUserId = currentUserId
        self.outbox = outbox
    }

    func create(_ draft: CustomSiteDraft) async throws -> CustomSiteCreationResult {
        guard let userId = currentUserId()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty
        else { throw APIError.missingAuthToken }

        // Le commit chiffré a lieu AVANT la première lecture réseau. Une
        // terminaison du processus ne peut donc plus faire disparaître le site.
        let pending = try await outbox.stage(userId: userId, draft: draft)
        do {
            return try await submit(pending, userId: userId) ?? .pending
        } catch {
            if error.isCancellation { throw error }
            if CustomSiteOutboxRetryPolicy.isRetryable(error) { return .pending }
            // Même sur 4xx, ne pas jeter silencieusement le brouillon non acquitté.
            throw error
        }
    }

    func retryPending() async {
        guard let userId = currentUserId()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty,
              let pending = try? await outbox.pending(userId: userId)
        else { return }

        for record in pending {
            do {
                _ = try await submit(record, userId: userId)
            } catch {
                if error.isCancellation { return }
                logger.warning("Custom-site replay failed; encrypted record retained")
                // Une panne réseau commune rendrait les tentatives suivantes
                // inutiles. Les erreurs terminales restent, elles, isolées.
                if CustomSiteOutboxRetryPolicy.isRetryable(error) { return }
            }
        }
    }

    private func submit(
        _ pending: PendingCustomSiteCreation,
        userId: String
    ) async throws -> CustomSiteCreationResult? {
        guard pending.ownerScopeId == CustomSiteOutboxOwner.scope(for: userId) else {
            throw APIError.missingAuthToken
        }
        guard inFlightRequestIds.insert(pending.requestId).inserted else { return nil }
        defer { inFlightRequestIds.remove(pending.requestId) }

        var payload = pending.draft.normalized()
        payload.clientRequestId = pending.requestId
        let result: CustomSiteCreationResult = try await api.requestJSON(
            "/api/android/sites/custom",
            method: .post,
            body: payload,
            authenticated: true,
            idempotencyKey: pending.requestId
        )
        guard result.id?.isEmpty == false || result.slug?.isEmpty == false else {
            throw APIError.decoding("Missing acknowledged custom-site identifier")
        }
        do {
            try await outbox.remove(userId: userId, requestId: pending.requestId)
        } catch {
            // Le serveur a réellement accusé la création. Garder la copie locale
            // provoquera seulement un rejeu idempotent au prochain lancement.
            logger.error("Unable to clear acknowledged custom-site outbox record")
        }
        return result
    }
}

extension CustomSiteDraft {
    /// Brouillon pré-rempli à partir de cellules observées.
    ///
    /// Les cellules apportent l'identité radio ; la position vient de
    /// l'utilisateur, pas du centroïde : celui-ci est la moyenne des points de
    /// mesure, souvent à plusieurs centaines de mètres du pylône réel.
    ///
    /// Une cellule par opérateur : deux cellules du même opérateur sur un même
    /// site décrivent deux secteurs, or le backend n'attend qu'une radio par
    /// opérateur. On garde alors celle qui a le plus d'observations.
    static func fromObservedCells(
        _ cells: [AndroidCommunitySiteMarker],
        latitude: Double,
        longitude: Double,
        name: String,
        type: String,
        description: String? = nil
    ) -> CustomSiteDraft {
        var bestByOperator: [String: AndroidCommunitySiteMarker] = [:]
        for cell in cells {
            guard let key = cell.operatorKey, !key.isEmpty else { continue }
            let current = bestByOperator[key]
            if current == nil || (cell.observationCount ?? 0) > (current?.observationCount ?? 0) {
                bestByOperator[key] = cell
            }
        }
        let radios = bestByOperator
            .sorted { $0.key < $1.key }
            .map { key, cell in
                CustomSiteOperatorRadio(
                    operator: key,
                    enb: cell.enb,
                    gnb: cell.gnb,
                    cellId: cell.cellId ?? cell.ci,
                    pci: cell.pci,
                    tac: cell.tac,
                    earfcn: cell.earfcn,
                    nrarfcn: cell.nrarfcn,
                    band: cell.band,
                    mcc: cell.mcc,
                    mnc: cell.mnc,
                    technology: cell.radioNodeType
                )
            }
        return CustomSiteDraft(
            latitude: latitude,
            longitude: longitude,
            name: name,
            type: type,
            description: description,
            // Le premier opérateur par ordre alphabétique n'est pas forcément le
            // propriétaire de l'infra : on ne l'invente pas, le contributeur le
            // désignera s'il le sait.
            infraOwnerOperator: nil,
            hostedOperators: radios.map(\.operator),
            operatorRadios: radios
        )
    }
}
