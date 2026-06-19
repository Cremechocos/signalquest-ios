import SwiftUI
import PhotosUI
import MapKit
import CoreLocation

// ════════════════════════════════════════════════════════════════
// MARK: - ViewModel
// ════════════════════════════════════════════════════════════════

@MainActor
final class PhotosViewModel: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var selectedPhoto: Photo?
    @Published var comments: [PhotoComment] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var draft: String = ""
    @Published var isSending = false

    private let service: PhotoServicing

    init(service: PhotoServicing) {
        self.service = service
    }

    func load() async {
        if AppEnvironment.usesDemoData {
            photos = Photo.demoList
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await service.listPhotos(filter: "approved", sortBy: "recent", limit: 30)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ photo: Photo) async {
        selectedPhoto = photo
        comments = []
        draft = ""
        if AppEnvironment.usesDemoData {
            comments = PhotoComment.demo
            return
        }
        do {
            comments = try await service.comments(photoId: photo.id)
        } catch {
            comments = []
        }
    }

    func like(_ photo: Photo) async {
        let isLiked = photo.isLikedByMe == true || photo.likedByCurrentUser == true
        let currentLikes = photo.likeCount ?? photo.likes ?? 0
        let newLiked = !isLiked
        let newLikes = max(0, currentLikes + (newLiked ? 1 : -1))

        let updated = photo.updatingLike(liked: newLiked, count: newLikes)
        updatePhotoInState(updated)

        if AppEnvironment.usesDemoData {
            Haptics.light()
            return
        }
        do {
            let response = try await service.toggleLike(photoId: photo.id, reaction: "❤️")
            let finalPhoto = photo.updatingLike(
                liked: response.liked ?? newLiked,
                count: response.likes ?? newLikes
            )
            updatePhotoInState(finalPhoto)
            Haptics.light()
        } catch {
            updatePhotoInState(photo)
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func sendComment() async {
        guard let photo = selectedPhoto else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            if AppEnvironment.usesDemoData {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let comment = PhotoComment(
                    id: "demo-comment-\(UUID().uuidString)",
                    photoId: photo.id,
                    userId: "demo-user",
                    userName: "Moi",
                    content: trimmed,
                    createdAt: Date(),
                    updatedAt: nil,
                    parentId: nil,
                    avatarUrl: nil
                )
                comments.insert(comment, at: 0)
                updatePhotoInState(photo.updatingCommentCount(count: (photo.commentCount ?? 0) + 1))
                draft = ""
                Haptics.success()
                return
            }
            if let comment = try await service.addComment(photoId: photo.id, content: trimmed) {
                comments.insert(comment, at: 0)
                updatePhotoInState(photo.updatingCommentCount(count: (photo.commentCount ?? 0) + 1))
            }
            draft = ""
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func share(
        _ photo: Photo,
        to conversation: MessageConversation,
        messagesService: MessagesServicing,
        feedService: SocialFeedServicing,
        e2ee: E2EEServicing?
    ) async -> Bool {
        do {
            if AppEnvironment.usesDemoData {
                try? await Task.sleep(nanoseconds: 300_000_000)
                Haptics.success()
                return true
            }
            if let postId = photo.socialPostId, !postId.isEmpty {
                _ = try await feedService.share(postId: postId, conversationId: conversation.id)
            } else {
                let attachment = UploadedAttachment(
                    kind: "IMAGE",
                    url: photo.imageUrl?.absoluteString ?? photo.thumbnailUrl?.absoluteString ?? "",
                    fileName: "photo.jpg",
                    contentType: "image/jpeg",
                    size: nil, width: nil, height: nil
                )
                _ = try await messagesService.sendAttachments(
                    [attachment],
                    caption: photo.displayCaption,
                    in: conversation,
                    replyToId: nil,
                    e2ee: e2ee
                )
            }
            Haptics.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    func upload(data: Data, siteId: String, description: String, operatorName: String) async {
        do {
            let photo = try await service.uploadPhoto(
                data: data, siteId: siteId, description: description,
                anfrCode: nil, operatorName: operatorName
            )
            photos.insert(photo, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updatePhotoInState(_ updated: Photo) {
        if let i = photos.firstIndex(where: { $0.id == updated.id }) { photos[i] = updated }
        if selectedPhoto?.id == updated.id { selectedPhoto = updated }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - PhotosView — galerie
// ════════════════════════════════════════════════════════════════

struct PhotosView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: PhotosViewModel
    @State private var showingUpload = false

    init(service: PhotoServicing = PhotoService(api: APIClient())) {
        _model = StateObject(wrappedValue: PhotosViewModel(service: service))
    }

    private let twoColumns = [
        GridItem(.flexible(), spacing: SQSpace.sm),
        GridItem(.flexible(), spacing: SQSpace.sm)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                galleryHeader
                if model.isLoading && model.photos.isEmpty {
                    gallerySkeleton
                } else if model.photos.isEmpty {
                    EmptyStateView(
                        title: "Aucune photo",
                        message: "Les photos validées apparaîtront ici.",
                        systemImage: "photo.on.rectangle"
                    )
                } else {
                    galleryContent
                }
                if let error = model.errorMessage {
                    ErrorStateView(title: "Photos indisponibles", message: error)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md)
            .padding(.bottom, 96)
        }
        .navigationTitle("Photos")
        .toolbarTitleInlineCompat()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingUpload = true } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(SQColor.brandRed)
                }
                .accessibilityLabel("Ajouter une photo")
            }
        }
        .signalQuestBackground()
        .task { if model.photos.isEmpty { await model.load() } }
        .sheet(item: $model.selectedPhoto) { _ in
            if let selected = model.selectedPhoto {
                PhotoDetailView(
                    photo: Binding(
                        get: { model.selectedPhoto ?? selected },
                        set: { model.selectedPhoto = $0 }
                    ),
                    comments: model.comments,
                    draft: $model.draft,
                    isSending: model.isSending,
                    onLike: { Task { await model.like(model.selectedPhoto ?? selected) } },
                    onSend: { Task { await model.sendComment() } },
                    onShareToConversation: { conversation in
                        await model.share(
                            model.selectedPhoto ?? selected,
                            to: conversation,
                            messagesService: services.messages,
                            feedService: services.feed,
                            e2ee: services.e2ee
                        )
                    }
                )
                .presentationDetents([.large])
                .presentationBackgroundCompat(.ultraThinMaterial)
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showingUpload) {
            PhotoUploadView(antennas: services.antennas) { data, siteId, desc, op in
                Task {
                    await model.upload(data: data, siteId: siteId, description: desc, operatorName: op)
                    showingUpload = false
                }
            }
            .presentationDetents([.large])
            .presentationBackgroundCompat(.ultraThinMaterial)
        }
    }

    // MARK: Header

    private var galleryHeader: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text("Terrain").sqKicker()
            SQSectionHeader("Photos") {
                HStack(spacing: SQSpace.sm) {
                    if !model.photos.isEmpty {
                        Text("\(model.photos.count) photos")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    Image(systemName: "camera.aperture")
                        .font(.title2)
                        .foregroundStyle(SQColor.brandRed)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var galleryContent: some View {
        if let first = model.photos.first {
            featuredTile(first)
                .onTapGesture { Task { await model.open(first) } }
                .sqFadeUp()
        }
        if model.photos.count > 1 {
            LazyVGrid(columns: twoColumns, spacing: SQSpace.sm) {
                ForEach(model.photos.dropFirst()) { photo in
                    gridTile(photo)
                        .onTapGesture { Task { await model.open(photo) } }
                        .sqFadeUp()
                }
            }
        }
    }

    // MARK: Featured tile — pleine largeur, 16:9

    private func featuredTile(_ photo: Photo) -> some View {
        let opColor = SQBrand.operatorColor(photo.operator)
        let isLiked = photo.isLikedByMe == true || photo.likedByCurrentUser == true
        return ZStack(alignment: .bottom) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RemoteImage(url: photo.imageUrl ?? photo.thumbnailUrl, maxDimension: 800, contentMode: .fill) {
                        Rectangle().fill(SQColor.fill).sqShimmer()
                    }
                }
            // Scrim + métadonnées
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(photo.displayCaption)
                        .font(SQType.subhead)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let address = photo.siteAddress, !address.isEmpty {
                        Label(address, systemImage: "mappin")
                            .font(SQFont.archivo(11, .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label("\(photo.likeCount ?? photo.likes ?? 0)", systemImage: isLiked ? "heart.fill" : "heart")
                        .font(SQFont.archivo(12, .semibold))
                        .foregroundStyle(isLiked ? SQColor.like : .white)
                    Label("\(photo.commentCount ?? 0)", systemImage: "bubble.left")
                        .font(SQFont.archivo(12, .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(SQSpace.md + 2)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
            )
        }
        .overlay(alignment: .topTrailing) {
            if let op = photo.operator, !op.isEmpty {
                Text(op.uppercased())
                    .font(SQType.micro)
                    .foregroundStyle(.white)
                    .padding(.horizontal, SQSpace.sm + 2)
                    .padding(.vertical, SQSpace.xs)
                    .background(opColor, in: Capsule())
                    .padding(SQSpace.sm)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous)
                .stroke(SQColor.separator.opacity(0.5), lineWidth: 1)
        }
    }

    // MARK: Grid tile — 2 colonnes, format 3:4

    private func gridTile(_ photo: Photo) -> some View {
        let opColor = SQBrand.operatorColor(photo.operator)
        let isLiked = photo.isLikedByMe == true || photo.likedByCurrentUser == true
        return ZStack(alignment: .bottom) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    RemoteImage(url: photo.thumbnailUrl ?? photo.imageUrl, maxDimension: 300, contentMode: .fill) {
                        Rectangle().fill(SQColor.fill).sqShimmer()
                    }
                }
            // Légende + opérateur + likes
            VStack(alignment: .leading, spacing: 3) {
                Text(photo.displayCaption)
                    .font(SQType.micro)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: SQSpace.xs) {
                    Circle()
                        .fill(opColor)
                        .frame(width: 6, height: 6)
                    if let op = photo.operator, !op.isEmpty {
                        Text(op)
                            .font(SQFont.archivo(11, .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isLiked ? SQColor.like : .white.opacity(0.9))
                    Text("\(photo.likeCount ?? photo.likes ?? 0)")
                        .font(SQFont.archivo(11, .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(SQSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous)
                .stroke(opColor.opacity(0.25), lineWidth: 1)
        }
    }

    // MARK: Skeleton

    private var gallerySkeleton: some View {
        VStack(spacing: SQSpace.sm) {
            RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous)
                .fill(SQColor.fill)
                .aspectRatio(16 / 9, contentMode: .fit)
                .sqShimmer()
            LazyVGrid(columns: twoColumns, spacing: SQSpace.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous)
                        .fill(SQColor.fill)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .sqShimmer()
                }
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - PhotoDetailView
// ════════════════════════════════════════════════════════════════

struct PhotoDetailView: View {
    @Binding var photo: Photo
    let comments: [PhotoComment]
    @Binding var draft: String
    let isSending: Bool
    let onLike: () -> Void
    let onSend: () -> Void
    let onShareToConversation: (MessageConversation) async -> Bool

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var showReport = false
    @State private var showShareSheet = false
    @State private var showNativeShare = false
    @State private var showAntennaDetail = false
    @FocusState private var commentFocused: Bool

    private var isLiked: Bool { photo.isLikedByMe == true || photo.likedByCurrentUser == true }
    private var likeCount: Int { photo.likeCount ?? photo.likes ?? 0 }
    private var commentCount: Int { photo.commentCount ?? comments.count }
    private var opColor: Color { SQBrand.operatorColor(photo.operator) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        heroSection
                        infoSection
                    }
                }
                composerBar
            }
            .signalQuestBackground()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.brandRed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showShareSheet = true } label: {
                            Label("Partager sur Signal Quest", systemImage: "bubble.left.and.bubble.right")
                        }
                        Button { showNativeShare = true } label: {
                            Label("Partager ailleurs…", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) { showReport = true } label: {
                            Label("Signaler la photo", systemImage: "flag")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Plus d'options")
                }
            }
            .sheet(isPresented: $showReport) {
                ReportSheet(targetType: "photo", targetId: photo.id, service: services.reports)
            }
            .sheet(isPresented: $showShareSheet) {
                PhotoShareSheet(photo: photo, messagesService: services.messages, onShare: onShareToConversation)
            }
            .sheet(isPresented: $showNativeShare) {
                let shareText = "\(photo.displayCaption) — Partagé via SignalQuest"
                if let url = photo.imageUrl {
                    ShareSheet(items: [shareText, url])
                } else {
                    ShareSheet(items: [shareText])
                }
            }
            .sheet(isPresented: $showAntennaDetail) {
                if let site = photo.minimalSite {
                    AntennaDetailSheet(
                        site: site,
                        market: "FR",
                        operatorName: photo.operator ?? "ALL",
                        service: services.antennas
                    )
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundCompat(.ultraThinMaterial)
                }
            }
        }
    }

    // MARK: Hero image

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    RemoteImage(url: photo.imageUrl ?? photo.thumbnailUrl, maxDimension: 1200, contentMode: .fill) {
                        Rectangle().fill(SQColor.fill).sqShimmer()
                    }
                }
                .clipped()
            // Badge opérateur
            if let op = photo.operator, !op.isEmpty {
                Text(op.uppercased())
                    .font(SQFont.archivo(9, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SQSpace.sm + 2)
                    .padding(.vertical, SQSpace.xs)
                    .background(opColor, in: Capsule())
                    .padding(SQSpace.md)
            }
        }
    }

    // MARK: Info panel

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.xl) {
            photoMeta
            actionsRow
            if let cap = photo.caption ?? photo.description, !cap.isEmpty {
                Text(cap)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if photo.siteId != nil {
                antennaCard
            }
            commentsSection
        }
        .padding(SQSpace.lg)
        .padding(.bottom, SQSpace.xxl)
    }

    // MARK: Titre + auteur

    private var photoMeta: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(photo.displayCaption)
                .font(SQType.title)
                .foregroundStyle(SQColor.label)

            // Site + adresse
            let metaParts = [photo.siteAddress, photo.siteId].compactMap { $0 }.filter { !$0.isEmpty }
            if !metaParts.isEmpty {
                Label(metaParts.joined(separator: " · "), systemImage: "mappin")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }

            // Auteur
            HStack(spacing: SQSpace.sm) {
                SQAvatar(url: photo.authorAvatar, name: photo.authorName ?? "?", size: 28)
                Text(photo.authorName ?? "Contributeur")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(SQColor.label)
                Spacer()
                if let date = photo.uploadedAt ?? photo.createdAt {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }

    // MARK: Barre d'actions

    private var actionsRow: some View {
        HStack(spacing: SQSpace.xl) {
            // Like
            Button(action: onLike) {
                HStack(spacing: SQSpace.xs + 2) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isLiked ? SQColor.like : SQColor.labelSecondary)
                        .sqLikePop(trigger: isLiked)
                    Text("\(likeCount)")
                        .font(SQFont.archivo(14, .semibold))
                        .foregroundStyle(SQColor.label)
                        .contentTransition(.numericText())
                }
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel(isLiked ? "Retirer le like" : "Liker")

            // Commentaire
            Button { commentFocused = true } label: {
                HStack(spacing: SQSpace.xs + 2) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                    Text("\(commentCount)")
                        .font(SQFont.archivo(14, .semibold))
                        .foregroundStyle(SQColor.label)
                        .contentTransition(.numericText())
                }
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Commenter")

            Spacer()

            // Partager
            Menu {
                Button { showShareSheet = true } label: {
                    Label("Partager sur Signal Quest", systemImage: "bubble.left.and.bubble.right")
                }
                Button { showNativeShare = true } label: {
                    Label("Partager ailleurs…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "paperplane")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Partager")
        }
        .padding(SQSpace.md + 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1)
        }
    }

    // MARK: Lien vers l'antenne

    private var antennaCard: some View {
        Button {
            Haptics.light()
            showAntennaDetail = true
        } label: {
            HStack(spacing: SQSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                        .fill(opColor.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(opColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voir l'antenne")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.label)
                    Text([photo.siteAddress, photo.siteId].compactMap { $0 }.first ?? "")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
            .padding(SQSpace.md + 2)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                    .stroke(opColor.opacity(0.28), lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Commentaires

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            SQSectionHeader("Commentaires") {
                EmptyView()
            }
            if comments.isEmpty {
                EmptyStateView(
                    title: "Aucun commentaire",
                    message: "Sois le premier à commenter cette photo.",
                    systemImage: "bubble.right"
                )
            } else {
                VStack(spacing: SQSpace.sm) {
                    ForEach(comments) { comment in
                        commentBubble(comment)
                    }
                }
            }
        }
    }

    private func commentBubble(_ comment: PhotoComment) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm) {
            SQAvatar(url: comment.avatarUrl, name: comment.userName ?? "?", size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(comment.userName ?? "Utilisateur")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SQColor.label)
                    Spacer()
                    if let date = comment.createdAt {
                        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(.caption2)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Text(comment.content ?? "")
                    .font(.footnote)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SQSpace.md)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                    .stroke(SQColor.separator, lineWidth: 1)
            }
        }
    }

    // MARK: Composer

    private var composerBar: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: SQSpace.sm) {
            TextField("Ajouter un commentaire…", text: $draft, axis: .vertical)
                .textFieldStyle(SQTextFieldStyle())
                .lineLimit(1...4)
                .focused($commentFocused)
            Button {
                onSend()
                commentFocused = false
            } label: {
                ZStack {
                    Circle()
                        .fill(canSend ? AnyShapeStyle(SQGradient.signal) : AnyShapeStyle(SQColor.fill))
                        .frame(width: 40, height: 40)
                    if isSending {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .disabled(!canSend || isSending)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SQSpace.md + 2)
        .padding(.vertical, SQSpace.sm + 2)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - PhotoUploadView
// ════════════════════════════════════════════════════════════════

@MainActor
struct PhotoUploadView: View {
    let antennas: AntennasServicing
    var onUpload: (Data, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var selectedSite: AntennaSite?
    @State private var description = ""
    @State private var showSitePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    SQSheetHandle()

                    // Aperçu image
                    ZStack {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 260)
                                .clipShape(RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: SQRadius.xxl)
                                .fill(SQColor.fill)
                                .frame(height: 260)
                                .overlay {
                                    VStack(spacing: SQSpace.sm) {
                                        Image(systemName: "photo.badge.plus")
                                            .font(.largeTitle)
                                            .foregroundStyle(SQColor.labelSecondary)
                                        Text("Aperçu photo")
                                            .font(SQType.caption)
                                            .foregroundStyle(SQColor.labelSecondary)
                                    }
                                }
                        }
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choisir une photo", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(SQColor.brandRed)
                    .onChangeCompat(of: pickerItem) { _, newItem in
                        Task {
                            guard let data = try? await newItem?.loadTransferable(type: Data.self),
                                  let loaded = UIImage(data: data) else { return }
                            image = loaded
                        }
                    }

                    // Sélection du site
                    Button { showSitePicker = true } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(SQColor.brandRed)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedSite.map { $0.siteId ?? $0.id } ?? "Choisir un site")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(SQColor.label)
                                if let address = selectedSite?.address {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(SQColor.labelTertiary)
                        }
                        .padding(SQSpace.md + 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                                .stroke(SQColor.separator, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)

                    TextField("Légende", text: $description, axis: .vertical)
                        .textFieldStyle(SQTextFieldStyle())
                        .lineLimit(2...5)

                    GradientButton("Uploader", systemImage: "arrow.up.circle") {
                        guard let data = image?.jpegData(compressionQuality: 0.82),
                              let site = selectedSite else { return }
                        onUpload(data, site.siteId ?? site.id, description, site.operators.first ?? "")
                    }
                    .disabled(image == nil || selectedSite == nil)
                    .opacity(image == nil || selectedSite == nil ? 0.5 : 1)
                }
                .padding(SQSpace.lg)
            }
            .navigationTitle("Nouvelle photo")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }.tint(SQColor.brandRed)
                }
            }
            .signalQuestBackground()
            .sheet(isPresented: $showSitePicker) {
                AntennaSitePickerSheet(antennas: antennas) { site in
                    selectedSite = site
                    showSitePicker = false
                }
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - PhotoShareSheet
// ════════════════════════════════════════════════════════════════

struct PhotoShareSheet: View {
    let photo: Photo
    let messagesService: MessagesServicing
    let onShare: (MessageConversation) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [MessageConversation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var busyConversationId: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Photo") {
                    HStack(spacing: SQSpace.md) {
                        RemoteImage(url: photo.thumbnailUrl ?? photo.imageUrl, maxDimension: 120, contentMode: .fill) {
                            Rectangle().fill(SQColor.fill)
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Text(photo.displayCaption)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SQColor.label)
                                .lineLimit(2)
                            if let op = photo.operator {
                                Text(op)
                                    .font(.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                    }
                }

                Section("Partager sur Signal Quest") {
                    if isLoading {
                        ProgressView()
                    } else if conversations.isEmpty {
                        Text("Aucune conversation active")
                            .font(.footnote)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    ForEach(conversations) { conversation in
                        Button {
                            Task { await share(conversation) }
                        } label: {
                            HStack(spacing: SQSpace.md) {
                                SQAvatar(
                                    url: conversation.groupPhotoUrl ?? conversation.participants.first?.user.avatarUrl,
                                    name: conversation.displayTitle,
                                    size: 40
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.displayTitle.isEmpty ? "Conversation" : conversation.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(SQColor.label)
                                    Text(conversation.e2eeEnabled == true ? "Chiffrée" : "Conversation")
                                        .font(.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                                Spacer()
                                if busyConversationId == conversation.id {
                                    ProgressView().tint(SQColor.brandRed)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                        .foregroundStyle(SQColor.brandRed)
                                }
                            }
                        }
                        .disabled(busyConversationId != nil)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(SQColor.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle("Partager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            conversations = AppEnvironment.usesDemoData ? .demo : try await messagesService.conversations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func share(_ conversation: MessageConversation) async {
        busyConversationId = conversation.id
        defer { busyConversationId = nil }
        if await onShare(conversation) { dismiss() }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - AntennaSitePickerSheet
// ════════════════════════════════════════════════════════════════

struct AntennaSitePickerSheet: View {
    let antennas: AntennasServicing
    let onSelect: (AntennaSite) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var locationService = LocationService()
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var sites: [AntennaSite] = []
    @State private var visibleBox: BoundingBox?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var sitesLoadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                SQRegionMap(
                    region: Binding(get: { region }, set: { newRegion in
                        region = newRegion
                        scheduleSitesLoad(for: newRegion)
                    }),
                    items: sites.filter { $0.latitude != nil && $0.longitude != nil }
                ) { site in
                    MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: site.latitude!, longitude: site.longitude!)) {
                        Button {
                            onSelect(site)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(SQColor.brandRed)
                                    .frame(width: 28, height: 28)
                                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .onAppear { scheduleSitesLoad(for: region) }

                VStack(spacing: SQSpace.sm) {
                    HStack(spacing: SQSpace.sm) {
                        if isLoading { ProgressView().tint(SQColor.brandRed) }
                        Text(sites.isEmpty ? "Déplace la carte pour charger" : "\(sites.count) sites visibles")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(SQColor.label)
                    }
                    .padding(.horizontal, SQSpace.md + 2)
                    .padding(.vertical, SQSpace.sm + 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(SQColor.separator, lineWidth: 1))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(SQColor.danger)
                            .padding(.horizontal, SQSpace.md)
                            .padding(.vertical, SQSpace.xs + 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.top, SQSpace.md)
            }
            .navigationTitle("Choisir un site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }.tint(SQColor.brandRed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let location = locationService.lastLocation {
                            let target = MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            )
                            region = target
                            scheduleSitesLoad(for: target)
                        } else {
                            locationService.requestOneShotLocation()
                        }
                    } label: {
                        Image(systemName: "location.fill").foregroundStyle(SQColor.brandRed)
                    }
                }
            }
            .task { locationService.requestOneShotLocation() }
            .onReceive(locationService.$lastLocation.compactMap { $0 }) { location in
                let target = MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )
                region = target
                scheduleSitesLoad(for: target)
            }
        }
    }

    private func scheduleSitesLoad(for region: MKCoordinateRegion) {
        visibleBox = BoundingBox(
            north: region.center.latitude + region.span.latitudeDelta / 2,
            south: region.center.latitude - region.span.latitudeDelta / 2,
            east: region.center.longitude + region.span.longitudeDelta / 2,
            west: region.center.longitude - region.span.longitudeDelta / 2
        )
        sitesLoadTask?.cancel()
        sitesLoadTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await loadSites()
        }
    }

    private func loadSites() async {
        guard let box = visibleBox else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            sites = try await antennas.list(bbox: box)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - Photo extensions
// ════════════════════════════════════════════════════════════════

extension Photo {
    /// Construit un `AntennaSite` minimal pour ouvrir la fiche depuis une photo.
    var minimalSite: AntennaSite? {
        guard let siteId else { return nil }
        return AntennaSite(
            id: siteId,
            siteId: siteId,
            latitude: latitude,
            longitude: longitude,
            operators: [self.operator].compactMap { $0 },
            technologies: [],
            bands: [],
            azimuths: [],
            sharingType: nil,
            crozonLeader: nil,
            address: siteAddress,
            height: nil,
            owner: nil
        )
    }

    func updatingLike(liked: Bool, count: Int) -> Photo {
        Photo(
            id: id, siteId: siteId, enb: enb,
            imageUrl: imageUrl, thumbnailUrl: thumbnailUrl, ogImageUrl: ogImageUrl,
            uploadedAt: uploadedAt, createdAt: createdAt,
            description: description, caption: caption,
            likes: count, likeCount: count,
            socialPostId: socialPostId, approved: approved,
            operator: self.operator,
            commentCount: commentCount, repostsCount: repostsCount,
            favoritesCount: favoritesCount, reactions: reactions,
            likedByCurrentUser: liked, isLikedByMe: liked,
            userReaction: userReaction,
            authorId: authorId, authorName: authorName, authorAvatar: authorAvatar,
            siteAddress: siteAddress, latitude: latitude, longitude: longitude
        )
    }

    func updatingCommentCount(count: Int) -> Photo {
        Photo(
            id: id, siteId: siteId, enb: enb,
            imageUrl: imageUrl, thumbnailUrl: thumbnailUrl, ogImageUrl: ogImageUrl,
            uploadedAt: uploadedAt, createdAt: createdAt,
            description: description, caption: caption,
            likes: likes, likeCount: likeCount,
            socialPostId: socialPostId, approved: approved,
            operator: self.operator,
            commentCount: count, repostsCount: repostsCount,
            favoritesCount: favoritesCount, reactions: reactions,
            likedByCurrentUser: likedByCurrentUser, isLikedByMe: isLikedByMe,
            userReaction: userReaction,
            authorId: authorId, authorName: authorName, authorAvatar: authorAvatar,
            siteAddress: siteAddress, latitude: latitude, longitude: longitude
        )
    }

    static var demoList: [Photo] {
        [
            Photo(
                id: "demo-photo-1", siteId: "PAR-001", enb: nil,
                imageUrl: nil, thumbnailUrl: nil, ogImageUrl: nil,
                uploadedAt: Date(), createdAt: Date(),
                description: "Site urbain validé par la communauté",
                caption: "Paris centre",
                likes: 12, likeCount: 12,
                socialPostId: nil, approved: true,
                operator: "Orange",
                commentCount: 2, repostsCount: 0, favoritesCount: 4,
                reactions: [], likedByCurrentUser: false, isLikedByMe: false,
                userReaction: nil,
                authorId: "demo", authorName: "SignalQuest", authorAvatar: nil,
                siteAddress: "Paris", latitude: 48.8566, longitude: 2.3522
            ),
            Photo(
                id: "demo-photo-2", siteId: "LYO-002", enb: nil,
                imageUrl: nil, thumbnailUrl: nil, ogImageUrl: nil,
                uploadedAt: Date(), createdAt: Date(),
                description: "Photo de support antenne",
                caption: "Lyon Presqu'île",
                likes: 8, likeCount: 8,
                socialPostId: nil, approved: true,
                operator: "SFR",
                commentCount: 1, repostsCount: 0, favoritesCount: 2,
                reactions: [], likedByCurrentUser: false, isLikedByMe: false,
                userReaction: nil,
                authorId: "demo", authorName: "SignalQuest", authorAvatar: nil,
                siteAddress: "Lyon", latitude: 45.764, longitude: 4.8357
            ),
            Photo(
                id: "demo-photo-3", siteId: "MAR-003", enb: nil,
                imageUrl: nil, thumbnailUrl: nil, ogImageUrl: nil,
                uploadedAt: Date(), createdAt: Date(),
                description: "Antenne en toiture",
                caption: "Marseille Vieux-Port",
                likes: 5, likeCount: 5,
                socialPostId: nil, approved: true,
                operator: "Bouygues",
                commentCount: 0, repostsCount: 0, favoritesCount: 1,
                reactions: [], likedByCurrentUser: false, isLikedByMe: false,
                userReaction: nil,
                authorId: "demo", authorName: "SignalQuest", authorAvatar: nil,
                siteAddress: "Marseille", latitude: 43.2965, longitude: 5.3698
            )
        ]
    }
}

extension PhotoComment {
    static var demo: [PhotoComment] {
        [
            PhotoComment(
                id: "demo-comment-1", photoId: "demo-photo-1",
                userId: "demo-user", userName: "Camille",
                content: "Photo claire, site facile à reconnaître.",
                createdAt: Date(), updatedAt: nil, parentId: nil, avatarUrl: nil
            ),
            PhotoComment(
                id: "demo-comment-2", photoId: "demo-photo-1",
                userId: "demo-user-2", userName: "Thomas",
                content: "Bon angle, on voit bien les secteurs.",
                createdAt: Date(), updatedAt: nil, parentId: nil, avatarUrl: nil
            )
        ]
    }
}
