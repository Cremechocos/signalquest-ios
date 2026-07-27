import Foundation

/// Onglets du fil communautaire.
///
/// Le backend accepte **11 filtres, 3 rankings et 2 portées** depuis le début ;
/// iOS envoyait `filter=all` + `ranking=smart` en dur et n'exposait donc qu'une
/// seule des combinaisons possibles. Ces onglets n'ajoutent aucun écran : ils
/// rendent atteignable ce que le serveur sait déjà faire.
///
/// Volontairement RESTREINT à six entrées. Le backend en autorise davantage
/// (`liked`, `reposted`, `posts`, `media`…), mais une barre d'onglets qui défile
/// sur deux écrans ne se lit plus. Les filtres restants relèvent d'un écran de
/// recherche, pas de la navigation principale.
enum FeedTab: String, CaseIterable, Identifiable, Sendable {
    case forYou
    case latest
    case following
    case friends
    case telecom
    case saved

    var id: String { rawValue }

    /// Valeur du paramètre `filter` attendue par `/api/social/feed`.
    var filter: String {
        switch self {
        case .forYou, .latest: return "all"
        case .following: return "following"
        case .friends: return "friends"
        case .telecom: return "telecom"
        case .saved: return "saved"
        }
    }

    /// Valeur du paramètre `ranking`.
    ///
    /// « Pour toi » est le SEUL à demander `foryou` : c'est le classement nourri
    /// par les signaux d'engagement. Les autres gardent `smart`, qui reste un
    /// bon défaut hors personnalisation, sauf « Récent » qui doit être
    /// strictement chronologique.
    var ranking: String {
        switch self {
        case .forYou: return "foryou"
        case .latest: return "latest"
        default: return "smart"
        }
    }

    var title: String {
        switch self {
        case .forYou: return "Pour toi"
        case .latest: return "Récent"
        case .following: return "Abonnements"
        case .friends: return "Amis"
        case .telecom: return "Réseau"
        case .saved: return "Enregistrés"
        }
    }

    var systemImage: String {
        switch self {
        case .forYou: return "sparkles"
        case .latest: return "clock"
        case .following: return "person.badge.plus"
        case .friends: return "person.2"
        case .telecom: return "antenna.radiowaves.left.and.right"
        case .saved: return "bookmark"
        }
    }

    /// Message d'état vide propre à l'onglet — « Ton fil est encore vide » est
    /// faux et décourageant sur « Amis » quand on n'a simplement pas d'amis.
    var emptyMessage: String {
        switch self {
        case .forYou: return "Lance quelques speedtests et suis des membres : les recommandations arrivent vite."
        case .latest: return "Aucune publication récente pour l'instant."
        case .following: return "Tu ne suis encore personne. Explore les profils pour remplir cet onglet."
        case .friends: return "Aucune publication de tes amis pour l'instant."
        case .telecom: return "Aucune mesure ni identification partagée récemment."
        case .saved: return "Touche le marque-page d'une publication pour la retrouver ici."
        }
    }
}
