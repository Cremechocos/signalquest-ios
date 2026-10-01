import Foundation

/// Message système vérifié d'une conversation v2 (§2.5, §2.7, D.4) : ce que dit
/// la chaîne d'appartenance gardée par l'appareil, déjà vérifiée, jamais ce
/// qu'annonce le serveur. La genèse se résume à qui a activé le chiffrement et,
/// dans un groupe, à ses admins : un nouvel arrivant voit la conversation que
/// fixent les signatures, et qui l'y a fait entrer (premier contact, §3.5).
struct E2EEV2MembershipEvent: Equatable, Identifiable {
    enum Kind: Equatable {
        case enabled(by: String)
        case admins([String])
        case added(String, by: String)
        case removed(String, by: String)
        case left(String)
        case madeAdmin(String, by: String)
        case adminRoleRemoved(String, by: String)
        case browsersExcluded(by: String)
        case browsersAllowed(by: String)
    }

    /// Changement signé qui l'annonce : l'ordre des événements est celui de la chaîne.
    let changeNumber: Int
    let kind: Kind
    /// Heure signée par l'auteur du changement (D.4), pour placer l'événement
    /// dans le fil.
    let atMs: Int64
    let text: String

    var id: String { "membership-\(changeNumber)" }
}

enum E2EEV2MembershipEvents {
    /// La chaîne gardée, vérifiée quand l'appareil l'a acceptée, relue en changements.
    static func changes(from chain: [E2EEV2SignedString]) throws -> [E2EEV2MembershipChange] {
        var previous: String?
        return try chain.map { item in
            let change = try E2EEV2MembershipChange.parse(item.canonical, previousCanonical: previous)
            previous = item.canonical
            return change
        }
    }

    /// `members` : nom de chaque utilisateur, comme pour le fil. Un changement
    /// sans effet (rôle déjà tenu, réglage déjà en place) n'annonce rien.
    static func present(
        _ changes: [E2EEV2MembershipChange],
        genesisLength: Int,
        isGroup: Bool,
        ownUserId: String,
        members: [String: MessageUser],
        bundle: Bundle = .main
    ) -> [E2EEV2MembershipEvent] {
        let names = Names(ownUserId: ownUserId, members: members, bundle: bundle)
        let genesisAdmins = changes
            .filter { $0.changeNumber <= genesisLength && $0.action == "ROLE_ADMIN" }
            .map(\.targetUserId)
        var events: [E2EEV2MembershipEvent] = []
        var admins = Set(genesisAdmins)
        var excludesWeb = false
        for change in changes {
            let actor = change.actorUserId, target = change.targetUserId
            var kind: E2EEV2MembershipEvent.Kind?
            if change.changeNumber <= genesisLength {
                switch change.action {
                case "ADD" where change.changeNumber == 1: kind = .enabled(by: actor)
                case "ROLE_ADMIN" where target == genesisAdmins.first: kind = .admins(genesisAdmins)
                case "EXCLUDE_WEB_ON": excludesWeb = true; kind = .browsersExcluded(by: actor)
                default: break
                }
            } else {
                switch change.action {
                case "ADD": kind = .added(target, by: actor)
                case "REMOVE": admins.remove(target); kind = .removed(target, by: actor)
                case "LEAVE": admins.remove(actor); kind = .left(actor)
                case "ROLE_ADMIN" where !admins.contains(target):
                    admins.insert(target); kind = .madeAdmin(target, by: actor)
                case "ROLE_MEMBER" where admins.contains(target):
                    admins.remove(target); kind = .adminRoleRemoved(target, by: actor)
                case "EXCLUDE_WEB_ON" where !excludesWeb: excludesWeb = true; kind = .browsersExcluded(by: actor)
                case "EXCLUDE_WEB_OFF" where excludesWeb: excludesWeb = false; kind = .browsersAllowed(by: actor)
                default: break
                }
            }
            if let kind {
                events.append(E2EEV2MembershipEvent(
                    changeNumber: change.changeNumber, kind: kind, atMs: change.createdAtMs,
                    text: names.text(kind, isGroup: isGroup)
                ))
            }
        }
        return events
    }

    /// Les phrases se tournent sans accord de genre : « t’a fait entrer »,
    /// « t’a donné le rôle d’admin », jamais « t’a ajouté(e) ».
    private struct Names {
        let ownUserId: String
        let members: [String: MessageUser]
        let bundle: Bundle

        func isOwn(_ userId: String) -> Bool { userId == ownUserId }

        /// En tête de phrase.
        func subject(_ userId: String) -> String {
            name(userId) ?? String(localized: "Un membre", bundle: bundle)
        }

        func object(_ userId: String) -> String {
            name(userId) ?? String(localized: "un membre", bundle: bundle)
        }

        private func name(_ userId: String) -> String? {
            let name = members[userId]?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }

        func text(_ kind: E2EEV2MembershipEvent.Kind, isGroup: Bool) -> String {
            switch kind {
            case .enabled(let by):
                return isOwn(by)
                    ? String(localized: "Tu as activé le chiffrement de bout en bout de cette conversation.", bundle: bundle)
                    : String(localized: "\(subject(by)) a activé le chiffrement de bout en bout de cette conversation.", bundle: bundle)
            case .admins(let userIds):
                let list = userIds
                    .map { isOwn($0) ? String(localized: "toi", bundle: bundle) : object($0) }
                    .joined(separator: ", ")
                return String(localized: "Admins : \(list).", bundle: bundle)
            case .added(let user, let by):
                if isOwn(by) { return String(localized: "Tu as ajouté \(object(user)).", bundle: bundle) }
                if isOwn(user) { return String(localized: "\(subject(by)) t’a fait entrer dans le groupe.", bundle: bundle) }
                return String(localized: "\(subject(by)) a ajouté \(object(user)).", bundle: bundle)
            case .removed(let user, let by):
                if isOwn(by) { return String(localized: "Tu as retiré \(object(user)) du groupe.", bundle: bundle) }
                if isOwn(user) { return String(localized: "\(subject(by)) t’a fait sortir du groupe.", bundle: bundle) }
                return String(localized: "\(subject(by)) a retiré \(object(user)) du groupe.", bundle: bundle)
            case .left(let user):
                if isGroup {
                    return isOwn(user)
                        ? String(localized: "Tu as quitté le groupe.", bundle: bundle)
                        : String(localized: "\(subject(user)) a quitté le groupe.", bundle: bundle)
                }
                return isOwn(user)
                    ? String(localized: "Tu as quitté la conversation.", bundle: bundle)
                    : String(localized: "\(subject(user)) a quitté la conversation.", bundle: bundle)
            case .madeAdmin(let user, let by):
                if isOwn(by) { return String(localized: "Tu as nommé \(object(user)) admin.", bundle: bundle) }
                if isOwn(user) { return String(localized: "\(subject(by)) t’a donné le rôle d’admin.", bundle: bundle) }
                return String(localized: "\(subject(by)) a nommé \(object(user)) admin.", bundle: bundle)
            case .adminRoleRemoved(let user, let by) where user == by:
                return isOwn(by)
                    ? String(localized: "Tu as renoncé au rôle d’admin.", bundle: bundle)
                    : String(localized: "\(subject(by)) a renoncé au rôle d’admin.", bundle: bundle)
            case .adminRoleRemoved(let user, let by):
                if isOwn(by) { return String(localized: "Tu as retiré le rôle d’admin à \(object(user)).", bundle: bundle) }
                if isOwn(user) { return String(localized: "\(subject(by)) t’a retiré le rôle d’admin.", bundle: bundle) }
                return String(localized: "\(subject(by)) a retiré le rôle d’admin à \(object(user)).", bundle: bundle)
            case .browsersExcluded(let by):
                return isOwn(by)
                    ? String(localized: "Tu as exclu les navigateurs de cette conversation.", bundle: bundle)
                    : String(localized: "\(subject(by)) a exclu les navigateurs de cette conversation.", bundle: bundle)
            case .browsersAllowed(let by):
                return isOwn(by)
                    ? String(localized: "Tu as de nouveau autorisé les navigateurs dans cette conversation.", bundle: bundle)
                    : String(localized: "\(subject(by)) a de nouveau autorisé les navigateurs dans cette conversation.", bundle: bundle)
            }
        }
    }
}
