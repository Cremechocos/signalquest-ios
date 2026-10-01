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
    @Published var friends: [Friend] = []
    @Published var showHideEditor = false
    @Published var showCloseFriendsEditor = false

    /// Octets choisis, conservés seulement pour l'aperçu. Le service les
    /// ré-encode sans métadonnées avant tout envoi réseau.
    private var pickedImageData: Data?
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
        closeFriendIds = Set((await closeResult)?.map(\.id) ?? [])
    }

    func loadPickerImage() async {
        guard let item = selectedItem else { return }
        do {
            // Aperçu décodé réduit, pas en pleine taille (SOC-36).
            if let data = try await item.loadTransferable(type: Data.self),
               let image = ImagePipeline.downsample(data: data, maxPixel: 1600) {
                previewImage = image
                pickedImageData = data
            }
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Photo floutée avant publication (plan 3, vague 1) : elle remplace
    /// l'originale, et c'est elle qui part.
    func applyBlurredImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        previewImage = image
        pickedImageData = data
    }

    /// Persiste la liste d'amis proches (PUT). Appelé à la fermeture de l'éditeur.
    func saveCloseFriends() async {
        do { _ = try await service.setCloseFriends(userIds: Array(closeFriendIds)) }
        catch { if !error.isCancellation { errorMessage = error.userFacingMessage } }
    }

    func publish() async {
        let caption = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // Un relevé réseau seul fait une story, comme côté serveur : l'appui ne
        // faisait rien (SOC-34).
        guard caption != nil || pickedImageData != nil || attachRadio else { return }
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
                background: nil,
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

struct StoryComposer: View {
    @StateObject private var model: StoryComposerViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var showPremiumPaywall = false
    /// Éditeur « Flouter » de la photo (plan 3, vague 1).
    @State private var showBlurEditor = false

    private let onPublished: (SocialStory) -> Void

    init(
        service: StoriesServicing,
        friendsService: FriendsServicing,
        onPublished: @escaping (SocialStory) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: StoryComposerViewModel(service: service, friendsService: friendsService))
        self.onPublished = onPublished
    }

    var body: some View {
        let previewImage = model.previewImage
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg + 2) {
                    SQSheetHandle()
                    PhotosPicker(selection: $model.selectedItem, matching: .images) {
                        ZStack {
                            if let image = previewImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle()
                                    .fill(SQColor.surfaceMuted)
                                VStack(spacing: SQSpace.sm) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 40))
                                        .accessibilityHidden(true)
                                    Text("Ajouter un média")
                                        .font(SQType.subhead)
                                }
                                .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .sqShadowCard()
                    }
                    .buttonStyle(SQPressButtonStyle())
                    // Posé sur le sélecteur, pas dans son étiquette : un bouton
                    // imbriqué n'y recevrait pas le toucher.
                    .overlay(alignment: .topLeading) {
                        if previewImage != nil {
                            PhotoBlurButton { showBlurEditor = true }
                                .accessibilityIdentifier("story.blur")
                        }
                    }
                    .onChangeCompat(of: model.selectedItem) { _, _ in
                        Task { await model.loadPickerImage() }
                    }
                    .sheet(isPresented: $showBlurEditor) {
                        if let image = model.previewImage {
                            PhotoBlurEditor(image: image) { blurred, _ in model.applyBlurredImage(blurred) }
                        }
                    }

                    // Champ capsule « Crème » : SurfaceMuted, sans bordure.
                    TextField("Une légende ?", text: $model.text, axis: .vertical)
                        .lineLimit(2...6)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .padding(.horizontal, SQSpace.lg)
                        .padding(.vertical, SQSpace.sm + 2)
                        .frame(minHeight: 44)
                        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.pill, style: .continuous))

                    audienceSection
                    hideSection
                    signalSection
                    ttlSection
                    durationRow

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(SQColor.danger)
                    }

                    GradientButton("Publier", systemImage: "paperplane.fill", isBusy: model.isSending) {
                        Task {
                            await model.publish()
                            if model.didPublish {
                                if let story = model.publishedStory { onPublished(story) }
                                dismiss()
                            }
                        }
                    }
                }
                .padding(SQSpace.xl)
            }
            .signalQuestBackground()
            .navigationTitle("Nouvelle story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
            .task {
                await model.loadAudience()
                await services.entitlements.refreshBackendSnapshot()
            }
            .sheet(isPresented: $model.showHideEditor) {
                FriendMultiSelectSheet(title: "Masquer à…", friends: model.friends, selected: $model.hiddenUserIds)
            }
            .sheet(isPresented: $model.showCloseFriendsEditor) {
                FriendMultiSelectSheet(title: "Amis proches", friends: model.friends, selected: $model.closeFriendIds) {
                    Task { await model.saveCloseFriends() }
                }
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
    }

    /// Story typée « signal ».
    private var signalSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Toggle(isOn: $model.attachRadio) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Joindre mon relevé réseau")
                        .font(SQFont.body(15, .medium))
                    Text("Techno, opérateur et qualité au moment du partage.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .tint(SQColor.brandRed)
        }
        .padding(SQSpace.md)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private var audienceSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Audience").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
            // Segments capsules « Crème » : actif brique, inactif surface + ombre repos.
            HStack(spacing: SQSpace.sm) {
                ForEach(StoryAudience.allCases) { audience in
                    let selected = model.audience == audience
                    Button {
                        Haptics.selection()
                        model.audience = audience
                    } label: {
                        Text(audience.label)
                            .font(SQFont.body(13, .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .background(
                                selected ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                                in: Capsule(style: .continuous)
                            )
                            .foregroundStyle(selected ? SQColor.onAccent : SQColor.label)
                            .sqShadowSoft()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if model.audience == .closeFriends {
                menuRow(
                    systemImage: "star.fill",
                    title: String(localized: "Gérer mes amis proches (\(model.closeFriendIds.count))")
                ) {
                    model.showCloseFriendsEditor = true
                }
            }
        }
    }

    private var hideSection: some View {
        menuRow(
            systemImage: "eye.slash",
            title: model.hiddenUserIds.isEmpty
                ? String(localized: "Masquer à…")
                : model.hiddenUserIds.count == 1
                    ? String(localized: "Masqué à 1 personne")
                    : String(localized: "Masqué à \(model.hiddenUserIds.count) personnes")
        ) {
            model.showHideEditor = true
        }
    }

    /// Rangée de menu « Crème » : pastille icône 36 rayon 12 `accentSoft`,
    /// libellé Figtree 500 15.5, chevron tertiaire — sur petite tuile surface.
    private func menuRow(systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 36, height: 36)
                    .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(SQFont.body(15.5, .medium))
                    .foregroundStyle(SQColor.label)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.sm + 2)
            .sqCardBackground(cornerRadius: SQRadius.md, elevation: .rest)
        }
        .buttonStyle(SQPressButtonStyle())
    }

    private var ttlSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Durée de vie").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 3),
                spacing: SQSpace.sm
            ) {
                ForEach([1, 6, 12, 24, 48, 72], id: \.self) { hours in
                    let selected = model.ttlHours == hours
                    Button {
                        if hours == 24 || services.entitlements.confirmedServerTier == .premium {
                            model.ttlHours = hours
                        } else {
                            showPremiumPaywall = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(hours) h")
                            if hours != 24 { Image(systemName: "lock.fill").font(.system(size: 9)) }
                        }
                        .font(SQFont.body(13, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SQSpace.sm)
                        .background(
                            selected ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                            in: Capsule(style: .continuous)
                        )
                        .foregroundStyle(selected ? SQColor.onAccent : SQColor.label)
                        .sqShadowSoft()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint(hours == 24 ? "Disponible pour tous" : "Réservé à Premium")
                }
            }
        }
    }

    private var durationRow: some View {
        HStack(spacing: SQSpace.sm) {
            Label("Affichage", systemImage: "timer")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
            Spacer()
            HStack(spacing: SQSpace.xs + 2) {
                ForEach([5, 10, 15], id: \.self) { seconds in
                    let selected = model.displayDuration == seconds
                    Button {
                        Haptics.selection()
                        model.displayDuration = seconds
                    } label: {
                        Text("\(seconds)s")
                            .font(SQFont.body(13, .semibold))
                            .padding(.horizontal, SQSpace.md)
                            .frame(minHeight: 40)
                            .background(
                                selected ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                                in: Capsule(style: .continuous)
                            )
                            .foregroundStyle(selected ? SQColor.onAccent : SQColor.label)
                            .sqShadowSoft()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityLabel("Durée d'affichage \(seconds) secondes")
                }
            }
        }
    }
}

/// Sélecteur multi-amis réutilisable (masquer à… / amis proches).
struct FriendMultiSelectSheet: View {
    let title: String
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
