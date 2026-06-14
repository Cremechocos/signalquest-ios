import SwiftUI
import PhotosUI

struct EditProfileView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    let user: AuthUser

    @State private var name: String
    @State private var handle: String
    @State private var bio: String
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarPreview: UIImage?
    @State private var isBusy = false
    @State private var error: String?

    init(user: AuthUser) {
        self.user = user
        _name = State(initialValue: user.name ?? "")
        _handle = State(initialValue: user.handle ?? "")
        _bio = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.xl) {
                    avatarEditor
                        .padding(.top, SQSpace.md)
                        .sqFadeUp()

                    VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
                        Text("Identité").sqKicker()
                        TextField("Nom", text: $name)
                            .textContentType(.name)
                            .textFieldStyle(SQTextFieldStyle())
                        TextField("Nom d’utilisateur", text: $handle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(SQTextFieldStyle())
                            .disabled(handleLocked)
                            .opacity(handleLocked ? 0.55 : 1)
                        if handleLocked {
                            Text("Le nom d’utilisateur ne peut être choisi qu’une seule fois.")
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.labelTertiary)
                        }
                        TextField("Bio", text: $bio, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(SQTextFieldStyle())
                    }
                    .sqFadeUp()

                    if let error {
                        Text(error)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SQSpace.md)
                            .background(SQColor.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    }

                    GradientButton("Enregistrer", systemImage: "checkmark.circle.fill", isBusy: isBusy) {
                        Task { await save() }
                    }
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Éditer le profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }.tint(SQColor.brandRed)
                }
            }
            .onChange(of: avatarItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        avatarPreview = img
                    }
                }
            }
        }
    }

    private var avatarEditor: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = avatarPreview {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                } else {
                    SQAvatar(url: user.avatarUrl, name: user.displayName, size: 96)
                }
            }
            .padding(5)
            .overlay {
                Circle().stroke(SQColor.brandRed, lineWidth: 3)
            }
            PhotosPicker(selection: $avatarItem, matching: .images) {
                Image(systemName: "camera.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(SQColor.brandRed, in: Circle())
                    .overlay { Circle().stroke(SQColor.bg, lineWidth: 2) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Le backend verrouille le nom d'utilisateur une fois défini.
    private var handleLocked: Bool { !(user.handle ?? "").isEmpty }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        do {
            // N'envoyer `handle` QUE s'il n'est pas encore défini : sinon le backend
            // renvoie 409 USER_HANDLE_LOCKED et fait échouer tout le PUT (même le nom).
            let handlePatch = handleLocked ? nil : handle.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            _ = try await services.users.updateProfile(UserProfilePatch(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                handle: handlePatch,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                avatarUrl: nil
            ))
            if let image = avatarPreview, let data = image.jpegData(compressionQuality: 0.85) {
                _ = try await services.users.uploadAvatar(data: data, filename: "avatar.jpg", mimeType: "image/jpeg")
            }
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
