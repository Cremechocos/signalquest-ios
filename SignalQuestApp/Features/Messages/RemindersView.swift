import SwiftUI

/// Liste des rappels de la conversation (messages que l'utilisateur a demandé à
/// se faire rappeler), avec suppression. Affiche le message rappelé et l'échéance.
struct RemindersView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?

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
        Group {
            if isLoading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, items.isEmpty {
                ErrorStateView(title: "Indisponible", message: errorMessage) {
                    Task { await load() }
                }
                .padding()
            } else if activeItems.isEmpty {
                EmptyStateView(
                    title: "Aucun rappel",
                    message: "Ajoute un rappel depuis le menu contextuel d'un message.",
                    systemImage: "bell.badge"
                )
            } else {
                List {
                    ForEach(activeItems) { item in
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
        .navigationTitle("Rappels")
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .task { await load() }
    }

    private func row(_ item: MessageReminder) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
            if let date = item.remindAt {
                Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "bell")
                    .font(SQType.caption.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
            }
            if let reason = item.reason, !reason.isEmpty {
                Text(reason)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Text(content(for: item))
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .lineLimit(3)
        }
        .padding(.vertical, SQSpace.xs)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(SQColor.separator)
    }

    private func content(for item: MessageReminder) -> String {
        guard let message = item.message else { return "Message" }
        if message.deletedAt != nil { return "Message supprimé" }
        if message.isEncrypted { return decrypted[message.id] ?? "🔒 Message chiffré" }
        let value = message.content ?? ""
        return value.isEmpty ? "Pièce jointe" : value
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.reminders(conversationId: conversation.id)
            errorMessage = nil
            await decryptAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func decryptAll() async {
        guard isE2EE, let e2ee else { return }
        for item in items {
            guard let message = item.message, message.isEncrypted, decrypted[message.id] == nil else { continue }
            decrypted[message.id] = try? await e2ee.decryptText(conversationId: conversation.id, message: message)
        }
    }

    private func delete(at offsets: IndexSet) async {
        let targets = offsets.map { activeItems[$0] }
        for target in targets {
            do {
                try await service.deleteReminder(conversationId: conversation.id, reminderId: target.id)
                items.removeAll { $0.id == target.id }
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
