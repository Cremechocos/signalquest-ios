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
                    AuthFieldRow("Nom affiché", isFocused: focus == .name) {
                        TextField("Nom affiché", text: $name, prompt: SQFormPrompt.text("Ton nom"))
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
                                Text(currentHandle.isEmpty ? String(localized: "Choisir un nom d’utilisateur") : "@\(currentHandle)")
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
                }
            }
        }
        .sheet(isPresented: $showHandleSheet) {
            // Le @pseudo est déjà enregistré côté serveur : l'en-tête du profil
            // le relit sans attendre « Enregistrer » (qui peut ne jamais venir).
            ChooseHandleSheet(onSuccess: { newHandle in
                currentHandle = newHandle
                Task { await session.refreshUser() }
            })
        }
        .task { await loadProfileBio() }
    }

    /// Le @pseudo s'enregistre dans sa propre feuille : seuls le nom, la bio et
    /// la photo attendent « Enregistrer ».
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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Vider le nom était ignoré en silence (nilIfEmpty → clé omise) : l'action
        // « réussissait » sans rien changer. On refuse un nom vide explicitement
        // plutôt que de laisser croire à un enregistrement (EDITPROFILE-NAME-EMPTY-06).
        guard !trimmedName.isEmpty else {
            error = String(localized: "Le nom ne peut pas être vide.")
            return
        }
        do {
            // Le @handle se choisit/modifie via ChooseHandleSheet (vérif live + cooldown 30 j).
            // Ici on n'enregistre que le nom (partageable) et la bio.
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
                _ = try await services.users.uploadAvatar(data: data, filename: "avatar.jpg", mimeType: "image/jpeg")
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
