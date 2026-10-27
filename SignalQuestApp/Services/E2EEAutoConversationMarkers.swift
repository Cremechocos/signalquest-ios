import CryptoKit
import Foundation

/// Numéro de la première époque marquée servi avec chaque conversation
/// (E2EE-AUTO §7.2, révision 13, « Marqueur de conversation »). L'app retient
/// le plus petit numéro vu et ne le remonte jamais : la garde contre une époque
/// non marquée posée après une époque marquée vaut aussi pour un appareil qui
/// n'a encore lu aucune époque marquée de la conversation.
struct E2EEAutoConversationMarkers {
    var defaults: UserDefaults = .standard

    private static func key(ownerScopeId: String) -> String {
        let owner = SHA256.hash(data: Data(ownerScopeId.utf8)).map { String(format: "%02x", $0) }.joined()
        return "e2ee-auto-first-epoch-v1:\(owner)"
    }

    /// Garde le plus petit numéro servi par conversation.
    func record(_ conversations: [MessageConversation], ownerScopeId: String) {
        let served = conversations.compactMap { conversation in
            conversation.firstAutoEpochNumber.map { (conversation.id, $0) }
        }
        guard !served.isEmpty else { return }
        let key = Self.key(ownerScopeId: ownerScopeId)
        var kept = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        var changed = false
        for (conversationId, number) in served where kept[conversationId].map({ number < $0 }) ?? true {
            kept[conversationId] = number
            changed = true
        }
        if changed { defaults.set(kept, forKey: key) }
    }

    func firstAutoEpochNumber(conversationId: String, ownerScopeId: String) -> Int? {
        (defaults.dictionary(forKey: Self.key(ownerScopeId: ownerScopeId)) as? [String: Int])?[conversationId]
    }

    /// Le plus petit entre le numéro gardé avec les époques lues ici et le numéro servi.
    func guardNumber(local: Int?, conversationId: String, ownerScopeId: String) -> Int? {
        let served = firstAutoEpochNumber(conversationId: conversationId, ownerScopeId: ownerScopeId)
        switch (local, served) {
        case let (local?, served?): return min(local, served)
        default: return local ?? served
        }
    }

    /// Décision du §7.2 pour une époque lue, jugée après la lecture de la
    /// conversation (vecteur `epoch-markers-v1`).
    enum Decision: String, Sendable {
        case marked = "MARKED"
        case unmarkedReadable = "UNMARKED_READABLE"
        case securityLine = "SECURITY_LINE"
    }

    /// Une époque non marquée n'est lisible que sous le numéro retenu, et, sans
    /// numéro retenu, que si la conversation n'est pas servie `e2eeAuto`.
    static func decide(epochNumber: Int, marked: Bool, retained: Int?, servedAuto: Bool) -> Decision {
        if marked { return .marked }
        if let retained { return epochNumber < retained ? .unmarkedReadable : .securityLine }
        return servedAuto ? .securityLine : .unmarkedReadable
    }
}
