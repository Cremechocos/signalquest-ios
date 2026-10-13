import SwiftUI

/// Liste des rappels de la conversation (messages que l'utilisateur a demandé à
/// se faire rappeler), avec suppression. Affiche le message rappelé et l'échéance.
struct RemindersView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// Nom de la conversation, sous le titre.
    var subtitle: String? = nil

    @State private var items: [MessageReminder] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var decrypted: [String: String] = [:]

    private var isE2EE: Bool { conversation.e2eeEnabled == true }
    /// On masque les rappels déjà rejetés / déclenchés pour ne montrer que les actifs.
    private var activeItems: [MessageReminder] {
        items.filter { ($0.status ?? "active").lowercased() == "active" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Rappels", subtitle: subtitle.map { LocalizedStringKey($0) }, backIdentifier: "reminders.back")
                if isLoading && items.isEmpty {
                    SQSpinner().frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, items.isEmpty {
                    ErrorStateView(title: "Indisponible", message: errorMessage) {
                        Task { await load() }
                    }
                } else if activeItems.isEmpty {
                    EmptyStateView(
                        title: "Aucun rappel",
                        message: "Ajoute un rappel depuis le menu contextuel d'un message.",
                        systemImage: "bell.badge"
                    )
                } else {
                    // Une seule carte, une ligne par rappel.
                    VStack(spacing: 0) {
                        ForEach(activeItems) { item in
                            if item.id != activeItems.first?.id { Divider().padding(.leading, 64) }
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
        .navigationTitle("Rappels")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task { await load() }
    }

    private func row(_ item: MessageReminder) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: "bell.fill", size: 36, font: .system(size: 14, weight: .medium))
            VStack(alignment: .leading, spacing: SQSpace.xs2) {
                if let date = item.remindAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                }
                if let reason = item.reason, !reason.isEmpty {
                    Text(reason)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Text(content(for: item))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(3)
            }
            // Regroupe date + motif + contenu en un seul élément VoiceOver (A11Y-1).
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
            .accessibilityLabel("Supprimer le rappel")
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, SQSpace.xs)
        .padding(.vertical, SQSpace.sm2)
    }

    private func content(for item: MessageReminder) -> String {
        guard let message = item.message else { return String(localized: "Message") }
        if message.deletedAt != nil { return String(localized: "Message supprimé") }
        if message.isEncrypted { return decrypted[message.id] ?? String(localized: "🔒 Message chiffré") }
        let value = message.content ?? ""
        return value.isEmpty ? String(localized: "Pièce jointe") : value
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.reminders(conversationId: conversation.id)
            errorMessage = nil
            await decryptAll()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    private func decryptAll() async {
        guard isE2EE, let e2ee else { return }
        for item in items {
            guard let message = item.message, message.isEncrypted, decrypted[message.id] == nil else { continue }
            decrypted[message.id] = try? await e2ee.decryptText(conversationId: conversation.id, message: message)
        }
    }

    private func delete(_ target: MessageReminder) async {
        errorMessage = nil
        do {
            try await service.deleteReminder(conversationId: conversation.id, reminderId: target.id)
            items.removeAll { $0.id == target.id }
            Haptics.success()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}
