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
        case .publicAll: return "Public"
        case .friends: return "Amis"
        case .closeFriends: return "Proches"
        }
    }
}

@MainActor
final class StoryComposerViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var selectedItem: PhotosPickerItem?
    @Published var previewImage: UIImage?
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var didPublish = false
    /// Durée d'affichage de la story (autorisée : 5/10/15 s).
    @Published var displayDuration: Int = 10

    // Audience avancée.
    @Published var audience: StoryAudience = .friends
    @Published var ttlHours: Int = 24
    @Published var hiddenUserIds: Set<String> = []
    @Published var closeFriendIds: Set<String> = []
    @Published var friends: [Friend] = []
    @Published var showHideEditor = false
    @Published var showCloseFriendsEditor = false

    /// Données JPEG de l'image choisie, prêtes à téléverser.
    private var pickedImageData: Data?
    private let service: StoriesServicing
    private let friendsService: FriendsServicing
    init(service: StoriesServicing, friendsService: FriendsServicing) {
        self.service = service
        self.friendsService = friendsService
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
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                previewImage = image
                pickedImageData = image.jpegData(compressionQuality: 0.85) ?? data
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Persiste la liste d'amis proches (PUT). Appelé à la fermeture de l'éditeur.
    func saveCloseFriends() async {
        do { _ = try await service.setCloseFriends(userIds: Array(closeFriendIds)) }
        catch { errorMessage = error.localizedDescription }
    }

    func publish() async {
        let caption = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard caption != nil || pickedImageData != nil else { return }
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
            _ = try await service.create(
                text: caption,
                mediaUrl: mediaUrl,
                thumbnailUrl: thumbnailUrl,
                mediaKind: mediaUrl != nil ? "image" : nil,
                displayDurationSeconds: displayDuration,
                visibility: audience.rawValue,
                ttlHours: ttlHours,
                hiddenUserIds: Array(hiddenUserIds),
                background: nil
            )
            didPublish = true
            Haptics.success()
        } catch {
            // Le backend renvoie 403 si une durée > 24 h est demandée sans Premium.
            errorMessage = ttlHours != 24
                ? "Durée longue réservée aux comptes Premium."
                : error.localizedDescription
            Haptics.error()
        }
    }
}

struct StoryComposer: View {
    @StateObject private var model: StoryComposerViewModel
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var showPremiumPaywall = false

    init(service: StoriesServicing, friendsService: FriendsServicing) {
        _model = StateObject(wrappedValue: StoryComposerViewModel(service: service, friendsService: friendsService))
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
                    .onChangeCompat(of: model.selectedItem) { _, _ in
                        Task { await model.loadPickerImage() }
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
                            if model.didPublish { dismiss() }
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
                    title: "Gérer mes amis proches (\(model.closeFriendIds.count))"
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
                ? "Masquer à…"
                : "Masqué à \(model.hiddenUserIds.count) personne\(model.hiddenUserIds.count > 1 ? "s" : "")"
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
                Text(title)
                    .font(SQFont.body(15.5, .medium))
                    .foregroundStyle(SQColor.label)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.sm + 2)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .sqShadowSoft()
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
