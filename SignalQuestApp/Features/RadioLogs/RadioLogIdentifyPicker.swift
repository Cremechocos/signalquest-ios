import CoreLocation
import Foundation
import SwiftUI

/// Un candidat proposé à l'utilisateur pour un site non identifié.
///
/// L'app VÉRIFIE, elle n'attribue pas : ce que présente cet écran est une piste
/// (`identify/quick` par proximité) et une liste d'antennes voisines. Le choix
/// reste à l'utilisateur, et c'est son geste qui déclenche l'écriture.
struct RadioLogCandidate: Identifiable, Equatable {
    let id: String
    let siteId: String
    let latitude: Double?
    let longitude: Double?
    let operators: [String]
    let technologies: [String]
    let address: String?
    /// Distance à la position médiane des relevés du site.
    let distanceMeters: Int?
    /// Score de confiance du serveur, quand c'est lui qui a proposé la piste.
    let confidenceScore: Int?
    /// Vrai pour la piste que le serveur a classée en tête.
    let isServerHypothesis: Bool

    var distanceLabel: String? {
        guard let distanceMeters else { return nil }
        return SQUnits.distance(meters: Double(distanceMeters))
    }
}

/// Charge et classe les candidats d'un site. Partagé par la feuille unitaire et
/// par la file en chaîne — les deux posent exactement la même question.
@MainActor
final class RadioLogIdentifyPicker: ObservableObject {
    @Published private(set) var candidates: [RadioLogCandidate] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedId: String?
    @Published private(set) var isSubmitting = false
    /// Anneaux TA du nœud visé — « depuis ce point, le site est à peu près à cette
    /// distance ». Leur intersection le désigne, et c'est ce qui permet de trancher entre
    /// deux antennes voisines. Calculés sur le journal DÉJÀ SYNCHRONISÉ localement : aucun
    /// appel réseau, les relevés sont là.
    @Published private(set) var taRings: [TaRingSelection.Ring] = []
    /// Ce que la géométrie permet de dire : des anneaux qui ne se croisent nulle part
    /// apprennent quelque chose, mais ne doivent pas passer pour une localisation.
    @Published private(set) var taAssessment: TaRingSelection.Assessment = .unusable
    /// Relevés retirés du calcul parce qu'ils contredisaient franchement les autres. Compté
    /// pour être DIT : un élagage silencieux priverait l'utilisateur du moyen de nous corriger.
    @Published private(set) var taDiscardedCount: Int = 0

    private let service: RadioLogsServicing
    private let identify: IdentifyServicing
    private let antennas: AntennasServicing

    /// Demi-côté de la fenêtre de recherche d'antennes voisines, en degrés.
    /// 0,027° ≈ 3 km en latitude — au-delà, on ne propose plus une antenne
    /// « voisine » mais un site au hasard dans la commune d'à côté.
    private let searchHalfSpan = 0.027

    init(service: RadioLogsServicing, identify: IdentifyServicing, antennas: AntennasServicing) {
        self.service = service
        self.identify = identify
        self.antennas = antennas
    }

    /// Anneaux du nœud, depuis le cache local du journal.
    ///
    /// Le filtre porte sur le NŒUD, pas sur la cellule : ce sont les relevés du même eNB,
    /// pris d'endroits différents, qui se croisent. Les prendre cellule par cellule
    /// donnerait des cercles trop peu nombreux pour désigner quoi que ce soit.
    private func loadTaRings(for site: RadioLogSite) {
        let entries = service.cachedSnapshot().entries.filter { entry in
            switch site.kind {
            case .enb: return entry.enb == site.node
            case .gnb: return entry.gnb == site.node
            }
        }
        let readings = entries.compactMap { entry -> TaRingSelection.Reading? in
            guard let latitude = entry.latitude, let longitude = entry.longitude else { return nil }
            return TaRingSelection.Reading(
                latitude: latitude,
                longitude: longitude,
                timingAdvance: entry.timingAdvance,
                accuracyMeters: nil,
                observedAt: entry.observedAt
            )
        }
        // Élagage : un TA peut être juste et décrire pourtant une AUTRE cellule (les mesures
        // d'une voisine collées à cette identité). Sur un cas réel, un seul anneau de ce genre
        // déplaçait le site estimé de 2,8 km. Ce qui est écarté est compté, jamais caché.
        let pruned = TaRingSelection.pruneOutliers(TaRingSelection.rings(for: readings))
        taRings = pruned.kept
        taDiscardedCount = pruned.discarded.count
        taAssessment = TaRingSelection.assess(pruned.kept)
    }

    func load(for site: RadioLogSite) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        loadTaRings(for: site)

        guard let latitude = site.latitude, let longitude = site.longitude else {
            // Sans position, ni le serveur ni nous ne pouvons proposer quoi que
            // ce soit d'honnête. On le dit, plutôt que d'afficher une liste vide.
            errorMessage = String(localized: "Aucun de ces relevés ne porte de position : impossible de proposer une antenne.")
            candidates = []
            return
        }

        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let market = RadioLogOperatorResolver.marketCode(forOperator: site.operatorName, mcc: site.mcc) ?? "FR"
        // Clé canonique, pas le nom brut du log : « Orange » ne filtre rien
        // côté carte, « ORANGE » oui. `ALL` quand on ne sait pas — mieux vaut
        // proposer les antennes de tous les opérateurs que zéro.
        let operatorKey = RadioLogOperatorResolver.operatorKey(forOperator: site.operatorName) ?? "ALL"

        async let hypothesisTask = service.hypothesis(for: site)
        async let nearbyTask = try? antennas.list(
            bbox: BoundingBox(
                north: latitude + searchHalfSpan,
                south: latitude - searchHalfSpan,
                east: longitude + searchHalfSpan / cos(latitude * .pi / 180),
                west: longitude - searchHalfSpan / cos(latitude * .pi / 180)
            ),
            market: market,
            operatorName: operatorKey,
            technologies: []
        )

        let hypothesis = await hypothesisTask
        let nearby = await nearbyTask ?? []

        var result: [RadioLogCandidate] = []
        var seen = Set<String>()

        if let hypothesis {
            seen.insert(hypothesis.siteId)
            result.append(
                RadioLogCandidate(
                    id: hypothesis.siteId,
                    siteId: hypothesis.siteId,
                    latitude: hypothesis.latitude,
                    longitude: hypothesis.longitude,
                    operators: [site.operatorName].compactMap { $0 },
                    technologies: [site.techLabel],
                    address: nil,
                    distanceMeters: hypothesis.distanceMeters,
                    confidenceScore: hypothesis.confidenceScore,
                    isServerHypothesis: true
                )
            )
        }

        for antenna in nearby where antenna.hasValidCoordinate {
            let siteId = antenna.siteId ?? antenna.id
            guard !siteId.isEmpty, seen.insert(siteId).inserted else { continue }
            guard let antennaLat = antenna.latitude, let antennaLng = antenna.longitude else { continue }
            let distance = origin.distance(from: CLLocation(latitude: antennaLat, longitude: antennaLng))
            result.append(
                RadioLogCandidate(
                    id: siteId,
                    siteId: siteId,
                    latitude: antennaLat,
                    longitude: antennaLng,
                    operators: antenna.operators,
                    technologies: antenna.technologies,
                    address: antenna.address,
                    distanceMeters: Int(distance.rounded()),
                    confidenceScore: nil,
                    isServerHypothesis: false
                )
            )
        }

        // La piste du serveur en tête, le reste par distance croissante.
        candidates = result.sorted { lhs, rhs in
            if lhs.isServerHypothesis != rhs.isServerHypothesis { return lhs.isServerHypothesis }
            return (lhs.distanceMeters ?? .max) < (rhs.distanceMeters ?? .max)
        }
        selectedId = candidates.first?.id
        if candidates.isEmpty {
            errorMessage = String(localized: "Aucune antenne connue à moins de 3 km de ces relevés.")
        }
    }

    /// Ajoute une antenne choisie À LA MAIN sur la carte et la sélectionne.
    ///
    /// Elle rejoint la liste au lieu de la remplacer : on doit pouvoir revenir
    /// sur les propositions du serveur après avoir regardé la carte, sans
    /// relancer la recherche.
    func addManualChoice(_ antenna: AntennaSite, origin: RadioLogSite) {
        let siteId = antenna.siteId ?? antenna.id
        guard !siteId.isEmpty else { return }
        if let existing = candidates.first(where: { $0.siteId == siteId }) {
            selectedId = existing.id
            return
        }
        var distance: Int?
        if let latitude = antenna.latitude, let longitude = antenna.longitude,
           let originLat = origin.latitude, let originLng = origin.longitude {
            distance = Int(
                CLLocation(latitude: originLat, longitude: originLng)
                    .distance(from: CLLocation(latitude: latitude, longitude: longitude))
                    .rounded()
            )
        }
        let candidate = RadioLogCandidate(
            id: siteId,
            siteId: siteId,
            latitude: antenna.latitude,
            longitude: antenna.longitude,
            operators: antenna.operators,
            technologies: antenna.technologies,
            address: antenna.address,
            distanceMeters: distance,
            confidenceScore: nil,
            isServerHypothesis: false
        )
        candidates.insert(candidate, at: 0)
        selectedId = candidate.id
        errorMessage = nil
    }

    /// Écrit l'identification. Retourne le `siteId` retenu, ou nil en cas d'échec
    /// (le message d'erreur est alors posé sur `errorMessage`).
    func submit(site: RadioLogSite) async -> String? {
        guard let selectedId, let candidate = candidates.first(where: { $0.id == selectedId }) else {
            errorMessage = String(localized: "Choisis une antenne avant de valider.")
            return nil
        }
        guard !isSubmitting else { return nil }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let result = try await identify.identify(Self.request(for: site, candidate: candidate))
            guard result.success else {
                errorMessage = result.message ?? String(localized: "Identification non confirmée par le serveur.")
                Haptics.error()
                return nil
            }
            Haptics.success()
            return result.siteId ?? candidate.siteId
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            return nil
        }
    }

    /// Construit la charge d'`identify/direct`.
    ///
    /// Tout ce que le serveur sait exploiter y est : le PLMN sous ses VRAIS noms
    /// (`mobileCountryCode`/`mobileNetworkCode` — sans eux c'est `MISSING_PLMN`),
    /// la techno, la bande, la porteuse, et l'identité de cellule complète en
    /// chaîne. `sectorIndex` est délibérément absent : la règle serveur (PSS
    /// Orange, cellId mod 3 SFR/Bouygues…) fait autorité sur tout calcul client.
    /// Pure : ni état, ni réseau. `nonisolated` pour que le test puisse la lire
    /// sans passer par le main actor — et parce qu'elle n'a rien d'un travail
    /// d'interface.
    nonisolated static func request(for site: RadioLogSite, candidate: RadioLogCandidate) -> IdentifyDirectRequest {
        // Cellule représentative : la plus relevée, donc la plus sûre.
        let cell = site.cells.max { $0.logCount < $1.logCount }
        let plmn: (mcc: String?, mnc: String?)
        if let mcc = site.mcc, let mnc = site.mnc {
            plmn = (mcc, mnc)
        } else if let fallback = RadioLogOperatorResolver.mccMnc(forOperator: site.operatorName) {
            plmn = (fallback.mcc, fallback.mnc)
        } else {
            plmn = (site.mcc, site.mnc)
        }

        return IdentifyDirectRequest(
            siteId: candidate.siteId,
            enb: site.kind == .enb ? site.node : nil,
            gnb: site.kind == .gnb ? site.node : nil,
            pci: cell?.pci,
            cellId: cell?.eciCellId,
            ci: cell?.ci.map(String.init),
            tech: site.techLabel,
            band: site.band ?? cell?.band,
            earfcn: site.earfcn ?? cell?.earfcn,
            // Clé canonique là aussi : le serveur ne lit `operator` que pour les
            // comptes privilégiés, mais quand il le lit, il le compare à des clés.
            operatorName: RadioLogOperatorResolver.operatorKey(forOperator: site.operatorName) ?? site.operatorName,
            mcc: plmn.mcc,
            mnc: plmn.mnc,
            latitude: site.latitude,
            longitude: site.longitude
        )
    }

    /// Ce qui manque, en clair, pour que l'identification ne parte pas vers un
    /// échec prévisible. Nil = la charge est complète.
    nonisolated static func blockingReason(for site: RadioLogSite) -> String? {
        let hasPlmn = (site.mcc != nil && site.mnc != nil)
            || RadioLogOperatorResolver.mccMnc(forOperator: site.operatorName) != nil
        if !hasPlmn {
            return String(localized: "Opérateur du relevé inconnu : le serveur ne peut pas rattacher cette identification.")
        }
        if !site.hasCoordinate {
            return String(localized: "Aucun de ces relevés ne porte de position.")
        }
        return nil
    }
}
