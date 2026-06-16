import SwiftUI

/// Cible de présentation du viewer photo depuis la carte.
struct MapPhotoTarget: Identifiable, Equatable {
    let id: String
    let thumbnailURL: URL?
}

/// Viewer plein écran d'une photo d'antenne ouverte depuis la carte :
/// photo en grand (zoom pincé), infos antenne + badge opérateur, like et
/// commentaires. S'appuie sur `PhotoServicing` (detail / comments / like).
struct MapPhotoViewer: View {
    let photoId: String
    let initialThumbnailURL: URL?
    let service: PhotoServicing
    /// Couleur d'accent registry pour un opérateur donné.
    let operatorAccent: (String) -> Color

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var photo: Photo?
    @State private var comments: [PhotoComment] = []
    @State private var isLoading = true
    @State private var liked = false
    @State private var likeCount = 0
    @State private var likeBusy = false
    @State private var commentDraft = ""
    @State private var sendingComment = false
    @State private var appeared = false
    @FocusState private var commentFocused: Bool

    private var imageURL: URL? {
        photo?.imageUrl ?? photo?.thumbnailUrl ?? initialThumbnailURL
    }

    private var operatorName: String? {
        photo?.operator?.isEmpty == false ? photo?.operator : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                photoArea
                infoPanel
            }

            topBar
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    // MARK: Photo

    private var photoArea: some View {
        ZoomablePhoto(url: imageURL, placeholder: initialThumbnailURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Fermer")
            Spacer()
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
    }

    // MARK: Panneau d'infos

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            header
            if let caption = photo?.displayCaption, !caption.isEmpty, caption != "Photo SignalQuest" {
                Text(caption)
                    .font(SQFont.body(14, .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
            Divider().overlay(Color.white.opacity(0.12))
            commentsSection
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(.rect(topLeadingRadius: 22, topTrailingRadius: 22))
        .offset(y: appeared ? 0 : 40)
        .opacity(appeared ? 1 : 0)
    }

    private var header: some View {
        HStack(spacing: SQSpace.sm) {
            if let operatorName {
                Text(operatorName.uppercased())
                    .font(SQFont.archivo(12, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(operatorAccent(operatorName), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(siteTitle)
                    .font(SQFont.archivo(15, .bold))
                    .foregroundStyle(.white)
                if let subtitle = siteSubtitle {
                    Text(subtitle)
                        .font(SQFont.body(12, .regular))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            Spacer()
        }
    }

    private var siteTitle: String {
        if let address = photo?.siteAddress, !address.isEmpty { return address }
        if let site = photo?.siteId, !site.isEmpty { return "Site \(site)" }
        if let enb = photo?.enb, !enb.isEmpty { return "eNB \(enb)" }
        return "Antenne"
    }

    private var siteSubtitle: String? {
        var parts: [String] = []
        if let author = photo?.authorName, !author.isEmpty { parts.append(author) }
        if let date = photo?.uploadedAt ?? photo?.createdAt {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var actionRow: some View {
        HStack(spacing: SQSpace.lg) {
            Button {
                Task { await toggleLike() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(liked ? SQColor.brandRed : .white)
                        .symbolEffectBounceCompat(value: liked)
                    Text("\(likeCount)")
                        .font(SQFont.archivo(14, .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
            }
            .disabled(likeBusy)
            .buttonStyle(SQPressButtonStyle())

            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(comments.count)")
                    .font(SQFont.archivo(14, .semibold))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white)

            Spacer()
        }
    }

    // MARK: Commentaires

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            if isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity)
            } else if comments.isEmpty {
                Text("Soyez le premier à commenter")
                    .font(SQFont.body(13, .regular))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        ForEach(comments) { comment in
                            commentRow(comment)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            composer
        }
    }

    private func commentRow(_ comment: PhotoComment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(comment.userName ?? "Membre")
                    .font(SQFont.archivo(13, .bold))
                    .foregroundStyle(.white)
                if let date = comment.createdAt {
                    Text(date.formatted(.relative(presentation: .numeric)))
                        .font(SQFont.body(11, .regular))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Text(comment.content ?? "")
                .font(SQFont.body(13, .regular))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        HStack(spacing: SQSpace.sm) {
            TextField("Ajouter un commentaire…", text: $commentDraft, axis: .vertical)
                .font(SQFont.body(14, .regular))
                .foregroundStyle(.white)
                .tint(SQColor.brandRed)
                .focused($commentFocused)
                .lineLimit(1...3)
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .background(.white.opacity(0.1), in: Capsule())

            Button {
                Task { await sendComment() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(canSend ? SQColor.brandRed : Color.white.opacity(0.18), in: Circle())
            }
            .disabled(!canSend || sendingComment)
        }
    }

    private var canSend: Bool {
        !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Données

    private func load() async {
        async let detail = try? service.photo(id: photoId)
        async let loadedComments = try? service.comments(photoId: photoId)
        let photoResult = await detail
        let commentsResult = await loadedComments ?? []
        await MainActor.run {
            if let photoResult {
                self.photo = photoResult
                self.likeCount = photoResult.likeCount ?? photoResult.likes ?? 0
                self.liked = photoResult.isLikedByMe ?? photoResult.likedByCurrentUser ?? false
            }
            self.comments = commentsResult
            self.isLoading = false
        }
    }

    private func toggleLike() async {
        guard !likeBusy else { return }
        likeBusy = true
        defer { likeBusy = false }
        // Optimisme : bascule immédiate puis réconciliation serveur.
        let previousLiked = liked
        let previousCount = likeCount
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            liked.toggle()
            likeCount = max(0, likeCount + (liked ? 1 : -1))
        }
        Haptics.light()
        do {
            let response = try await service.toggleLike(photoId: photoId, reaction: "❤️")
            await MainActor.run {
                if let serverLiked = response.liked { liked = serverLiked }
                if let serverLikes = response.likes { likeCount = serverLikes }
            }
        } catch {
            await MainActor.run {
                liked = previousLiked
                likeCount = previousCount
            }
        }
    }

    private func sendComment() async {
        let content = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !sendingComment else { return }
        sendingComment = true
        defer { sendingComment = false }
        commentFocused = false
        do {
            if let created = try await service.addComment(photoId: photoId, content: content) {
                await MainActor.run {
                    withAnimation { comments.append(created) }
                    commentDraft = ""
                }
            } else {
                // Réponse sans corps : on recharge la liste pour rester cohérent.
                let refreshed = (try? await service.comments(photoId: photoId)) ?? comments
                await MainActor.run {
                    comments = refreshed
                    commentDraft = ""
                }
            }
        } catch {
            // On garde le brouillon pour permettre un nouvel essai.
        }
    }
}

/// Image plein écran zoomable (pincement + double-tap), avec vignette de
/// transition pendant le chargement de l'image pleine résolution.
private struct ZoomablePhoto: View {
    let url: URL?
    let placeholder: URL?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    fallback
                } else if let placeholder {
                    AsyncImage(url: placeholder) { p in
                        (p.image ?? Image(systemName: "photo")).resizable().scaledToFit().blur(radius: 8).opacity(0.6)
                    }
                    .overlay { ProgressView().tint(.white) }
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { value in scale = min(max(lastScale * value, 1), 4) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 { withAnimation(.spring) { resetZoom() } }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if scale > 1 { resetZoom() } else { scale = 2.5; lastScale = 2.5 }
                }
            }
        }
    }

    private var fallback: some View {
        Label("Photo indisponible", systemImage: "photo.badge.exclamationmark")
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resetZoom() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }
}
