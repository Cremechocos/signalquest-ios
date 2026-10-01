import SwiftUI
import CoreLocation
import MapKit

/// Politique de rendu de la couche couverture selon le zoom (pure & testable).
/// Points bruts dès le « zoom ville » (~z11) ; clusters seulement au niveau région/pays.
/// Caps relevés pour ne plus tronquer les points (bug « points qui disparaissent au zoom »).
enum CoverageRenderPolicy {
    /// Zoom à partir duquel le CLIENT demande les points bruts (`detail=points`) ; en
    /// dessous, des clusters (`detail=overview`). « Zoom ville ». Seuil iOS uniquement —
    /// Android a sa propre constante (z13), qu'on ne touche pas.
    static let rawPointsFromZoom = 11
    /// Plafond de points bruts par tuile (= `limit` demandé au backend). Unifié quel que
    /// soit le zoom — fini la dégradation 900→250 qui masquait ~75 % des points au dézoom.
    static let pointCapPerTile = 2500
    /// Plafond du repli `/api/coverage/points` (bbox, sans tuiles).
    static let fallbackCap = 6000

    /// Rendu piloté par la DONNÉE reçue (robuste quel que soit le zoom / le seuil de
    /// fetch) : on affiche les points bruts s'il y en a (ou si un filtre bande est actif),
    /// sinon les clusters. Mutuellement exclusifs.
    static func mode(for tile: AndroidCoverageTileResponse, selectedBands: Set<Int>) -> (useClusters: Bool, useRawPoints: Bool) {
        let verified = tile.stats?.appliedBandFilter?.matches(selectedBands) == true
        return mode(hasPoints: !tile.points.isEmpty, hasClusters: !tile.clusters.isEmpty,
                    hasBandFilter: !selectedBands.isEmpty && !verified)
    }

    static func matches(_ point: AndroidCoveragePoint, selectedBands: Set<Int>) -> Bool {
        guard !selectedBands.isEmpty else { return true }
        let observed = Set((point.bands ?? []) + (point.band.map { [$0] } ?? []))
        return !observed.isDisjoint(with: selectedBands)
    }

    /// Raw legacy points remain locally filterable. An aggregate or empty legacy
    /// response cannot claim that the server honored the selected bands.
    static func validate(_ tile: AndroidCoverageTileResponse, selectedBands: Set<Int>) throws {
        guard !selectedBands.isEmpty else { return }
        if let applied = tile.stats?.appliedBandFilter {
            guard applied.matches(selectedBands) else { throw CoverageBandFilterUnavailable() }
        } else if tile.points.isEmpty {
            throw CoverageBandFilterUnavailable()
        }
    }

    static func mode(hasPoints: Bool, hasClusters: Bool, hasBandFilter: Bool) -> (useClusters: Bool, useRawPoints: Bool) {
        let useRawPoints = hasPoints || hasBandFilter
        let useClusters = hasClusters && !useRawPoints
        return (useClusters, useRawPoints)
    }
}

enum CoverageQualityBand: String, CaseIterable, Identifiable {
    case excellent
    case good
    case fair
    case weak
    case poor
    /// « Sans réseau constaté » : dessiné hachuré, distinct de « pas de mesure ».
    case noService
    case unknown

    var id: String { rawValue }

    static var visibleBands: [CoverageQualityBand] {
        [.excellent, .good, .fair, .weak, .poor, .noService]
    }

    /// Un RSRP déjà connu comme tel : `SQQualityScale.Signal(rsrp:)`.
    static func band(for rsrp: Double?) -> CoverageQualityBand {
        band(SQQualityScale.Signal(rsrp: rsrp))
    }

    /// Un point de la carte : seuils de sa technologie, « sans réseau constaté »
    /// avant toute valeur (contrat quality-scale v1).
    static func band(forDbm dbm: Double?, technology: String?) -> CoverageQualityBand {
        band(SQQualityScale.Signal(dbm: dbm, technology: technology))
    }

    private static func band(_ signal: SQQualityScale.Signal) -> CoverageQualityBand {
        switch signal {
        case .excellent: return .excellent
        case .good: return .good
        case .fair: return .fair
        case .weak: return .weak
        case .poor: return .poor
        case .noService: return .noService
        case .unknown: return .unknown
        }
    }

    var isHatched: Bool { scale.isHatched }

    private var scale: SQQualityScale.Signal {
        switch self {
        case .excellent: return .excellent
        case .good: return .good
        case .fair: return .fair
        case .weak: return .weak
        case .poor: return .poor
        case .noService: return .noService
        case .unknown: return .unknown
        }
    }

    var title: String { scale.label }

    var colorHex: UInt32 { scale.hex }
    var swiftUIColor: Color { scale.color }
    var uiColor: UIColor { scale.uiColor }
}

/// Bandes de GÉNÉRATION pour la couche couverture (mode « génération », distinct du
/// RSRP). Couleurs alignées sur la carte « Mes mesures » (SessionGenerationColor) :
/// 5G violet · 4G bleu · 3G sarcelle · 2G ardoise · gris (aucun/inconnu).
enum CoverageGenerationBand: String, CaseIterable, Identifiable {
    case g5, g4, g3, g2, none

    var id: String { rawValue }

    static var visibleBands: [CoverageGenerationBand] { [.g5, .g4, .g3, .g2, .none] }

    static func band(for tech: String?) -> CoverageGenerationBand {
        switch SQQualityScale.Generation(technology: tech) {
        case .fiveG: return .g5
        case .fourG: return .g4
        case .threeG: return .g3
        case .twoG: return .g2
        case .none: return .none
        }
    }

    private var scale: SQQualityScale.Generation {
        switch self {
        case .g5: return .fiveG
        case .g4: return .fourG
        case .g3: return .threeG
        case .g2: return .twoG
        case .none: return .none
        }
    }

    /// Rang de priorité pour élire la génération dominante d'un lieu
    /// (5G > 4G > 3G > 2G > aucun). Sert à ne conserver qu'UNE pastille par point
    /// logique en 5G NSA, où le backend renvoie des frères co-localisés (ancre
    /// LTE taguée « 4G » + cellule NR taguée « 5G »).
    var rank: Int { scale.rank }

    var title: String { scale.label }

    /// « LTE » au Canada et aux États-Unis, comme le filtre : un testeur de
    /// Montréal lisait « 4G » dans la légende (UI-02).
    func title(forMarket code: String?) -> String {
        guard self == .g4, let code else { return title }
        return MapFilterCatalog.technologies(forMarket: code).first { $0.value == "4G" }?.label ?? title
    }

    var colorHex: UInt32 { scale.hex }

    var swiftUIColor: Color { Color(hex: colorHex) }
}

/// Paliers de débit descendant pour colorer la couche dense des speedtests —
/// échelle identique au web (`speedColorUtils.ts`) et à Android : rouge → orange
/// → jaune → vert clair → vert → cyan → bleu.
enum SpeedBand: String, CaseIterable {
    case verySlow
    case slow
    case medium
    case good
    case veryGood
    case excellent
    case exceptional

    static func band(forDownload mbps: Double) -> SpeedBand {
        switch SQQualityScale.Throughput(mbps: mbps) {
        case .exceptional: return .exceptional
        case .excellent: return .excellent
        case .veryGood: return .veryGood
        case .good: return .good
        case .medium: return .medium
        case .slow: return .slow
        case .verySlow: return .verySlow
        }
    }

    var uiColor: UIColor {
        let scale: SQQualityScale.Throughput
        switch self {
        case .exceptional: scale = .exceptional
        case .excellent: scale = .excellent
        case .veryGood: scale = .veryGood
        case .good: scale = .good
        case .medium: scale = .medium
        case .slow: scale = .slow
        case .verySlow: scale = .verySlow
        }
        return scale.uiColor
    }
}

struct CoverageBandFilterUnavailable: Error, LocalizedError {
    var errorDescription: String? {
        String(localized: "Le filtre de fréquence n’est pas disponible pour ces données. Zoome ou retire ce filtre pour les consulter.")
    }
}
