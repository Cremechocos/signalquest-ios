import SwiftUI

/// Écran « Messages enregistrés » (favoris — parité Android). Liste les messages
/// que l'utilisateur a enregistrés (toutes conversations), avec contexte de
/// conversation et retrait d'un tap. Présenté en feuille depuis le fil.
struct SavedMessagesView: View {
    let service: MessagesServicing
    let currentUserId: String?
    var e2ee: E2EEServicing? = nil
    /// Conversation ouverte derrière la feuille : toucher un enregistré qui en
    /// vient ferme juste la feuille, sans rouvrir la même conversation.
    var currentConversationId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppRouter
    @State private var entries: [SavedMessageEntry] = []
    @State private var decrypted: [String: String] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var removing: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(title: "Messages enregistrés", closeIdentifier: "saved.close") { dismiss() }
                if isLoading && entries.isEmpty {
                    SQSpinner()
                        .tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, entries.isEmpty {
                    ErrorStateView(title: "Indisponible", message: errorMessage) {
                        Task { await load() }
                    }
                } else if entries.isEmpty {
                    emptyState
                } else {
                    // Une seule carte, une ligne par message.
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            if entry.id != entries.first?.id { Divider().padding(.leading, SQSpace.md) }
                            row(entry)
                        }
                    }
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }
            }
            .padding(SQSpace.lg)
        }
        // Échec d'un retrait sur une liste remplie : dit près de la liste.
        .actionErrorBar(entries.isEmpty ? nil : errorMessage)
        .sqSheet(background: SQColor.bg)
        .task { await load() }
    }

    private var emptyState: some View {
        EmptyStateView(
            title: "Aucun message enregistré",
            message: "Touche longuement un message puis « Enregistrer » pour le retrouver ici.",
            systemImage: "bookmark"
        )
        .frame(maxWidth: .infinity)
    }

    private func row(_ entry: SavedMessageEntry) -> some View {
        let message = entry.message
        let info = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: SQSpace.xs) {
                if let sender = message.sender?.displayName {
                    Text(message.senderId == currentUserId ? String(localized: "Toi") : sender)
                        .font(SQType.caption.weight(.bold))
                        .foregroundStyle(SQColor.label)
                }
                Image(systemName: entry.conversation?.isGroup == true ? "person.3.fill" : "person.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
                Text(conversationLabel(entry))
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
                    .sqSingleLine()
            }
            Text(snippet(message))
                .font(SQType.callout)
                .foregroundStyle(SQColor.label)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            if let savedAt = entry.savedAt {
                Text("Enregistré le \(savedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
            // Regroupe conversation + extrait + auteur/date en un seul élément
            // VoiceOver, sans absorber le bouton « Retirer » (A11Y-1).
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
        return HStack(alignment: .top, spacing: SQSpace.sm) {
            // Le message mène à sa conversation quand le serveur la renseigne.
            if let conversationId = entry.conversation?.id, !conversationId.isEmpty {
                Button {
                    open(conversationId)
                } label: {
                    info.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Ouvrir la conversation")
            } else {
                info
            }
            Button {
                Task { await remove(entry) }
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(removing.contains(message.id))
            .accessibilityLabel("Retirer des enregistrés")
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, SQSpace.xs)
        .padding(.vertical, SQSpace.sm2)
        .opacity(removing.contains(message.id) ? 0.4 : 1)
    }

    private func open(_ conversationId: String) {
        Haptics.light()
        dismiss()
        if conversationId != currentConversationId {
            router.route(toConversation: conversationId)
        }
    }

    private func conversationLabel(_ entry: SavedMessageEntry) -> String {
        if let title = entry.conversation?.title, !title.isEmpty { return title }
        return entry.conversation?.isGroup == true ? String(localized: "Groupe") : String(localized: "Conversation")
    }

    private func snippet(_ message: MessageItem) -> String {
        if message.isEncrypted { return decrypted[message.id] ?? String(localized: "🔒 Message chiffré") }
        if let card = ShareCardData.parse(fromMetadataJSON: message.metadata) { return card.title }
        if MessageLocationData.parse(fromMetadataJSON: message.metadata) != nil { return String(localized: "📍 Position partagée") }
        let content = message.content ?? ""
        if !content.isEmpty { return content }
        return message.attachments.isEmpty ? String(localized: "Message") : String(localized: "Pièce jointe")
    }

    private func load() async {
        do {
            entries = try await service.savedMessages()
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
        isLoading = false
        await decryptEntries()
    }

    /// Les messages chiffrés enregistrés restaient « Message chiffré » (SOC-32) :
    /// ils sont déchiffrés avec la clé déjà déverrouillée. Sans clé, l'extrait
    /// reste masqué et aucune demande de déverrouillage n'est lancée d'ici.
    private func decryptEntries() async {
        guard let e2ee, await e2ee.isUnlocked() else { return }
        for entry in entries where entry.message.isEncrypted && decrypted[entry.message.id] == nil {
            guard let conversationId = entry.message.conversationId ?? entry.conversation?.id,
                  let text = try? await e2ee.decryptText(conversationId: conversationId, message: entry.message)
            else { continue }
            decrypted[entry.message.id] = text
        }
    }

    private func remove(_ entry: SavedMessageEntry) async {
        let id = entry.message.id
        removing.insert(id)
        errorMessage = nil
        do {
            try await service.unsaveMessage(messageId: id)
            entries.removeAll { $0.message.id == id }
            Haptics.success()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
        removing.remove(id)
    }
}
