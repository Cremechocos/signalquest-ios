import SwiftUI

/// Liste des messages programmés de la conversation, avec suppression. Affiche le
/// contenu déchiffré quand c'est possible : les messages planifiés SONT chiffrés
/// (payload v2) quand la conversation est E2EE (voir MessagesService.createScheduledMessage).
/// Le repli « 🔒 » apparaît si la conversation n'est pas encore déverrouillée.
struct ScheduledMessagesView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// Nom de la conversation, sous le titre.
    var subtitle: String? = nil

    @State private var items: [ScheduledMessage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var decrypted: [String: String] = [:]

    private var isE2EE: Bool { conversation.e2eeEnabled == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Messages programmés", subtitle: subtitle.map { LocalizedStringKey($0) }, backIdentifier: "scheduled.back")
                if isLoading && items.isEmpty {
                    SQSpinner().frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, items.isEmpty {
                    ErrorStateView(title: "Indisponible", message: errorMessage) {
                        Task { await load() }
                    }
                } else if items.isEmpty {
                    EmptyStateView(
                        title: "Aucun message programmé",
                        message: "Programme un envoi depuis le « + » du composer.",
                        systemImage: "clock.badge"
                    )
                } else {
                    // Une seule carte, une ligne par envoi programmé.
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            if item.id != items.first?.id { Divider().padding(.leading, 64) }
                            row(item)
                        }
                    }
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        // Échec d'une suppression sur une liste remplie : dit près de la liste.
        .actionErrorBar(items.isEmpty ? nil : errorMessage)
        .navigationTitle("Messages programmés")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task { await load() }
    }

    private func row(_ item: ScheduledMessage) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: "clock.fill", size: 36, font: .system(size: 14, weight: .medium))
            VStack(alignment: .leading, spacing: SQSpace.xs2) {
                if let date = item.sendAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                }
                Text(content(for: item))
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(4)
                if let status = item.status, status != "scheduled" {
                    Text(statusLabel(status))
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.warning)
                }
            }
            // Regroupe date + contenu + statut en un seul élément VoiceOver (A11Y-1).
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await delete(item) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SQColor.chipInk)
                    .frame(width: 28, height: 28)
                    .background(SQColor.chip, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Annuler l’envoi")
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, SQSpace.xs)
        .padding(.vertical, SQSpace.sm2)
    }

    private func content(for item: ScheduledMessage) -> String {
        if item.isEncrypted { return decrypted[item.id] ?? String(localized: "🔒 Message chiffré") }
        let value = item.content ?? ""
        return value.isEmpty ? String(localized: "(vide)") : value
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "dispatching": return String(localized: "Envoi en cours…")
        case "failed_membership", "failed_validation", "failed_dispatch": return String(localized: "Échec d'envoi")
        case "canceled": return String(localized: "Annulé")
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
            errorMessage = error.userFacingMessage
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

    private func delete(_ target: ScheduledMessage) async {
        errorMessage = nil
        do {
            try await service.deleteScheduledMessage(conversationId: conversation.id, scheduledId: target.id)
            items.removeAll { $0.id == target.id }
            Haptics.success()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}
