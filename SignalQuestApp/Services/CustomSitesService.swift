import Foundation

/// Création d'un site pointé à la main.
///
/// Le cas qui justifie ce service : transformer une ou plusieurs **cellules
/// observées** en site cartographié. Ces cellules portent une identité radio
/// complète (eNB, PCI, TAC, bande, PLMN) mais seulement un centroïde estimé à
/// ~1 km ; le contributeur, lui, sait où est le pylône. On garde donc les
/// identifiants et on remplace la position.
protocol CustomSitesServicing: Sendable {
    func create(_ draft: CustomSiteDraft) async throws -> CustomSiteCreationResult
}

/// Identité radio d'UN opérateur sur le site. Le backend accepte un tableau :
/// un même pylône peut porter les cellules de plusieurs opérateurs.
struct CustomSiteOperatorRadio: Encodable, Equatable, Sendable {
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

struct CustomSiteDraft: Encodable, Equatable, Sendable {
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
    }
}

final class CustomSitesService: CustomSitesServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func create(_ draft: CustomSiteDraft) async throws -> CustomSiteCreationResult {
        try await api.requestJSON(
            "/api/android/sites/custom",
            method: .post,
            body: draft.normalized(),
            authenticated: true
        )
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
