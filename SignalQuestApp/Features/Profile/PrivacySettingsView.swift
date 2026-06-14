import SwiftUI

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    @Published var defaultVisibility: String = "public"
    @Published var allowMentions = true
    @Published var allowFollow = true
    @Published var allowDMs = true
    @Published var showRadioOnPosts = true
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var loaded = false
    @Published var errorMessage: String?
    @Published var savedConfirmation = false

    private let service: PrivacyServicing
    init(service: PrivacyServicing) { self.service = service }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            apply(try await service.get())
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() async {
        isSaving = true
        errorMessage = nil
        savedConfirmation = false
        defer { isSaving = false }
        let patch = UpdatePrivacyRequest(
            defaultVisibility: defaultVisibility,
            allowMentions: allowMentions,
            allowFollow: allowFollow,
            allowDMs: allowDMs,
            showRadioOnPosts: showRadioOnPosts
        )
        do {
            apply(try await service.update(patch))
            savedConfirmation = true
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func apply(_ p: SocialPrivacy) {
        if let v = p.defaultVisibility { defaultVisibility = v }
        if let v = p.allowMentions { allowMentions = v }
        if let v = p.allowFollow { allowFollow = v }
        if let v = p.allowDMs { allowDMs = v }
        if let v = p.showRadioOnPosts { showRadioOnPosts = v }
    }
}

/// Écran « Confidentialité » : permet à l'utilisateur d'exercer son contrôle et
/// son droit d'opposition (RGPD art. 7.3 / 21) sur la visibilité de ses contenus
/// et les interactions le concernant.
struct PrivacySettingsView: View {
    @StateObject private var model: PrivacySettingsViewModel

    init(service: PrivacyServicing) {
        _model = StateObject(wrappedValue: PrivacySettingsViewModel(service: service))
    }

    private let visibilityOptions: [(value: String, label: String)] = [
        ("public", "Public"),
        ("friends", "Amis"),
        ("private", "Privé"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Visibilité par défaut", selection: $model.defaultVisibility) {
                    ForEach(visibilityOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .foregroundStyle(SQColor.label)
            } header: {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Confidentialité").sqKicker()
                    Text("Publications")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            } footer: {
                Text("Qui peut voir tes nouvelles publications par défaut.")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            Section("Interactions") {
                Toggle("Autoriser les mentions", isOn: $model.allowMentions)
                Toggle("Autoriser qu’on m’ajoute / me suive", isOn: $model.allowFollow)
                Toggle("Autoriser les messages privés", isOn: $model.allowDMs)
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)

            Section {
                Toggle("Afficher mes données réseau sur mes posts", isOn: $model.showRadioOnPosts)
            } footer: {
                Text("Quand c’est activé, tes publications peuvent afficher l’opérateur et la technologie réseau associés à la mesure.")
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)

            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(SQColor.danger) }
                    .listRowBackground(SQColor.danger.opacity(0.10))
            }
            if model.savedConfirmation {
                Section {
                    Label("Préférences enregistrées", systemImage: "checkmark.circle")
                        .foregroundStyle(SQColor.success)
                }
                .listRowBackground(SQColor.success.opacity(0.10))
            }

            Section {
                GradientButton("Enregistrer", systemImage: "checkmark.circle.fill", isBusy: model.isSaving) {
                    Task { await model.save() }
                }
                .disabled(!model.loaded)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Confidentialité")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !model.loaded { await model.load() } }
        .overlay {
            if model.isLoading && !model.loaded {
                ProgressView().tint(SQColor.brandRed)
            }
        }
    }
}
