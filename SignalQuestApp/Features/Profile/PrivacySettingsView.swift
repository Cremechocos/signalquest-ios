import SwiftUI

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    @Published var shareLiveLocationWithFriends = false
    @Published var shareRadioDataWithFriends = false
    @Published var shareSessionsWithFriends = false
    @Published var sharePhotosOnFriendMap = false
    @Published var shareExactMeasurements = false
    @Published var lastSeenVisibility: LastSeenVisibility = .none
    @Published var messageRequestPolicy: MessageRequestPolicy = .friendsOnly
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
            shareLiveLocationWithFriends: shareLiveLocationWithFriends,
            shareRadioDataWithFriends: shareRadioDataWithFriends,
            shareSessionsWithFriends: shareSessionsWithFriends,
            sharePhotosOnFriendMap: sharePhotosOnFriendMap,
            shareExactMeasurements: shareExactMeasurements,
            lastSeenVisibility: lastSeenVisibility,
            messageRequestPolicy: messageRequestPolicy
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
        shareLiveLocationWithFriends = p.shareLiveLocationWithFriends
        shareRadioDataWithFriends = p.shareRadioDataWithFriends
        shareSessionsWithFriends = p.shareSessionsWithFriends
        sharePhotosOnFriendMap = p.sharePhotosOnFriendMap
        shareExactMeasurements = p.shareExactMeasurements
        UserDefaults.standard.set(
            p.shareExactMeasurements,
            forKey: MeasurementPrivacySettings.shareExactMeasurementsKey
        )
        lastSeenVisibility = p.lastSeenVisibility
        messageRequestPolicy = p.messageRequestPolicy
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

    var body: some View {
        Form {
            Section {
                Toggle("Partager ma position en direct", isOn: $model.shareLiveLocationWithFriends)
                Toggle("Partager mes données radio", isOn: $model.shareRadioDataWithFriends)
                Toggle("Partager mes sessions", isOn: $model.shareSessionsWithFriends)
                Toggle("Afficher mes photos sur la carte Amis", isOn: $model.sharePhotosOnFriendMap)
            } header: {
                Text("Carte des amis")
            } footer: {
                Text("Ces partages sont désactivés par défaut. Les désactiver retire aussi les données temps réel déjà publiées.")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            Section {
                Toggle("Partager la position exacte de mes mesures", isOn: $model.shareExactMeasurements)
            } header: {
                Text("Mesures publiques")
            } footer: {
                Text("Désactivé par défaut : les coordonnées visibles publiquement sont floutées. Si tu désactives ce réglage, le serveur floute aussi rétroactivement tes mesures déjà publiées.")
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)

            Section("Présence") {
                Picker("Afficher ma dernière activité", selection: $model.lastSeenVisibility) {
                    Text("À mes amis").tag(LastSeenVisibility.friends)
                    Text("À personne").tag(LastSeenVisibility.none)
                }
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)

            Section {
                Picker("Qui peut me contacter", selection: $model.messageRequestPolicy) {
                    Text("Tout le monde").tag(MessageRequestPolicy.everyone)
                    Text("Mes amis uniquement").tag(MessageRequestPolicy.friendsOnly)
                    Text("Personne").tag(MessageRequestPolicy.noOne)
                }
            } header: {
                Text("Messages privés")
            } footer: {
                Text("Ce réglage contrôle les nouvelles demandes de conversation. Les conversations existantes restent accessibles.")
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)

            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(SQColor.danger) }
                    .listRowBackground(SQColor.dangerSoft)
            }
            if model.savedConfirmation {
                Section {
                    Label("Préférences enregistrées", systemImage: "checkmark.circle")
                        .foregroundStyle(SQColor.success)
                }
                .listRowBackground(SQColor.successSoft)
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
