import Foundation

/// Surfaces fermées par défaut d'une conversation chiffrée (spec E2EE §13),
/// décidées en un seul endroit et testées.
enum EncryptedConversationSurfaces {
    /// Conversation v2 : état collant, dérivé du manifeste signé de l'époque 1
    /// (§12). Seule une conversation chiffrée peut l'être ; pour elle, un état
    /// illisible vaut v2.
    static func isV2(
        _ conversation: MessageConversation,
        ownerNamespace: String = LocalAccountScope.storageNamespace,
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore()
    ) -> Bool {
        guard conversation.e2eeEnabled == true else { return false }
        return !E2EEV2VerifiedEpochKeys.allowsLegacyEpochPath(
            conversationId: conversation.id, ownerNamespace: ownerNamespace, stateStore: stateStore
        )
    }

    /// Message du fil v2 : l'appareil l'a déjà déchiffré et son texte est dans
    /// `content` (`E2EEV2ThreadPresenter`) ; seul le v1 passe par un texte déchiffré à part.
    static func isReadableV2(_ message: MessageItem, usesV2: Bool) -> Bool {
        usesV2 && message.e2eeVersion == 2 && message.e2eeCiphertextB64 == nil
    }

    /// Texte d'une bulle : vide si supprimé, le texte v2 tel quel, le texte v1
    /// déchiffré, sinon le cadenas.
    static func displayedText(for message: MessageItem, usesV2: Bool, decrypted: [String: String]) -> String {
        if message.deletedAt != nil { return "" }
        if message.isEncrypted && !isReadableV2(message, usesV2: usesV2) {
            return decrypted[message.id] ?? String(localized: "🔒 Message chiffré")
        }
        return message.content ?? ""
    }

    /// En v2, le fil est lu et écrit par la messagerie v2 : le mot de passe ne
    /// déverrouille que le v1 (§12).
    static func canSend(isEncrypted: Bool, usesV2: Bool, legacyUnlocked: Bool) -> Bool {
        !isEncrypted || usesV2 || legacyUnlocked
    }

    /// Bandeau « déverrouille pour lire » : v1 seulement, et jamais avant de
    /// savoir si la conversation est v2.
    static func showsLegacyUnlockBanner(isEncrypted: Bool, v2Resolved: Bool, isV2: Bool, legacyUnlocked: Bool) -> Bool {
        isEncrypted && v2Resolved && !isV2 && !legacyUnlocked
    }

    /// Fils, rappels, enregistrés et épingles passent par les routes v1 : ni une
    /// bulle encore locale ni un identifiant v2 (`messageRef`) n'y sont connus.
    static func allowsServerActions(messageId: String, isV2: Bool) -> Bool {
        !messageId.hasPrefix("local-") && !isV2
    }

    /// Messages programmés désactivés dans une conversation v2 (décision du 30/09) :
    /// le serveur enverrait plus tard un contenu que plus aucun appareil ne
    /// rechiffre sous l'époque du moment.
    static func allowsScheduling(isV2: Bool) -> Bool {
        !isV2
    }

    /// L'aperçu du sélecteur d'apps est masqué tant qu'un écran montre le
    /// contenu déchiffré d'une conversation chiffrée.
    static func hidesSnapshot(of conversation: MessageConversation) -> Bool {
        conversation.e2eeEnabled == true
    }

    /// La liste des conversations aussi, dès qu'elle montre un aperçu déchiffré
    /// ou un brouillon d'une conversation chiffrée.
    static func listHidesSnapshot(
        _ conversations: [MessageConversation],
        decryptedPreviews: [String: String],
        drafts: [String: String]
    ) -> Bool {
        conversations.contains { conversation in
            conversation.e2eeEnabled == true
                && (decryptedPreviews[conversation.id]?.isEmpty == false || drafts[conversation.id]?.isEmpty == false)
        }
    }
}

/// Messages v2 supprimés « pour moi », sur cet appareil et par compte.
///
/// En v2, « pour moi » ne passe pas par le serveur (§5) : sans mémoire locale,
/// la relève suivante rendait le message. Seuls les identifiants opaques
/// (`messageRef`) sont gardés, jamais le texte.
enum E2EEV2HiddenMessagesStore {
    static let maxRefsPerConversation = 1_000
    private static let prefix = "SignalQuest.E2EEV2HiddenMessages.v1"

    private static func key(_ ownerScopeId: String) -> String {
        "\(prefix).\(LocalAccountScope.storageNamespace(for: ownerScopeId))"
    }

    private static func all(ownerScopeId: String, defaults: UserDefaults) -> [String: [String]] {
        guard ownerScopeId.hasPrefix("user:"),
              let data = defaults.data(forKey: key(ownerScopeId)),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return map
    }

    static func hiddenRefs(
        conversationId: String,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        Set(all(ownerScopeId: ownerScopeId, defaults: defaults)[conversationId] ?? [])
    }

    static func hide(
        messageRef: String,
        conversationId: String,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) {
        guard ownerScopeId.hasPrefix("user:"), !messageRef.isEmpty else { return }
        var map = all(ownerScopeId: ownerScopeId, defaults: defaults)
        var refs = (map[conversationId] ?? []).filter { $0 != messageRef }
        refs.insert(messageRef, at: 0)
        map[conversationId] = Array(refs.prefix(maxRefsPerConversation))
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key(ownerScopeId))
        }
    }

    /// À la déconnexion : la préférence appartient au compte qui s'en va.
    static func purge(ownerScopeId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(ownerScopeId))
    }
}
