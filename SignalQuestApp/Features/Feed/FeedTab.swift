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
    /// le fil des abonnements de toute app sociale. « Autour » aussi, par défaut (plan
    /// Fil Communauté validé le 24/11, comme le Web) : on y cherche ce qui vient de se
    /// passer près de soi. Les autres gardent `smart`.
    var ranking: String {
        switch self {
        case .forYou: return "foryou"
        case .following, .nearby: return "latest"
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

    /// Titre d'état vide propre à l'onglet, commun au Web et à Android (plan Fil
    /// Communauté du 24/11). « Autour » a le sien, qui porte le rayon servi.
    var emptyTitle: String {
        switch self {
        case .forYou: return "Ton fil est encore vide"
        case .following: return "Tu ne suis encore personne"
        case .nearby: return "Rien ici pour l’instant"
        case .photos: return "Aucune photo pour l’instant"
        case .saved: return "Rien ici pour l’instant"
        }
    }

    /// Message d'état vide propre à l'onglet — « Ton fil est encore vide » est
    /// faux et décourageant sur « Amis » quand on n'a simplement pas d'amis.
    var emptyMessage: String {
        switch self {
        case .forYou: return "Lance quelques speedtests et suis des membres : les recommandations arrivent vite."
        case .following: return "Les publications des profils que tu suis arriveront ici, de la plus récente à la plus ancienne."
        case .nearby: return "Rien n’a été partagé à moins de 30 km ces derniers temps."
        case .photos: return "Aucune photo partagée pour l'instant. Ajoute-en une depuis une antenne ou une publication."
        case .saved: return "Enregistre une publication pour la retrouver ici."
        }
    }
}

/// Tri d'un onglet, préférence `feedSort` du compte (contrat feedSort v1, Fil Communauté C8) :
/// « Pertinence » ou « Récent ». Un choix vaut pour le compte, sur toutes ses apps.
enum FeedSortChoice: String, CaseIterable, Sendable {
    case relevance
    case latest
}

extension FeedTab {
    /// Clé de l'onglet dans `feedSort` ; nil pour un onglet sans choix de tri (Suivis est
    /// toujours chronologique, Enregistrés garde son ordre).
    var sortKey: String? {
        switch self {
        case .forYou: return "forYou"
        case .nearby: return "nearby"
        case .photos: return "photos"
        case .following, .saved: return nil
        }
    }

    /// Défaut du serveur tant que le membre n'a rien choisi (choix d'Alexandre du 24/11).
    var defaultSort: FeedSortChoice { self == .nearby || self == .following ? .latest : .relevance }

    /// `ranking` envoyé pour un tri : « Récent » = `latest` ; « Pertinence » = `foryou` sur
    /// Pour toi, `smart` sur Autour et Photos. Sans choix, le tri par défaut de l'onglet.
    func ranking(for sort: FeedSortChoice?) -> String {
        guard sortKey != nil else { return ranking }
        switch sort ?? defaultSort {
        case .latest: return "latest"
        case .relevance: return self == .forYou ? "foryou" : "smart"
        }
    }

    /// `rankWindow=1` (contrat B3 v1.1) : la Pertinence classée sur toute la fenêtre de
    /// candidats, demandée sur toutes les pages d'un onglet réglé sur Pertinence.
    func sendsRankWindow(for sort: FeedSortChoice?) -> Bool {
        sortKey != nil && (sort ?? defaultSort) == .relevance
    }

    /// Fil chronologique : séparateurs de jour et heure exacte au-delà de 24 h.
    func isChronological(for sort: FeedSortChoice?) -> Bool { ranking(for: sort) == "latest" }

    /// Lit `feedSort` tel que servi ; une clé ou une valeur inconnue est ignorée (défaut).
    static func sortPreference(from raw: [String: String]?) -> [FeedTab: FeedSortChoice] {
        var result: [FeedTab: FeedSortChoice] = [:]
        for tab in FeedTab.allCases {
            if let key = tab.sortKey, let value = raw?[key].flatMap(FeedSortChoice.init(rawValue:)) {
                result[tab] = value
            }
        }
        return result
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
