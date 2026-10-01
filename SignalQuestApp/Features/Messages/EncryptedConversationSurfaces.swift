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
