import Foundation

/// Sondage attaché à une publication du fil.
///
/// Modèle DISTINCT de `MessagePoll` — la tentation de réutiliser ce dernier est
/// forte, mais le backend ne sert pas la même forme : le fil expose `label`,
/// `votesCount`, `votedByMe` et `allowMultiple` là où la messagerie expose
/// `text`, `count`, `votesByMe` et `multiSelect`. Un modèle commun exigerait des
/// `CodingKeys` divergents et deux chemins de décodage dans le même type, pour
/// une économie nulle.
struct FeedPoll: Codable, Equatable {
    let id: String
    let question: String?
    let expiresAt: Date?
    let allowMultiple: Bool
    let totalVotes: Int
    let hasExpired: Bool
    let options: [Option]

    struct Option: Codable, Equatable, Identifiable {
        let id: String
        let label: String
        let position: Int
        let votesCount: Int
        let votedByMe: Bool
    }

    /// Un sondage clos n'accepte plus de vote — le serveur refuserait, autant ne
    /// pas proposer l'action.
    var isOpen: Bool { !hasExpired }

    var hasVoted: Bool { options.contains(where: \.votedByMe) }

    /// Part d'un choix, entre 0 et 1. Renvoie 0 sans vote plutôt que `NaN` :
    /// une division par zéro remonterait jusqu'à un `frame` SwiftUI et
    /// planterait le rendu.
    func share(of option: Option) -> Double {
        guard totalVotes > 0 else { return 0 }
        return Double(option.votesCount) / Double(totalVotes)
    }

    /// Options triées pour l'affichage. Le backend renvoie déjà `position`, mais
    /// s'y fier sans trier laisserait l'ordre à la merci de la sérialisation.
    var orderedOptions: [Option] { options.sorted { $0.position < $1.position } }
}
