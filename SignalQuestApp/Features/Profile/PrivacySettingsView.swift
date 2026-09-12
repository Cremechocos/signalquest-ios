import SwiftUI

/// Écran « Confidentialité » : permet à l'utilisateur d'exercer son contrôle et
/// son droit d'opposition (RGPD art. 7.3 / 21) sur la visibilité de ses contenus
/// et les interactions le concernant.
struct PrivacySettingsView: View {
    @StateObject private var model: PrivacySettingsViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    /// Feuille de divulgation présentée quand l'utilisateur ACTIVE lui-même le
    /// partage de position (PRIV-LOC-CONSENT-01) : on explique ce que les amis
    /// verront avant que l'activation ne soit informée puis confirmée.
    @State private var showLiveShareDisclosure = false
    @State private var zoneEditor: PrivacyZoneEditorRoute?
    @EnvironmentObject private var unitsStore: SQUnitsStore

    init(service: PrivacyServicing) {
        _model = StateObject(wrappedValue: PrivacySettingsViewModel(service: service))
    }

    var body: some View {
        Form {
            if model.isLoadingPrivacy && !model.loaded {
                Section { ProgressView("Chargement des partages…") }.listRowBackground(SQColor.surface)
            }
            if let error = model.privacyError {
                Section("Partages") {
                    loadError(error, hasPrevious: model.loaded) { await model.loadPrivacy() }
                }
                .listRowBackground(SQColor.dangerSoft)
            }
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
            .disabled(!model.loaded || model.isLoadingPrivacy || model.isSaving || !model.isSessionCurrent)

            if let error = model.preferencesError {
                Section("Préférences du compte") {
                    loadError(error, hasPrevious: model.preferencesLoaded) { await model.loadPreferences() }
                }
                .listRowBackground(SQColor.dangerSoft)
            }
            if model.isLoadingPreferences && !model.preferencesLoaded {
                Section { ProgressView("Chargement des préférences…") }.listRowBackground(SQColor.surface)
            }

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
            .disabled(!model.preferencesLoaded || model.isLoadingPreferences || model.isSavingPreferences || !model.isSessionCurrent)

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
                Text("\(model.preferences.unitsSystem.hint). Le réglage s'applique partout dans l'app et suit ton compte sur le web et Android.")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)
            .disabled(!model.preferencesLoaded || model.isLoadingPreferences || model.isSavingPreferences || !model.isSessionCurrent)

            // ── Zones privées ────────────────────────────────────────────────
            //
            // DEUX natures, et il faut les séparer. Les zones DÉCLARÉES (domicile,
            // travail) sont celles qu'on a posées soi-même et qu'on vient régler
            // ici. Les zones AUTO-DÉTECTÉES sont les hypothèses du système
            // d'apprentissage : mesuré sur un compte réel, 72 sur 73 — les lister
            // à plat noyait la seule qui compte et repoussait les réglages
            // suivants hors de portée du défilement.
            Section {
                if model.isLoadingZones { ProgressView("Chargement des zones…") }
                if let error = model.zonesError {
                    loadError(error, hasPrevious: model.zonesLoaded) { await model.loadZones() }
                }
                if let error = model.zoneMutationError {
                    Text(error).font(SQType.caption).foregroundStyle(SQColor.dangerInk)
                }
                if model.zonesLoaded && model.declaredZones.isEmpty && model.detectedZones.isEmpty {
                    Text("Aucune zone privée enregistrée. Ajoute un lieu à protéger.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                } else if model.zonesLoaded {
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
                Button {
                    zoneEditor = PrivacyZoneEditorRoute(zone: nil)
                } label: {
                    Label("Créer une zone privée", systemImage: "plus.circle.fill")
                }
                .disabled(!model.zonesLoaded || model.isLoadingZones || model.zoneBusyId != nil || !model.isSessionCurrent)
            } header: {
                Text("Zones privées")
            } footer: {
                Text("Les nouveaux speedtests sont protégés lorsqu’une zone est active et que son masquage est activé. Touche un lieu pour modifier son nom, sa position ou son rayon.")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            Section {
                Label("Positions publiques exactes", systemImage: "location.fill")
            } header: {
                Text("Mesures publiques")
            } footer: {
                Text("Lorsqu’une mesure est publiée, sa position disponible est exacte. Les zones privées actives peuvent protéger tes nouveaux speedtests.")
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
            .disabled(!model.loaded || model.isLoadingPrivacy || model.isSaving || !model.isSessionCurrent)

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
            .disabled(!model.loaded || model.isLoadingPrivacy || model.isSaving || !model.isSessionCurrent)

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
                    let owner = services.api.credentials.snapshot().sessionID
                    Task {
                        // Ne propager au diffuseur QUE si l'enregistrement serveur a
                        // réussi (PRIV-SAVE-UNCOND-05).
                        guard await model.save(), model.isSessionCurrent,
                              services.api.credentials.snapshot().sessionID == owner else { return }
                        services.livePresence.applySharingSettings(
                            shareLocation: model.shareLiveLocationWithFriends,
                            shareRadio: model.shareRadioDataWithFriends,
                            expectedSessionID: owner
                        )
                    }
                }
                .disabled(!model.canSavePrivacy)
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
            await model.load()
        }
        .refreshable { await model.load() }
        .onChangeCompat(of: session.state) { _, _ in
            model.sessionDidChange()
            if !model.isSessionCurrent { zoneEditor = nil; showLiveShareDisclosure = false }
        }
        .onChangeCompat(of: model.liveShareMode) { _, newMode in
            guard model.isSessionCurrent else { return }
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
        .sheet(item: $zoneEditor) { route in
            PrivacyZoneEditorView(model: model, zone: route.zone, location: services.location)
        }
    }

    @ViewBuilder
    private func zoneRow(_ zone: PrivacyZone) -> some View {
        HStack(spacing: SQSpace.md) {
            Button { zoneEditor = PrivacyZoneEditorRoute(zone: zone) } label: {
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
                            .lineLimit(2)
                        Text([zone.typeLabel == zone.name ? "" : zone.typeLabel, zone.summary]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Modifier cette zone")
            if model.zoneBusyId == zone.id {
                ProgressView()
            } else {
                Toggle("", isOn: Binding(
                    get: { zone.isActive && zone.hideSpeedtestsOnMap },
                    set: { hidden in Task { await model.setZoneHidden(zone, hidden: hidden) } }
                ))
                .labelsHidden()
                .accessibilityLabel(Text("Protection de \(zone.name)"))
            }
        }
        .disabled(model.isLoadingZones || model.zoneBusyId != nil || !model.isSessionCurrent)
        .accessibilityElement(children: .contain)
    }

    private func loadError(_ error: String, hasPrevious: Bool, retry: @escaping @MainActor () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(error).font(SQType.caption).foregroundStyle(SQColor.dangerInk)
            if hasPrevious {
                Text("Dernier état connu conservé.").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
            }
            Button("Réessayer") { Task { await retry() } }
        }
    }
}

private struct PresencePreferenceControls: View {
    @ObservedObject var service: LivePresenceService
    @State private var isRetrying = false

    var body: some View {
        if service.presenceLoaded {
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
        } else {
            Text("Le statut de présence n’est pas encore chargé.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Button {
                guard !isRetrying else { return }
                isRetrying = true
                Task {
                    await service.refreshSharingSettings()
                    isRetrying = false
                }
            } label: {
                HStack {
                    Text("Réessayer")
                    if isRetrying { ProgressView() }
                }
            }
            .disabled(isRetrying)
        }
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
