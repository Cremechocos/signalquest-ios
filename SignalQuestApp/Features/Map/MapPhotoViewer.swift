import CoreLocation
import SwiftUI

/// Une photo de la visionneuse. La vignette sert de transition pendant le
/// chargement ; les autres champs sont ce que l'appelant sait déjà, affiché
/// tant que le détail du serveur n'a pas répondu (ou s'il ne répond pas).
struct MapPhotoTarget: Identifiable, Equatable {
    let id: String
    let thumbnailURL: URL?
    var imageURL: URL? = nil
    var authorName: String? = nil
    var caption: String? = nil
    var date: Date? = nil
    var likeCount: Int? = nil
    var commentCount: Int? = nil
}

/// Le site photographié, résumé en tête du panneau : numéro, nom, adresse et
/// distance, puis statut, opérateurs, technologies et hauteur.
struct MapPhotoSite {
    struct Operator: Hashable {
        let label: String
        let color: Color
    }
    var kicker: String?
    var title: String
    var caption: String?
    var status: String?
    var statusColor: Color = SQColor.labelSecondary
    var operators: [Operator] = []
    var technologies: [String] = []
    var height: String?
}

/// Visionneuse plein écran des photos d'un site, ouverte depuis la carte comme
/// depuis la fiche antenne : défilement entre les photos, zoom (pincement,
/// double toucher), le site en tête du panneau, puis l'auteur, J'aime et les
/// commentaires. S'appuie sur `PhotoServicing` (detail / comments / like).
struct MapPhotoViewer: View {
    let items: [MapPhotoTarget]
    let service: PhotoServicing
    /// Couleur d'accent registry pour un opérateur donné.
    let operatorAccent: (String) -> Color
    /// Nom d'affichage registry d'un opérateur (« Orange » pour `ORANGE`).
    let operatorLabel: (String) -> String
    /// Ce que l'appelant sait du site ; sinon, on le déduit de la photo.
    let site: MapPhotoSite?
    /// Ouvre la fiche du site par-dessus la photo ; absent depuis la fiche elle-même.
    let onOpenSite: (() -> Void)?

    init(
        items: [MapPhotoTarget],
        initialId: String,
        service: PhotoServicing,
        operatorAccent: @escaping (String) -> Color,
        operatorLabel: @escaping (String) -> String = { $0 },
        site: MapPhotoSite? = nil,
        onOpenSite: (() -> Void)? = nil
    ) {
        self.items = items.isEmpty ? [MapPhotoTarget(id: initialId, thumbnailURL: nil)] : items
        self.service = service
        self.operatorAccent = operatorAccent
        self.operatorLabel = operatorLabel
        self.site = site
        self.onOpenSite = onOpenSite
        _currentId = State(initialValue: initialId)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    /// Photo ou commentaire à signaler : la même photo ouverte depuis l'écran
    /// Photos se signalait, pas depuis la carte (AF-CARTE-16).
    @State private var reportTarget: MapPhotoReport?

    private enum MapPhotoReport: Identifiable {
        case photo(String)
        case comment(String)
        var id: String {
            switch self {
            case .photo(let id): return "photo-\(id)"
            case .comment(let id): return "comment-\(id)"
            }
        }
        var target: ReportTarget {
            switch self {
            case .photo(let id): return .photo(id)
            case .comment(let id): return .photoComment(id)
            }
        }
    }

    @State private var currentId: String
    @State private var details: [String: Photo] = [:]
    @State private var comments: [PhotoComment] = []
    @State private var isLoading = true
    @State private var liked = false
    @State private var likeCount = 0
    @State private var likeBusy = false
    @State private var commentDraft = ""
    @State private var sendingComment = false
    @State private var commentError: String?
    @State private var commentsExpanded = false
    @State private var photoZoomed = false
    @State private var pagerDrag: CGFloat = 0
    @State private var dismissDrag: CGFloat = 0
    @State private var pagerAxis: Axis?
    @State private var appeared = false
    @FocusState private var commentFocused: Bool

    private var photoId: String { currentId }
    private var photo: Photo? { details[currentId] }
    private var current: MapPhotoTarget? { items.first { $0.id == currentId } }
    private var currentIndex: Int { items.firstIndex { $0.id == currentId } ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                photoPager
                infoPanel
            }

            topBar
                .frame(maxHeight: .infinity, alignment: .top)
        }
        // Sombre pour la visionneuse seule : `preferredColorScheme` gagnerait aussi
        // la fiche ou la carte restées dessous, qui resteraient sombres à la fermeture.
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .sheet(item: $reportTarget) { report in
            ReportSheet(target: report.target, service: services.reports)
        }
        .task(id: currentId) { await load() }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    // MARK: Photos

    /// Pager maison plutôt qu'un `TabView` paginé : un seul geste décide de
    /// l'axe au premier mouvement (horizontal = photo voisine, vers le bas =
    /// fermer). Un second geste de glissement posé sur les pages d'un `TabView`
    /// lui vole le défilement. Zoomée, la photo garde le glissement pour elle.
    private var photoPager: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Group {
                        // Seules la photo affichée et ses voisines se chargent.
                        if abs(index - currentIndex) <= 1 {
                            ZoomablePhoto(
                                url: details[item.id]?.imageUrl ?? item.imageURL ?? details[item.id]?.thumbnailUrl ?? item.thumbnailURL,
                                placeholder: item.thumbnailURL,
                                isZoomed: Binding(
                                    get: { item.id == currentId && photoZoomed },
                                    set: { if item.id == currentId { photoZoomed = $0 } }
                                )
                            )
                        } else {
                            Color.black
                        }
                    }
                    .frame(width: width, height: geo.size.height)
                    .accessibilityHidden(item.id != currentId)
                }
            }
            .offset(x: -CGFloat(currentIndex) * width + pagerDrag, y: dismissDrag)
            .frame(width: width, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(pagerGesture(width: width), including: photoZoomed ? .subviews : .all)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        Circle()
                            .fill(item.id == currentId ? Color.white : Color.white.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, SQSpace.sm)
                .accessibilityHidden(true)
            }
        }
        .accessibilityAction(named: Text("Photo suivante")) { showPhoto(at: currentIndex + 1) }
        .accessibilityAction(named: Text("Photo précédente")) { showPhoto(at: currentIndex - 1) }
    }

    private func pagerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if pagerAxis == nil {
                    pagerAxis = abs(value.translation.width) >= abs(value.translation.height) ? .horizontal : .vertical
                }
                switch pagerAxis {
                case .horizontal:
                    // Résistance aux bords : pas de page avant la première ni après la dernière.
                    let atEdge = (currentIndex == 0 && value.translation.width > 0)
                        || (currentIndex == items.count - 1 && value.translation.width < 0)
                    pagerDrag = atEdge ? value.translation.width / 3 : value.translation.width
                case .vertical:
                    dismissDrag = max(0, value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { value in
                let axis = pagerAxis
                pagerAxis = nil
                if axis == .vertical, dismissDrag > 120 {
                    dismiss()
                    return
                }
                var target = currentIndex
                if axis == .horizontal {
                    let travel = value.predictedEndTranslation.width
                    if travel < -width / 3 { target += 1 }
                    if travel > width / 3 { target -= 1 }
                }
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) {
                    pagerDrag = 0
                    dismissDrag = 0
                    if items.indices.contains(target) { currentId = items[target].id }
                }
            }
    }

    private func showPhoto(at index: Int) {
        guard items.indices.contains(index) else { return }
        withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { currentId = items[index].id }
    }

    private var topBar: some View {
        HStack {
            glassButton(systemImage: "xmark", label: "Fermer") { dismiss() }
                .accessibilityIdentifier("photoViewer.close")
            Spacer()
            if case .authenticated = session.state {
                Menu {
                    Button(role: .destructive) { reportTarget = .photo(photoId) } label: {
                        Label("Signaler la photo", systemImage: "flag")
                    }
                } label: {
                    glassIcon("ellipsis")
                }
                .accessibilityLabel("Plus d'options")
            }
        }
        .overlay {
            if items.count > 1 {
                Text(verbatim: "\(currentIndex + 1) / \(items.count)")
                    .font(SQFont.body(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .accessibilityLabel(Text("Photo \(currentIndex + 1) sur \(items.count)"))
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
    }

    private func glassButton(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { glassIcon(systemImage) }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel(label)
    }

    private func glassIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(SQColor.label)
            .frame(width: 44, height: 44)
            .background { sqMapGlassBackground(Circle()) }
            .sqShadowSoft()
    }

    // MARK: Panneau

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            grabber
            siteBlock
            Divider().overlay(SQColor.separator)
            photoRow
            if commentsExpanded {
                commentsSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composer
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.bottom, SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Le panneau descend jusqu'au bord de l'écran, sous l'indicateur d'accueil.
        .background {
            SQColor.surface
                .clipShape(.rect(topLeadingRadius: SQRadius.xl, topTrailingRadius: SQRadius.xl))
                .ignoresSafeArea(edges: .bottom)
        }
        .offset(y: appeared ? 0 : 40)
        .opacity(appeared ? 1 : 0)
    }

    /// Glisser vers le haut déplie les commentaires, vers le bas les replie.
    private var grabber: some View {
        Capsule()
            .fill(SQColor.separator)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8).onEnded { value in
                    if value.translation.height < -20 { setCommentsExpanded(true) }
                    if value.translation.height > 20 { setCommentsExpanded(false) }
                }
            )
            .onTapGesture { setCommentsExpanded(!commentsExpanded) }
            .accessibilityHidden(true)
    }

    private var resolvedSite: MapPhotoSite {
        if let site { return site }
        let operators = (photo?.siteOperators?.isEmpty == false ? photo?.siteOperators ?? [] : [photo?.operator].compactMap { $0 })
            .filter { !$0.isEmpty }
            .map { MapPhotoSite.Operator(label: operatorLabel($0), color: operatorAccent($0)) }
        return MapPhotoSite(
            kicker: photo?.siteId.flatMap { $0.isEmpty ? nil : String(localized: "Site \($0)") },
            title: siteTitle,
            caption: photoDistance,
            operators: operators
        )
    }

    private var siteTitle: String {
        if let address = photo?.siteAddress, !address.isEmpty { return address }
        if let site = photo?.siteId, !site.isEmpty { return String(localized: "Site \(site)") }
        if let enb = photo?.enb, !enb.isEmpty { return "eNB \(enb)" }
        return String(localized: "Antenne")
    }

    private var photoDistance: String? {
        guard let latitude = photo?.latitude, let longitude = photo?.longitude,
              let here = services.location.cachedLocation() else { return nil }
        return SQUnits.distance(meters: here.distance(from: CLLocation(latitude: latitude, longitude: longitude)))
    }

    private var siteBlock: some View {
        let site = resolvedSite
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .center, spacing: SQSpace.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    if let kicker = site.kicker {
                        Text(kicker).sqKicker()
                    }
                    Text(site.title)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                    if let caption = site.caption {
                        Text(caption)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if let onOpenSite {
                    Button(action: onOpenSite) {
                        HStack(spacing: 4) {
                            Text("Fiche")
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        }
                        .font(SQType.chip)
                        .foregroundStyle(SQColor.label)
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 44)
                        .background(SQColor.surface, in: Capsule(style: .continuous))
                        .overlay { Capsule(style: .continuous).strokeBorder(SQColor.separator, lineWidth: 1) }
                    }
                    .buttonStyle(SQPressButtonStyle(scale: 0.97))
                    .accessibilityLabel("Ouvrir la fiche du site")
                    .accessibilityIdentifier("photoViewer.openSite")
                }
            }
            if site.status != nil || !site.operators.isEmpty || !site.technologies.isEmpty || site.height != nil {
                FlowLayout(spacing: SQSpace.xs2) {
                    if let status = site.status {
                        SQEditorialTag(text: status, color: site.statusColor)
                    }
                    if !site.operators.isEmpty {
                        HStack(spacing: 5) {
                            HStack(spacing: -3) {
                                ForEach(site.operators, id: \.self) { item in
                                    Circle().fill(item.color).frame(width: 9, height: 9)
                                        .overlay { Circle().strokeBorder(SQColor.surface, lineWidth: 1.5) }
                                }
                            }
                            Text(site.operators.map(\.label).joined(separator: " · "))
                                .font(SQType.chip)
                                .foregroundStyle(SQColor.label)
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .background(SQColor.fill, in: Capsule(style: .continuous))
                    }
                    ForEach(site.technologies, id: \.self) { tech in
                        MapTechTag(technology: tech, label: tech)
                    }
                    if let height = site.height {
                        Text(height)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .frame(minHeight: 22)
                    }
                }
            }
        }
    }

    private var byline: String {
        let author = photo?.authorName ?? current?.authorName
        let date = photo?.uploadedAt ?? photo?.createdAt ?? current?.date
        var parts: [String] = []
        if let author, !author.isEmpty { parts.append(String(localized: "Photo de \(author)")) }
        if let date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.isEmpty ? String(localized: "Photo") : parts.joined(separator: " · ")
    }

    private var photoCaption: String? {
        let caption = photo?.displayCaption ?? current?.caption
        guard let caption, !caption.isEmpty, caption != String(localized: "Photo SignalQuest") else { return nil }
        return caption
    }

    private var commentTotal: Int {
        isLoading ? max(comments.count, current?.commentCount ?? 0) : comments.count
    }

    private var photoRow: some View {
        HStack(alignment: .center, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(byline)
                    .font(SQType.caption.weight(.bold))
                    .foregroundStyle(SQColor.label)
                if let photoCaption {
                    Text(photoCaption)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button {
                Task { await toggleLike() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(liked ? SQColor.like : SQColor.ink2)
                        .symbolEffectBounceCompat(value: liked)
                    Text("\(likeCount)")
                        .font(SQType.chip)
                        .foregroundStyle(SQColor.ink2)
                        .contentTransition(.numericText())
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(likeBusy)
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("J’aime")
            .accessibilityValue("\(likeCount)")
            .accessibilityAddTraits(liked ? .isSelected : [])

            Button { setCommentsExpanded(!commentsExpanded) } label: {
                HStack(spacing: 4) {
                    Image(systemName: commentsExpanded ? "bubble.left.fill" : "bubble.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(commentTotal)")
                        .font(SQType.chip)
                        .contentTransition(.numericText())
                }
                .foregroundStyle(SQColor.ink2)
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Commentaires")
            .accessibilityValue("\(commentTotal)")
            .accessibilityAddTraits(commentsExpanded ? .isSelected : [])
            .accessibilityIdentifier("photoViewer.comments")
        }
    }

    private func setCommentsExpanded(_ expanded: Bool) {
        guard expanded != commentsExpanded else { return }
        withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { commentsExpanded = expanded }
    }

    // MARK: Commentaires

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            if isLoading {
                SQSpinner().tint(SQColor.label).frame(maxWidth: .infinity)
            } else if comments.isEmpty {
                Text("Commente en premier")
                    .font(SQFont.body(13, .regular))
                    .foregroundStyle(SQColor.labelSecondary)
            } else {
                // Quelques commentaires prennent leur hauteur ; au-delà, ils défilent.
                ViewThatFits(in: .vertical) {
                    commentList
                    ScrollView { commentList }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private var commentList: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            ForEach(comments) { comment in
                commentRow(comment)
            }
        }
    }

    private func commentRow(_ comment: PhotoComment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(comment.userName ?? String(localized: "Membre"))
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.label)
                if let date = comment.createdAt {
                    Text(date.formatted(.relative(presentation: .numeric)))
                        .font(SQFont.body(12, .regular))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Text(comment.content ?? "")
                .font(SQFont.body(13, .regular))
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if case let .authenticated(user) = session.state {
                if comment.userId == user.id {
                    Button(role: .destructive) {
                        Task { await deleteComment(comment) }
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                } else {
                    Button(role: .destructive) { reportTarget = .comment(comment.id) } label: {
                        Label("Signaler le commentaire", systemImage: "flag")
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            if let commentError {
                SQInlineError(message: commentError)
            }
            HStack(spacing: SQSpace.sm) {
                TextField("Ajouter un commentaire…", text: $commentDraft, axis: .vertical)
                    .font(SQFont.body(14, .regular))
                    .foregroundStyle(SQColor.label)
                    .tint(SQColor.brandRed)
                    .focused($commentFocused)
                    .lineLimit(1...3)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm)
                    .frame(minHeight: 44)
                    .background(SQColor.fill, in: Capsule(style: .continuous))
                    .onChange(of: commentFocused) { focused in
                        if focused { setCommentsExpanded(true) }
                    }

                Button {
                    Task { await sendComment() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SQColor.onInk)
                        .frame(width: 44, height: 44)
                        .background(SQColor.label, in: Circle())
                        .opacity(canSend ? 1 : 0.46)
                }
                .disabled(!canSend || sendingComment)
                .accessibilityLabel("Envoyer le commentaire")
            }
        }
    }

    private var canSend: Bool {
        !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Données

    /// Recharge le détail et les commentaires de la photo affichée. Le compteur
    /// de J'aime repart de ce que l'appelant savait, le temps que le serveur réponde.
    private func load() async {
        let id = currentId
        isLoading = true
        comments = []
        commentError = nil
        likeCount = details[id].map { $0.likeCount ?? $0.likes ?? 0 } ?? current?.likeCount ?? 0
        liked = details[id].map { $0.isLikedByMe ?? $0.likedByCurrentUser ?? false } ?? false
        async let detail = try? service.photo(id: id)
        async let loadedComments = try? service.comments(photoId: id)
        let photoResult = await detail
        let commentsResult = await loadedComments ?? []
        guard !Task.isCancelled, id == currentId else { return }
        if let photoResult {
            details[id] = photoResult
            likeCount = photoResult.likeCount ?? photoResult.likes ?? 0
            liked = photoResult.isLikedByMe ?? photoResult.likedByCurrentUser ?? false
        }
        comments = commentsResult
        isLoading = false
    }

    private func toggleLike() async {
        guard !likeBusy else { return }
        likeBusy = true
        defer { likeBusy = false }
        // Optimisme : bascule immédiate puis réconciliation serveur.
        let previousLiked = liked
        let previousCount = likeCount
        withAnimation(SQMotion.resolve(.spring(response: 0.3, dampingFraction: 0.6), reduceMotion)) {
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

    private func deleteComment(_ comment: PhotoComment) async {
        do {
            try await service.deleteComment(photoId: photoId, commentId: comment.id)
            comments.removeAll { $0.id == comment.id }
        } catch {
            if !error.isCancellation { commentError = error.userFacingMessage }
        }
    }

    private func sendComment() async {
        let content = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !sendingComment else { return }
        sendingComment = true
        commentError = nil
        defer { sendingComment = false }
        commentFocused = false
        do {
            if let created = try await service.addComment(photoId: photoId, content: content) {
                await MainActor.run {
                    withAnimation(SQMotion.resolve(.default, reduceMotion)) { comments.append(created) }
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
            // On garde le brouillon pour permettre un nouvel essai, et on le dit.
            if !error.isCancellation {
                await MainActor.run { commentError = error.userFacingMessage }
            }
        }
    }
}

/// Image plein écran zoomable (pincement + double-tap), avec vignette de
/// transition pendant le chargement de l'image pleine résolution. `isZoomed`
/// dit au pager quand laisser le glissement à la photo.
private struct ZoomablePhoto: View {
    let url: URL?
    let placeholder: URL?
    @Binding var isZoomed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .overlay { SQSpinner().tint(.white) }
                } else {
                    SQSpinner().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        if scale <= 1 {
                            withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { resetZoom() }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset },
                including: scale > 1 ? .all : .subviews
            )
            .onChange(of: scale > 1) { zoomed in isZoomed = zoomed }
            .onTapGesture(count: 2) {
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) {
                    if scale > 1 { resetZoom() } else { scale = 2.5; lastScale = 2.5 }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo en plein écran")
            .accessibilityAddTraits(.isImage)
            .accessibilityValue(scale > 1 ? "Zoom \(Int((scale * 100).rounded())) %" : "Taille adaptée")
            .accessibilityAction(named: Text("Agrandir")) {
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) {
                    scale = min(4, max(2, scale + 0.5)); lastScale = scale
                }
            }
            .accessibilityAction(named: Text("Réduire")) {
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) {
                    scale = max(1, scale - 0.5); lastScale = scale
                    if scale == 1 { resetZoom() }
                }
            }
            .accessibilityAction(named: Text("Taille adaptée")) {
                withAnimation(SQMotion.resolve(SQMotion.snappy, reduceMotion)) { resetZoom() }
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
