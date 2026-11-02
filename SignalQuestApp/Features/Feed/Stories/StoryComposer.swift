import SwiftUI
import PhotosUI

/// Audience d'une story (parité Android). Mappe sur la `visibility` backend.
enum StoryAudience: String, CaseIterable, Identifiable, Hashable {
    case publicAll = "public"
    case friends = "friends"
    case closeFriends = "close_friends"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .publicAll: return String(localized: "Public")
        case .friends: return String(localized: "Amis")
        case .closeFriends: return String(localized: "Proches")
        }
    }
}

/// Fond d'une story sans photo, tiré de la charte Crème. Il part en `#RRGGBB` :
/// le lecteur (iOS, web, Android) affiche toute couleur hex et choisit l'encre selon la luminosité.
enum StoryBackground: String, CaseIterable, Identifiable {
    case nuit, creme, brique, olive, ambre, encre

    var id: String { rawValue }
    var hex: String {
        switch self {
        case .nuit: return "#191410"
        case .creme: return "#F3EDE2"
        case .brique: return "#B04A3C"
        case .olive: return "#606B46"
        case .ambre: return "#85602B"
        case .encre: return "#332818"
        }
    }
    var label: String {
        switch self {
        case .nuit: return String(localized: "Nuit")
        case .creme: return String(localized: "Crème")
        case .brique: return String(localized: "Brique")
        case .olive: return String(localized: "Olive")
        case .ambre: return String(localized: "Ambre")
        case .encre: return String(localized: "Encre")
        }
    }
}

@MainActor
final class StoryComposerViewModel: ObservableObject {
    /// Plafond du schéma serveur (`POST /api/social/stories`) : au-delà, la story
    /// entière est refusée (400 INVALID_STORY, sans détail).
    nonisolated static let maxTextLength = 1200
    @Published var text: String = "" {
        didSet {
            let clamped = Self.clampedCaption(text)
            if clamped != text { text = clamped }
        }
    }
    @Published var selectedItem: PhotosPickerItem?
    @Published var previewImage: UIImage?
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var didPublish = false
    /// Story renvoyée par le serveur : le fil l'insère sans attendre le
    /// prochain rechargement (SOC-34).
    @Published var publishedStory: SocialStory?
    /// Durée d'affichage de la story (autorisée : 5/10/15 s).
    @Published var displayDuration: Int = 10

    // Audience avancée.
    @Published var audience: StoryAudience = .friends
    @Published var ttlHours: Int = 24
    @Published var hiddenUserIds: Set<String> = []
    /// Joint le relevé radio courant : c'est ce qui fait une story « signal ».
    /// Le serveur accepte alors une story SANS texte ni image — exactement le
    /// cas d'usage, partager sa couverture.
    @Published var attachRadio = false
    @Published var closeFriendIds: Set<String> = []
    /// Fond d'une story sans photo ; ignoré dès qu'une photo est choisie.
    @Published var background: StoryBackground = .nuit
    /// La liste d'amis proches est-elle bien revenue du serveur, et dans quel état ?
    /// Sans cela, une liste vide (chargement raté) serait enregistrée à la fermeture
    /// de l'éditeur et effacerait la vraie.
    private(set) var closeFriendsLoaded = false
    private var savedCloseFriendIds: Set<String> = []
    @Published var friends: [Friend] = []
    @Published var showHideEditor = false
    @Published var showCloseFriendsEditor = false

    /// Octets choisis, conservés seulement pour l'aperçu. Le service les
    /// ré-encode sans métadonnées avant tout envoi réseau.
    private var pickedImageData: Data?
    /// Photo choisie avant retouche, et ses octets : rouvrir « Modifier » repart d'elle.
    private(set) var editSource: UIImage?
    private var originalImageData: Data?
    private(set) var photoEdits = PhotoEdits()
    private let service: StoriesServicing
    private let friendsService: FriendsServicing
    init(service: StoriesServicing, friendsService: FriendsServicing) {
        self.service = service
        self.friendsService = friendsService
    }

    /// Coupe la légende au plafond du serveur. Le serveur compte comme JavaScript,
    /// en unités UTF-16 : un emoji peut en valoir quatre. On coupe entre deux
    /// caractères, jamais au milieu d'un emoji.
    nonisolated static func clampedCaption(_ value: String) -> String {
        guard value.utf16.count > maxTextLength else { return value }
        var result = ""
        var units = 0
        for character in value {
            let size = character.utf16.count
            if units + size > maxTextLength { break }
            result.append(character)
            units += size
        }
        return result
    }

    /// Charge les amis (sélecteurs) + la liste actuelle d'amis proches. Échec
    /// silencieux : les sélecteurs restent simplement vides.
    func loadAudience() async {
        async let friendsResult = try? friendsService.list()
        async let closeResult = try? service.closeFriends()
        friends = (await friendsResult) ?? []
        if let close = await closeResult {
            closeFriendIds = Set(close.map(\.id))
            savedCloseFriendIds = closeFriendIds
            closeFriendsLoaded = true
        }
    }

    /// Photo prise avec l'appareil (E4) : même chemin qu'une photo de la photothèque.
    func loadCapturedPhoto(_ data: Data) {
        guard let image = ImagePipeline.downsample(data: data, maxPixel: 1600) else {
            errorMessage = String(localized: "Photo illisible")
            return
        }
        selectedItem = nil
        previewImage = image
        pickedImageData = data
        editSource = image
        originalImageData = data
        photoEdits = PhotoEdits()
    }

    func loadPickerImage() async {
        guard let item = selectedItem else { return }
        do {
            // Aperçu décodé réduit, pas en pleine taille (SOC-36).
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = ImagePipeline.downsample(data: data, maxPixel: 1600) else {
                errorMessage = String(localized: "Photo illisible")
                return
            }
            previewImage = image
            pickedImageData = data
            editSource = image
            originalImageData = data
            photoEdits = PhotoEdits()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Retouches (« Modifier ») : c'est la copie retouchée qui s'affiche et part ;
    /// l'original et les retouches restent, pour rouvrir l'éditeur sans rien perdre.
    func applyEdits(_ image: UIImage, _ edits: PhotoEdits) {
        photoEdits = edits
        if edits.isIdentity, let editSource, let originalImageData {
            previewImage = editSource
            pickedImageData = originalImageData
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        previewImage = image
        pickedImageData = data
    }

    var hasPhoto: Bool { pickedImageData != nil }

    /// Retire la photo : la story redevient une story texte, sur son fond.
    func removePhoto() {
        selectedItem = nil
        previewImage = nil
        pickedImageData = nil
        editSource = nil
        originalImageData = nil
        photoEdits = PhotoEdits()
    }

    /// Persiste la liste d'amis proches (PUT). Appelé à la fermeture de l'éditeur,
    /// seulement si la liste du serveur a été lue ET que tu l'as modifiée.
    func saveCloseFriends() async {
        guard closeFriendsLoaded, closeFriendIds != savedCloseFriendIds else { return }
        let ids = closeFriendIds
        do {
            _ = try await service.setCloseFriends(userIds: Array(ids))
            savedCloseFriendIds = ids
        } catch { if !error.isCancellation { errorMessage = error.userFacingMessage } }
    }

    /// Un texte, une photo ou un relevé réseau suffit à faire une story, comme côté serveur.
    var canPublish: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil || pickedImageData != nil || attachRadio
    }

    func publish() async {
        let caption = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard canPublish else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            var mediaUrl: URL?
            var thumbnailUrl: URL?
            if let data = pickedImageData {
                let upload = try await service.uploadMedia(data: data)
                mediaUrl = upload.url
                thumbnailUrl = upload.thumbnailUrl
            }
            publishedStory = try await service.create(
                text: caption,
                mediaUrl: mediaUrl,
                thumbnailUrl: thumbnailUrl,
                mediaKind: mediaUrl != nil ? "image" : nil,
                displayDurationSeconds: displayDuration,
                visibility: audience.rawValue,
                ttlHours: ttlHours,
                hiddenUserIds: Array(hiddenUserIds),
                background: mediaUrl == nil ? background.hex : nil,
                attachRadio: attachRadio,
                metadata: nil
            )
            didPublish = true
            Haptics.success()
        } catch {
            guard !error.isCancellation else { return }
            // Seul le refus 403 PREMIUM_REQUIRED parle de Premium : toute erreur
            // (réseau, 429, 500) s'affichait « Durée longue réservée aux comptes
            // Premium » dès qu'une durée autre que 24 h était choisie (SOC-34).
            if case APIError.http(403, let code, _, _, _) = error, code == "PREMIUM_REQUIRED" {
                errorMessage = String(localized: "Durée longue réservée aux comptes Premium.")
            } else {
                errorMessage = error.userFacingMessage
            }
            Haptics.error()
        }
    }
}

/// Création d'une story en deux temps, plein écran : d'abord la story telle que les autres
/// la verront (photo ou fond, légende par-dessus, relevé joint), puis « Partager »
/// (audience et options). Choix d'Alexandre du 02/11 : le contenu avant les réglages.
struct StoryComposer: View {
    @StateObject private var model: StoryComposerViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step: Step = .create
    @State private var showPremiumPaywall = false
    @State private var showPhotoEditor = false
    @State private var showsCamera = false
    @FocusState private var captionFocused: Bool

    private let author: AuthUser?
    private let onPublished: (SocialStory) -> Void

    private enum Step { case create, share }

    init(
        service: StoriesServicing,
        friendsService: FriendsServicing,
        author: AuthUser? = nil,
        onPublished: @escaping (SocialStory) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: StoryComposerViewModel(service: service, friendsService: friendsService))
        self.author = author
        self.onPublished = onPublished
    }

    var body: some View {
        ZStack {
            switch step {
            case .create:
                createStep
                    .transition(.opacity)
            case .share:
                shareStep
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }
        }
        .onChangeCompat(of: model.selectedItem) { _, _ in
            Task { await model.loadPickerImage() }
        }
        .fullScreenCover(isPresented: $showPhotoEditor) {
            if let image = model.editSource ?? model.previewImage {
                // Une story est verticale : le cadre 9:16 est imposé.
                PhotoEditorView(image: image, edits: model.photoEdits, fixedAspect: 9 / 16) { edited, edits in
                    model.applyEdits(edited, edits)
                }
                // Même noir que la story : l'éditeur ne s'allume pas en crème au-dessus.
                .environment(\.colorScheme, .dark)
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraCapturePicker(isPresented: $showsCamera) { model.loadCapturedPhoto($0) }
                .ignoresSafeArea()
        }
        .task {
            await model.loadAudience()
            await services.entitlements.refreshBackendSnapshot()
        }
        .sheet(isPresented: $model.showHideEditor) {
            FriendMultiSelectSheet(title: "Masquer à…", friends: model.friends, selected: $model.hiddenUserIds)
        }
        // Enregistré à toute fermeture, « OK » ou glissement : seul « OK »
        // enregistrait, et le serveur gardait l'ancienne liste (AF-FIL-14).
        .sheet(isPresented: $model.showCloseFriendsEditor, onDismiss: {
            Task { await model.saveCloseFriends() }
        }) {
            FriendMultiSelectSheet(title: "Amis proches", friends: model.friends, selected: $model.closeFriendIds) {}
        }
        .sheet(isPresented: $showPremiumPaywall) {
            NavigationStack {
                PaywallView(
                    store: services.entitlements,
                    entryPoint: .premiumFeature("Durée personnalisée des stories")
                )
            }
            .presentationDetents([.large])
        }
    }

    private func go(to next: Step) {
        captionFocused = false
        Haptics.light()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { step = next }
    }

    // MARK: - Étape 1 : la story

    private var createStep: some View {
        VStack(spacing: SQSpace.md) {
            StoryCanvas(model: model, author: author, editable: true, captionFocused: $captionFocused)
                .overlay(alignment: .top) { canvasTopBar }
                .padding(.horizontal, SQSpace.sm)
                // La story prend la place qui reste : les outils restent toujours visibles.
                .frame(maxHeight: .infinity)
                .layoutPriority(-1)

            if !model.hasPhoto {
                backgroundPicker
            }
            // Toujours posée, masquée quand la story a un contenu : la story ne change pas de taille.
            Text(verbatim: emptyHint)
                .font(SQType.caption)
                .foregroundStyle(SQColor.onGlass.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, SQSpace.lg)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .opacity(model.canPublish ? 0 : 1)
                .accessibilityHidden(model.canPublish)
            toolBar
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .padding(.top, SQSpace.xs)
        .padding(.bottom, SQSpace.sm)
        .background(Color.black.ignoresSafeArea())
        // Le clavier passe par-dessus : la story ne rétrécit pas et les boutons ne bougent pas.
        .ignoresSafeArea(.keyboard)
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
    }

    private var canvasTopBar: some View {
        HStack(spacing: SQSpace.sm) {
            glassIconButton("xmark", label: String(localized: "Annuler"), identifier: "story.composer.close") { dismiss() }
            Spacer(minLength: 0)
            if captionFocused {
                // En saisie : un seul geste visible, terminer le texte.
                Button {
                    captionFocused = false
                } label: {
                    // Même verre sombre que ✕ : lisible sur un fond Crème comme sur une photo claire.
                    Text("OK")
                        .font(SQType.button)
                        .foregroundStyle(SQColor.onGlass)
                        .padding(.horizontal, SQSpace.md)
                        .frame(height: 36)
                        .background(.black.opacity(0.55), in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityIdentifier("story.caption.done")
            } else if model.hasPhoto {
                PhotoEditButton { showPhotoEditor = true }
                    .accessibilityIdentifier("story.edit")
                glassIconButton("trash", label: String(localized: "Retirer la photo"), identifier: "story.removePhoto") {
                    Haptics.light()
                    model.removePhoto()
                }
            }
        }
        .padding(SQSpace.sm)
    }

    /// Six fonds de la charte, touchables sous la story.
    private var backgroundPicker: some View {
        HStack(spacing: SQSpace.xs) {
            ForEach(StoryBackground.allCases) { background in
                Button {
                    Haptics.selection()
                    model.background = background
                } label: {
                    Circle()
                        .fill(StoryViewer.backgroundColor(background.hex)?.color ?? .black)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(SQColor.onGlass.opacity(0.35), lineWidth: 1))
                        .overlay {
                            if model.background == background {
                                Circle().strokeBorder(SQColor.onGlass, lineWidth: 2.5).padding(-5)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: background.label))
                .accessibilityAddTraits(model.background == background ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Fond de la story"))
        .accessibilityIdentifier("story.backgrounds")
    }

    private var toolBar: some View {
        // Aux tailles d'accessibilité, « Suivant » passe sur sa ligne : sinon il sortait de l'écran.
        let stacked = dynamicTypeSize.isAccessibilitySize
        return VStack(spacing: SQSpace.sm) {
            HStack(alignment: .center, spacing: SQSpace.xs) {
                tools
                if !stacked {
                    Spacer(minLength: SQSpace.sm)
                    nextButton.fixedSize()
                }
            }
            if stacked { nextButton }
        }
        .padding(.horizontal, SQSpace.md)
    }

    @ViewBuilder
    private var tools: some View {
        PhotosPicker(selection: $model.selectedItem, matching: .images) {
            StoryToolLabel(title: String(localized: "Photo"), systemImage: "photo.on.rectangle", isOn: false)
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityIdentifier("story.library")

        if CameraCapturePicker.isAvailable {
            Button { showsCamera = true } label: {
                StoryToolLabel(title: String(localized: "Caméra"), systemImage: "camera", isOn: false)
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityIdentifier("story.camera")
        }

        Button {
            Haptics.selection()
            model.attachRadio.toggle()
        } label: {
            StoryToolLabel(title: String(localized: "Réseau"), systemImage: "antenna.radiowaves.left.and.right", isOn: model.attachRadio)
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityHint(Text("Joint l’opérateur et la technologie de ton dernier relevé"))
        .accessibilityAddTraits(model.attachRadio ? .isSelected : [])
        .accessibilityIdentifier("story.radio")
    }

    private var nextButton: some View {
        GradientButton(String(localized: "Suivant"), systemImage: "arrow.right", style: .primary) {
            go(to: .share)
        }
        .disabled(!model.canPublish)
        .accessibilityHint(model.canPublish ? Text("") : Text(emptyHint))
        .accessibilityIdentifier("story.next")
    }

    private var emptyHint: String {
        String(localized: "Ajoute une photo, un texte ou ton relevé réseau.")
    }

    private func glassIconButton(_ systemImage: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(SQColor.onGlass)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.55), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Étape 2 : Partager

    private var shareStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: SQSpace.sm) {
                Button { go(to: .create) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(SQColor.label)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel(Text("Retour à la story"))
                .accessibilityIdentifier("story.back")
                Text("Partager")
                    .font(SQFont.display(22, .heavy, relativeTo: .title2))
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SQSpace.sm)
            .padding(.top, SQSpace.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    HStack(alignment: .center, spacing: SQSpace.md) {
                        StoryCanvas(model: model, author: author, editable: false, captionFocused: $captionFocused)
                            .frame(width: 72)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Text(storyKind)
                                .font(SQType.subhead(.bold))
                                .foregroundStyle(SQColor.label)
                            Text(String(localized: "Visible \(ttlLabel(model.ttlHours)), \(model.displayDuration) s à l’écran"))
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    section(String(localized: "Qui la voit")) {
                        ForEach(Array([StoryAudience.friends, .publicAll, .closeFriends].enumerated()), id: \.element) { index, audience in
                            if index > 0 { Divider().padding(.leading, 62) }
                            audienceRow(audience)
                        }
                        if model.audience == .closeFriends {
                            Divider().padding(.leading, 62)
                            optionRow(systemImage: "list.star", title: String(localized: "Liste d’amis proches"),
                                      value: "\(model.closeFriendIds.count)") {
                                // Liste du serveur non lue (échec réseau) : nouvel essai avant d'éditer.
                                if !model.closeFriendsLoaded { Task { await model.loadAudience() } }
                                model.showCloseFriendsEditor = true
                            }
                        }
                        Divider().padding(.leading, 62)
                        optionRow(systemImage: "hand.raised", title: String(localized: "Masquer à…"), value: hiddenValue) {
                            model.showHideEditor = true
                        }
                    }

                    if closeFriendsListEmpty {
                        SQNotice(message: String(localized: "Ta liste d’amis proches est vide : personne ne verrait cette story. Ajoute des amis ou choisis une autre audience."),
                                 tone: .warning)
                            .accessibilityIdentifier("story.closeFriends.empty")
                    }

                    section(String(localized: "Options")) {
                        ttlMenu
                        Divider().padding(.leading, 62)
                        durationMenu
                    }

                    if let error = model.errorMessage {
                        SQNotice(message: error, tone: .danger)
                            .accessibilityIdentifier("story.error")
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.md)
            }

            GradientButton(String(localized: "Partager la story"), systemImage: "paperplane.fill", isBusy: model.isSending) {
                Task {
                    await model.publish()
                    if model.didPublish {
                        if let story = model.publishedStory { onPublished(story) }
                        dismiss()
                    }
                }
            }
            .disabled(!model.canPublish || closeFriendsListEmpty)
            .accessibilityIdentifier("story.publish")
            .padding(.horizontal, SQSpace.lg)
            .padding(.bottom, SQSpace.md)
        }
        .background(SQColor.bg.ignoresSafeArea())
    }

    /// « Proches » avec une liste lue et vide : la story ne serait montrée à personne.
    private var closeFriendsListEmpty: Bool {
        model.audience == .closeFriends && model.closeFriendsLoaded && model.closeFriendIds.isEmpty
    }

    private var storyKind: String {
        if model.hasPhoto { return String(localized: "Story photo") }
        if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "Story réseau") }
        return String(localized: "Story texte")
    }

    private func ttlLabel(_ hours: Int) -> String {
        String(localized: "\(hours) h")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            Text(verbatim: title)
                .font(SQType.caption(.bold))
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.leading, SQSpace.xs)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
    }

    private func audienceRow(_ audience: StoryAudience) -> some View {
        let isSelected = model.audience == audience
        return Button {
            Haptics.selection()
            model.audience = audience
        } label: {
            SQListRow(audience.label, subtitle: audienceDetail(audience), systemImage: audienceIcon(audience)) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? SQColor.label : SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("story.audience.\(audience.rawValue)")
    }

    private func audienceIcon(_ audience: StoryAudience) -> String {
        switch audience {
        case .friends: return "person.2"
        case .publicAll: return "globe.europe.africa"
        case .closeFriends: return "star"
        }
    }

    private func audienceDetail(_ audience: StoryAudience) -> String {
        switch audience {
        case .friends: return String(localized: "Tes amis seulement")
        case .publicAll: return String(localized: "Tous les membres de SignalQuest")
        case .closeFriends: return String(localized: "Seulement ta liste d’amis proches")
        }
    }

    /// 24 h pour tous ; toute autre durée est réservée à Premium.
    private var ttlMenu: some View {
        Menu {
            ForEach([24, 12, 6, 1, 48, 72], id: \.self) { hours in
                Button {
                    selectTTL(hours)
                } label: {
                    if model.ttlHours == hours {
                        Label(ttlLabel(hours), systemImage: "checkmark")
                    } else if hours != 24 && !isPremium {
                        Label(ttlLabel(hours), systemImage: "lock.fill")
                    } else {
                        Text(verbatim: ttlLabel(hours))
                    }
                }
            }
        } label: {
            menuRow(systemImage: "clock", title: String(localized: "Disparaît après"), value: ttlLabel(model.ttlHours))
        }
        .accessibilityIdentifier("story.ttl")
    }

    private var durationMenu: some View {
        Menu {
            ForEach([5, 10, 15], id: \.self) { seconds in
                Button {
                    Haptics.selection()
                    model.displayDuration = seconds
                } label: {
                    if model.displayDuration == seconds {
                        Label(String(localized: "\(seconds) s"), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "\(seconds) s"))
                    }
                }
            }
        } label: {
            menuRow(systemImage: "timer", title: String(localized: "Durée à l’écran"), value: String(localized: "\(model.displayDuration) s"))
        }
        .accessibilityIdentifier("story.duration")
    }

    private func menuRow(systemImage: String, title: String, value: String) -> some View {
        SQListRow(title, subtitle: stackedValue ? value : nil, systemImage: systemImage) {
            HStack(spacing: SQSpace.xs2) {
                if !stackedValue {
                    Text(verbatim: value)
                        .font(SQType.subhead(.medium))
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: value))
    }

    /// Aux tailles d'accessibilité, la valeur passe sous le titre au lieu de se
    /// couper en plein mot à droite.
    private var stackedValue: Bool { dynamicTypeSize.isAccessibilitySize }

    private var isPremium: Bool { services.entitlements.confirmedServerTier == .premium }

    private func selectTTL(_ hours: Int) {
        if hours == 24 || isPremium {
            Haptics.selection()
            model.ttlHours = hours
        } else {
            showPremiumPaywall = true
        }
    }

    private var hiddenValue: String {
        switch model.hiddenUserIds.count {
        case 0: return String(localized: "Personne")
        case 1: return String(localized: "1 personne")
        default: return String(localized: "\(model.hiddenUserIds.count) personnes")
        }
    }

    private func optionRow(systemImage: String, title: String, value: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            SQListRow(title, subtitle: stackedValue ? value : nil, systemImage: systemImage) {
                HStack(spacing: SQSpace.xs2) {
                    if !stackedValue {
                        Text(verbatim: value)
                            .font(SQType.subhead(.medium))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityValue(Text(verbatim: value))
    }
}

/// Outil sous la story : symbole et mot, allumé quand il est actif.
private struct StoryToolLabel: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .frame(height: 22)
                .accessibilityHidden(true)
            // Aux tailles d'accessibilité, le symbole seul : le libellé passe par
            // VoiceOver et par l'aperçu agrandi d'un appui long, comme dans le dock.
            if !dynamicTypeSize.isAccessibilitySize {
                Text(verbatim: title)
                    .font(SQType.caption(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
        .foregroundStyle(isOn ? Color.black : SQColor.onGlass)
        .frame(minWidth: 60, minHeight: 52)
        .padding(.horizontal, SQSpace.xs)
        .background {
            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                .fill(isOn ? SQColor.onGlass : SQColor.onGlass.opacity(0.12))
        }
        .contentShape(Rectangle())
    }
}

/// La story en 9:16, comme le lecteur l'affiche : photo et légende en bas, ou fond et texte
/// au centre sous l'avatar, puis le relevé joint. `editable` : la légende se tape dessus.
private struct StoryCanvas: View {
    @ObservedObject var model: StoryComposerViewModel
    let author: AuthUser?
    let editable: Bool
    var captionFocused: FocusState<Bool>.Binding
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Color.clear
            .aspectRatio(9 / 16, contentMode: .fit)
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: editable ? SQRadius.xl : SQRadius.sm, style: .continuous))
            // La story est une image de taille fixe chez ceux qui la verront : elle ne grossit pas ici.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// Toucher le fond ouvre ou ferme le clavier ; le champ garde ses propres touchers.
    private func toggleFocus() {
        if editable { captionFocused.wrappedValue.toggle() }
    }

    @ViewBuilder
    private var content: some View {
        if let image = model.previewImage {
            // La photo remplit le cadre sans jamais le dimensionner : en `scaledToFill`
            // dans une pile, elle l'élargissait et poussait la légende hors de la story.
            Color.clear
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityLabel(Text("Photo de la story"))
                }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleFocus)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .frame(height: editable ? 220 : 40)
                        .allowsHitTesting(false)
                }
                // En saisie, la photo s'assombrit et la légende monte au centre, au-dessus du clavier.
                .overlay {
                    if isTyping {
                        Color.black.opacity(0.45)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: toggleFocus)
                    }
                }
                .overlay(alignment: isTyping ? .center : .bottomLeading) {
                    VStack(alignment: isTyping ? .center : .leading, spacing: editable ? SQSpace.sm2 : 2) {
                        caption(alignment: isTyping ? .center : .leading,
                                font: isTyping ? SQFont.display(24, .bold, relativeTo: .title2)
                                    : SQFont.body(editable ? 17 : 6, .semibold, relativeTo: .body))
                        radioPill
                    }
                    .padding(.horizontal, editable ? SQSpace.lg : SQSpace.xs)
                    .padding(.bottom, editable ? SQSpace.lg : SQSpace.xs)
                }
                .environment(\.colorScheme, .dark)
        } else {
            let tint = StoryViewer.backgroundColor(model.background.hex)
            ZStack {
                (tint?.color ?? .black)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleFocus)
                VStack(spacing: editable ? SQSpace.lg : SQSpace.xs) {
                    SQAvatar(url: author?.avatarUrl, name: author?.name ?? author?.handle ?? "", size: editable ? 72 : 18)
                    caption(alignment: .center, font: SQFont.display(editable ? 26 : 8, .bold, relativeTo: .title2))
                    radioPill
                }
                .padding(.horizontal, editable ? SQSpace.xl : SQSpace.xs)
            }
            .environment(\.colorScheme, tint?.isLight == true ? .light : .dark)
        }
    }

    private var isTyping: Bool { editable && captionFocused.wrappedValue }

    private var inkColor: Color {
        model.previewImage == nil ? SQColor.label : SQColor.onGlass
    }

    @ViewBuilder
    private func caption(alignment: TextAlignment, font: Font) -> some View {
        if editable {
            // Le texte d'aide est posé sous le champ : un `prompt` ne passe pas à la ligne
            // et se coupait (« Écris quelque c… ») sur une story étroite.
            ZStack(alignment: alignment == .center ? .center : .leading) {
                if model.text.isEmpty {
                    Text(verbatim: placeholder)
                        .font(font)
                        .foregroundStyle(inkColor.opacity(0.6))
                        .multilineTextAlignment(alignment)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                captionField(alignment: alignment, font: font)
            }
        } else if !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(model.text)
                .font(font)
                .foregroundStyle(inkColor)
                .multilineTextAlignment(alignment)
                .lineLimit(4)
        }
    }

    private func captionField(alignment: TextAlignment, font: Font) -> some View {
        TextField("", text: $model.text, axis: .vertical)
            .font(font)
            .foregroundStyle(inkColor)
            .multilineTextAlignment(alignment)
            .lineLimit(1...(model.previewImage == nil ? 8 : 4))
            .textFieldStyle(.plain)
            .tint(inkColor)
            .focused(captionFocused)
            .submitLabel(.done)
            // Un champ vertical prend « ✓ » pour un saut de ligne : ✓ termine la saisie.
            .onChangeCompat(of: model.text) { _, text in
                guard text.contains("\n") else { return }
                model.text = text.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                captionFocused.wrappedValue = false
            }
            .accessibilityLabel(Text(model.previewImage == nil ? "Texte de la story" : "Légende"))
            .accessibilityHint(Text(verbatim: placeholder))
            .accessibilityIdentifier("story.caption")
    }

    private var placeholder: String {
        model.previewImage == nil ? String(localized: "Écris quelque chose…") : String(localized: "Ajoute une légende…")
    }

    /// Ce que le serveur joindra n'est connu qu'à l'envoi (son dernier relevé) : on ne devine pas l'opérateur.
    @ViewBuilder
    private var radioPill: some View {
        if model.attachRadio && editable {
            Label {
                Text("Relevé réseau joint")
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
            .font(SQType.caption(.bold))
            .foregroundStyle(inkColor)
            .lineLimit(1)
            .padding(.horizontal, SQSpace.sm2)
            .frame(minHeight: 26)
            .background(inkColor.opacity(0.16), in: Capsule(style: .continuous))
        } else if model.attachRadio {
            // Mini-story de « Partager » : le symbole seul.
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(inkColor)
                .padding(3)
                .background(inkColor.opacity(0.16), in: Capsule(style: .continuous))
        }
    }
}

/// Sélecteur multi-amis réutilisable (masquer à… / amis proches).
struct FriendMultiSelectSheet: View {
    let title: LocalizedStringKey
    let friends: [Friend]
    @Binding var selected: Set<String>
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if friends.isEmpty {
                    EmptyStateView(title: "Aucun ami", message: "Ajoute des amis pour affiner l'audience.", systemImage: "person.2")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(friends) { friend in
                            Button {
                                if selected.contains(friend.userId) { selected.remove(friend.userId) }
                                else { selected.insert(friend.userId) }
                                Haptics.selection()
                            } label: {
                                HStack(spacing: SQSpace.md) {
                                    SQAvatar(url: friend.avatarUrl, name: friend.displayName, size: 36)
                                    Text(friend.displayName).foregroundStyle(SQColor.label)
                                    Spacer()
                                    Image(systemName: selected.contains(friend.userId) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(friend.userId) ? SQColor.brandRed : SQColor.labelTertiary)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .signalQuestBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { onDone(); dismiss() }.tint(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
