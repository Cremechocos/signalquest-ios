import CoreLocation
import Foundation

/// Onglets du fil communautaire.
///
/// Le backend accepte **11 filtres, 3 rankings et 2 portées** depuis le début ;
/// iOS envoyait `filter=all` + `ranking=smart` en dur et n'exposait donc qu'une
/// seule des combinaisons possibles. Ces onglets n'ajoutent aucun écran : ils
/// rendent atteignable ce que le serveur sait déjà faire.
///
/// Quatre onglets sans recoupement (choix d'Alexandre du 24/11 à 19:29) : « Récent »
/// n'était que « Pour toi » trié par date, un ami est forcément suivi, et « Réseau »
/// reprenait les mesures déjà mêlées à « Pour toi ». « Enregistrés » vit dans le menu ⋯.
enum FeedTab: String, CaseIterable, Identifiable, Sendable {
    case forYou
    case following
    case nearby
    case photos
    case saved

    var id: String { rawValue }

    /// Valeur du paramètre `filter` attendue par `/api/social/feed`.
    var filter: String {
        switch self {
        case .forYou: return "all"
        // Les amis compris : un ami est forcément suivi.
        case .following: return "following"
        // Publications à 30 km du point envoyé (NEARBY-FEED-1), comme Android et le Web.
        case .nearby: return "nearby"
        // `media` : le backend l'accepte depuis le début, iOS ne l'exposait pas.
        // Il ne rend que les publications porteuses d'une image ou d'une vidéo.
        case .photos: return "media"
        case .saved: return "saved"
        }
    }

    /// Valeur du paramètre `ranking`.
    ///
    /// « Pour toi » est le SEUL à demander `foryou` : c'est le classement nourri
    /// par les signaux d'engagement. « Suivis » est strictement chronologique, comme
    /// le fil des abonnements de toute app sociale. Les autres gardent `smart`.
    var ranking: String {
        switch self {
        case .forYou: return "foryou"
        case .following: return "latest"
        default: return "smart"
        }
    }

    /// L'onglet envoie la position (arrondie) de l'appareil.
    var needsPosition: Bool { self == .nearby }

    var title: String {
        switch self {
        case .forYou: return "Pour toi"
        case .following: return "Suivis"
        case .nearby: return "Autour"
        case .photos: return "Photos"
        case .saved: return "Enregistrés"
        }
    }

    var systemImage: String {
        switch self {
        case .forYou: return "sparkles"
        case .following: return "person.2"
        case .nearby: return "location"
        case .photos: return "photo.on.rectangle.angled"
        case .saved: return "bookmark"
        }
    }

    /// Cet onglet se rend en GRILLE et non en cartes.
    ///
    /// Une galerie se parcourt à l'œil : trois vignettes par ligne montrent en un
    /// écran ce que six cartes pleine largeur mettraient six écrans à révéler. Le
    /// reste du fil garde ses cartes, où le texte et les métriques comptent.
    var rendersAsGallery: Bool { self == .photos }

    /// Message d'état vide propre à l'onglet — « Ton fil est encore vide » est
    /// faux et décourageant sur « Amis » quand on n'a simplement pas d'amis.
    var emptyMessage: String {
        switch self {
        case .forYou: return "Lance quelques speedtests et suis des membres : les recommandations arrivent vite."
        case .following: return "Tu ne suis encore personne. Explore les profils pour remplir cet onglet."
        case .nearby: return "Rien n’a été partagé à moins de 30 km ces derniers temps."
        case .photos: return "Aucune photo partagée pour l'instant. Ajoute-en une depuis une antenne ou une publication."
        case .saved: return "Enregistre une publication pour la retrouver ici."
        }
    }
}

/// Point de l'onglet « Autour », arrondi au centième de degré (environ 1 km) AVANT d'être envoyé :
/// le serveur l'arrondit aussi, la position exacte ne quitte jamais l'appareil.
struct FeedNearPoint: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = (coordinate.latitude * 100).rounded() / 100
        longitude = (coordinate.longitude * 100).rounded() / 100
    }

    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "lat", value: String(format: "%.2f", latitude)),
         URLQueryItem(name: "lng", value: String(format: "%.2f", longitude))]
    }
}
