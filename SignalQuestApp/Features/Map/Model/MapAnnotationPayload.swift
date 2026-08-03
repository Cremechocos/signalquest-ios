import SwiftUI
import CoreLocation
import MapKit

/// Données riches d'un ami géolocalisé pour le rendu « Find My » (avatar +
/// anneau de présence + cône de cap + badge techno). Portées par le payload afin
/// que la `MKAnnotationView` les rende sans dépendre du reste du modèle.
struct FriendAnnotationInfo: Equatable {
    let userId: String
    let displayName: String
    let avatarURL: URL?
    let presence: SocialPresenceStatus
    /// Cap en degrés (0 = nord), nil si indisponible → aucun cône dessiné.
    let heading: Double?
    let speedMps: Double?
    let accuracyMeters: Double?
    let technology: String?
    let operatorName: String?
    /// Position périmée (> TTL serveur) : marqueur rendu estompé. On NE porte PAS
    /// `updatedAt` ici : il changerait à chaque relevé et recréerait inutilement
    /// l'annotation (annulant le chargement async de l'avatar). La fraîcheur exacte
    /// est lue depuis le `SocialFriendLive` par la fiche.
    let isStale: Bool
}

struct MapAnnotationPayload: Identifiable, Equatable {
    let id: String
    let kind: MapDisplayItem.Kind
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let metric: String?
    let backendId: String?
    let details: MapItemDetails?
    let antennaId: String?
    let clusterCount: Int?
    let azimuths: [Double]
    let showsAzimuths: Bool
    /// Couleur registry de l'opérateur ; prioritaire sur les heuristiques de
    /// `markerColor` quand elle est connue.
    var tint: Color? = nil
    /// Cellule communautaire seulement « observée » (vs site probable) : rendu
    /// plus translucide pour signaler une confiance moindre.
    var communityObserved: Bool = false
    /// Vignette à afficher directement sur la carte (couche Photos) : le marqueur
    /// devient une mini-photo « polaroïd » au lieu d'une pastille.
    var thumbnailURL: URL? = nil
    /// Statut d'activation d'un site prévisionnel : pilote l'anneau + le badge
    /// (actif ✓ / upgrade ↑ / déclaré / prévu).
    var plannedStatus: PlannedActivationStatus? = nil
    /// Glyphe SF Symbol forcé (ex. pannes colorées par type d'incident).
    var glyphOverride: String? = nil
    /// Nombre de photos publiques sur le site (antennes) → badge appareil-photo.
    var contributionPhotos: Int = 0
    /// eNB du site identifié par la communauté → coche verte sur le marqueur.
    var hasEnb: Bool = false
    /// gNB identifié → l'anneau 5G passe au vert (sinon il reste à la couleur
    /// opérateur : le site émet en 5G, mais personne ne l'a encore identifiée).
    var hasGnb: Bool = false
    /// Le site porte de la 5G → anneau fin autour de la pastille.
    var has5G: Bool = false
    /// Longueur des lobes d'azimut, en points d'écran. 0 = pas de lobes. Croît
    /// avec le zoom : à z14 les sites sont serrés à l'écran et des lobes longs se
    /// recouvriraient ; plus on zoome, plus il y a de place pour les déployer.
    var azimuthReachPoints: CGFloat = 0
    /// Données d'un ami vivant (couche Amis) : pilote le rendu « Find My ».
    var friend: FriendAnnotationInfo? = nil

    /// Étiquette VoiceOver du marqueur : sans elle, antennes/clusters/speedtests/
    /// amis/photos sont des éléments anonymes non lisibles (A11Y-03/T1-6).
    var accessibilityLabel: String {
        if let count = clusterCount, count > 1 {
            return String(localized: "Groupe de \(count) éléments. \(title)")
        }
        var parts = [title]
        if !subtitle.isEmpty { parts.append(subtitle) }
        if let metric, !metric.isEmpty { parts.append(metric) }
        return parts.joined(separator: ", ")
    }

    static func == (lhs: MapAnnotationPayload, rhs: MapAnnotationPayload) -> Bool {
        lhs.id == rhs.id &&
        lhs.kind == rhs.kind &&
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.metric == rhs.metric &&
        lhs.backendId == rhs.backendId &&
        lhs.details == rhs.details &&
        lhs.antennaId == rhs.antennaId &&
        lhs.clusterCount == rhs.clusterCount &&
        lhs.azimuths == rhs.azimuths &&
        lhs.showsAzimuths == rhs.showsAzimuths &&
        lhs.tint == rhs.tint &&
        lhs.communityObserved == rhs.communityObserved &&
        lhs.thumbnailURL == rhs.thumbnailURL &&
        lhs.plannedStatus == rhs.plannedStatus &&
        lhs.glyphOverride == rhs.glyphOverride &&
        lhs.contributionPhotos == rhs.contributionPhotos &&
        lhs.hasEnb == rhs.hasEnb &&
        lhs.hasGnb == rhs.hasGnb &&
        lhs.has5G == rhs.has5G &&
        lhs.azimuthReachPoints == rhs.azimuthReachPoints &&
        lhs.friend == rhs.friend
    }
}

extension MapAnnotationPayload {
    var markerColor: Color {
        // La couleur registry de l'opérateur prime quand elle est connue
        // (antennes, sites communautaires).
        if let tint { return tint }
        if kind == .antenna {
            // TEL-MAP-02 : couleur de marque via la résolution tolérante SQBrand
            // (Orange/Free/SFR/Bouygues + ultramarins) au lieu d'une déduction par
            // sous-chaîne qui renvoyait Orange ET Free en rouge.
            return SQBrand.operatorColor(subtitle)
        }
        switch kind {
        case .speedtest:
            return speedtestColor(downloadMbps: firstNumber(in: title) ?? 0)
        case .photo: return SQColor.brandPink
        case .friend: return SQColor.brandBlue
        case .coverage:
            return coverageColor(rsrp: firstNumber(in: subtitle).map { -abs($0) })
        case .validation: return SQColor.brandGreen
        case .outage: return .red
        case .planned: return SQColor.brandBlue
        case .session: return SQColor.brandOrange
        case .antenna: return .red
        case .communitySite: return SQColor.brandPink
        // Site pointé à la main : rose communautaire quand l'opérateur saisi n'a
        // pas pu être résolu en couleur de marque (`tint` absent).
        case .customSite: return SQColor.brandPink
        }
    }

    func firstNumber(in text: String) -> Double? {
        let pattern = #"[-+]?\d+(?:[.,]\d+)?"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: "."))
    }

    /// Échelle de couleur des speedtests — alignée sur le web
    /// (`lib/speedColorUtils.ts` SPEED_THRESHOLDS) : rouge → orange → jaune →
    /// vert clair → vert → cyan → bleu.
    func speedtestColor(downloadMbps: Double) -> Color {
        switch downloadMbps {
        case 1000...:      return Color(hex: 0x3B82F6) // exceptionnel
        case 600..<1000:   return Color(hex: 0x06B6D4) // excellent
        case 300..<600:    return Color(hex: 0x22C55E) // très bon
        case 100..<300:    return Color(hex: 0x84CC16) // bon
        case 30..<100:     return Color(hex: 0xEAB308) // moyen
        case 10..<30:      return Color(hex: 0xF97316) // lent
        default:           return Color(hex: 0xEF4444) // très lent
        }
    }

    /// Échelle de couleur de couverture par RSRP — alignée sur le web
    /// (`lib/signal-quality.ts` QUALITY_HEX / RSRP_SCALE).
    func coverageColor(rsrp: Double?) -> Color {
        guard let rsrp else { return Color(hex: 0x94A3B8) } // none
        switch rsrp {
        case (-80)...:        return Color(hex: 0x10B981) // excellent
        case -90..<(-80):     return Color(hex: 0x84CC16) // bon
        case -100..<(-90):    return Color(hex: 0xF59E0B) // moyen
        case -110..<(-100):   return Color(hex: 0xF97316) // faible
        default:              return Color(hex: 0xEF4444) // très faible
        }
    }
}
