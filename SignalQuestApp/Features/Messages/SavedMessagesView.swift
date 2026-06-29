import SwiftUI

/// Écran « Messages enregistrés » (favoris — parité Android). Liste les messages
/// que l'utilisateur a enregistrés (toutes conversations), avec contexte de
/// conversation et retrait d'un tap. Présenté en feuille depuis le fil.
struct SavedMessagesView: View {
    let service: MessagesServicing
    let currentUserId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SavedMessageEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var removing: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView()
                        .tint(SQColor.brandRed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, entries.isEmpty {
                    ErrorStateView(title: "Indisponible", message: errorMessage) {
                        Task { await load() }
                    }
                    .padding()
                } else if entries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: SQSpace.sm) {
                            ForEach(entries) { entry in
                                row(entry)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Messages enregistrés")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
            .signalQuestBackground()
            .task { await load() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: SQSpace.sm) {
            Image(systemName: "bookmark")
                .font(.system(size: 34))
                .foregroundStyle(SQColor.labelTertiary)
            Text("Aucun message enregistré")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text("Touche longuement un message puis « Enregistrer » pour le retrouver ici.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(SQSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: SavedMessageEntry) -> some View {
        let message = entry.message
        return HStack(alignment: .top, spacing: SQSpace.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SQSpace.xs) {
                    Image(systemName: entry.conversation?.isGroup == true ? "person.3.fill" : "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(SQColor.labelTertiary)
                        .accessibilityHidden(true)
                    Text(conversationLabel(entry))
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelTertiary)
                        .lineLimit(1)
                }
                Text(snippet(message))
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: SQSpace.xs) {
                    if let sender = message.sender?.displayName {
                        Text(message.senderId == currentUserId ? "Vous" : sender)
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    if let savedAt = entry.savedAt {
                        Text("· enregistré le \(savedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelTertiary)
                    }
                }
            }
            Spacer(minLength: SQSpace.sm)
            Button {
                Task { await remove(entry) }
            } label: {
                Image(systemName: "bookmark.slash.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(SQColor.brandRed)
            }
            .buttonStyle(.plain)
            .disabled(removing.contains(message.id))
            .accessibilityLabel("Retirer des enregistrés")
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1)
        }
        .opacity(removing.contains(message.id) ? 0.4 : 1)
    }

    private func conversationLabel(_ entry: SavedMessageEntry) -> String {
        if let title = entry.conversation?.title, !title.isEmpty { return title }
        return entry.conversation?.isGroup == true ? "Groupe" : "Conversation"
    }

    private func snippet(_ message: MessageItem) -> String {
        if message.isEncrypted { return "🔒 Message chiffré" }
        if let card = ShareCardData.parse(fromMetadataJSON: message.metadata) { return card.title }
        if MessageLocationData.parse(fromMetadataJSON: message.metadata) != nil { return "📍 Position partagée" }
        let content = message.content ?? ""
        if !content.isEmpty { return content }
        return message.attachments.isEmpty ? "Message" : "Pièce jointe"
    }

    private func load() async {
        do {
            entries = try await service.savedMessages()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func remove(_ entry: SavedMessageEntry) async {
        let id = entry.message.id
        removing.insert(id)
        do {
            try await service.unsaveMessage(messageId: id)
            entries.removeAll { $0.message.id == id }
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
        removing.remove(id)
    }
}
