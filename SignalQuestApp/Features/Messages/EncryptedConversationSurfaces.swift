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

    /// Transférer un message (U01) : une cible chiffrée est toujours sûre puisque l'envoi y
    /// chiffre ; seul « chiffré vers clair » est interdit, il ferait sortir un texte lisible
    /// d'une conversation chiffrée.
    static func allowsForward(fromEncrypted: Bool, toEncrypted: Bool) -> Bool {
        !fromEncrypted || toEncrypted
    }

    /// Par où le texte transféré part, selon la cible. Jamais par le presse-papiers.
    enum ForwardRoute: Equatable {
        /// Conversation non chiffrée : l'envoi de texte ordinaire.
        case plain
        /// Chiffrée v1 : `sendText` avec le service E2EE (déverrouillé).
        case legacyEncrypted
        /// Chiffrée v2 : la messagerie v2.
        case v2
        /// Chiffrée v2 mais fermée dans cette version : rien n'y part.
        case unavailable
    }

    static func forwardRoute(toEncrypted: Bool, targetIsV2: Bool, v2Enabled: Bool) -> ForwardRoute {
        guard toEncrypted else { return .plain }
        guard targetIsV2 else { return .legacyEncrypted }
        return v2Enabled ? .v2 : .unavailable
    }

    /// Ce que dit l'app quand un envoi v2 ne part pas ; `nil` quand le serveur l'a accepté.
    /// Les messages restent gardés sur l'appareil (file durable) : le texte le dit sans promettre une heure.
    /// `keptForRetry` : le texte reste gardé avec un bouton Renvoyer (le fil) ; sinon rien n'est gardé (le transfert).
    static func v2SendFailureMessage(_ result: E2EEV2MessageSendResultV2, keptForRetry: Bool = true) -> String? {
        switch result {
        case .sent, .alreadyAccepted:
            return nil
        case .capabilityMissing:
            return keptForRetry
                ? String(localized: "Un membre doit mettre à jour SignalQuest pour recevoir ce message. Il reste gardé ici : touche Renvoyer quand ce sera fait.")
                : String(localized: "Un membre doit mettre à jour SignalQuest pour recevoir ce message. Réessaie quand ce sera fait.")
        case .membersNotTrusted:
            return String(localized: "Un membre a un nouveau numéro de sécurité. Vérifie-le avant d’envoyer.")
        case .needsEpoch, .needsRotation:
            return String(localized: "La conversation chiffrée se met à jour. Réessaie dans un instant.")
        case .failure(let failure) where MessageRequestLimitError.isPending(failure):
            // DM-REQ-1 : le premier message est parti, la suite attend l'acceptation.
            return String(localized: "Ta demande de message n’a pas encore été acceptée.")
        case .failure(let failure) where MessageRequestLimitError.isLimit(failure):
            return MessageRequestLimitError(failure: failure).errorDescription
        case .failure(let failure):
            return failure.kind == .retryable
                ? String(localized: "Connexion instable. Réessaie.")
                : String(localized: "Ce message chiffré n’a pas pu être envoyé.")
        }
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

/// Où un partage reçu (extension « Partager vers SignalQuest ») peut aller,
/// décidé en un seul endroit et testé.
enum ShareDestinationPolicy {
    /// Pourquoi le fil ne prend pas ce partage.
    enum FeedBlocker: Equatable {
        /// Une publication ne porte ni vidéo ni fichier.
        case videoOrFile
        /// Une publication ne porte qu'une photo.
        case severalImages
    }

    /// `nil` : le fil accepte. Le composer du fil publie du texte et UNE photo.
    static func feedBlocker(for manifest: ShareInbox.Manifest) -> FeedBlocker? {
        if manifest.attachment != nil { return .videoOrFile }
        if manifest.imageCount > 1 { return .severalImages }
        return nil
    }

    /// Une conversation reçoit le partage si l'envoi y est possible. Dans une
    /// conversation chiffrée, seul le texte l'est : une photo ou un fichier
    /// partirait par la route des pièces jointes, jamais chiffrée.
    static func conversationAccepts(
        _ manifest: ShareInbox.Manifest,
        toEncrypted: Bool,
        route: EncryptedConversationSurfaces.ForwardRoute
    ) -> Bool {
        guard route != .unavailable else { return false }
        return !toEncrypted || manifest.items.isEmpty
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
