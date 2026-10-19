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
    @Published var isLoadingMore = false
    @Published var hasMore = false
    /// Total annoncé par le serveur pour le filtre courant ; `nil` s'il ne le donne pas.
    @Published var totalCount: Int?
    @Published var errorMessage: String?
    /// Échec d'une action lancée depuis la fiche d'une photo (like, réseau) :
    /// affiché dans la fiche, pas en « Photos indisponibles » derrière elle
    /// (SOC-14).
    @Published var actionError: String?
    @Published var commentsErrorMessage: String?
    @Published var commentSendErrorMessage: String?
    @Published var isLoadingComments = false
    @Published var draft: String = ""
    @Published var isSending = false
    /// Galerie affichée : `pending` montre les photos de l'utilisateur encore
    /// en vérification, que la galerie publique ne montre jamais (AF-FIL-10).
    @Published var filter: GalleryFilter = .approved

    enum GalleryFilter: String, CaseIterable, Identifiable {
        case approved, mine, pending
        var id: String { rawValue }
        var label: String {
            switch self {
            case .approved: return String(localized: "Toutes")
            case .mine: return String(localized: "Mes photos")
            case .pending: return String(localized: "En vérification")
            }
        }
    }

    private let service: PhotoServicing
    private var page = 1
    private let pageSize = 30
    private var galleryRequest = UUID()
    private var commentsRequest = UUID()
    private var commentContext = UUID()
    private var retryPagination = false

    init(service: PhotoServicing) {
        self.service = service
    }

    /// Retire son propre commentaire (le serveur refuse celui d'un autre).
    func deleteComment(_ comment: PhotoComment) async {
        guard let photo = selectedPhoto else { return }
        do {
            try await service.deleteComment(photoId: photo.id, commentId: comment.id)
            comments.removeAll { $0.id == comment.id }
        } catch {
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }

    func load() async {
        let request = UUID()
        galleryRequest = request
        isLoadingMore = false
        if AppEnvironment.usesDemoData {
            photos = Photo.demoList
            hasMore = false
            totalCount = nil
            errorMessage = nil
            retryPagination = false
            return
        }
        isLoading = true
        defer { if galleryRequest == request { isLoading = false } }
        do {
            let response = try await service.listPhotos(filter: filter.rawValue, sortBy: "recent", page: 1, limit: pageSize)
            guard galleryRequest == request, !Task.isCancelled else { return }
            photos = response.photos
            page = 1
            totalCount = response.meta?.total
            hasMore = response.meta?.hasMore ?? (response.photos.count >= pageSize)
            errorMessage = nil
            retryPagination = false
        } catch {
            if galleryRequest == request, !error.isCancellation {
                errorMessage = error.userFacingMessage
                retryPagination = false
            }
        }
    }

    /// Charge la page suivante et l'ajoute (dédup par id). Déclenché quand la dernière
    /// vignette apparaît. Sans ça, la galerie restait bloquée sur la 1re page (≈ 31
    /// photos) même quand le serveur en avait davantage — `meta.hasMore` était décodé
    /// mais jamais exploité (PHOTO-PAGINATION-01).
    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore, !AppEnvironment.usesDemoData else { return }
        isLoadingMore = true
        let request = galleryRequest
        defer { if galleryRequest == request { isLoadingMore = false } }
        do {
            let response = try await service.listPhotos(filter: filter.rawValue, sortBy: "recent", page: page + 1, limit: pageSize)
            guard galleryRequest == request, !Task.isCancelled else { return }
            var known = Set(photos.map(\.id))
            photos.append(contentsOf: response.photos.filter { known.insert($0.id).inserted })
            page += 1
            totalCount = response.meta?.total ?? totalCount
            hasMore = response.meta?.hasMore ?? (response.photos.count >= pageSize)
            errorMessage = nil
            retryPagination = false
        } catch {
            if galleryRequest == request, !error.isCancellation {
                errorMessage = error.userFacingMessage
                retryPagination = true
            }
        }
    }

    func retryGallery() async {
        if retryPagination { await loadMore() }
        else { await load() }
    }

    func open(_ photo: Photo) async {
        commentContext = UUID()
        selectedPhoto = photo
        comments = []
        draft = ""
        isSending = false
        commentSendErrorMessage = nil
        commentsErrorMessage = nil
        await reloadComments()
    }

    func reloadComments() async {
        guard let photo = selectedPhoto else { return }
        let request = UUID()
        commentsRequest = request
        isLoadingComments = true
        defer { if commentsRequest == request { isLoadingComments = false } }
        if AppEnvironment.usesDemoData {
            comments = PhotoComment.demo
            commentsErrorMessage = nil
            return
        }
        do {
            let loaded = try await service.comments(photoId: photo.id)
            guard commentsRequest == request, selectedPhoto?.id == photo.id, !Task.isCancelled else { return }
            comments = loaded
            commentsErrorMessage = nil
        } catch {
            guard commentsRequest == request, selectedPhoto?.id == photo.id, !error.isCancellation else { return }
            commentsErrorMessage = error.userFacingMessage
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
            if !error.isCancellation { actionError = error.userFacingMessage }
            Haptics.error()
        }
    }

    func sendComment() async {
        guard let photo = selectedPhoto, !isSending else { return }
        let context = commentContext
        let submittedDraft = draft
        let trimmed = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        commentSendErrorMessage = nil
        defer { if commentContext == context { isSending = false } }
        do {
            if AppEnvironment.usesDemoData {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard commentContext == context, selectedPhoto?.id == photo.id, !Task.isCancelled else { return }
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
                if draft == submittedDraft { draft = "" }
                Haptics.success()
                return
            }
            let saved = try await service.addComment(photoId: photo.id, content: trimmed)
            guard commentContext == context, selectedPhoto?.id == photo.id, !Task.isCancelled else { return }
            commentsRequest = UUID()
            isLoadingComments = false
            if let comment = saved {
                comments.insert(comment, at: 0)
                let current = selectedPhoto ?? photo
                updatePhotoInState(current.updatingCommentCount(count: (current.commentCount ?? 0) + 1))
            }
            if draft == submittedDraft { draft = "" }
            Haptics.success()
        } catch {
            guard commentContext == context, selectedPhoto?.id == photo.id, !error.isCancellation else { return }
            commentSendErrorMessage = error.userFacingMessage
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
                    e2ee: e2ee,
                    ttlSeconds: 0
                )
            }
            Haptics.success()
            return true
        } catch {
            // La feuille de partage affiche l'échec : ici il s'affichait
            // derrière deux feuilles (SOC-37).
            Haptics.error()
            return false
        }
    }

    /// Renvoie `nil` si l'envoi a réussi, sinon le message à afficher dans la feuille
    /// (session expirée, fichier trop gros, trop de requêtes… ne sont pas la même panne).
    func upload(data: Data, siteId: String, description: String, operatorName: String?, exifMetadata: String?) async -> String? {
        do {
            let photo = try await service.uploadPhoto(
                data: data, siteId: siteId, description: description,
                anfrCode: nil, operatorName: operatorName, exifMetadata: exifMetadata
            )
            photos.insert(photo, at: 0)
            return nil
        } catch {
            // La feuille d'envoi affiche l'échec elle-même.
            return error.isCancellation ? String(localized: "Échec de l'envoi. Réessaie.") : error.userFacingMessage
        }
    }

    func updateOperator(_ photo: Photo, operatorName: String) async -> Bool {
        let normalized = operatorName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty, normalized != photo.operator?.uppercased() else { return true }
        let updated = photo.updatingOperator(normalized)
        updatePhotoInState(updated)
        do {
            try await service.updatePhotoOperator(photoId: photo.id, operatorName: normalized)
            Haptics.success()
            return true
        } catch {
            updatePhotoInState(photo)
            if !error.isCancellation { actionError = error.userFacingMessage }
            Haptics.error()
            return false
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
    @EnvironmentObject private var session: AuthSessionViewModel
    @StateObject private var model: PhotosViewModel
    @State private var showingUpload = false
    @Environment(\.dismiss) private var dismiss

    init(service: PhotoServicing, initialFilter: PhotosViewModel.GalleryFilter = .approved) {
        let model = PhotosViewModel(service: service)
        model.filter = initialFilter
        _model = StateObject(wrappedValue: model)
    }

    private let twoColumns = [
        GridItem(.flexible(), spacing: SQSpace.sm),
        GridItem(.flexible(), spacing: SQSpace.sm)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                galleryHeader
                if model.isLoading && model.photos.isEmpty {
                    gallerySkeleton
                } else if model.photos.isEmpty && model.errorMessage == nil {
                    EmptyStateView(
                        title: "Aucune photo",
                        message: model.filter == .pending
                            ? "Aucune de tes photos n’attend de vérification."
                            : model.filter == .mine
                                ? "Les photos que tu envoies apparaîtront ici."
                                : "Les photos validées apparaîtront ici.",
                        systemImage: "photo.on.rectangle"
                    )
                } else {
                    galleryContent
                }
                if let error = model.errorMessage {
                    ErrorStateView(title: "Photos indisponibles", message: error, retry: { Task { await model.retryGallery() } })
                        .disabled(model.isLoading || model.isLoadingMore)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, 96)
            .sqReadableWidth()
        }
        .navigationTitle("Photos")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .refreshable { await model.load() }
        .task { if model.photos.isEmpty { await model.load() } }
        .sheet(item: $model.selectedPhoto, onDismiss: { model.actionError = nil }) { _ in
            if let selected = model.selectedPhoto {
                PhotoDetailView(
                    photo: Binding(
                        get: { model.selectedPhoto ?? selected },
                        set: { model.selectedPhoto = $0 }
                    ),
                    comments: model.comments,
                    isLoadingComments: model.isLoadingComments,
                    commentsError: model.commentsErrorMessage,
                    commentSendError: model.commentSendErrorMessage,
                    onRetryComments: { Task { await model.reloadComments() } },
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
                    },
                    onChangeOperator: { photo, networkOperator in
                        await model.updateOperator(photo, operatorName: networkOperator)
                    },
                    actionError: model.actionError,
                    onDeleteComment: { comment in await model.deleteComment(comment) }
                )
                .presentationDetents([.large])
                .presentationBackgroundCompat(SQColor.bg)
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showingUpload) {
            PhotoUploadView(antennas: services.antennas, markets: services.markets) { data, siteId, desc, op, exif in
                await model.upload(data: data, siteId: siteId, description: desc, operatorName: op, exifMetadata: exif)
            }
            .presentationDetents([.large])
            .presentationBackgroundCompat(SQColor.bg)
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: Header

    private var galleryHeader: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "photos.back") { dismiss() }
                Spacer()
                MapChipIconButton(systemImage: "plus", label: "Ajouter une photo", identifier: "photos.add") { showingUpload = true }
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Photos")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("photos.title")
                Text("Les photos d’antennes partagées par la communauté, et les tiennes.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // « Mes photos » et « En vérification » n'ont de sens qu'avec un compte.
            if case .authenticated = session.state {
                SQSegmentedFilter(
                    selection: $model.filter,
                    options: PhotosViewModel.GalleryFilter.allCases.map { (value: $0, label: $0.label, icon: String?.none) }
                )
                // Le segment ajoute sa propre marge latérale : on la compense.
                .padding(.horizontal, -SQSpace.lg)
                .accessibilityIdentifier("photos.filter")
                .onChangeCompat(of: model.filter) { _, _ in
                    Task { await model.load() }
                }
            }
            if !model.photos.isEmpty {
                // Le total serveur quand il existe ; sinon, tant que d'autres pages restent,
                // le nombre de photos chargées plutôt qu'un total qu'on ne connaît pas.
                Group {
                    if let total = model.totalCount, total >= model.photos.count {
                        Text("\(total) photos · les plus récentes d’abord")
                    } else if model.hasMore {
                        Text("\(model.photos.count) photos chargées")
                    } else {
                        Text("\(model.photos.count) photos · les plus récentes d’abord")
                    }
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.horizontal, SQSpace.xs)
                .accessibilityIdentifier("photos.summary")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Content

    @ViewBuilder
    private var galleryContent: some View {
        if let first = model.photos.first {
            featuredTile(first)
                .onTapGesture { Task { await model.open(first) } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Photo \(first.displayCaption)")
                .accessibilityAction { Task { await model.open(first) } }
                .sqFadeUp()
        }
        if model.photos.count > 1 {
            LazyVGrid(columns: twoColumns, spacing: SQSpace.sm) {
                ForEach(model.photos.dropFirst()) { photo in
                    gridTile(photo)
                        .onTapGesture { Task { await model.open(photo) } }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Photo \(photo.displayCaption)")
                        .accessibilityAction { Task { await model.open(photo) } }
                        .sqFadeUp()
                        // Scroll infini : la dernière vignette visible tire la page suivante.
                        .onAppear {
                            if photo.id == model.photos.last?.id { Task { await model.loadMore() } }
                        }
                }
            }
        }
        if model.isLoadingMore {
            SQSpinner()
                .tint(SQColor.brandRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SQSpace.md)
        }
    }

    // MARK: Featured tile — pleine largeur, 16:9

    private func featuredTile(_ photo: Photo) -> some View {
        let isLiked = photo.isLikedByMe == true || photo.likedByCurrentUser == true
        return ZStack(alignment: .bottom) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RemoteImage(url: photo.imageUrl ?? photo.thumbnailUrl, maxDimension: 800, contentMode: .fill, showsFailureUI: true) {
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
                            .font(SQFont.body(12, .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .sqSingleLine()
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Label("\(photo.likeCount ?? photo.likes ?? 0)", systemImage: isLiked ? "heart.fill" : "heart")
                        .font(SQFont.body(12, .semibold))
                        .foregroundStyle(isLiked ? SQColor.like : .white)
                    Label("\(photo.commentCount ?? 0)", systemImage: "bubble.left")
                        .font(SQFont.body(12, .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(SQSpace.md2)
            .background(
                // Voile de lisibilité sous les métadonnées (fonctionnel, pas décoratif).
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
            )
            // Posées sur l'image, les métadonnées plafonnent leur taille : au-delà,
            // elles la recouvraient entière. Le détail de la photo les reprend en grand.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: SQSpace.xs) {
                if photo.approved == false { Self.pendingTag }
                Spacer(minLength: 0)
                if let op = photo.operator, !op.isEmpty { Self.operatorChip(op) }
            }
            .padding(SQSpace.sm)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        // L'image remplie déborde de son cadre : le toucher s'arrête à la tuile.
        .contentShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    // MARK: Grid tile — 2 colonnes, format 3:4

    private func gridTile(_ photo: Photo) -> some View {
        let opColor = SQBrand.operatorColor(photo.operator)
        let isLiked = photo.isLikedByMe == true || photo.likedByCurrentUser == true
        return ZStack(alignment: .bottom) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    RemoteImage(url: photo.thumbnailUrl ?? photo.imageUrl, maxDimension: 300, contentMode: .fill, showsFailureUI: true) {
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
                        Text(verbatim: Self.operatorLabel(op))
                            .font(SQFont.body(12, .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .sqSingleLine()
                    }
                    Spacer()
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isLiked ? SQColor.like : .white.opacity(0.9))
                    Text("\(photo.likeCount ?? photo.likes ?? 0)")
                        .font(SQFont.body(12, .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(SQSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Voile de lisibilité sous la légende (fonctionnel, pas décoratif).
                LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
            )
            // Même plafond que la grande tuile : la vignette garde son format 3:4.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .overlay(alignment: .topLeading) {
            if photo.approved == false {
                Self.pendingTag
                    .padding(SQSpace.sm)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        // L'image remplie déborde de son cadre : le toucher s'arrête à la tuile.
        .contentShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
    }

    /// « Orange » plutôt que la clé brute « ORANGE » ; une clé inconnue reste telle quelle.
    static func operatorLabel(_ raw: String) -> String {
        SQBrand.operatorName(raw) ?? raw
    }

    /// Puce claire posée sur l'image : la pastille de l'opérateur et son nom.
    static func operatorChip(_ raw: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(SQBrand.operatorColor(raw)).frame(width: 8, height: 8)
            Text(verbatim: operatorLabel(raw))
                .font(SQFont.body(12, .bold, relativeTo: .caption2))
                .foregroundStyle(SQColor.label)
                .sqSingleLine()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(SQColor.surface.opacity(0.94), in: Capsule(style: .continuous))
    }

    /// Une photo pas encore validée par la modération.
    static var pendingTag: some View {
        Label("En vérification", systemImage: "hourglass")
            .font(SQFont.body(12, .bold, relativeTo: .caption2))
            .foregroundStyle(OutageTint.degradedInk)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(SQColor.surface.opacity(0.94), in: Capsule(style: .continuous))
    }

    // MARK: Skeleton

    private var gallerySkeleton: some View {
        VStack(spacing: SQSpace.sm) {
            RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                .fill(SQColor.fill)
                .aspectRatio(16 / 9, contentMode: .fit)
                .sqShimmer()
            LazyVGrid(columns: twoColumns, spacing: SQSpace.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
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

struct PhotoCommentsFeedback: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: SQSpace.md) {
            if isLoading && isEmpty {
                ProgressView("Chargement des commentaires…")
                    .foregroundStyle(SQColor.labelSecondary)
                    .tint(SQColor.accentInk)
                    .accessibilityIdentifier("photo.comments.loading")
            } else if let error {
                ErrorStateView(title: "Commentaires indisponibles", message: error, retry: onRetry)
                    .disabled(isLoading)
                    .accessibilityIdentifier("photo.comments.error")
            } else if isEmpty {
                EmptyStateView(title: "Aucun commentaire", message: "Sois le premier à commenter cette photo.",
                               systemImage: "bubble.right")
                    .accessibilityIdentifier("photo.comments.empty")
            }
            if isLoading && !isEmpty { SQSpinner().accessibilityIdentifier("photo.comments.loading") }
        }
    }
}

struct PhotoDetailView: View {
    @Binding var photo: Photo
    let comments: [PhotoComment]
    let isLoadingComments: Bool
    let commentsError: String?
    let commentSendError: String?
    let onRetryComments: () -> Void
    @Binding var draft: String
    let isSending: Bool
    let onLike: () -> Void
    let onSend: () -> Void
    let onShareToConversation: (MessageConversation) async -> Bool
    let onChangeOperator: (Photo, String) async -> Bool
    var actionError: String? = nil
    /// Supprimer son commentaire ; les autres se signalent (AF-FIL-11).
    var onDeleteComment: ((PhotoComment) async -> Void)? = nil

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showReport = false
    @State private var reportedComment: PhotoComment?
    @State private var showShareSheet = false
    @State private var showNativeShare = false
    @State private var showAntennaDetail = false
    @State private var showOperatorPicker = false
    @FocusState private var commentFocused: Bool

    private var isLiked: Bool { photo.isLikedByMe == true || photo.likedByCurrentUser == true }
    private var likeCount: Int { photo.likeCount ?? photo.likes ?? 0 }
    private var commentCount: Int { photo.commentCount ?? comments.count }
    private var photoMarketCode: String? {
        let normalized = photo.marketCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        heroSection
                        if let actionError {
                            Label(actionError, systemImage: "exclamationmark.triangle")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, SQSpace.lg)
                                .padding(.top, SQSpace.md)
                                .accessibilityIdentifier("photo.actionError")
                        }
                        infoSection
                    }
                }
                composerBar
            }
            .signalQuestBackground()
            .overlay(alignment: .top) { floatingBar }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showReport) {
                ReportSheet(target: .photo(photo.id), service: services.reports)
            }
            .sheet(item: $reportedComment) { comment in
                ReportSheet(target: .photoComment(comment.id), service: services.reports)
            }
            .sheet(isPresented: $showShareSheet) {
                PhotoShareSheet(photo: photo, messagesService: services.messages, onShare: onShareToConversation)
            }
            .sheet(isPresented: $showNativeShare) {
                let shareText = String(localized: "\(photo.displayCaption) — Partagé via SignalQuest")
                if let url = photo.imageUrl {
                    ShareSheet(items: [shareText, url])
                } else {
                    ShareSheet(items: [shareText])
                }
            }
            .sheet(isPresented: $showAntennaDetail) {
                if let site = photo.minimalSite, let marketCode = photoMarketCode {
                    AntennaDetailSheet(
                        site: site,
                        market: marketCode,
                        operatorName: photo.operator ?? "ALL",
                        service: services.antennas
                    )
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundCompat(SQColor.bg)
                } else {
                    EmptyStateView(
                        title: "Détails du site indisponibles",
                        message: "Cette ancienne photo ne contient pas de marché vérifiable. SignalQuest ne l’attribue pas automatiquement à la France.",
                        systemImage: "globe.europe.africa"
                    )
                    .padding(SQSpace.lg)
                    .presentationDetents([.medium])
                    .presentationBackgroundCompat(SQColor.bg)
                }
            }
            .confirmationDialog(
                "Réseau concerné",
                isPresented: $showOperatorPicker,
                titleVisibility: .visible
            ) {
                ForEach(operatorChoices, id: \.self) { networkOperator in
                    Button(PhotosView.operatorLabel(networkOperator)) {
                        Task { _ = await onChangeOperator(photo, networkOperator) }
                    }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Cette photo est rattachée à un support mutualisé. Choisis le réseau réellement concerné.")
            }
        }
    }

    /// Fermer et options, en boutons ronds posés sur la photo.
    private var floatingBar: some View {
        HStack {
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "photo.close") { dismiss() }
            Spacer()
            Menu {
                Button { showShareSheet = true } label: {
                    Label("Partager sur SignalQuest", systemImage: "bubble.left.and.bubble.right")
                }
                Button { showNativeShare = true } label: {
                    Label("Partager ailleurs…", systemImage: "square.and.arrow.up")
                }
                // On ne signale pas sa propre photo.
                if ownsPhoto, operatorChoices.count > 1 {
                    Divider()
                    Button { showOperatorPicker = true } label: {
                        Label("Modifier le réseau", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                if !ownsPhoto {
                    Divider()
                    Button(role: .destructive) { showReport = true } label: {
                        Label("Signaler la photo", systemImage: "flag")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .sqSurface(SQColor.chip, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Plus d'options")
            .accessibilityIdentifier("photo.more")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.md)
    }

    private var operatorChoices: [String] {
        Array(Set((photo.siteOperators ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }))
            .sorted()
    }

    private var ownsPhoto: Bool {
        guard case let .authenticated(user) = session.state else { return false }
        return photo.authorId == user.id
    }

    // MARK: Hero image

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    RemoteImage(url: photo.imageUrl ?? photo.thumbnailUrl, maxDimension: 1200, contentMode: .fill, showsFailureUI: true) {
                        Rectangle().fill(SQColor.fill).sqShimmer()
                    }
                }
                .clipped()
            HStack(spacing: SQSpace.sm) {
                if let op = photo.operator, !op.isEmpty { PhotosView.operatorChip(op) }
                if photo.approved == false { PhotosView.pendingTag }
            }
            .padding(SQSpace.md)
        }
    }

    // MARK: Info panel

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.xl) {
            photoMeta
            actionsRow
            // Le titre reprend déjà la légende : on n'ajoute que ce qu'il ne dit pas.
            if let cap = [photo.caption, photo.description].compactMap({ $0 }).first(where: { !$0.isEmpty && $0 != photo.displayCaption }) {
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
                .font(SQFont.display(24, .bold, relativeTo: .title2))
                .foregroundStyle(SQColor.label)
                .sqHeader()

            // Site + adresse
            let metaParts = [photo.siteAddress, photo.siteId].compactMap { $0 }.filter { !$0.isEmpty }
            if !metaParts.isEmpty {
                Label(metaParts.joined(separator: " · "), systemImage: "mappin")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
            }

            // Auteur
            HStack(spacing: SQSpace.sm) {
                SQAvatar(url: photo.authorAvatar, name: photo.authorName ?? "?", size: 28)
                Text(photo.authorName ?? String(localized: "Contributeur"))
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
                HStack(spacing: SQSpace.xs2) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isLiked ? SQColor.like : SQColor.labelSecondary)
                        .sqLikePop(trigger: isLiked)
                    Text("\(likeCount)")
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                        .contentTransition(.numericText())
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel(isLiked ? String(localized: "Retirer le like") : String(localized: "Liker"))

            // Commentaire
            Button { commentFocused = true } label: {
                HStack(spacing: SQSpace.xs2) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                    Text("\(commentCount)")
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                        .contentTransition(.numericText())
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Commenter")

            Spacer()

            // Partager
            Menu {
                Button { showShareSheet = true } label: {
                    Label("Partager sur SignalQuest", systemImage: "bubble.left.and.bubble.right")
                }
                Button { showNativeShare = true } label: {
                    Label("Partager ailleurs…", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "paperplane")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Partager")
        }
        .padding(SQSpace.md2)
        .sqCardBackground()
    }

    // MARK: Lien vers l'antenne

    private var antennaCard: some View {
        Button {
            Haptics.light()
            showAntennaDetail = true
        } label: {
            HStack(spacing: SQSpace.md) {
                SQIconPastille(systemImage: "antenna.radiowaves.left.and.right", size: 44, font: .system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voir l'antenne")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.label)
                    Text([photo.siteAddress, photo.siteId].compactMap { $0 }.first ?? "")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                    if photoMarketCode == nil {
                        Text("Marché non renseigné · attribution automatique désactivée")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.warning)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.md2)
            .sqCardBackground()
        }
        .buttonStyle(SQPressButtonStyle())
    }

    // MARK: Commentaires

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            SQSectionHeader("Commentaires") {
                EmptyView()
            }
            PhotoCommentsFeedback(isLoading: isLoadingComments, error: commentsError,
                                  isEmpty: comments.isEmpty, onRetry: onRetryComments)
            if let commentSendError {
                ErrorStateView(title: "Commentaire non envoyé", message: commentSendError)
                    .accessibilityIdentifier("photo.comments.sendError")
            }
            if !comments.isEmpty {
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
                    Text(comment.userName ?? String(localized: "Utilisateur"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SQColor.label)
                    Spacer()
                    if let date = comment.createdAt {
                        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(SQFont.body(12, relativeTo: .caption2))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Text(comment.content ?? "")
                    .font(.footnote)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SQSpace.md)
            .sqCardBackground(cornerRadius: SQRadius.md, elevation: .rest)
        }
        // Contenu d'utilisateurs : il se signale, comme les commentaires des
        // publications (règle 1.2) ; le sien se supprime.
        .contextMenu {
            if isMine(comment) {
                if let onDeleteComment {
                    Button(role: .destructive) {
                        Task { await onDeleteComment(comment) }
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            } else if case .authenticated = session.state {
                Button(role: .destructive) { reportedComment = comment } label: {
                    Label("Signaler le commentaire", systemImage: "flag")
                }
            }
        }
    }

    private func isMine(_ comment: PhotoComment) -> Bool {
        guard case let .authenticated(user) = session.state else { return false }
        return comment.userId == user.id
    }

    // MARK: Composer

    private var composerBar: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: SQSpace.sm) {
            TextField("Ajouter un commentaire…", text: $draft, axis: .vertical)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .lineLimit(1...4)
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.sm2)
                .frame(minHeight: 44)
                .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous))
                .focused($commentFocused)
            Button {
                onSend()
                commentFocused = false
            } label: {
                ZStack {
                    Circle()
                        .fill(canSend ? SQColor.brandRed : SQColor.surfaceMuted)
                        .frame(width: 44, height: 44)
                    if isSending {
                        SQSpinner()
                            .tint(SQColor.onAccent)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(canSend ? SQColor.onAccent : SQColor.labelTertiary)
                    }
                }
            }
            .disabled(!canSend || isSending)
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Envoyer le commentaire")
        }
        .padding(.horizontal, SQSpace.md2)
        .padding(.vertical, SQSpace.sm2)
        .background(SQColor.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(SQColor.separator).frame(height: 1)
        }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - PhotoUploadView
// ════════════════════════════════════════════════════════════════

@MainActor
struct PhotoUploadView: View {
    let antennas: AntennasServicing
    let markets: MarketRegistryServicing
    /// Renvoie `nil` si l'upload a réussi (la feuille se ferme alors), sinon le
    /// message d'échec à afficher. Le dernier paramètre est le JSON `exifMetadata`
    /// extrait de l'original.
    var onUpload: (Data, String, String, String?, String?) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var imageData: Data?
    /// Zones à flouter (plan 3, vague 1), appliquées à l'envoi sur l'original
    /// réduit : ses métadonnées (position, date) restent celles de l'original.
    @State private var blurRegions: [CGRect] = []
    @State private var showBlurEditor = false
    @State private var isUploading = false
    @State private var uploadError: String?
    @State private var selectedSite: AntennaSite?
    @State private var selectedOperator: String?
    @State private var description = ""
    @State private var showSitePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    uploadHeader
                    // Aperçu image
                    ZStack {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 260)
                                .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                                .sqShadowCard()
                                .overlay(alignment: .topLeading) {
                                    PhotoBlurButton { showBlurEditor = true }
                                        .accessibilityIdentifier("photoUpload.blur")
                                }
                        } else {
                            RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                                .fill(SQColor.surfaceMuted)
                                .frame(height: 260)
                                .overlay {
                                    VStack(spacing: SQSpace.sm) {
                                        Image(systemName: "photo.badge.plus")
                                            .font(.system(size: 22, weight: .medium))
                                            .foregroundStyle(SQColor.brandRed)
                                            .frame(width: 46, height: 46)
                                            .background(SQColor.accentSoft, in: Circle())
                                        Text("Aperçu photo")
                                            .font(SQType.caption)
                                            .foregroundStyle(SQColor.labelSecondary)
                                    }
                                }
                        }
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        HStack(spacing: SQSpace.sm2) {
                            Image(systemName: "photo")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Choisir une photo")
                                .font(SQType.button)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 56)
                        .foregroundStyle(SQColor.label)
                        .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
                        .sqShadowSoft()
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .onChangeCompat(of: pickerItem) { _, newItem in
                        Task {
                            guard let newItem else { return }
                            // Aperçu décodé réduit ; l'envoi garde l'original (SOC-36).
                            let data: Data?
                            do {
                                data = try await newItem.loadTransferable(type: Data.self)
                            } catch {
                                if !error.isCancellation { uploadError = error.userFacingMessage }
                                return
                            }
                            guard let data, let loaded = ImagePipeline.downsample(data: data, maxPixel: 1600) else {
                                uploadError = String(localized: "Image illisible.")
                                return
                            }
                            uploadError = nil
                            imageData = data
                            image = loaded
                            blurRegions = []
                        }
                    }
                    .sheet(isPresented: $showBlurEditor) {
                        if let image {
                            PhotoBlurEditor(image: image) { blurred, regions in
                                // L'aperçu flouté sert de base à une nouvelle retouche :
                                // mêmes proportions, les zones s'additionnent.
                                self.image = blurred
                                blurRegions.append(contentsOf: regions)
                            }
                        }
                    }

                    // Sélection du site
                    Button { showSitePicker = true } label: {
                        HStack(spacing: SQSpace.md) {
                            SQIconPastille(systemImage: "antenna.radiowaves.left.and.right", size: 40, font: .system(size: 16, weight: .medium))
                            VStack(alignment: .leading, spacing: 2) {
                                // L'adresse nomme le site quand on la connaît ; le code passe en second.
                                Text(selectedSite.map { $0.address ?? String(localized: "Site \($0.siteId ?? $0.id)") } ?? String(localized: "Choisir un site"))
                                    .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                                    .foregroundStyle(SQColor.label)
                                    .lineLimit(2)
                                if let site = selectedSite, site.address != nil {
                                    Text("Site \(site.siteId ?? site.id)")
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(SQColor.labelTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(SQSpace.md2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sqCardBackground()
                    }
                    .buttonStyle(SQPressButtonStyle())

                    if availableOperators.count > 1 {
                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Text("Cette photo concerne quel réseau ?")
                                .font(SQType.subhead)
                                .foregroundStyle(SQColor.label)
                            Text("Le support est mutualisé : choisis le réseau visible sur la photo.")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                            Picker("Réseau concerné", selection: $selectedOperator) {
                                Text("Choisir un réseau").tag(String?.none)
                                ForEach(availableOperators, id: \.self) { networkOperator in
                                    Text(verbatim: PhotosView.operatorLabel(networkOperator)).tag(Optional(networkOperator))
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(SQColor.brandRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SQSpace.md)
                            .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                            .accessibilityHint("Choisis l'opérateur réellement concerné par la photo")
                        }
                    } else if let networkOperator = availableOperators.first {
                        Label("Réseau concerné : \(PhotosView.operatorLabel(networkOperator))", systemImage: "antenna.radiowaves.left.and.right")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }

                    TextField("Légende (facultatif)", text: $description, axis: .vertical)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2...5)
                        .padding(SQSpace.md2)
                        .sqFieldSurface(in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))

                    GradientButton("Envoyer la photo", systemImage: "arrow.up.circle", isBusy: isUploading) {
                        guard let original = imageData, let site = selectedSite else { return }
                        let regions = blurRegions
                        Task {
                            isUploading = true
                            uploadError = nil
                            // Extraction EXIF + downscale hors du main thread (PHOTO-PERF-01/SEC-01).
                            let prepared = await Task.detached(priority: .userInitiated) {
                                PhotoUploadPreparation.prepare(from: original, blurRegions: regions)
                            }.value
                            guard let prepared else {
                                isUploading = false
                                uploadError = String(localized: "Image illisible.")
                                return
                            }
                            // Aucun réseau connu sur le support : on ne l'invente
                            // pas. Le serveur conserve alors l'attribution vide ;
                            // seul un support réellement mutualisé impose le choix.
                            let networkOperator = selectedOperator ?? availableOperators.first
                            let failure = await onUpload(prepared.jpeg, site.writeSiteId, description, networkOperator, prepared.exifJSON)
                            isUploading = false
                            if let failure { uploadError = failure } else { dismiss() }
                        }
                    }
                    .disabled(uploadDisabled)
                    .opacity(uploadDisabled ? 0.5 : 1)

                    if let uploadError {
                        SQInlineError(message: uploadError)
                    }
                }
                .padding(SQSpace.lg)
            }
            .navigationTitle("Nouvelle photo")
            .toolbar(.hidden, for: .navigationBar)
            .signalQuestBackground()
            .sheet(isPresented: $showSitePicker) {
                AntennaSitePickerSheet(antennas: antennas, markets: markets) { site in
                    selectedSite = site
                    selectedOperator = nil
                    showSitePicker = false
                }
            }
        }
    }

    private var uploadHeader: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Nouvelle photo")
                    .font(SQFont.display(24, .bold, relativeTo: .title2))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                Text("Elle rejoint la galerie une fois vérifiée par la modération.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            MapChipIconButton(systemImage: "xmark", label: "Annuler", identifier: "photoUpload.close") { dismiss() }
        }
        .padding(.top, SQSpace.sm)
    }

    private var availableOperators: [String] {
        Array(Set((selectedSite?.operators ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }))
            .sorted()
    }

    private var requiresOperatorChoice: Bool { availableOperators.count > 1 }

    private var uploadDisabled: Bool {
        imageData == nil || selectedSite == nil || (requiresOperatorChoice && selectedOperator == nil) || isUploading
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
                Section {
                    HStack(spacing: SQSpace.md) {
                        RemoteImage(url: photo.thumbnailUrl ?? photo.imageUrl, maxDimension: 120, contentMode: .fill, showsFailureUI: true) {
                            Rectangle().fill(SQColor.fill)
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Text(photo.displayCaption)
                                .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(SQColor.label)
                                .lineLimit(2)
                            if let op = photo.operator {
                                Text(verbatim: PhotosView.operatorLabel(op))
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                    }
                    .listRowBackground(SQColor.surface)
                } header: {
                    Text("Photo")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .textCase(nil)
                }

                Section {
                    if isLoading {
                        SQSpinner().tint(SQColor.brandRed)
                            .listRowBackground(SQColor.surface)
                    } else if conversations.isEmpty {
                        Text("Aucune conversation active")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .listRowBackground(SQColor.surface)
                    }
                    ForEach(conversations) { conversation in
                        // Partage indisponible vers une conversation chiffrée : soit la
                        // carte de partage passerait en clair (SEC-1), soit l'envoi de
                        // pièce jointe échouerait en E2EE (UX-3). On désactive plutôt
                        // qu'échouer après coup sous un badge « Chiffrée ».
                        let isE2EE = conversation.e2eeEnabled == true
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
                                    Text(conversation.displayTitle.isEmpty ? String(localized: "Conversation") : conversation.displayTitle)
                                        .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                                        .foregroundStyle(SQColor.label)
                                    Text(isE2EE ? String(localized: "Chiffrée · partage indisponible") : String(localized: "Conversation"))
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                                Spacer()
                                if busyConversationId == conversation.id {
                                    SQSpinner().tint(SQColor.brandRed)
                                } else {
                                    Image(systemName: isE2EE ? "lock.slash" : "paperplane.fill")
                                        .foregroundStyle(isE2EE ? SQColor.labelTertiary : SQColor.brandRed)
                                }
                            }
                        }
                        .disabled(busyConversationId != nil || isE2EE)
                        .listRowBackground(SQColor.surface)
                    }
                } header: {
                    Text("Partager sur SignalQuest")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .textCase(nil)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.dangerInk)
                            .listRowBackground(SQColor.dangerSoft)
                    }
                }
            }
            .listRowSeparatorTint(SQColor.separator)
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
            errorMessage = error.userFacingMessage
        }
    }

    private func share(_ conversation: MessageConversation) async {
        busyConversationId = conversation.id
        defer { busyConversationId = nil }
        errorMessage = nil
        if await onShare(conversation) {
            dismiss()
        } else {
            errorMessage = String(localized: "Échec de l'envoi. Réessaie.")
        }
    }
}

// ════════════════════════════════════════════════════════════════
// MARK: - AntennaSitePickerSheet
// ════════════════════════════════════════════════════════════════

struct AntennaSitePickerSheet: View {
    let antennas: AntennasServicing
    let markets: MarketRegistryServicing
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
    @State private var marketLabel: String?
    @State private var isCommunityFallback = false

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
                            // Cible de 44 pt autour du repère de 28 pt (TRX-14).
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Choisir le site \(site.siteId ?? site.id)"))
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                // Ne charge pas Paris par défaut : le centre initial est seulement
                // un cadrage visuel. Le premier fetch suit un déplacement explicite
                // ou une position autorisée, jamais un marché supposé.

                VStack(spacing: SQSpace.sm) {
                    HStack(spacing: SQSpace.sm) {
                        if isLoading { SQSpinner().tint(SQColor.brandRed) }
                        Text(sites.isEmpty ? String(localized: "Déplace la carte pour charger") : String(localized: "\(sites.count) site visible"))
                            .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(SQColor.label)
                    }
                    .padding(.horizontal, SQSpace.md2)
                    .padding(.vertical, SQSpace.sm2)
                    .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
                    .sqShadowSoft()

                    if let marketLabel {
                        Text(isCommunityFallback ? String(localized: "\(marketLabel) · sites communautaires") : marketLabel)
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                            .padding(.horizontal, SQSpace.md)
                            .padding(.vertical, SQSpace.xs)
                            .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.dangerInk)
                            .padding(.horizontal, SQSpace.md)
                            .padding(.vertical, SQSpace.xs2)
                            .background(SQColor.dangerSoft, in: Capsule(style: .continuous))
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
                        if let location = locationService.cachedLocation() {
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
                    .accessibilityLabel("Recentrer sur ma position")
                }
            }
            // Ne PAS déclencher le prompt système à l'apparition (hors contexte) :
            // on ne demande une position que si l'autorisation est déjà accordée.
            // Sinon l'utilisateur reste maître (le bouton localisation de la barre
            // déclenche la demande sur action explicite) — UXP-11.
            .task {
                let status = locationService.authorizationStatus
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    locationService.requestOneShotLocation()
                }
            }
            .onReceive(locationService.$lastLocation.compactMap { $0 }) { location in
                guard locationService.isUsable(location) else { return }
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
        isCommunityFallback = false

        guard let market = await markets.marketForLocation(
            latitude: region.center.latitude,
            longitude: region.center.longitude
        ) else {
            sites = []
            marketLabel = nil
            errorMessage = String(localized: "Pays non référencé à cet emplacement. Déplace la carte vers une zone terrestre connue.")
            return
        }
        guard !Task.isCancelled else { return }
        let marketCode = market.marketCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !marketCode.isEmpty else {
            sites = []
            marketLabel = nil
            errorMessage = String(localized: "Le registre ne fournit pas de code marché fiable pour cette zone.")
            return
        }
        marketLabel = market.label

        do {
            let operatorKeys = market.selectableOperators
                .map(\.key)
                .filter { !$0.isEmpty && $0.uppercased() != "ALL" }
            var merged: [AntennaSite] = []
            var seen = Set<String>()
            for operatorKey in operatorKeys.isEmpty ? ["ALL"] : operatorKeys {
                guard !Task.isCancelled else { return }
                let batch = try await antennas.list(
                    bbox: box,
                    market: marketCode,
                    operatorName: operatorKey,
                    technologies: []
                )
                for site in batch {
                    let key = site.writeSiteId
                    if seen.insert(key).inserted { merged.append(site) }
                }
            }
            if merged.isEmpty {
                let community = try await antennas.listCommunitySites(
                    bbox: box,
                    market: marketCode,
                    operatorName: nil
                )
                for site in community {
                    let key = site.writeSiteId
                    if seen.insert(key).inserted { merged.append(site) }
                }
                isCommunityFallback = !merged.isEmpty
            }
            sites = merged
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
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
            operator: self.operator, marketCode: marketCode, siteOperators: siteOperators,
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
            operator: self.operator, marketCode: marketCode, siteOperators: siteOperators,
            commentCount: count, repostsCount: repostsCount,
            favoritesCount: favoritesCount, reactions: reactions,
            likedByCurrentUser: likedByCurrentUser, isLikedByMe: isLikedByMe,
            userReaction: userReaction,
            authorId: authorId, authorName: authorName, authorAvatar: authorAvatar,
            siteAddress: siteAddress, latitude: latitude, longitude: longitude
        )
    }

    func updatingOperator(_ operatorName: String) -> Photo {
        Photo(
            id: id, siteId: siteId, enb: enb,
            imageUrl: imageUrl, thumbnailUrl: thumbnailUrl, ogImageUrl: ogImageUrl,
            uploadedAt: uploadedAt, createdAt: createdAt,
            description: description, caption: caption,
            likes: likes, likeCount: likeCount,
            socialPostId: socialPostId, approved: approved,
            operator: operatorName, marketCode: marketCode, siteOperators: siteOperators,
            commentCount: commentCount, repostsCount: repostsCount,
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
                operator: "Orange", marketCode: "FR", siteOperators: ["ORANGE", "SFR"],
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
                operator: "SFR", marketCode: "FR", siteOperators: ["SFR"],
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
                operator: "Bouygues", marketCode: "FR", siteOperators: ["BOUYGUES"],
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
