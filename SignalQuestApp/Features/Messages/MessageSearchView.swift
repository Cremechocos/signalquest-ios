import SwiftUI

/// Recherche de messages dans la conversation courante. Champ de recherche +
/// résultats tappables : un tap renvoie l'id du message au parent qui scrolle
/// jusqu'à lui. Décryptage à la volée pour les conversations chiffrées.
struct MessageSearchView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// Callback déclenché au tap d'un résultat : renvoie l'id du message ciblé.
    let onSelectMessage: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MessageSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var decrypted: [String: String] = [:]
    @State private var searchTask: Task<Void, Never>?

    private var isE2EE: Bool { conversation.e2eeEnabled == true }

    var body: some View {
        VStack(spacing: 0) {
            SQSearchField(text: $query, placeholder: "Rechercher dans la conversation") {
                runSearch()
            }
            .padding(.horizontal)
            .padding(.vertical, SQSpace.sm)

            content
        }
        .navigationTitle("Rechercher")
        .toolbarTitleInlineCompat()
        .signalQuestBackground()
        .onChangeCompat(of: query) { _, _ in scheduleSearch() }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching && results.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, SQSpace.xxl)
            Spacer()
        } else if let errorMessage {
            ErrorStateView(title: "Recherche indisponible", message: errorMessage)
                .padding()
            Spacer()
        } else if hasSearched && results.isEmpty {
            EmptyStateView(
                title: "Aucun résultat",
                message: "Aucun message ne correspond à « \(query) ».",
                systemImage: "magnifyingglass"
            )
            Spacer()
        } else if !hasSearched {
            EmptyStateView(
                title: "Rechercher",
                message: "Tape un mot-clé pour retrouver un message de cette conversation.",
                systemImage: "text.magnifyingglass"
            )
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: SQSpace.sm) {
                    ForEach(results) { result in
                        resultRow(result)
                    }
                }
                .padding()
            }
        }
    }

    private func resultRow(_ result: MessageSearchResult) -> some View {
        let message = result.message
        return Button {
            Haptics.selection()
            dismiss()
            onSelectMessage(message.id)
        } label: {
            HStack(spacing: SQSpace.sm) {
                SQAvatar(url: message.sender?.avatarUrl, name: message.sender?.displayName ?? "?", size: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(message.sender?.displayName ?? "Message")
                            .font(SQType.caption.weight(.semibold))
                            .foregroundStyle(SQColor.label)
                        Spacer()
                        if let date = message.createdAt {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.labelTertiary)
                        }
                    }
                    Text(snippet(for: message))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(SQSpace.md + 2)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
        }
        .buttonStyle(.plain)
    }

    private func snippet(for message: MessageItem) -> String {
        if message.deletedAt != nil { return "Message supprimé" }
        if !message.attachments.isEmpty && (message.content ?? "").isEmpty {
            return "Pièce jointe"
        }
        if message.isEncrypted {
            return decrypted[message.id] ?? "🔒 Message chiffré"
        }
        return message.content ?? ""
    }

    // MARK: Recherche

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            hasSearched = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await performSearch()
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        Task { await performSearch() }
    }

    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            var filters = MessageSearchFilters.empty
            filters.conversationId = conversation.id
            let found = try await service.searchMessages(query: trimmed, filters: filters, take: 50)
            results = found
            hasSearched = true
            errorMessage = nil
            await decryptResults()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            hasSearched = true
        }
    }

    private func decryptResults() async {
        guard isE2EE, let e2ee else { return }
        for result in results where result.message.isEncrypted && decrypted[result.message.id] == nil {
            decrypted[result.message.id] = try? await e2ee.decryptText(conversationId: conversation.id, message: result.message)
        }
    }
}
