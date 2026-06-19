import SwiftUI
import PhotosUI

struct EditProfileView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    let user: AuthUser

    @State private var name: String
    @State private var currentHandle: String
    @State private var showHandleSheet = false
    @State private var bio: String
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarPreview: UIImage?
    @State private var isBusy = false
    @State private var error: String?

    init(user: AuthUser) {
        self.user = user
        _name = State(initialValue: user.name ?? "")
        _currentHandle = State(initialValue: user.handle ?? "")
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
                        Button { showHandleSheet = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Nom d’utilisateur")
                                        .font(SQType.micro)
                                        .foregroundStyle(SQColor.labelTertiary)
                                    Text(currentHandle.isEmpty ? "Choisir un nom d’utilisateur" : "@\(currentHandle)")
                                        .font(SQType.body)
                                        .foregroundStyle(SQColor.label)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(SQColor.labelTertiary)
                            }
                            .padding(SQSpace.md)
                            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        }
                        .buttonStyle(.plain)
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
            .onChangeCompat(of: avatarItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        avatarPreview = img
                    }
                }
            }
            .sheet(isPresented: $showHandleSheet) {
                ChooseHandleSheet(onSuccess: { newHandle in currentHandle = newHandle })
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
            .accessibilityHidden(true)
            PhotosPicker(selection: $avatarItem, matching: .images) {
                Image(systemName: "camera.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(SQColor.brandRed, in: Circle())
                    .overlay { Circle().stroke(SQColor.bg, lineWidth: 2) }
            }
            .accessibilityLabel("Changer la photo de profil")
        }
        .frame(maxWidth: .infinity)
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        do {
            // Le @handle se choisit/modifie via ChooseHandleSheet (vérif live + cooldown 30 j).
            // Ici on n'enregistre que le nom (partageable) et la bio.
            _ = try await services.users.updateProfile(UserProfilePatch(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                handle: nil,
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
