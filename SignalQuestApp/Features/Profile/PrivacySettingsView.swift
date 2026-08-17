import SwiftUI

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    @Published var shareLiveLocationWithFriends = false
    @Published var shareRadioDataWithFriends = false
    @Published var shareSessionsWithFriends = false
    @Published var sharePhotosOnFriendMap = false
    @Published var shareExactMeasurements = false
    /// Réglage LOCAL (pas backend) : quand publier ma position en direct.
    @Published var liveShareMode: LiveShareMode = LiveShareModeStore.load()
    @Published var lastSeenVisibility: LastSeenVisibility = .none
    @Published var messageRequestPolicy: MessageRequestPolicy = .friendsOnly
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var loaded = false
    @Published var errorMessage: String?
    @Published var savedConfirmation = false

    // Préférences de compte et zones privées. Côté serveur elles vivent hors de
    // `/social/privacy`, mais pour l'utilisateur c'est le même sujet — et elles
    // n'étaient exposées nulle part dans l'app.
    @Published var preferences = UserPreferences()
    @Published var zones: [PrivacyZone] = []
    @Published var zoneBusyId: String?

    /// Zones posées par l'utilisateur : celles qu'il vient régler ici.
    var declaredZones: [PrivacyZone] { zones.filter { !$0.isAutoDetected } }
    /// Hypothèses du système d'apprentissage. Repliées : mesuré sur un compte
    /// réel, 72 sur 73 — à plat, elles noyaient la seule zone déclarée.
    var detectedZones: [PrivacyZone] { zones.filter(\.isAutoDetected) }
    var hiddenDetectedCount: Int { detectedZones.filter(\.hideSpeedtestsOnMap).count }

    private let service: PrivacyServicing
    init(service: PrivacyServicing) { self.service = service }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        // Les trois lectures sont indépendantes : en série, l'écran attendrait
        // trois allers-retours avant d'afficher quoi que ce soit.
        async let privacy = service.get()
        async let prefs = try? service.preferences()
        async let zoneList = try? service.zones()
        do {
            apply(try await privacy)
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        if let loadedPrefs = await prefs {
            preferences = loadedPrefs
            unitsStore?.apply(loadedPrefs.unitsSystem)
        }
        zones = await zoneList ?? []
    }

    /// Injecté par la vue : le miroir observable de l'unité, pour que le reste de
    /// l'app suive immédiatement un changement fait ici.
    weak var unitsStore: SQUnitsStore?

    func setUnits(_ system: SQUnitsSystem) async {
        let previous = preferences.unitsSystem
        preferences.unitsSystem = system
        unitsStore?.apply(system)
        do {
            preferences = try await service.updatePreferences(preferences)
            unitsStore?.apply(preferences.unitsSystem)
            Haptics.success()
        } catch {
            // Retour à l'état précédent : afficher des miles que le serveur n'a
            // pas enregistrés ferait mentir l'écran au prochain lancement.
            preferences.unitsSystem = previous
            unitsStore?.apply(previous)
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func setShowHandleOnLeaderboard(_ value: Bool) async {
        let previous = preferences.showHandleOnLeaderboard
        preferences.showHandleOnLeaderboard = value
        do {
            preferences = try await service.updatePreferences(preferences)
            Haptics.success()
        } catch {
            preferences.showHandleOnLeaderboard = previous
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func setZoneHidden(_ zone: PrivacyZone, hidden: Bool) async {
        zoneBusyId = zone.id
        defer { zoneBusyId = nil }
        do {
            try await service.updateZone(id: zone.id, hideSpeedtestsOnMap: hidden, isActive: nil)
            if let index = zones.firstIndex(where: { $0.id == zone.id }) {
                zones[index].hideSpeedtestsOnMap = hidden
            }
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Renvoie `true` si l'enregistrement serveur a réussi. Le caller ne doit
    /// démarrer la diffusion locale que dans ce cas (sinon on diffuse une position
    /// dont l'activation n'a pas été persistée — PRIV-SAVE-UNCOND-05).
    @discardableResult
    func save() async -> Bool {
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
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            return false
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
    @EnvironmentObject private var services: AppServices
    /// Feuille de divulgation présentée quand l'utilisateur ACTIVE lui-même le
    /// partage de position (PRIV-LOC-CONSENT-01) : on explique ce que les amis
    /// verront avant que l'activation ne soit informée puis confirmée.
    @State private var showLiveShareDisclosure = false
    @EnvironmentObject private var unitsStore: SQUnitsStore

    init(service: PrivacyServicing) {
        _model = StateObject(wrappedValue: PrivacySettingsViewModel(service: service))
    }

    var body: some View {
        Form {
            Section {
                // Binding manuel : le setter n'est appelé que sur une action
                // utilisateur, jamais par `apply()` (qui écrit la @Published
                // directement au chargement) — on n'ouvre donc la divulgation que
                // sur une activation VOLONTAIRE (PRIV-LOC-CONSENT-01).
                Toggle("Partager ma position en direct", isOn: Binding(
                    get: { model.shareLiveLocationWithFriends },
                    set: { isOn in
                        model.shareLiveLocationWithFriends = isOn
                        if isOn { showLiveShareDisclosure = true }
                    }
                ))
                Toggle("Partager mes données radio", isOn: $model.shareRadioDataWithFriends)
                Toggle("Partager mes sessions", isOn: $model.shareSessionsWithFriends)
                Toggle("Afficher mes photos sur la carte Amis", isOn: $model.sharePhotosOnFriendMap)
                if model.shareLiveLocationWithFriends {
                    Picker("Quand partager ma position", selection: $model.liveShareMode) {
                        ForEach(LiveShareMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }
            } header: {
                Text("Carte des amis")
            } footer: {
                Text(model.shareLiveLocationWithFriends
                     ? model.liveShareMode.detail
                     : "Ces partages sont désactivés par défaut. Les désactiver retire aussi les données temps réel déjà publiées.")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            // ── Classements ──────────────────────────────────────────────────
            Section {
                Toggle(
                    "Afficher mon identifiant plutôt que mon nom",
                    isOn: Binding(
                        get: { model.preferences.showHandleOnLeaderboard },
                        set: { value in Task { await model.setShowHandleOnLeaderboard(value) } }
                    )
                )
            } header: {
                Text("Classements")
            } footer: {
                Text("Les classements sont publics. Ce réglage y remplace ton nom par ton @, sans te retirer du classement.")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            // ── Unités ───────────────────────────────────────────────────────
            Section {
                Picker(
                    "Distances",
                    selection: Binding(
                        get: { model.preferences.unitsSystem },
                        set: { value in Task { await model.setUnits(value) } }
                    )
                ) {
                    ForEach(SQUnitsSystem.allCases, id: \.self) { system in
                        Text(system.label).tag(system)
                    }
                }
            } header: {
                Text("Unités")
            } footer: {
                Text(model.preferences.unitsSystem.hint + ". Le réglage s'applique partout dans l'app et suit ton compte sur le web et Android.")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            // ── Zones privées ────────────────────────────────────────────────
            //
            // DEUX natures, et il faut les séparer. Les zones DÉCLARÉES (domicile,
            // travail) sont celles qu'on a posées soi-même et qu'on vient régler
            // ici. Les zones AUTO-DÉTECTÉES sont les hypothèses du système
            // d'apprentissage : mesuré sur un compte réel, 72 sur 73 — les lister
            // à plat noyait la seule qui compte et repoussait les réglages
            // suivants hors de portée du défilement.
            Section {
                if model.declaredZones.isEmpty && model.detectedZones.isEmpty {
                    Text("Aucune zone privée. Tu peux en créer depuis le site ou l'application Android.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                } else {
                    ForEach(model.declaredZones) { zone in
                        zoneRow(zone)
                    }
                    if !model.detectedZones.isEmpty {
                        DisclosureGroup {
                            ForEach(model.detectedZones) { zone in
                                zoneRow(zone)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(model.detectedZones.count) lieux détectés automatiquement")
                                    .font(SQFont.body(15, .medium))
                                    .foregroundStyle(SQColor.label)
                                Text(model.hiddenDetectedCount == 0
                                     ? "Aucun n'est masqué"
                                     : "\(model.hiddenDetectedCount) masqué(s) sur la carte")
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Zones privées")
            } footer: {
                Text("Activé, tes speedtests réalisés dans cette zone n'apparaissent pas sur la carte publique. Utile autour de chez toi ou de ton lieu de travail.")
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
                PresencePreferenceControls(service: services.livePresence)
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
                Section { Text(error).foregroundStyle(SQColor.dangerInk) }
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
                    Task {
                        // Ne propager au diffuseur QUE si l'enregistrement serveur a
                        // réussi (PRIV-SAVE-UNCOND-05).
                        guard await model.save() else { return }
                        services.livePresence.applySharingSettings(
                            shareLocation: model.shareLiveLocationWithFriends,
                            shareRadio: model.shareRadioDataWithFriends
                        )
                    }
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
                .task {
            // Le modèle propage l'unité au reste de l'app via ce miroir.
            model.unitsStore = unitsStore
            if !model.loaded { await model.load() }
        }
        .onChangeCompat(of: model.liveShareMode) { _, newMode in
            services.livePresence.setMode(newMode)
        }
        .sheet(isPresented: $showLiveShareDisclosure) {
            LiveLocationDisclosureSheet(
                // Annulation explicite : on revient à l'état désactivé pour que
                // rien ne soit partagé sans un consentement éclairé.
                onCancel: { model.shareLiveLocationWithFriends = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .overlay {
            if model.isLoading && !model.loaded {
                ProgressView().tint(SQColor.brandRed)
            }
        }
    }

    @ViewBuilder
    private func zoneRow(_ zone: PrivacyZone) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: zone.typeIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(zone.name)
                    .font(SQFont.body(15, .medium))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                // Le type n'est répété que s'il n'est pas déjà le nom : une zone
                // « Domicile » de type « Domicile » se lisait « Domicile ·
                // Domicile · 121 m ».
                Text([zone.typeLabel == zone.name ? "" : zone.typeLabel, zone.summary]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.zoneBusyId == zone.id {
                ProgressView()
            } else {
                Toggle("", isOn: Binding(
                    get: { zone.hideSpeedtestsOnMap },
                    set: { hidden in Task { await model.setZoneHidden(zone, hidden: hidden) } }
                ))
                .labelsHidden()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zone.name), masquer mes speedtests")
        .accessibilityValue(zone.hideSpeedtestsOnMap ? "activé" : "désactivé")
    }
}

private struct PresencePreferenceControls: View {
    @ObservedObject var service: LivePresenceService

    var body: some View {
        Picker(
            "Mon statut",
            selection: Binding(
                get: { service.status },
                set: { service.setPresence(status: $0, customStatus: service.customStatus) }
            )
        ) {
            ForEach(
                [SocialPresenceStatus.online, .away, .dnd, .invisible],
                id: \.self
            ) { status in
                Text(status.label).tag(status)
            }
        }
        TextField(
            "Statut personnalisé (facultatif)",
            text: Binding(
                get: { service.customStatus ?? "" },
                set: { service.setPresence(status: service.status, customStatus: $0) }
            )
        )
        .textInputAutocapitalization(.sentences)
    }
}

/// Divulgation de transparence présentée au moment où l'utilisateur active le
/// partage de position en direct. Décrit fidèlement ce que `LivePresenceService`
/// publie réellement (position + cap, cadence ~15-20 s accélérée quand un ami
/// regarde, expiration au TTL serveur ~3 min, réservé aux amis). Aucun claim
/// d'arrière-plan/app fermée — le partage suit le mode choisi juste en dessous.
private struct LiveLocationDisclosureSheet: View {
    var onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "location.fill.viewfinder")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(SQColor.brandRed)
                        Text("Partager ta position en direct")
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Voici ce que tes amis verront une fois ce partage activé.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        disclosureRow(
                            icon: "mappin.and.ellipse",
                            title: "Ta position et ton cap",
                            detail: "Tes amis voient ta position en direct et la direction dans laquelle tu te déplaces, sur la carte des amis."
                        )
                        disclosureRow(
                            icon: "clock.arrow.circlepath",
                            title: "Actualisée en temps réel",
                            detail: "Environ toutes les 15 à 20 s, et plus souvent quand un ami regarde ta position."
                        )
                        disclosureRow(
                            icon: "timer",
                            title: "Elle expire toute seule",
                            detail: "Ta position disparaît automatiquement après environ 3 min sans mise à jour, et dès que tu coupes le partage."
                        )
                        disclosureRow(
                            icon: "person.2.fill",
                            title: "Tes amis uniquement",
                            detail: "Seuls tes amis y ont accès. Le partage suit le mode que tu choisis juste en dessous."
                        )
                    }
                }
                .padding(24)
            }

            VStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Text("Activer le partage")
                        .font(SQType.button)
                        .foregroundStyle(SQColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            SQColor.brandRed,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Text("Annuler")
                        .font(SQType.button)
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .signalQuestBackground()
    }

    private func disclosureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 30, height: 30)
                .background(
                    SQColor.accentSoft,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.label)
                Text(detail)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}
