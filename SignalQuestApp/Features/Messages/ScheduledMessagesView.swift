import SwiftUI

/// Liste des messages programmés de la conversation, avec suppression. Affiche le
/// contenu déchiffré quand c'est possible : les messages planifiés SONT chiffrés
/// (payload v2) quand la conversation est E2EE (voir MessagesService.createScheduledMessage).
/// Le repli « 🔒 » apparaît si la conversation n'est pas encore déverrouillée.
struct ScheduledMessagesView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?

    @State private var items: [ScheduledMessage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var decrypted: [String: String] = [:]

    private var isE2EE: Bool { conversation.e2eeEnabled == true }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, items.isEmpty {
                ErrorStateView(title: "Indisponible", message: errorMessage) {
                    Task { await load() }
                }
                .padding()
            } else if items.isEmpty {
                EmptyStateView(
                    title: "Aucun message programmé",
                    message: "Programme un envoi depuis le « + » du composer.",
                    systemImage: "clock.badge"
                )
            } else {
                List {
                    ForEach(items) { item in
                        row(item)
                    }
                    .onDelete { offsets in
                        Task { await delete(at: offsets) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Messages programmés")
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .task { await load() }
    }

    private func row(_ item: ScheduledMessage) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm + 2) {
            Image(systemName: "clock.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 36, height: 36)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
                if let date = item.sendAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(SQColor.brandRed)
                }
                Text(content(for: item))
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(4)
                if let status = item.status, status != "scheduled" {
                    Text(statusLabel(status))
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.warning)
                }
            }
        }
        .padding(SQSpace.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowSoft()
        // Regroupe date + contenu + statut en un seul élément VoiceOver (A11Y-1).
        .accessibilityElement(children: .combine)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: SQSpace.xs + 2, leading: SQSpace.lg, bottom: SQSpace.xs + 2, trailing: SQSpace.lg))
    }

    private func content(for item: ScheduledMessage) -> String {
        if item.isEncrypted { return decrypted[item.id] ?? "🔒 Message chiffré" }
        let value = item.content ?? ""
        return value.isEmpty ? "(vide)" : value
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "dispatching": return "Envoi en cours…"
        case "failed_membership", "failed_validation", "failed_dispatch": return "Échec d'envoi"
        case "canceled": return "Annulé"
        default: return status
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.scheduledMessages(conversationId: conversation.id)
            errorMessage = nil
            await decryptAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func decryptAll() async {
        guard isE2EE, let e2ee else { return }
        for item in items where item.isEncrypted && decrypted[item.id] == nil {
            // Reconstitue un MessageItem minimal pour réutiliser decryptText.
            let proxy = MessageItem(
                id: item.id,
                conversationId: item.conversationId,
                senderId: item.senderId,
                kind: item.kind,
                content: nil,
                e2eeVersion: item.e2eeVersion,
                e2eeIvB64: item.e2eeIvB64,
                e2eeCiphertextB64: item.e2eeCiphertextB64,
                e2eeAadB64: item.e2eeAadB64,
                metadata: item.metadata,
                createdAt: item.createdAt,
                editedAt: nil,
                deletedAt: nil,
                replyToId: item.replyToId,
                threadReplyCount: nil,
                sender: nil,
                attachments: [],
                reactions: []
            )
            decrypted[item.id] = try? await e2ee.decryptText(conversationId: conversation.id, message: proxy)
        }
    }

    private func delete(at offsets: IndexSet) async {
        let targets = offsets.map { items[$0] }
        for target in targets {
            do {
                try await service.deleteScheduledMessage(conversationId: conversation.id, scheduledId: target.id)
                items.removeAll { $0.id == target.id }
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
