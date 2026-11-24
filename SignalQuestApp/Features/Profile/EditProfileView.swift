import SwiftUI
import PhotosUI

struct EditProfileView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    let user: AuthUser

    /// Limite de caractères de la bio, alignée sur une valeur serveur raisonnable.
    static let bioCharacterLimit = 300

    @State private var name: String
    @State private var currentHandle: String
    @State private var showHandleSheet = false
    @State private var bio: String
    /// Bio telle que chargée du serveur — sert à n'envoyer la bio que si elle a
    /// réellement changé (évite l'écrasement à vide d'une bio non rechargée — EDITPROFILE-BUG-01).
    @State private var loadedBio: String
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarPreview: UIImage?
    @State private var isBusy = false
    @State private var error: String?
    @State private var showsSpotlight = false
    /// L'entrée « Mise en valeur » attend l'état des droits, qui n'est pas forcément lu à l'ouverture.
    @State private var spotlightOffered = false
    private enum Field { case name, bio }
    @FocusState private var focus: Field?

    init(user: AuthUser) {
        self.user = user
        _name = State(initialValue: user.name ?? "")
        _currentHandle = State(initialValue: user.handle ?? "")
        _bio = State(initialValue: user.bio ?? "")
        _loadedBio = State(initialValue: user.bio ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "profile.edit.close") {
                        dismiss()
                    }
                }
                Text("Modifier le profil")
                    .font(SQFont.display(30, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()

                avatarEditor

                AuthFieldGroup {
                    AuthFieldRow("Nom affiché (facultatif)", isFocused: focus == .name) {
                        TextField("Nom affiché", text: $name, prompt: SQFormPrompt.text("Par exemple : Lucie B."))
                            .textContentType(.name)
                            .submitLabel(.next)
                            .focused($focus, equals: .name)
                            .onSubmit { focus = .bio }
                            .accessibilityLabel("Nom affiché")
                            .accessibilityIdentifier("profile.edit.name")
                    } onTap: { focus = .name }
                    AuthFieldDivider()
                    Button { showHandleSheet = true } label: {
                        HStack(spacing: SQSpace.sm) {
                            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                                Text("Nom d’utilisateur")
                                    .font(SQType.caption(.bold))
                                    .foregroundStyle(SQColor.labelSecondary)
                                // Sans « @ » dans les formulaires (identité membre v1).
                                Text(currentHandle.isEmpty ? String(localized: "Choisir un nom d’utilisateur") : currentHandle)
                                    .font(SQType.body)
                                    .foregroundStyle(SQColor.label)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, SQSpace.md2)
                        .padding(.vertical, SQSpace.sm2)
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.edit.handle")
                    AuthFieldDivider()
                    AuthFieldRow("Bio", isFocused: focus == .bio,
                                 accessory: Text(verbatim: "\(bio.count) / \(Self.bioCharacterLimit)")) {
                        TextField("Bio", text: $bio, prompt: SQFormPrompt.text("Quelques mots sur toi"), axis: .vertical)
                            .lineLimit(2...5)
                            .focused($focus, equals: .bio)
                            .accessibilityLabel("Bio")
                            .accessibilityValue(Text("\(bio.count) caractères sur \(Self.bioCharacterLimit)"))
                            .accessibilityIdentifier("profile.edit.bio")
                            // Limite + compteur côté client (EDITPROFILE-AVATAR-BIO-07) :
                            // évite qu'une bio trop longue soit rejetée par le serveur
                            // sans indication.
                            .onChangeCompat(of: bio) { _, newValue in
                                if newValue.count > Self.bioCharacterLimit {
                                    bio = String(newValue.prefix(Self.bioCharacterLimit))
                                }
                            }
                    } onTap: { focus = .bio }
                }

                Text("Ton nom et ta bio sont visibles sur ton profil public et dans les classements.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.xs)
                    .padding(.top, -SQSpace.xs)

                if spotlightOffered {
                    spotlightEntry
                }

                if let error {
                    SQNotice(message: error, systemImage: "exclamationmark.triangle", tone: .danger)
                }

                GradientButton("Enregistrer", isBusy: isBusy) {
                    Task { await save() }
                }
                .disabled(!hasChanges || isBusy)
                .accessibilityIdentifier("profile.edit.save")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
        .interactiveDismissDisabled(isBusy)
        .onChangeCompat(of: avatarItem) { _, newValue in
            guard let newValue else { return }
            Task {
                // Aperçu d'avatar décodé réduit, pas en pleine taille (SOC-36).
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let img = ImagePipeline.downsample(data: data, maxPixel: 600) {
                    avatarPreview = img
                    error = nil
                } else {
                    // Sans message, le choix semblait pris en compte alors que rien n'avait changé.
                    avatarItem = nil
                    error = String(localized: "Image illisible.")
                }
            }
        }
        .sheet(isPresented: $showHandleSheet) {
            // Le nom d'utilisateur est déjà enregistré côté serveur : l'en-tête du profil
            // le relit sans attendre « Enregistrer » (qui peut ne jamais venir).
            ChooseHandleSheet(onSuccess: { newHandle in
                currentHandle = newHandle
                Task { await session.refreshUser() }
            })
        }
        .task { await loadProfileBio() }
        .task {
            spotlightOffered = ProfileSpotlightAccess.isOffered(services.entitlements)
            if services.entitlements.serverState.snapshot == nil {
                await services.entitlements.refreshBackendSnapshot()
                spotlightOffered = ProfileSpotlightAccess.isOffered(services.entitlements)
            }
        }
        .sheet(isPresented: $showsSpotlight) {
            ProfileSpotlightSettingsView(
                user: user,
                store: services.entitlements,
                service: ProfileSpotlightService(api: services.api),
                ownSpotlight: { [feed = services.feed, id = user.id] in
                    // La vraie courbe, lue sur son propre profil public.
                    (try? await feed.userProfile(userId: id))?.spotlight
                }
            )
        }
    }

    /// Ouvre les réglages de la mise en valeur, enregistrés à part : « Enregistrer » ci-dessous
    /// ne garde que le nom, la bio et la photo.
    private var spotlightEntry: some View {
        Button { showsSpotlight = true } label: {
            HStack(spacing: SQSpace.sm) {
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    Text("Mise en valeur du profil")
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                    Text("Bannière et couleur sur ton profil et dans le fil.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, SQSpace.md2)
            .padding(.vertical, SQSpace.sm2)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("profile.edit.spotlight")
    }

    /// Le nom d'utilisateur s'enregistre dans sa propre feuille : seuls le nom affiché, la bio
    /// et la photo attendent « Enregistrer ».
    private var hasChanges: Bool {
        avatarPreview != nil
            || name.trimmingCharacters(in: .whitespacesAndNewlines) != (user.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            || bio.trimmingCharacters(in: .whitespacesAndNewlines) != loadedBio.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recharge la bio depuis le serveur pour préremplir le champ sans l'écraser.
    /// On ne l'applique que si l'utilisateur n'a pas déjà édité le champ.
    private func loadProfileBio() async {
        guard let fresh = try? await services.users.profile() else { return }
        await MainActor.run {
            if bio == loadedBio { bio = fresh.bio ?? bio }
            loadedBio = fresh.bio ?? loadedBio
        }
    }

    private var avatarEditor: some View {
        VStack(spacing: SQSpace.sm) {
            Group {
                if let image = avatarPreview {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                } else {
                    SQAvatar(url: user.avatarUrl, name: user.displayName, size: 84)
                }
            }
            .accessibilityHidden(true)
            PhotosPicker(selection: $avatarItem, matching: .images) {
                Text("Changer la photo")
                    .font(SQType.callout(.semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
                    .padding(.horizontal, SQSpace.sm)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Changer la photo de profil")
            .accessibilityIdentifier("profile.edit.photo")
            .padding(.top, -SQSpace.xs)
        }
        .frame(maxWidth: .infinity)
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        // Identité membre v1 : le nom affiché est facultatif. Vidé, il part en `""` (jamais
        // omis, ce qui ne changeait rien en silence, EDITPROFILE-NAME-EMPTY-06) et le serveur
        // l'enregistre à `null` : le profil montre alors le nom d'utilisateur.
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Le nom d'utilisateur se change dans ChooseHandleSheet (vérification pendant la
            // saisie, délai de 30 jours). Ici, seuls le nom affiché et la bio.
            // EDITPROFILE-BUG-01 : n'envoyer la bio que si elle a changé. Le backend
            // fait un PUT ; envoyer une bio non rechargée l'écraserait à vide. `nil`
            // est omis par l'encodeur (encodeIfPresent) → la bio existante est préservée.
            let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            let bioChanged = trimmedBio != loadedBio.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await services.users.updateProfile(UserProfilePatch(
                name: trimmedName,
                handle: nil,
                bio: bioChanged ? trimmedBio : nil,
                avatarUrl: nil
            ))
            if let image = avatarPreview,
               let original = image.jpegData(compressionQuality: 1),
               // Redimensionnement de l'avatar (≤512 px) HORS du main thread : une photo
               // pleine résolution pesait plusieurs Mo à l'upload (EDITPROFILE-AVATAR-BIO-07).
               let data = await Task.detached(priority: .userInitiated, operation: {
                   PhotoUploadPreparation.downscaledJPEG(from: original, maxSide: 512, quality: 0.85)
               }).value {
                do {
                    _ = try await services.users.uploadAvatar(data: data, filename: "avatar.jpg", mimeType: "image/jpeg")
                } catch {
                    // Le nom et la bio sont déjà enregistrés : la session doit les relire
                    // avant qu'on remonte l'échec de la photo.
                    await session.refreshUser()
                    Haptics.error()
                    self.error = String(localized: "Profil enregistré, mais la photo n’a pas pu être envoyée. Réessaie.")
                    return
                }
            }
            // Rafraîchir la session : sans ça, l'en-tête du profil gardait l'ancien nom/
            // avatar jusqu'au relancement de l'app (EDITPROFILE-STALE-03).
            await session.refreshUser()
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.userFacingMessage
        }
    }
}

// MARK: - Mise en valeur du profil (D13)

/// Réglages du Profil mis en valeur, tels que les sert `GET`/`PUT /api/me/profile/spotlight`
/// (contrat Abonnements §3, v1.20). Le seuil de « Mes mesures » est servi, jamais écrit en dur ;
/// absent, la phrase du seuil se tait plutôt que d'inventer un nombre.
struct ProfileSpotlightSettings: Decodable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case measures
        case photo
        case noBanner = "none"
    }

    var kind: Kind
    var photoId: String?
    var accent: ProfileSpotlight.Accent
    var measuresCount: Int?
    var threshold: Int?
    /// Plus Premium, mais l'a été : bannière et couleur sont gardées et reviendront avec Premium.
    var kept: Bool

    /// « Mes mesures » n'a pas encore assez de speedtests : seule la couleur s'affiche.
    var belowThreshold: Bool {
        guard let measuresCount, let threshold else { return false }
        return measuresCount < threshold
    }

    init(kind: Kind, photoId: String?, accent: ProfileSpotlight.Accent,
         measuresCount: Int?, threshold: Int?, kept: Bool) {
        self.kind = kind
        self.photoId = photoId
        self.accent = accent
        self.measuresCount = measuresCount
        self.threshold = threshold
        self.kept = kept
    }

    private enum Keys: String, CodingKey { case banner, accent, measures, kept }
    private enum BannerKeys: String, CodingKey { case kind, photoId }
    private enum MeasuresKeys: String, CodingKey { case count, threshold }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let banner = try? c.nestedContainer(keyedBy: BannerKeys.self, forKey: .banner)
        kind = (try? banner?.decode(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .measures
        photoId = kind == .photo ? banner?.decodeFlexibleString(forKey: .photoId) : nil
        accent = (try? c.decode(String.self, forKey: .accent)).flatMap(ProfileSpotlight.Accent.init(rawValue:)) ?? .gold
        let measures = try? c.nestedContainer(keyedBy: MeasuresKeys.self, forKey: .measures)
        measuresCount = (try? measures?.decode(Int.self, forKey: .count)) ?? nil
        threshold = (try? measures?.decode(Int.self, forKey: .threshold)) ?? nil
        kept = (try? c.decode(Bool.self, forKey: .kept)) ?? false
    }
}

/// Une photo du membre utilisable comme bannière : `bannerUrl` est l'image que montrera la bannière.
struct ProfileSpotlightPhoto: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let thumbnailUrl: URL?
    let bannerUrl: URL?

    init(id: String, thumbnailUrl: URL?, bannerUrl: URL?) {
        self.id = id
        self.thumbnailUrl = thumbnailUrl
        self.bannerUrl = bannerUrl
    }

    private enum Keys: String, CodingKey { case id, thumbnailUrl, bannerUrl }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        thumbnailUrl = c.decodeLossyURL(forKey: .thumbnailUrl)
        bannerUrl = c.decodeLossyURL(forKey: .bannerUrl)
    }
}

struct ProfileSpotlightPhotoPage: Decodable, Sendable {
    let photos: [ProfileSpotlightPhoto]
    let nextCursor: String?

    private enum Keys: String, CodingKey { case photos, nextCursor }

    init(photos: [ProfileSpotlightPhoto], nextCursor: String?) {
        self.photos = photos
        self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        photos = c.decodeLossyArray([ProfileSpotlightPhoto].self, forKey: .photos)
        nextCursor = c.decodeFlexibleString(forKey: .nextCursor)
    }
}

protocol ProfileSpotlightServicing: Sendable {
    func settings() async throws -> ProfileSpotlightSettings
    func save(kind: ProfileSpotlightSettings.Kind, photoId: String?, accent: ProfileSpotlight.Accent) async throws -> ProfileSpotlightSettings
    /// 30 par page, la plus récente d'abord.
    func photos(cursor: String?) async throws -> ProfileSpotlightPhotoPage
}

struct ProfileSpotlightService: ProfileSpotlightServicing {
    let api: APIClient

    func settings() async throws -> ProfileSpotlightSettings {
        try await api.request(APIEndpoint(path: "/api/me/profile/spotlight"), as: ProfileSpotlightSettings.self)
    }

    func save(kind: ProfileSpotlightSettings.Kind, photoId: String?, accent: ProfileSpotlight.Accent) async throws -> ProfileSpotlightSettings {
        struct Banner: Encodable { let kind: String; let photoId: String? }
        struct Body: Encodable { let banner: Banner; let accent: String }
        let body = Body(banner: Banner(kind: kind.rawValue, photoId: kind == .photo ? photoId : nil),
                        accent: accent.rawValue)
        return try await api.requestJSON("/api/me/profile/spotlight", method: .put, body: body)
    }

    func photos(cursor: String?) async throws -> ProfileSpotlightPhotoPage {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        return try await api.request(
            APIEndpoint(path: "/api/me/profile/spotlight/photos", query: query),
            as: ProfileSpotlightPhotoPage.self
        )
    }
}

/// L'écran de réglages : choix en cours, aperçu fidèle et enregistrement explicite, comme Android.
@MainActor
final class ProfileSpotlightSettingsModel: ObservableObject {
    /// Ce que dit la ligne sous « Enregistrer » ; chaque refus du serveur a son texte, jamais le brut.
    enum Outcome: Equatable {
        case saved, premiumRequired, invalidAccent, photoNotEligible, offline, failed
    }

    struct Picker: Equatable {
        var photos: [ProfileSpotlightPhoto] = []
        var nextCursor: String?
        var loading = false
        var failed = false
        var loaded = false
    }

    @Published private(set) var loading = true
    @Published private(set) var loadFailed = false
    /// Dernier état connu du serveur : sert à savoir si quelque chose a changé.
    @Published private(set) var settings: ProfileSpotlightSettings?
    @Published private(set) var kind: ProfileSpotlightSettings.Kind = .measures
    @Published private(set) var accent: ProfileSpotlight.Accent = .gold
    @Published private(set) var photoId: String?
    /// Image de la photo choisie ; `nil` tant qu'elle n'est pas retrouvée (aperçu neutre).
    @Published private(set) var photoBannerURL: URL?
    /// Vraie courbe du membre, lue sur son profil public ; `nil` : aucun tracé inventé.
    @Published private(set) var ownSeries: [Double]?
    @Published private(set) var saving = false
    @Published private(set) var outcome: Outcome?
    @Published private(set) var picker = Picker()

    private let service: ProfileSpotlightServicing
    private let ownSpotlight: () async -> ProfileSpotlight?

    init(service: ProfileSpotlightServicing, ownSpotlight: @escaping () async -> ProfileSpotlight?) {
        self.service = service
        self.ownSpotlight = ownSpotlight
    }

    /// Un changement à enregistrer ; une bannière photo sans photo choisie ne s'enregistre pas.
    var canSave: Bool {
        guard let saved = settings, !saving else { return false }
        if kind == .photo && photoId == nil { return false }
        return kind != saved.kind || accent != saved.accent || (kind == .photo && photoId != saved.photoId)
    }

    /// Ce que l'aperçu montre pour les réglages en cours, selon la même règle que le serveur.
    var previewBanner: ProfileSpotlight.Banner {
        switch kind {
        case .noBanner:
            return .empty
        case .measures:
            guard settings?.belowThreshold != true, let ownSeries else { return .empty }
            return .measures(ownSeries)
        case .photo:
            guard photoId != nil, let photoBannerURL else { return .empty }
            return .photo(photoBannerURL)
        }
    }

    func load() async {
        loading = true
        loadFailed = false
        do {
            let loaded = try await service.settings()
            apply(loaded)
            loading = false
            // Aperçu fidèle, au mieux : un échec laisse un aperçu sans tracé ni image, jamais un faux.
            if loaded.kind == .measures, !loaded.belowThreshold { await loadOwnSeries() }
            if loaded.kind == .photo, let id = loaded.photoId, let page = try? await service.photos(cursor: nil) {
                photoBannerURL = page.photos.first { $0.id == id }?.bannerUrl
                picker = Picker(photos: page.photos, nextCursor: page.nextCursor, loaded: true)
            }
        } catch {
            loading = false
            loadFailed = true
        }
    }

    func select(_ kind: ProfileSpotlightSettings.Kind) {
        self.kind = kind
        outcome = nil
        // « Mes mesures » rechoisie après coup : la courbe se lit à ce moment-là si elle manque.
        if kind == .measures, ownSeries == nil, settings?.belowThreshold == false {
            Task { await loadOwnSeries() }
        }
    }

    func select(_ accent: ProfileSpotlight.Accent) {
        self.accent = accent
        outcome = nil
    }

    /// Choisir une photo bascule la bannière sur « Une de mes photos ».
    func choose(_ photo: ProfileSpotlightPhoto) {
        kind = .photo
        photoId = photo.id
        photoBannerURL = photo.bannerUrl
        outcome = nil
    }

    func loadMorePhotos() async {
        if picker.loading || (picker.loaded && picker.nextCursor == nil && !picker.failed) { return }
        picker.loading = true
        picker.failed = false
        do {
            let page = try await service.photos(cursor: picker.nextCursor)
            var seen = Set(picker.photos.map(\.id))
            picker.photos += page.photos.filter { seen.insert($0.id).inserted }
            picker.nextCursor = page.nextCursor
            picker.loaded = true
        } catch {
            picker.failed = true
        }
        picker.loading = false
    }

    func save() async {
        guard canSave else { return }
        saving = true
        outcome = nil
        do {
            let saved = try await service.save(kind: kind, photoId: kind == .photo ? photoId : nil, accent: accent)
            apply(saved)
            outcome = .saved
            Haptics.success()
        } catch {
            outcome = Self.outcome(for: error)
        }
        saving = false
    }

    static func outcome(for error: Error) -> Outcome {
        guard let api = error as? APIError else { return .failed }
        if api.isOffline { return .offline }
        if case .http(_, let code, _, _, _) = api {
            switch code {
            case "PREMIUM_REQUIRED": return .premiumRequired
            case "INVALID_ACCENT": return .invalidAccent
            case "PHOTO_NOT_ELIGIBLE": return .photoNotEligible
            default: break
            }
        }
        return .failed
    }

    private func apply(_ settings: ProfileSpotlightSettings) {
        self.settings = settings
        kind = settings.kind
        accent = settings.accent
        photoId = settings.photoId
    }

    private func loadOwnSeries() async {
        if case .measures(let series) = await ownSpotlight()?.banner { ownSeries = series }
    }
}

/// Le bloc n'existe que si le serveur annonce `profile.spotlight` (D20) : tant qu'il ne l'annonce
/// pas, ni l'entrée ni la ligne du paywall n'apparaissent, et c'est voulu.
enum ProfileSpotlightAccess {
    static let benefitKey = "profile.spotlight"

    @MainActor
    static func isOffered(_ store: EntitlementsStore) -> Bool {
        store.serverState.snapshot?.benefits?.premium.contains(benefitKey) == true
    }
}

/// « Mise en valeur du profil » : Premium, gratuit, ou gardé après la fin de Premium (D13,
/// planches 3 et 4 d'Android, sans maquette iOS : choix d'Alexandre du 24/11).
struct ProfileSpotlightSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let user: AuthUser
    /// Observé : un achat fait depuis « Découvrir Premium » ouvre les réglages sans rouvrir l'écran.
    @ObservedObject private var store: EntitlementsStore
    @StateObject private var model: ProfileSpotlightSettingsModel
    @State private var showsPicker = false
    @State private var showsPaywall = false

    init(user: AuthUser, store: EntitlementsStore, service: ProfileSpotlightServicing,
         ownSpotlight: @escaping () async -> ProfileSpotlight?) {
        self.user = user
        self.store = store
        _model = StateObject(wrappedValue: ProfileSpotlightSettingsModel(service: service, ownSpotlight: ownSpotlight))
    }

    private var isPremium: Bool { store.confirmedServerTier == .premium }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "profile.spotlight.close") {
                        dismiss()
                    }
                }
                Text("Mise en valeur du profil")
                    .font(SQFont.display(30, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                content
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sqSheet(background: SQColor.bg)
        .interactiveDismissDisabled(model.saving)
        .task { if model.settings == nil { await model.load() } }
        .sheet(isPresented: $showsPicker) {
            ProfileSpotlightPhotoPicker(model: model) { showsPicker = false }
        }
        .sheet(isPresented: $showsPaywall, onDismiss: {
            // Premium pris ou non : les réglages se relisent avec le palier du serveur.
            Task {
                await store.refreshBackendSnapshot()
                await model.load()
            }
        }) {
            PaywallView(store: store, entryPoint: .premiumFeature(String(localized: "Mise en valeur du profil")))
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.settings == nil {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .fill(SQColor.fill)
                .frame(height: 160)
                .sqShimmer()
                .accessibilityHidden(true)
        } else if isPremium && model.settings == nil {
            ErrorStateView(title: "Réglages indisponibles", message: "Vérifie ta connexion, puis réessaie.") {
                Task { await model.load() }
            }
        } else if isPremium {
            premiumSettings
        } else if model.settings?.kept == true {
            note("Ta bannière et ta couleur sont gardées. Elles réapparaissent dès que Premium revient.")
            discoverButton
        } else {
            note("Une bannière tirée de tes mesures ou de tes photos, et une couleur sur ton profil et dans le fil.")
            VStack(spacing: 0) {
                freeRow("Bannière")
                Divider().overlay(SQColor.separator)
                freeRow("Couleur")
            }
            .padding(.horizontal, SQSpace.md)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            discoverButton
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(SQType.callout)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// « Bannière — Aucune » : ce que le compte gratuit a aujourd'hui, dit sans artifice.
    private func freeRow(_ label: LocalizedStringKey) -> some View {
        HStack {
            Text(label).font(SQType.callout(.bold)).foregroundStyle(SQColor.label)
            Spacer(minLength: SQSpace.sm)
            Text("Aucune").font(SQType.callout).foregroundStyle(SQColor.labelSecondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var discoverButton: some View {
        GradientButton("Découvrir Premium", style: .secondary) { showsPaywall = true }
            .accessibilityIdentifier("profile.spotlight.discover")
    }

    @ViewBuilder
    private var premiumSettings: some View {
        preview
        if model.kind == .measures, model.settings?.belowThreshold == true, let threshold = model.settings?.threshold {
            // Le seuil est servi, jamais écrit en dur.
            note("Ta bannière se dessinera après tes \(threshold) premiers speedtests. En attendant, ton profil garde ta couleur.")
        }
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            sectionLabel("Bannière")
            VStack(spacing: 0) {
                kindRow(.measures, title: "Mes mesures",
                        hint: "La courbe de tes derniers débits mesurés. Aucun lieu n’y figure.")
                Divider().overlay(SQColor.separator)
                HStack(spacing: SQSpace.sm) {
                    // Sans photo déjà choisie, la ligne ouvre le sélecteur : « Photo » seule n'a rien à montrer.
                    kindRow(.photo, title: "Une de mes photos", hint: "Choisie parmi tes photos déjà publiées.",
                            action: model.photoId == nil ? { showsPicker = true } : nil)
                    Button("Choisir") { showsPicker = true }
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Choisir une photo")
                        .accessibilityIdentifier("profile.spotlight.choosePhoto")
                }
                Divider().overlay(SQColor.separator)
                kindRow(.noBanner, title: "Aucune", hint: "Seule la couleur reste, autour de ton avatar.")
            }
            .padding(.horizontal, SQSpace.md)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            sectionLabel("Couleur")
            // Six pastilles sur une ligne d'iPhone ; en grand texte, la grille passe à la ligne.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: SQSpace.xxs)], spacing: SQSpace.xs) {
                ForEach(ProfileSpotlight.Accent.allCases, id: \.self) { accent in
                    swatch(accent)
                }
            }
            note("Visible sur ton profil et sur tes publications dans le fil.")
        }
        if let outcome = model.outcome {
            SQNotice(message: Self.message(for: outcome), tone: outcome == .saved ? .success : .danger)
        }
        GradientButton("Enregistrer", isBusy: model.saving) {
            Task { await model.save() }
        }
        .disabled(!model.canSave)
        .accessibilityIdentifier("profile.spotlight.save")
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .sqKicker()
            .accessibilityAddTraits(.isHeader)
            .padding(.leading, SQSpace.xs)
    }

    /// Aperçu : la bannière réglée et l'avatar cerclé de l'encre, comme les autres les verront.
    private var preview: some View {
        let banner = model.previewBanner
        return ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                Group {
                    if banner != .empty {
                        SQSpotlightBanner(spotlight: ProfileSpotlight(accent: model.accent, banner: banner))
                    } else {
                        SQColor.chip
                    }
                }
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                Color.clear.frame(height: 24)
            }
            SQAvatar(url: user.avatarUrl, name: user.displayName, size: 52)
                .padding(3)
                .background(SQColor.bg, in: SQAvatarShape())
                .overlay { SQAvatarShape().strokeBorder(model.accent.ink, lineWidth: 3) }
                .padding(.leading, SQSpace.lg)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("profile.spotlight.preview")
    }

    private func kindRow(_ kind: ProfileSpotlightSettings.Kind, title: LocalizedStringKey, hint: LocalizedStringKey,
                         action: (() -> Void)? = nil) -> some View {
        let selected = model.kind == kind
        return Button {
            if let action { action() } else { model.select(kind) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    Text(title).font(SQType.callout(.bold)).foregroundStyle(SQColor.label)
                    Text(hint).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(SQType.body.weight(.semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, SQSpace.sm2)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("profile.spotlight.kind.\(kind.rawValue)")
    }

    /// Pastille d'encre et son nom dessous ; le nom reste dans la couleur du texte : l'encre ne
    /// colore jamais un texte. Largeur minimale, pas fixe : en grand texte, la grille passe à la ligne.
    private func swatch(_ accent: ProfileSpotlight.Accent) -> some View {
        let selected = model.accent == accent
        return Button { model.select(accent) } label: {
            VStack(spacing: SQSpace.xs) {
                Circle()
                    .fill(accent.ink)
                    .frame(width: 30, height: 30)
                    .padding(4)
                    .overlay { Circle().strokeBorder(selected ? SQColor.accentInk : .clear, lineWidth: 2) }
                Text(verbatim: accent.label)
                    .font(selected ? SQType.caption(.bold) : SQType.caption)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: 52, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accent.label))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("profile.spotlight.accent.\(accent.rawValue)")
    }

    static func message(for outcome: ProfileSpotlightSettingsModel.Outcome) -> String {
        switch outcome {
        case .saved: String(localized: "Enregistré.")
        case .premiumRequired: String(localized: "La mise en valeur du profil est réservée aux membres Premium.")
        case .invalidAccent: String(localized: "Cette couleur n’est pas disponible. Choisis-en une autre.")
        case .photoNotEligible: String(localized: "Cette photo ne peut plus servir de bannière. Choisis-en une autre.")
        case .offline: String(localized: "Pas de connexion. Rien n’a été enregistré.")
        case .failed: String(localized: "Enregistrement impossible. Rien n’a changé : réessaie.")
        }
    }
}

/// Sélecteur « Une de mes photos » : 30 par page, la plus récente d'abord, dans une feuille.
struct ProfileSpotlightPhotoPicker: View {
    @ObservedObject var model: ProfileSpotlightSettingsModel
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack {
                    Text("Choisis une photo")
                        .font(SQFont.display(22, .bold, relativeTo: .title2))
                        .foregroundStyle(SQColor.label)
                        .sqHeader()
                    Spacer(minLength: SQSpace.sm)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "profile.spotlight.picker.close") {
                        onClose()
                    }
                }
                let picker = model.picker
                if picker.photos.isEmpty && (picker.loading || !picker.loaded) && !picker.failed {
                    RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                        .fill(SQColor.fill)
                        .frame(height: 160)
                        .sqShimmer()
                        .accessibilityHidden(true)
                } else if picker.photos.isEmpty && picker.failed {
                    retry
                } else if picker.photos.isEmpty {
                    Text("Tu n’as pas encore de photo publiée.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                } else {
                    grid(picker)
                    if picker.failed { retry }
                }
            }
            .padding(SQSpace.lg)
        }
        .sqSheet(background: SQColor.bg)
        .presentationDetents([.medium, .large])
        .task { if !model.picker.loaded { await model.loadMorePhotos() } }
    }

    private var retry: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text("Impossible de charger les photos.")
                .font(SQType.callout)
                .foregroundStyle(SQColor.labelSecondary)
            Button("Réessayer") { Task { await model.loadMorePhotos() } }
                .font(SQType.callout(.semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
        }
    }

    private func grid(_ picker: ProfileSpotlightSettingsModel.Picker) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 3), spacing: SQSpace.sm) {
            ForEach(Array(picker.photos.enumerated()), id: \.element.id) { index, photo in
                let shape = RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                let selected = photo.id == model.photoId
                Button {
                    model.choose(photo)
                    onClose()
                } label: {
                    Color.clear
                        .frame(height: 104)
                        .overlay {
                            RemoteImage(url: photo.thumbnailUrl ?? photo.bannerUrl, maxDimension: 200,
                                        contentMode: .fill, showsFailureUI: true) {
                                Rectangle().fill(SQColor.fill).sqShimmer()
                            }
                        }
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(selected ? SQColor.accentInk : .clear, lineWidth: 3) }
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Photo \(index + 1) sur \(picker.photos.count)"))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                // Les trois dernières vignettes demandent la page suivante ; le modèle refuse un doublon.
                .onAppear {
                    if picker.nextCursor != nil, index >= picker.photos.count - 3 {
                        Task { await model.loadMorePhotos() }
                    }
                }
            }
        }
    }
}
