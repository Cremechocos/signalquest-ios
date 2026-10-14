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
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = ImagePipeline.downsample(data: data, maxPixel: 1600) else {
                errorMessage = String(localized: "Photo illisible")
                return
            }
            previewImage = image
            pickedImageData = data
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
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack(spacing: SQSpace.sm) {
                    Text("Nouvelle story")
                        .font(SQFont.display(22, .heavy, relativeTo: .title2))
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Annuler", identifier: "story.composer.close") {
                        dismiss()
                    }
                }

                mediaAndCaption

                segmentGroup("Qui la voit") {
                    ForEach([StoryAudience.friends, .publicAll, .closeFriends]) { audience in
                        segment(audience.label, isSelected: model.audience == audience) {
                            model.audience = audience
                        }
                    }
                }
                segmentGroup("Disparaît après") { ttlSegments }
                segmentGroup("Affichage") {
                    ForEach([5, 10, 15], id: \.self) { seconds in
                        segment(String(localized: "\(seconds) s"), isSelected: model.displayDuration == seconds) {
                            model.displayDuration = seconds
                        }
                        .accessibilityLabel("Durée d'affichage \(seconds) secondes")
                    }
                }

                optionsCard

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(SQColor.dangerInk)
                }

                GradientButton("Publier la story", isBusy: model.isSending) {
                    Task {
                        await model.publish()
                        if model.didPublish {
                            if let story = model.publishedStory { onPublished(story) }
                            dismiss()
                        }
                    }
                }
                // Story vide : le bouton est grisé plutôt que sans effet.
                .disabled(!model.canPublish)
                .accessibilityIdentifier("story.publish")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xxl)
        }
        .onChangeCompat(of: model.selectedItem) { _, _ in
            Task { await model.loadPickerImage() }
        }
        .sheet(isPresented: $showBlurEditor) {
            if let image = model.previewImage {
                PhotoBlurEditor(image: image) { blurred, _ in model.applyBlurredImage(blurred) }
            }
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
        .sqSheet(background: SQColor.bg)
    }

    /// Aperçu du média et légende côte à côte.
    private var mediaAndCaption: some View {
        let previewImage = model.previewImage
        return HStack(alignment: .top, spacing: SQSpace.md) {
            PhotosPicker(selection: $model.selectedItem, matching: .images) {
                ZStack {
                    if let image = previewImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(SQColor.chip)
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(SQColor.labelSecondary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 112, height: 198)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel(previewImage == nil ? "Ajouter un média" : "Changer le média")
            // Posé sur le sélecteur, pas dans son étiquette : un bouton
            // imbriqué n'y recevrait pas le toucher.
            .overlay(alignment: .topLeading) {
                if previewImage != nil {
                    PhotoBlurButton { showBlurEditor = true }
                        .accessibilityIdentifier("story.blur")
                }
            }

            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Ta légende")
                    .font(SQType.caption(.bold))
                    .foregroundStyle(SQColor.labelSecondary)
                TextField("Une légende ?", text: $model.text, axis: .vertical)
                    .lineLimit(3...7)
                    .font(SQFont.body(15, .regular, relativeTo: .body))
                    .foregroundStyle(SQColor.label)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("story.caption")
                Spacer(minLength: 0)
                PhotosPicker(selection: $model.selectedItem, matching: .images) {
                    Text(previewImage == nil ? "Ajouter un média" : "Changer le média")
                        .font(SQType.subhead(.bold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, minHeight: 198, alignment: .topLeading)
        }
    }

    /// 24 h pour tous ; 12 h et 6 h en segments, les autres durées dans « Plus ».
    /// Toute durée autre que 24 h est réservée à Premium.
    @ViewBuilder
    private var ttlSegments: some View {
        ForEach([24, 12, 6], id: \.self) { hours in
            segment(String(localized: "\(hours) h"), isSelected: model.ttlHours == hours, locked: hours != 24 && !isPremium) {
                selectTTL(hours)
            }
            .accessibilityHint(hours == 24 ? "Disponible pour tous" : "Réservé à Premium")
        }
        let others = [1, 48, 72]
        let otherSelected = others.contains(model.ttlHours)
        Menu {
            ForEach(others, id: \.self) { hours in
                Button {
                    selectTTL(hours)
                } label: {
                    if model.ttlHours == hours {
                        Label("\(hours) h", systemImage: "checkmark")
                    } else if !isPremium {
                        Label("\(hours) h", systemImage: "lock.fill")
                    } else {
                        Text("\(hours) h")
                    }
                }
            }
        } label: {
            segmentLabel(otherSelected ? String(localized: "\(model.ttlHours) h") : String(localized: "Plus"),
                         isSelected: otherSelected, locked: false, showsChevron: true)
        }
        .accessibilityLabel("Autres durées")
        .accessibilityValue(otherSelected ? Text("\(model.ttlHours) h") : Text(""))
    }

    private var isPremium: Bool { services.entitlements.confirmedServerTier == .premium }

    private func selectTTL(_ hours: Int) {
        if hours == 24 || isPremium {
            Haptics.selection()
            model.ttlHours = hours
        } else {
            showPremiumPaywall = true
        }
    }

    /// Relevé réseau, puis « Masquer à… » (et les amis proches), sur une carte.
    private var optionsCard: some View {
        VStack(spacing: 0) {
            SQListRow(
                String(localized: "Joindre mon relevé réseau"),
                subtitle: String(localized: "Techno, opérateur et qualité au moment du partage."),
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                Toggle("Joindre mon relevé réseau", isOn: $model.attachRadio)
                    .labelsHidden()
                    .tint(SQColor.success)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)

            Divider().padding(.leading, 62)

            optionRow(systemImage: "hand.raised", title: String(localized: "Masquer à…"), value: hiddenValue) {
                model.showHideEditor = true
            }

            if model.audience == .closeFriends {
                Divider().padding(.leading, 62)
                optionRow(systemImage: "star", title: String(localized: "Amis proches"),
                          value: String(localized: "\(model.closeFriendIds.count)")) {
                    model.showCloseFriendsEditor = true
                }
            }
        }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
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
            SQListRow(title, systemImage: systemImage) {
                HStack(spacing: SQSpace.xs2) {
                    Text(verbatim: value)
                        .font(SQType.subhead(.medium))
                        .foregroundStyle(SQColor.labelSecondary)
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

    /// Titre discret puis piste de segments égaux (langage `Segmented` Halo).
    private func segmentGroup<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            Text(title)
                .font(SQType.caption(.bold))
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.leading, SQSpace.xs)
            HStack(spacing: 3) { content() }
                .padding(SQSpace.xs)
                .background(SQColor.segTrack, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
    }

    private func segment(_ title: String, isSelected: Bool, locked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            segmentLabel(title, isSelected: isSelected, locked: locked, showsChevron: false)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func segmentLabel(_ title: String, isSelected: Bool, locked: Bool, showsChevron: Bool) -> some View {
        HStack(spacing: SQSpace.xs) {
            Text(verbatim: title)
                .lineLimit(1)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 9)).accessibilityHidden(true)
            }
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
            }
        }
        .font(SQType.subhead(.bold))
        .foregroundStyle(isSelected ? SQColor.label : SQColor.ink2)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SQColor.segThumb)
                    .shadow(color: SQColor.shadowSoft, radius: 2, y: 1)
            }
        }
        .contentShape(Rectangle())
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
