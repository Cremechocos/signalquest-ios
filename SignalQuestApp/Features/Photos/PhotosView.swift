import SwiftUI
import PhotosUI
import MapKit
import CoreLocation

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
        
        let updatedPhoto = photo.updatingLike(liked: newLiked, count: newLikes)
        updatePhotoInState(updatedPhoto)
        
        if AppEnvironment.usesDemoData {
            Haptics.light()
            return
        }
        
        do {
            let response = try await service.toggleLike(photoId: photo.id, reaction: "❤️")
            let serverLiked = response.liked ?? newLiked
            let serverLikes = response.likes ?? newLikes
            let finalPhoto = photo.updatingLike(liked: serverLiked, count: serverLikes)
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
                let newCommentCount = (photo.commentCount ?? 0) + 1
                let updatedPhoto = photo.updatingCommentCount(count: newCommentCount)
                updatePhotoInState(updatedPhoto)
                draft = ""
                Haptics.success()
                return
            }
            if let comment = try await service.addComment(photoId: photo.id, content: trimmed) {
                comments.insert(comment, at: 0)
                let newCommentCount = (photo.commentCount ?? 0) + 1
                let updatedPhoto = photo.updatingCommentCount(count: newCommentCount)
                updatePhotoInState(updatedPhoto)
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
                    size: nil,
                    width: nil,
                    height: nil
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

    private func updatePhotoInState(_ updatedPhoto: Photo) {
        if let index = photos.firstIndex(where: { $0.id == updatedPhoto.id }) {
            photos[index] = updatedPhoto
        }
        if selectedPhoto?.id == updatedPhoto.id {
            selectedPhoto = updatedPhoto
        }
    }

    func upload(data: Data, siteId: String, description: String, operatorName: String) async {
        do {
            let photo = try await service.uploadPhoto(
                data: data,
                siteId: siteId,
                description: description,
                anfrCode: nil,
                operatorName: operatorName
            )
            photos.insert(photo, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PhotosView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: PhotosViewModel
    @State private var showingUpload = false

    init(service: PhotoServicing = PhotoService(api: APIClient())) {
        _model = StateObject(wrappedValue: PhotosViewModel(service: service))
    }

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                if model.isLoading && model.photos.isEmpty {
                    gridSkeleton
                } else if model.photos.isEmpty {
                    EmptyStateView(title: "Aucune photo", message: "Les photos validées apparaîtront ici.", systemImage: "photo.on.rectangle")
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(model.photos) { photo in
                            gridTile(photo)
                                .onTapGesture {
                                    Task { await model.open(photo) }
                                }
                        }
                    }
                }
                if let error = model.errorMessage {
                    ErrorStateView(title: "Photos indisponibles", message: error)
                }
            }
            .padding(SQSpace.lg)
            .padding(.bottom, 96)
        }
        .navigationTitle("Photos")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingUpload = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(SQColor.brandRed)
                }
            }
        }
        .signalQuestBackground()
        .task {
            if model.photos.isEmpty {
                await model.load()
            }
        }
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
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showingUpload) {
            PhotoUploadView(antennas: services.antennas) { data, siteId, description, operatorName in
                Task {
                    await model.upload(data: data, siteId: siteId, description: description, operatorName: operatorName)
                    showingUpload = false
                }
            }
            .presentationDetents([.large])
            .presentationBackground(.ultraThinMaterial)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text("Terrain").sqKicker()
            SQSectionHeader("Photos") {
                Image(systemName: "camera.aperture")
                    .font(.title2)
                    .foregroundStyle(SQColor.brandRed)
            }
        }
    }

    /// Cellule carrée de la grille 3 colonnes — coins 4 pt, scrim léger
    /// pour la légende et le compteur de likes.
    private func gridTile(_ photo: Photo) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(url: photo.thumbnailUrl ?? photo.imageUrl, maxDimension: 140, contentMode: .fill) {
                    Rectangle().fill(SQColor.fill).sqShimmer()
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(photo.displayCaption)
                        .font(SQType.micro)
                        .lineLimit(1)
                    Text("\(photo.likeCount ?? photo.likes ?? 0) likes")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(SQSpace.xs + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(shape)
            .contentShape(shape)
    }

    /// Squelette de chargement de la grille, balayé par sqShimmer.
    private var gridSkeleton: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(SQColor.fill)
                    .aspectRatio(1, contentMode: .fit)
                    .sqShimmer()
            }
        }
    }
}

struct PhotoDetailView: View {
    @Binding var photo: Photo
    let comments: [PhotoComment]
    @Binding var draft: String
    let isSending: Bool
    let onLike: () -> Void
    let onSend: () -> Void
    let onShareToConversation: (MessageConversation) async -> Bool

    @EnvironmentObject private var services: AppServices
    @State private var showReport = false
    @State private var showShareSheet = false
    @State private var showNativeShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: SQSpace.lg) {
                        AsyncImage(url: photo.imageUrl ?? photo.thumbnailUrl) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(SQColor.fill)
                            }
                        }
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous))

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: SQSpace.xs) {
                                Text(photo.displayCaption)
                                    .font(SQType.title)
                                    .foregroundStyle(SQColor.label)
                                Text([photo.operator, photo.siteId, photo.siteAddress].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                            Spacer()
                            
                            HStack(spacing: SQSpace.sm) {
                                let isLiked = photo.isLikedByMe == true || photo.likedByCurrentUser == true
                                Button(action: onLike) {
                                    Label("\(photo.likeCount ?? photo.likes ?? 0)", systemImage: isLiked ? "heart.fill" : "heart")
                                }
                                .buttonStyle(.bordered)
                                .tint(isLiked ? SQColor.like : SQColor.labelSecondary)
                                
                                Menu {
                                    Button {
                                        showShareSheet = true
                                    } label: {
                                        Label("Partager sur Signal Quest", systemImage: "bubble.left.and.bubble.right")
                                    }
                                    Button {
                                        showNativeShare = true
                                    } label: {
                                        Label("Partager ailleurs...", systemImage: "square.and.arrow.up")
                                    }
                                } label: {
                                    Label("Partager", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                                .tint(SQColor.labelSecondary)
                            }
                        }

                        SQSectionHeader("Commentaires")
                        if comments.isEmpty {
                            EmptyStateView(
                                title: "Aucun commentaire",
                                message: "Sois le premier à commenter cette photo.",
                                systemImage: "bubble.right"
                            )
                        } else {
                            ForEach(comments) { comment in
                                commentRow(comment)
                            }
                        }
                    }
                    .padding(SQSpace.lg)
                }
                commentComposer
            }
            .signalQuestBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("Partager sur Signal Quest", systemImage: "bubble.left.and.bubble.right")
                        }
                        Button {
                            showNativeShare = true
                        } label: {
                            Label("Partager ailleurs...", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) { showReport = true } label: {
                            Label("Signaler la photo", systemImage: "flag")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Plus d’options")
                }
            }
            .sheet(isPresented: $showReport) {
                ReportSheet(targetType: "photo", targetId: photo.id, service: services.reports)
            }
            .sheet(isPresented: $showShareSheet) {
                PhotoShareSheet(
                    photo: photo,
                    messagesService: services.messages,
                    onShare: onShareToConversation
                )
            }
            .sheet(isPresented: $showNativeShare) {
                let shareText = "\(photo.displayCaption) - Partagé via SignalQuest"
                if let imageUrl = photo.imageUrl {
                    ShareSheet(items: [shareText, imageUrl])
                } else {
                    ShareSheet(items: [shareText])
                }
            }
        }
    }

    private func commentRow(_ comment: PhotoComment) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm + 2) {
            SQAvatar(url: nil, name: comment.userName ?? "?", size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
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
            }
        }
        .padding(SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }

    private var commentComposer: some View {
        HStack(spacing: SQSpace.sm + 2) {
            TextField("Ajoute un commentaire", text: $draft, axis: .vertical)
                .textFieldStyle(SQTextFieldStyle())
                .lineLimit(1...4)
            Button {
                onSend()
            } label: {
                Image(systemName: isSending ? "ellipsis" : "paperplane.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(SQSpace.md)
                    .background(SQGradient.signal, in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(SQSpace.md)
        .background(.ultraThinMaterial)
    }
}

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
                                .overlay(
                                    VStack(spacing: SQSpace.sm + 2) {
                                        Image(systemName: "photo.badge.plus")
                                            .font(.largeTitle)
                                            .foregroundStyle(SQColor.labelSecondary)
                                        Text("Aperçu photo")
                                            .foregroundStyle(SQColor.labelSecondary)
                                    }
                                )
                        }
                    }

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choisir une photo", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(SQColor.brandRed)
                    .onChange(of: pickerItem) { _, newItem in
                        Task {
                            guard let data = try? await newItem?.loadTransferable(type: Data.self),
                                  let loaded = UIImage(data: data) else { return }
                            image = loaded
                        }
                    }

                    Button {
                        showSitePicker = true
                    } label: {
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
                        let siteId = site.siteId ?? site.id
                        let operatorName = site.operators.first ?? ""
                        onUpload(data, siteId, description, operatorName)
                    }
                    .disabled(image == nil || selectedSite == nil)
                    .opacity(image == nil || selectedSite == nil ? 0.5 : 1)
                }
                .padding(SQSpace.lg)
            }
            .navigationTitle("Nouvelle photo")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.brandRed)
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
                        AsyncImage(url: photo.thumbnailUrl ?? photo.imageUrl) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(SQColor.fill)
                            }
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))

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
                } header: {
                    Text("Photo")
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
        if await onShare(conversation) {
            dismiss()
        }
    }
}

/// Map-based picker that fetches antennas in the current camera viewport and lets
/// the user tap an annotation to select a site for the photo upload.
struct AntennaSitePickerSheet: View {
    let antennas: AntennasServicing
    let onSelect: (AntennaSite) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var locationService = LocationService()
    @State private var cameraPosition: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    ))
    @State private var sites: [AntennaSite] = []
    @State private var visibleBox: BoundingBox?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Map(position: $cameraPosition) {
                    ForEach(sites.filter { $0.latitude != nil && $0.longitude != nil }) { site in
                        Annotation(site.siteId ?? site.id, coordinate: CLLocationCoordinate2D(latitude: site.latitude!, longitude: site.longitude!)) {
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
                }
                .ignoresSafeArea(edges: .bottom)
                .onMapCameraChange(frequency: .onEnd) { ctx in
                    let region = ctx.region
                    visibleBox = BoundingBox(
                        north: region.center.latitude + region.span.latitudeDelta / 2,
                        south: region.center.latitude - region.span.latitudeDelta / 2,
                        east: region.center.longitude + region.span.longitudeDelta / 2,
                        west: region.center.longitude - region.span.longitudeDelta / 2
                    )
                    Task { await loadSites() }
                }

                VStack(spacing: SQSpace.sm) {
                    HStack(spacing: SQSpace.sm) {
                        if isLoading {
                            ProgressView().tint(SQColor.brandRed)
                        }
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
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.brandRed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let location = locationService.lastLocation {
                            cameraPosition = .region(MKCoordinateRegion(
                                center: location.coordinate,
                                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                            ))
                        } else {
                            locationService.requestOneShotLocation()
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .foregroundStyle(SQColor.brandRed)
                    }
                }
            }
            .task {
                locationService.requestOneShotLocation()
            }
            .onReceive(locationService.$lastLocation.compactMap { $0 }) { location in
                cameraPosition = .region(MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))
            }
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

extension Photo {
    func updatingLike(liked: Bool, count: Int) -> Photo {
        Photo(
            id: id,
            siteId: siteId,
            enb: enb,
            imageUrl: imageUrl,
            thumbnailUrl: thumbnailUrl,
            ogImageUrl: ogImageUrl,
            uploadedAt: uploadedAt,
            createdAt: createdAt,
            description: description,
            caption: caption,
            likes: count,
            likeCount: count,
            socialPostId: socialPostId,
            approved: approved,
            operator: self.operator,
            commentCount: commentCount,
            repostsCount: repostsCount,
            favoritesCount: favoritesCount,
            reactions: reactions,
            likedByCurrentUser: liked,
            isLikedByMe: liked,
            userReaction: userReaction,
            authorId: authorId,
            authorName: authorName,
            authorAvatar: authorAvatar,
            siteAddress: siteAddress,
            latitude: latitude,
            longitude: longitude
        )
    }

    func updatingCommentCount(count: Int) -> Photo {
        Photo(
            id: id,
            siteId: siteId,
            enb: enb,
            imageUrl: imageUrl,
            thumbnailUrl: thumbnailUrl,
            ogImageUrl: ogImageUrl,
            uploadedAt: uploadedAt,
            createdAt: createdAt,
            description: description,
            caption: caption,
            likes: likes,
            likeCount: likeCount,
            socialPostId: socialPostId,
            approved: approved,
            operator: self.operator,
            commentCount: count,
            repostsCount: repostsCount,
            favoritesCount: favoritesCount,
            reactions: reactions,
            likedByCurrentUser: likedByCurrentUser,
            isLikedByMe: isLikedByMe,
            userReaction: userReaction,
            authorId: authorId,
            authorName: authorName,
            authorAvatar: authorAvatar,
            siteAddress: siteAddress,
            latitude: latitude,
            longitude: longitude
        )
    }

    static var demoList: [Photo] {
        [
            Photo(
                id: "demo-photo-1",
                siteId: "PAR-001",
                enb: nil,
                imageUrl: nil,
                thumbnailUrl: nil,
                ogImageUrl: nil,
                uploadedAt: Date(),
                createdAt: Date(),
                description: "Site urbain validé par la communauté",
                caption: "Paris centre",
                likes: 12,
                likeCount: 12,
                socialPostId: nil,
                approved: true,
                operator: "SignalQuest",
                commentCount: 2,
                repostsCount: 0,
                favoritesCount: 4,
                reactions: [],
                likedByCurrentUser: false,
                isLikedByMe: false,
                userReaction: nil,
                authorId: "demo",
                authorName: "SignalQuest",
                authorAvatar: nil,
                siteAddress: "Paris",
                latitude: 48.8566,
                longitude: 2.3522
            ),
            Photo(
                id: "demo-photo-2",
                siteId: "LYO-002",
                enb: nil,
                imageUrl: nil,
                thumbnailUrl: nil,
                ogImageUrl: nil,
                uploadedAt: Date(),
                createdAt: Date(),
                description: "Photo de support antenne",
                caption: "Lyon",
                likes: 8,
                likeCount: 8,
                socialPostId: nil,
                approved: true,
                operator: "Communauté",
                commentCount: 1,
                repostsCount: 0,
                favoritesCount: 2,
                reactions: [],
                likedByCurrentUser: false,
                isLikedByMe: false,
                userReaction: nil,
                authorId: "demo",
                authorName: "SignalQuest",
                authorAvatar: nil,
                siteAddress: "Lyon",
                latitude: 45.764,
                longitude: 4.8357
            )
        ]
    }
}

extension PhotoComment {
    static var demo: [PhotoComment] {
        [
            PhotoComment(
                id: "demo-comment-1",
                photoId: "demo-photo-1",
                userId: "demo-user",
                userName: "Camille",
                content: "Photo claire, site facile à reconnaître.",
                createdAt: Date(),
                updatedAt: nil,
                parentId: nil,
                avatarUrl: nil
            )
        ]
    }
}
