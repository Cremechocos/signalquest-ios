import SwiftUI

/// Médias et fichiers d'une conversation (plan 3, vague 2) : les photos en
/// grille, puis les fichiers et les notes vocales, du plus récent au plus
/// ancien. Les pièces jointes viennent de la recherche des messages du
/// serveur, comme celles que le fil affiche déjà.
struct ConversationMediaView: View {
    let conversation: MessageConversation
    let service: MessagesServicing

    @EnvironmentObject private var session: AuthSessionViewModel
    @State private var messages: [MessageItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var imageViewerTarget: MessageImageTarget?
    @ScaledMetric(relativeTo: .body) private var tileMinimum: CGFloat = 96

    /// Au plus ce que la route renvoie en une fois.
    static let pageSize = 100

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                if isLoading && messages.isEmpty {
                    ProgressView()
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
                    if !photos.isEmpty { photosSection }
                    if !files.isEmpty { filesSection }
                }
            }
            .padding(SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg)
        .navigationTitle("Médias et fichiers")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $imageViewerTarget) { target in
            MessageImageViewer(target: target)
        }
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
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            SQSectionHeader("Photos")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum), spacing: 2)], spacing: 2) {
                ForEach(photos) { entry in
                    photoTile(entry)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
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
                        RemoteImage(url: entry.url, maxDimension: 240, contentMode: .fill, cacheScope: privateImageCacheScope) {
                            Rectangle().fill(SQColor.surfaceMuted).sqShimmer()
                        }
                    } else {
                        Rectangle().fill(SQColor.surfaceMuted)
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

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            SQSectionHeader("Fichiers et notes vocales")
            VStack(spacing: SQSpace.sm) {
                ForEach(files) { entry in
                    if entry.attachment.kind.uppercased() == "AUDIO" || (entry.attachment.contentType?.hasPrefix("audio/") ?? false) {
                        // Lue dans l'app, comme dans le fil de la conversation.
                        RemoteVoiceNoteBubble(attachment: entry.attachment, remoteURL: entry.url, mine: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SQSpace.sm)
                            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                            .accessibilityIdentifier("conversationMedia.voice")
                    } else {
                        fileRow(entry)
                    }
                }
            }
        }
    }

    private func fileRow(_ entry: Entry) -> some View {
        Link(destination: entry.url) {
            HStack(spacing: SQSpace.md) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(width: 36, height: 36)
                    .background(SQColor.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.attachment.fileName ?? String(localized: "Pièce jointe"))
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let date = entry.message.createdAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Spacer(minLength: SQSpace.sm)
            }
            .padding(SQSpace.md)
            .frame(minHeight: 44)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
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
            messages = try await service.searchMessages(query: "", filters: filters, take: Self.pageSize).map(\.message)
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
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
