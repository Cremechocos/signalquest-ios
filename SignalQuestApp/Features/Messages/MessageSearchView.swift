import SwiftUI

/// Recherche de messages dans la conversation courante. Champ de recherche +
/// résultats tappables : un tap renvoie l'id du message au parent qui scrolle
/// jusqu'à lui. Décryptage à la volée pour les conversations chiffrées.
struct MessageSearchView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// Conversation chiffrée : messages déjà déchiffrés sur l'appareil. La
    /// recherche s'y fait localement ; le mot cherché partait sinon en clair
    /// dans l'adresse de la requête (E2E-04).
    var localCorpus: [(message: MessageItem, text: String)]? = nil
    /// Nom de la conversation, sous le titre.
    var subtitle: String? = nil
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
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Rechercher", subtitle: subtitle.map { LocalizedStringKey($0) }, backIdentifier: "messageSearch.back")
                SQSearchField(text: $query, placeholder: "Rechercher dans la conversation") {
                    runSearch()
                }
                content
                if localCorpus != nil {
                    Text("Dans une conversation chiffrée, la recherche se fait sur ton appareil.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SQSpace.xs)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Rechercher")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .onChangeCompat(of: query) { _, _ in scheduleSearch() }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching && results.isEmpty {
            SQSpinner().frame(maxWidth: .infinity).padding(.top, SQSpace.xxl)
        } else if let errorMessage {
            ErrorStateView(title: "Recherche indisponible", message: errorMessage)
        } else if hasSearched && results.isEmpty {
            // En conversation chiffrée, le serveur ne voit que du texte chiffré : la
            // recherche par mot-clé ne peut rien matcher. On l'explique plutôt que
            // de laisser croire à tort que le message n'existe pas (UX-1).
            EmptyStateView(
                title: "Aucun résultat",
                message: localCorpus != nil
                    ? String(localized: "Aucun message déjà ouvert ne contient « \(query) ». La recherche se fait sur ton téléphone : le mot cherché n’est jamais envoyé.")
                    : String(localized: "Aucun message ne correspond à « \(query) »."),
                systemImage: localCorpus != nil ? "lock.fill" : "magnifyingglass"
            )
        } else if !hasSearched {
            EmptyStateView(
                title: "Rechercher",
                message: "Tape un mot-clé pour retrouver un message de cette conversation.",
                systemImage: "text.magnifyingglass"
            )
        } else {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("\(results.count) résultat")
                    .sqKicker()
                    .padding(.leading, SQSpace.xs)
                // Résultats en lignes sur une seule carte, le mot cherché en gras.
                LazyVStack(spacing: 0) {
                    ForEach(results) { result in
                        if result.id != results.first?.id { Divider().padding(.leading, SQSpace.md) }
                        resultRow(result)
                    }
                }
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.sender?.displayName ?? String(localized: "Message"))
                        .font(SQType.caption.weight(.bold))
                        .foregroundStyle(SQColor.label)
                    Spacer(minLength: SQSpace.sm)
                    if let date = message.createdAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Text(highlighted(snippet(for: message)))
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// Le mot cherché passe en gras et à l'encre dans l'extrait.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                attributed[lower..<upper].foregroundColor = SQColor.label
            }
            start = range.upperBound
        }
        return attributed
    }

    private func snippet(for message: MessageItem) -> String {
        if message.deletedAt != nil { return String(localized: "Message supprimé") }
        if !message.attachments.isEmpty && (message.content ?? "").isEmpty {
            return String(localized: "Pièce jointe")
        }
        if message.isEncrypted {
            return decrypted[message.id] ?? String(localized: "🔒 Message chiffré")
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
        if let localCorpus {
            // Plus récents d'abord, comme la recherche du serveur.
            let matches = localCorpus.filter {
                $0.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            for match in matches { decrypted[match.message.id] = match.text }
            results = matches.reversed().prefix(50).map { MessageSearchResult(message: $0.message) }
            hasSearched = true
            errorMessage = nil
            return
        }
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
            if !error.isCancellation { errorMessage = error.userFacingMessage }
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
