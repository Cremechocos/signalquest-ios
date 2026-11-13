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
    /// DISPUTED-SITE r1 : le nœud a-t-il déjà un site ? Appelé avant le formulaire.
    func check(_ radio: CustomSiteRadioSnapshot) async throws -> CustomSiteRadioCheck
    /// Envois en attente « à revoir » : le nœud a trouvé un site entre-temps.
    func pendingReviews() async -> [CustomSitePendingReview]
    /// « Créer quand même » : nouvelle demande, qui conteste le site actuel.
    func createAnyway(_ review: CustomSitePendingReview) async throws -> CustomSiteCreationResult
    /// « Abandonner mon site » : il ne sera pas envoyé.
    func abandon(_ review: CustomSitePendingReview) async
}

extension CustomSitesServicing {
    func check(_ radio: CustomSiteRadioSnapshot) async throws -> CustomSiteRadioCheck { .unchecked }
    func pendingReviews() async -> [CustomSitePendingReview] { [] }
    func createAnyway(_ review: CustomSitePendingReview) async throws -> CustomSiteCreationResult { .pending }
    func abandon(_ review: CustomSitePendingReview) async {}
}

extension Notification.Name {
    /// Un envoi en attente est passé « à revoir » (ou en est sorti).
    static let customSitePendingReviewsChanged = Notification.Name("customSitePendingReviewsChanged")
}

/// Relevé radio joint à la création (`radio`), comme Android. C'est lui seul que le serveur
/// compare aux sites existants : sans lui, aucun contrôle de doublon n'a lieu.
struct CustomSiteRadioSnapshot: Codable, Equatable, Sendable {
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
    var mobileOperator: String?
    var technology: String?

    /// « eNB 81234 », « gNB 1234 » : le nœud dont il s'agit.
    var nodeLabel: String? {
        if let enb = enb?.trimmingCharacters(in: .whitespaces), !enb.isEmpty { return "eNB \(enb)" }
        if let gnb = gnb?.trimmingCharacters(in: .whitespaces), !gnb.isEmpty { return "gNB \(gnb)" }
        return nil
    }

    var hasNode: Bool { nodeLabel != nil }
    var plmn: String? { mcc.map { "\($0)-\(mnc.map(String.init) ?? "")" } }
}

/// DISPUTED-SITE r1 : site qui porte déjà le nœud (`currentSite` du contrôle et du 409).
/// `siteId` se renvoie tel quel dans `disputedSiteId`.
struct CustomSiteCurrentSite: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case official, custom, unknown }
    let siteId: String
    let kind: Kind
    /// Le membre l'a créé lui-même ; toujours faux sans session.
    let ownedByRequester: Bool

    enum CodingKeys: String, CodingKey { case siteId, kind, ownedByRequester }

    init(siteId: String, kind: Kind, ownedByRequester: Bool) {
        self.siteId = siteId
        self.kind = kind
        self.ownedByRequester = ownedByRequester
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.decodeFlexibleString(forKey: .siteId)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .siteId, in: c, debugDescription: "Missing siteId")
        }
        siteId = id
        // Une valeur inconnue ne casse pas la lecture : on ne nomme alors pas le site.
        kind = (try? c.decode(String.self, forKey: .kind)).flatMap { Kind(rawValue: $0.lowercased()) } ?? .unknown
        ownedByRequester = (try? c.decode(Bool.self, forKey: .ownedByRequester)) ?? false
    }
}

/// Réponse de `GET /api/android/sites/custom/check`.
struct CustomSiteRadioCheck: Codable, Equatable, Sendable {
    var exists: Bool
    var source: String?
    var anfrSiteId: String?
    var registryMarket: String?
    var customSiteId: String?
    var customSiteName: String?
    var identificationStatus: String?
    var currentSite: CustomSiteCurrentSite?

    /// Contrôle absent (hors ligne, échec) : le formulaire s'ouvre, le serveur tranchera à l'envoi.
    static let unchecked = CustomSiteRadioCheck(exists: false)

    init(exists: Bool, source: String? = nil, anfrSiteId: String? = nil, registryMarket: String? = nil,
         customSiteId: String? = nil, customSiteName: String? = nil, identificationStatus: String? = nil,
         currentSite: CustomSiteCurrentSite? = nil) {
        self.exists = exists
        self.source = source
        self.anfrSiteId = anfrSiteId
        self.registryMarket = registryMarket
        self.customSiteId = customSiteId
        self.customSiteName = customSiteName
        self.identificationStatus = identificationStatus
        self.currentSite = currentSite
    }

    enum CodingKeys: String, CodingKey {
        case exists, source, anfrSiteId, registryMarket, customSiteId, customSiteName, identificationStatus, currentSite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exists = (try? c.decode(Bool.self, forKey: .exists)) ?? false
        source = try? c.decode(String.self, forKey: .source)
        anfrSiteId = c.decodeFlexibleString(forKey: .anfrSiteId)
        registryMarket = try? c.decode(String.self, forKey: .registryMarket)
        customSiteId = c.decodeFlexibleString(forKey: .customSiteId)
        customSiteName = try? c.decode(String.self, forKey: .customSiteName)
        identificationStatus = try? c.decode(String.self, forKey: .identificationStatus)
        currentSite = try? c.decode(CustomSiteCurrentSite.self, forKey: .currentSite)
    }

    /// Comme Android : on bloque seulement un nœud confirmé. Une hypothèse de l'algorithme
    /// laisse créer le site, qui la lève.
    var blocksCreation: Bool { exists && identificationStatus == "identified" }

    /// Site désigné : `currentSite` d'abord, sinon l'ordre du serveur (Validation, puis site communautaire).
    var linkedSiteId: String? {
        [currentSite?.siteId, anfrSiteId, customSiteId]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Nature du site : celle du serveur, sinon déduite de la source, sans inventer.
    var currentKind: CustomSiteCurrentSite.Kind {
        if let kind = currentSite?.kind { return kind }
        switch source {
        case "anfr", "registry": return .official
        case "custom": return .custom
        default: return .unknown
        }
    }

    var ownedByRequester: Bool { currentSite?.ownedByRequester ?? false }

    /// Nom du site communautaire, seulement quand c'est bien lui que le serveur désigne.
    var siteName: String? {
        guard currentKind == .custom, let name = customSiteName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        if let current = currentSite?.siteId, let custom = customSiteId, current != custom { return nil }
        return name
    }
}

/// Création refusée parce que le nœud a déjà un site (409 `RADIO_ALREADY_KNOWN` / `DISPUTE_OWN_SITE`).
/// `check` est relu après le refus (même calcul que le 409) ; nil = le serveur n'a désigné aucun site.
struct CustomSiteAlreadyLinkedError: Error, Equatable {
    let code: String?
    let check: CustomSiteRadioCheck?

    static let conflictCodes: Set<String> = ["RADIO_ALREADY_KNOWN", "DISPUTE_OWN_SITE"]
}

/// DISPUTED-SITE r1 : le membre a dit « Ce n'est pas le bon site » et crée le sien.
struct CustomSiteDispute: Equatable, Sendable {
    let siteId: String
    let kind: CustomSiteCurrentSite.Kind
    /// Nom du site communautaire quitté ; nil = inconnu, la note le tait.
    let siteName: String?
    let nodeLabel: String
    let radio: CustomSiteRadioSnapshot

    /// Jamais pour le site du membre (le serveur refuserait), ni sans site désigné, ni sans nœud.
    init?(check: CustomSiteRadioCheck, radio: CustomSiteRadioSnapshot) {
        guard !check.ownedByRequester, let siteId = check.linkedSiteId, let node = radio.nodeLabel else { return nil }
        self.siteId = siteId
        kind = check.currentKind
        siteName = check.siteName
        nodeLabel = node
        self.radio = radio
    }

    /// Vaut-elle pour cette création ? Même nœud et même PLMN, et le serveur désigne toujours
    /// le même site, qui n'est pas celui du membre.
    func applies(to radio: CustomSiteRadioSnapshot, check: CustomSiteRadioCheck) -> Bool {
        radio.nodeLabel == nodeLabel && radio.plmn == self.radio.plmn
            && !check.ownedByRequester && check.linkedSiteId == siteId
    }
}

/// Envoi en attente « à revoir » : créé hors ligne, il a trouvé à l'envoi son nœud déjà sur un
/// site. Il reste dans la file jusqu'au choix du membre.
struct CustomSitePendingReview: Identifiable, Equatable, Sendable {
    let requestId: String
    let name: String
    let latitude: Double
    let longitude: Double
    let check: CustomSiteRadioCheck
    let radio: CustomSiteRadioSnapshot
    var id: String { requestId }
    var nodeLabel: String { radio.nodeLabel ?? "" }
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
    /// Premier relevé, comparé par le serveur aux sites existants (DISPUTED-SITE r1).
    var radio: CustomSiteRadioSnapshot? = nil
    /// Site contesté (« Ce n'est pas le bon site » ou « Créer quand même ») : `currentSite.siteId` tel quel.
    var disputedSiteId: String? = nil
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
    /// Relit le site actuel du nœud ; injectable pour les tests.
    private let checkNode: (@Sendable (CustomSiteRadioSnapshot) async throws -> CustomSiteRadioCheck)?

    init(
        api: APIClient,
        currentUserId: @escaping @Sendable () -> String?,
        outbox: CustomSiteOutboxStore = CustomSiteOutboxStore(),
        checkNode: (@Sendable (CustomSiteRadioSnapshot) async throws -> CustomSiteRadioCheck)? = nil
    ) {
        self.api = api
        self.currentUserId = currentUserId
        self.outbox = outbox
        self.checkNode = checkNode
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
            // Refus définitif : l'erreur est montrée à l'utilisateur, le site ne
            // reste pas en file pour être rejoué à chaque lancement. Le nœud déjà
            // sur un site en fait partie : la feuille du refus est sous ses yeux.
            if error is CustomSiteAlreadyLinkedError || error.isPermanentRequestFailure {
                try? await outbox.remove(userId: userId, requestId: pending.requestId)
            }
            throw error
        }
    }

    func retryPending() async {
        guard let userId = currentUserId()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userId.isEmpty,
              let pending = try? await outbox.pending(userId: userId)
        else { return }

        // Un envoi « à revoir » attend le choix du membre : le rejouer redonnerait le même refus.
        for record in pending where record.review == nil {
            do {
                _ = try await submit(record, userId: userId)
            } catch {
                if error.isCancellation { return }
                logger.warning("Custom-site replay failed; encrypted record retained")
                // Une panne réseau commune rendrait les tentatives suivantes
                // inutiles. Les erreurs terminales restent, elles, isolées.
                if CustomSiteOutboxRetryPolicy.isRetryable(error) { return }
                if let linked = error as? CustomSiteAlreadyLinkedError, let check = linked.check,
                   check.linkedSiteId != nil {
                    // DISPUTED-SITE r1 : le nœud a trouvé un site entre-temps. Le site du membre
                    // n'est ni envoyé ni perdu : il attend « Créer quand même » ou « Abandonner ».
                    try? await outbox.markReview(userId: userId, requestId: record.requestId, check: check)
                    await Self.postReviewsChanged()
                    continue
                }
                if error is CustomSiteAlreadyLinkedError || error.isPermanentRequestFailure {
                    try? await outbox.remove(userId: userId, requestId: record.requestId)
                }
            }
        }
    }

    func check(_ radio: CustomSiteRadioSnapshot) async throws -> CustomSiteRadioCheck {
        if let checkNode { return try await checkNode(radio) }
        return try await api.request(
            APIEndpoint(path: "/api/android/sites/custom/check", query: Self.checkQuery(radio)),
            as: CustomSiteRadioCheck.self
        )
    }

    /// Les paramètres que lit le contrôle : nœud, cellule, opérateur et MCC du relevé.
    static func checkQuery(_ radio: CustomSiteRadioSnapshot) -> [URLQueryItem] {
        [
            radio.enb.map { URLQueryItem(name: "enb", value: $0) },
            radio.gnb.map { URLQueryItem(name: "gnb", value: $0) },
            radio.cellId.map { URLQueryItem(name: "cellId", value: $0) },
            radio.mobileOperator.map { URLQueryItem(name: "operator", value: $0) },
            radio.mcc.map { URLQueryItem(name: "mcc", value: String($0)) },
        ].compactMap { $0 }
    }

    func pendingReviews() async -> [CustomSitePendingReview] {
        guard let userId = currentUserId()?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty,
              let pending = try? await outbox.pending(userId: userId)
        else { return [] }
        return pending.compactMap { record in
            guard let check = record.review, let radio = record.draft.radio else { return nil }
            return CustomSitePendingReview(requestId: record.requestId, name: record.draft.name,
                                           latitude: record.draft.latitude, longitude: record.draft.longitude,
                                           check: check, radio: radio)
        }
    }

    /// Nouvelle demande (nouveau `clientRequestId`) qui déclare le site contesté ; l'ancienne sort
    /// de la file. Un nouveau refus repasse par la feuille, avec ce que le serveur dit alors.
    func createAnyway(_ review: CustomSitePendingReview) async throws -> CustomSiteCreationResult {
        guard let userId = currentUserId()?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty,
              let record = try await outbox.pending(userId: userId).first(where: { $0.requestId == review.requestId })
        else { throw APIError.missingAuthToken }
        var draft = record.draft
        draft.disputedSiteId = review.check.linkedSiteId
        // La nouvelle demande est écrite avant que l'ancienne sorte : le site n'est jamais perdu.
        let replacement = try await outbox.stage(userId: userId, draft: draft)
        try? await outbox.remove(userId: userId, requestId: record.requestId)
        await Self.postReviewsChanged()
        do {
            return try await submit(replacement, userId: userId) ?? .pending
        } catch {
            if error.isCancellation { throw error }
            if CustomSiteOutboxRetryPolicy.isRetryable(error) { return .pending }
            if let linked = error as? CustomSiteAlreadyLinkedError, let check = linked.check, check.linkedSiteId != nil {
                // Le site actuel a encore changé : l'envoi reste « à revoir », avec ce que dit le serveur.
                try? await outbox.markReview(userId: userId, requestId: replacement.requestId, check: check)
                await Self.postReviewsChanged()
            } else if error is CustomSiteAlreadyLinkedError || error.isPermanentRequestFailure {
                try? await outbox.remove(userId: userId, requestId: replacement.requestId)
            }
            throw error
        }
    }

    func abandon(_ review: CustomSitePendingReview) async {
        guard let userId = currentUserId()?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty else { return }
        try? await outbox.remove(userId: userId, requestId: review.requestId)
        await Self.postReviewsChanged()
    }

    @MainActor private static func postReviewsChanged() {
        NotificationCenter.default.post(name: .customSitePendingReviewsChanged, object: nil)
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
        let result: CustomSiteCreationResult
        do {
            result = try await api.requestJSON(
                "/api/android/sites/custom",
                method: .post,
                body: payload,
                authenticated: true,
                idempotencyKey: pending.requestId
            )
        } catch let APIError.http(status, code, _, _, _)
            where status == 409 && code.map(CustomSiteAlreadyLinkedError.conflictCodes.contains) == true {
            // Le corps du 409 porte `currentSite`, que l'APIClient ne remonte pas : le contrôle,
            // calculé par la même fonction côté serveur, le redonne.
            var check: CustomSiteRadioCheck?
            if let radio = payload.radio, radio.hasNode { check = try? await self.check(radio) }
            throw CustomSiteAlreadyLinkedError(code: code, check: check)
        }
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
            operatorRadios: radios,
            radio: primaryRadio(cells)
        )
    }

    /// Le relevé que le serveur compare aux sites existants : la cellule la plus observée parmi
    /// celles qui portent un nœud (eNB ou gNB), comme le premier relevé d'Android. Sans nœud,
    /// rien à comparer : pas de `radio`.
    static func primaryRadio(_ cells: [AndroidCommunitySiteMarker]) -> CustomSiteRadioSnapshot? {
        func present(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        let withNode = cells.filter { present($0.enb) != nil || present($0.gnb) != nil }
        guard let cell = withNode.max(by: { ($0.observationCount ?? 0) < ($1.observationCount ?? 0) }) else { return nil }
        return CustomSiteRadioSnapshot(
            enb: present(cell.enb),
            gnb: present(cell.gnb),
            cellId: present(cell.cellId ?? cell.ci),
            pci: cell.pci,
            tac: present(cell.tac),
            earfcn: cell.earfcn,
            nrarfcn: cell.nrarfcn,
            band: cell.band,
            mcc: cell.mcc,
            mnc: cell.mnc,
            mobileOperator: present(cell.operatorKey),
            technology: present(cell.radioNodeType)
        )
    }
}
