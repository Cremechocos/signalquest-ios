import SwiftUI

/// Médias et fichiers d'une conversation (plan 3, vague 2) : les photos en
/// grille, puis les fichiers et les notes vocales, du plus récent au plus
/// ancien. Les pièces jointes viennent de la recherche des messages du
/// serveur, comme celles que le fil affiche déjà.
struct ConversationMediaView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    /// Nom de la conversation, sous le titre.
    var subtitle: String? = nil

    @EnvironmentObject private var session: AuthSessionViewModel
    @State private var messages: [MessageItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Une page pleine laisse penser qu'il en reste : la suivante part de la date du plus ancien.
    @State private var hasMore = false
    @State private var isLoadingMore = false
    /// La page suivante n'a pas pu être lue : « Réessayer » remplace le spinner.
    @State private var loadMoreFailed = false
    @State private var imageViewerTarget: MessageImageTarget?
    /// `nil` : l'onglet par défaut, Photos s'il y en a.
    @State private var tab: Tab?
    @ScaledMetric(relativeTo: .body) private var tileMinimum: CGFloat = 96

    /// Au plus ce que la route renvoie en une fois.
    static let pageSize = 100

    private enum Tab: Hashable { case photos, files }

    private var selectedTab: Tab { tab ?? (photos.isEmpty && !files.isEmpty ? .files : .photos) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Médias et fichiers", subtitle: subtitle.map { LocalizedStringKey($0) }, backIdentifier: "conversationMedia.back")
                if isLoading && messages.isEmpty {
                    SQSpinner()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, messages.isEmpty {
                    ErrorStateView(title: "Médias indisponibles", message: errorMessage) {
                        Task { await load() }
                    }
                } else if photos.isEmpty && files.isEmpty {
                    EmptyStateView(
                        title: "Aucun média",
                        message: "Les photos, fichiers et notes vocales de la conversation s’afficheront ici.",
                        systemImage: "photo.on.rectangle"
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    SQSegmentedFilter(
                        selection: Binding(get: { selectedTab }, set: { tab = $0 }),
                        options: [
                            (value: Tab.photos, label: "Photos", icon: nil),
                            (value: Tab.files, label: "Fichiers et notes vocales", icon: nil)
                        ]
                    )
                    .padding(.horizontal, -SQSpace.lg)
                    switch selectedTab {
                    case .photos:
                        if photos.isEmpty { emptyTab("Aucune photo dans cette conversation.") } else { photosSection }
                    case .files:
                        if files.isEmpty { emptyTab("Aucun fichier ni note vocale dans cette conversation.") } else { filesSection }
                    }
                    if hasMore && loadMoreFailed {
                        // La tâche du spinner ne repart pas seule (le nombre de
                        // messages ne change pas) : le bouton relance la page.
                        VStack(spacing: SQSpace.xs) {
                            Text("Impossible de charger la suite")
                                .font(SQType.callout)
                                .foregroundStyle(SQColor.labelSecondary)
                                .sqAnnounce("Impossible de charger la suite")
                            Button {
                                Task { await loadMore() }
                            } label: {
                                Text("Réessayer")
                                    .font(SQType.callout(.semibold))
                                    .foregroundStyle(SQColor.accentInk)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(SQPressButtonStyle())
                            .accessibilityIdentifier("conversationMedia.loadMore.retry")
                        }
                        .frame(maxWidth: .infinity)
                    } else if hasMore {
                        SQSpinner()
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Chargement d’autres médias")
                            .task(id: messages.count) { await loadMore() }
                    }
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .background(SQColor.bg)
        .navigationTitle("Médias et fichiers")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $imageViewerTarget) { target in
            MessageImageViewer(target: target)
        }
    }

    private func emptyTab(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(SQType.callout)
            .foregroundStyle(SQColor.labelSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.xl)
    }

    private struct Entry: Identifiable {
        let id: String
        let attachment: MessageAttachment
        let url: URL
        let message: MessageItem
    }

    private var entries: [Entry] {
        messages.flatMap { message in
            message.attachments.enumerated().compactMap { index, attachment in
                guard let url = attachment.url else { return nil }
                return Entry(id: attachment.id ?? "\(message.id)-\(index)", attachment: attachment, url: url, message: message)
            }
        }
    }

    private var photos: [Entry] { entries.filter { Self.isImage($0.attachment) } }
    private var files: [Entry] { entries.filter { !Self.isImage($0.attachment) } }

    nonisolated static func isImage(_ attachment: MessageAttachment) -> Bool {
        attachment.kind.uppercased() == "IMAGE" || (attachment.contentType?.hasPrefix("image/") ?? false)
    }

    private var photosSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum), spacing: 3)], spacing: 3) {
            ForEach(photos) { entry in
                photoTile(entry)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func photoTile(_ entry: Entry) -> some View {
        Button {
            guard case .privateAccount(let accountSession) = privateImageCacheScope else { return }
            Haptics.selection()
            imageViewerTarget = MessageImageTarget(id: entry.id, url: entry.url, accountSession: accountSession)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fill)
                .overlay {
                    if let privateImageCacheScope {
                        RemoteImage(url: entry.url, maxDimension: 240, contentMode: .fill, cacheScope: privateImageCacheScope, showsFailureUI: true) {
                            Rectangle().fill(SQColor.chip).sqShimmer()
                        }
                    } else {
                        Rectangle().fill(SQColor.chip)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photoLabel(entry))
        .accessibilityHint("Toucher pour afficher en plein écran")
        .accessibilityIdentifier("conversationMedia.photo")
    }

    private func photoLabel(_ entry: Entry) -> String {
        let author = entry.message.sender?.displayName ?? String(localized: "Membre")
        guard let date = entry.message.createdAt else { return String(localized: "Photo de \(author)") }
        return String(localized: "Photo de \(author), \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    /// Fichiers et notes vocales en lignes sur une seule carte.
    private var filesSection: some View {
        VStack(spacing: 0) {
            ForEach(files) { entry in
                if entry.id != files.first?.id { Divider().padding(.leading, SQSpace.md) }
                if entry.attachment.kind.uppercased() == "AUDIO" || (entry.attachment.contentType?.hasPrefix("audio/") ?? false) {
                    // Lue dans l'app, comme dans le fil de la conversation.
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        RemoteVoiceNoteBubble(attachment: entry.attachment, remoteURL: entry.url, mine: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: fileSubtitle(entry))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .padding(SQSpace.md)
                    .accessibilityIdentifier("conversationMedia.voice")
                } else {
                    fileRow(entry)
                }
            }
        }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    /// « Camille · 12 oct. 14:40 » : qui l'a envoyé et quand.
    private func fileSubtitle(_ entry: Entry) -> String {
        let author = entry.message.sender?.displayName ?? String(localized: "Membre")
        guard let date = entry.message.createdAt else { return author }
        return "\(author) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func fileRow(_ entry: Entry) -> some View {
        Link(destination: entry.url) {
            HStack(spacing: SQSpace.md) {
                SQIconPastille(systemImage: "doc.fill", size: 36, tint: SQColor.accentInk, font: .system(size: 15, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.attachment.fileName ?? String(localized: "Pièce jointe"))
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: fileSubtitle(entry))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: SQSpace.sm)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm2)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Toucher pour ouvrir")
        .accessibilityIdentifier("conversationMedia.file")
    }

    private var privateImageCacheScope: ImageCacheScope? {
        guard case .authenticated(let user) = session.state,
              let localSession = LocalAccountScope.sessionSnapshot(),
              localSession.ownerScopeId == "user:\(user.id)" else { return nil }
        return .privateAccount(localSession)
    }

    private func load() async {
        if AppEnvironment.usesDemoData {
            messages = MessageItem.demoMedia
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            var filters = MessageSearchFilters()
            filters.conversationId = conversation.id
            filters.hasAttachment = true
            let page = try await service.searchMessages(query: "", filters: filters, take: Self.pageSize).map(\.message)
            messages = page
            hasMore = page.count >= Self.pageSize
            loadMoreFailed = false
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    /// Page suivante : les messages à pièce jointe antérieurs au plus ancien déjà chargé.
    /// Une page sans rien de nouveau (bornes comprises) clôt la liste.
    private func loadMore() async {
        guard hasMore, !isLoadingMore, !AppEnvironment.usesDemoData,
              let oldest = messages.compactMap(\.createdAt).min() else { return }
        isLoadingMore = true
        loadMoreFailed = false
        defer { isLoadingMore = false }
        do {
            var filters = MessageSearchFilters()
            filters.conversationId = conversation.id
            filters.hasAttachment = true
            filters.to = oldest
            let page = try await service.searchMessages(query: "", filters: filters, take: Self.pageSize).map(\.message)
            let known = Set(messages.map(\.id))
            let fresh = page.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else {
                hasMore = false
                return
            }
            messages = (messages + fresh).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            hasMore = page.count >= Self.pageSize
        } catch {
            // La liste garde ses médias et reste ouverte : un échec n'est pas la fin.
            if !error.isCancellation { loadMoreFailed = true }
        }
    }
}

extension MessageItem {
    /// Médias de la conversation de démo : trois photos et un fichier.
    static var demoMedia: [MessageItem] {
        let now = Date()
        func item(_ index: Int, kind: String, contentType: String, fileName: String) -> MessageItem {
            let attachment = MessageAttachment(
                id: "demo-media-\(index)", kind: kind,
                url: URL(string: "https://example.invalid/demo-media-\(index)"),
                fileName: fileName, contentType: contentType, size: 120_000, width: 1_200, height: 900
            )
            return MessageItem(
                id: "demo-media-message-\(index)", conversationId: "demo-conv-1", senderId: "demo-user",
                kind: "ATTACHMENT", content: nil, e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil,
                e2eeAadB64: nil, metadata: nil, createdAt: now.addingTimeInterval(-Double(index) * 3_600),
                editedAt: nil, deletedAt: nil, replyToId: nil, threadReplyCount: 0,
                sender: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                attachments: [attachment], reactions: []
            )
        }
        return [
            item(1, kind: "IMAGE", contentType: "image/jpeg", fileName: "pylone-nord.jpg"),
            item(2, kind: "IMAGE", contentType: "image/jpeg", fileName: "toit-mairie.jpg"),
            item(3, kind: "FILE", contentType: "application/pdf", fileName: "releve-couverture.pdf"),
            item(4, kind: "IMAGE", contentType: "image/jpeg", fileName: "armoire-technique.jpg")
        ]
    }
}
