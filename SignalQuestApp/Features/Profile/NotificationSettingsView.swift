import SwiftUI
import UIKit
import UserNotifications

/// Préférences de notifications du compte, enregistrées au geste (TRX-03).
/// Chaque interrupteur envoie un PATCH qui ne contient que lui, dans l'ordre
/// des gestes ; un échec ne ramène que ce réglage et le dit.
@MainActor
final class NotificationSettingsModel: ObservableObject {
    @Published var prefs: NotificationPreferences = .empty
    /// Préférences lues au moins une fois. Avant, les interrupteurs restent
    /// grisés : un réglage inconnu s'affichait « non ».
    @Published private(set) var prefsLoaded = false
    @Published var errorMessage: String?

    private let userService: UserServicing
    private var writes: Task<Void, Never>?

    init(userService: UserServicing) {
        self.userService = userService
    }

    func load() async {
        // Démo : un état réaliste plutôt que « Session expirée » et des
        // interrupteurs grisés dans les captures.
        if AppEnvironment.usesDemoData {
            prefs = .demo
            prefsLoaded = true
            return
        }
        do {
            prefs = try await userService.notificationPreferences()
            prefsLoaded = true
        } catch {
            if error.isCancellation { return }
            errorMessage = error.userFacingMessage
        }
    }

    func setPreference(_ keyPath: WritableKeyPath<NotificationPreferences, Bool?>, to value: Bool) {
        let previous = prefs[keyPath: keyPath]
        prefs[keyPath: keyPath] = value
        errorMessage = nil
        guard !AppEnvironment.usesDemoData else { return }
        var patch = NotificationPreferences.empty
        patch[keyPath: keyPath] = value
        let prior = writes
        writes = Task { [weak self, userService] in
            await prior?.value
            do {
                let saved = try await userService.updateNotificationPreferences(patch)
                guard let self else { return }
                // La réponse peut omettre un champ (le PATCH serveur oubliait
                // `notifySocialPush`) : la valeur envoyée fait alors foi.
                if let confirmed = saved[keyPath: keyPath], self.prefs[keyPath: keyPath] == value {
                    self.prefs[keyPath: keyPath] = confirmed
                }
            } catch {
                guard let self, !error.isCancellation else { return }
                // Un geste plus récent sur ce réglage garde la main.
                if self.prefs[keyPath: keyPath] == value { self.prefs[keyPath: keyPath] = previous }
                self.errorMessage = error.userFacingMessage
                Haptics.error()
            }
        }
    }

    /// Attend la fin des écritures en cours (tests).
    func waitForPendingWrites() async {
        await writes?.value
    }
}

private extension NotificationPreferences {
    /// Préférences de démonstration (captures, tours d'interface).
    static var demo: NotificationPreferences {
        var prefs = NotificationPreferences.empty
        prefs.notifyMessagesPush = true
        prefs.notifyMessagesInApp = true
        prefs.notifySocialPush = true
        prefs.notifyPhotoLikesPush = false
        prefs.notifyCommunityOutagesPush = true
        prefs.notifyAnfrUpdatesPush = false
        prefs.notifyAntennaReportsEmail = true
        prefs.callsDoNotDisturb = false
        return prefs
    }
}

/// Écran « Notifications » : l'autorisation iOS d'abord, puis ce que l'app
/// peut envoyer, groupé par usage. Ouvert depuis Réglages et par le lien
/// « Réglages de notifications » d'iOS, qui renvoyait vers iOS (TRX-21).
struct NotificationSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: NotificationSettingsModel
    /// Autorisation iOS réelle : refusée, aucun interrupteur ne sert (UXP-02).
    @State private var authorization: UNAuthorizationStatus?
    @State private var e2eeNotificationPrivacy: E2EEV2NotificationPrivacy = .full

    init(userService: UserServicing) {
        _model = StateObject(wrappedValue: NotificationSettingsModel(userService: userService))
    }

    var body: some View {
        Form {
            authorizationSection
            Section {
                preferenceToggle("Messages privés", \.notifyMessagesPush)
                Picker(selection: Binding(
                    get: { e2eeNotificationPrivacy },
                    set: { value in
                        if E2EEV2NotificationPrivacyStore.set(value) {
                            e2eeNotificationPrivacy = value
                            Haptics.selection()
                        } else {
                            model.errorMessage = String(localized: "Impossible de modifier les aperçus. Réessaie ou désactive les notifications dans les Réglages iOS.")
                        }
                    }
                )) {
                    Text("Contenu complet").tag(E2EEV2NotificationPrivacy.full)
                    Text("Expéditeur seulement").tag(E2EEV2NotificationPrivacy.senderOnly)
                    Text("Tout masquer").tag(E2EEV2NotificationPrivacy.hidden)
                } label: {
                    Text("Aperçu des messages chiffrés")
                }
                .pickerStyle(.menu)
                .frame(minHeight: 48)
                .tint(SQColor.accentInk)
                E2EEV2NotificationPreviewNotice(showReminder: true) { e2eeNotificationPrivacy = $0 }
                preferenceToggle("Bannière quand l’app est ouverte", \.notifyMessagesInApp)
                preferenceToggle("Appels : ne pas déranger", \.callsDoNotDisturb)
            } header: {
                Text("Messages et appels")
                    .accessibilityIdentifier("notifications.header.messages")
            } footer: {
                Text("Chaque réglage s’enregistre dès que tu le changes.")
                    .accessibilityIdentifier("notifications.footer.autosave")
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)

            Section {
                // Le fil PUBLIC, séparé des messages privés : un seul interrupteur
                // « Messages » coupait aussi commentaires, réponses et mentions.
                preferenceToggle("Commentaires et réponses", \.notifySocialPush)
                preferenceToggle("J’aime et commentaires sur mes photos", \.notifyPhotoLikesPush)
            } header: {
                Text("Communauté")
                    .accessibilityIdentifier("notifications.header.community")
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)

            Section {
                preferenceToggle("Pannes signalées par la communauté", \.notifyCommunityOutagesPush)
                // Plan 3, vague 2 : ce qui déclenche l'alerte près de ses lieux.
                if model.prefs.notifyCommunityOutagesPush == true {
                    NavigationLink {
                        ZoneAlertSettingsView(service: ZoneAlertService(api: services.api))
                    } label: {
                        Label("Pannes près de mes lieux", systemImage: "mappin.and.ellipse")
                    }
                    .accessibilityIdentifier("notifications.zoneAlerts")
                }
                HStack {
                    preferenceToggle("Mises à jour ANFR", \.notifyAnfrUpdatesPush)
                    SQInfoButton(term: .anfr)
                }
                preferenceToggle("Réponses à mes signalements, par e-mail", \.notifyAntennaReportsEmail)
                NavigationLink {
                    FavoriteAntennasView(favorites: services.favoriteAntennas)
                } label: {
                    HStack {
                        Label("Antennes suivies", systemImage: "star.fill")
                        Spacer()
                        Text("\(services.favoriteAntennas.favorites.count)")
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            } header: {
                Text("Antennes et réseau")
                    .accessibilityIdentifier("notifications.header.antennas")
            } footer: {
                Text("Pour une antenne suivie, l’alerte arrive dès le premier signalement, sans attendre que la communauté confirme.")
                    .accessibilityIdentifier("notifications.footer.antennas")
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("notifications.error")
                }
                .listRowBackground(SQColor.dangerSoft)
            }
        }
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: PushOwnerScope.current) {
            await model.load()
            e2eeNotificationPrivacy = E2EEV2NotificationPrivacyStore.get()
        }
        .task { await refreshAuthorization() }
        // Retour des Réglages iOS : l'autorisation a pu changer.
        .onChangeCompat(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshAuthorization() }
        }
    }

    @ViewBuilder
    private var authorizationSection: some View {
        switch authorization {
        case .notDetermined?:
            Section {
                Text("SignalQuest ne peut pas encore t’envoyer de notifications. Active-les pour être prévenu des messages, des réponses et des pannes.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                GradientButton("Activer les notifications", systemImage: "bell.fill") {
                    Task {
                        await services.push.requestAuthorizationAndRegister()
                        await refreshAuthorization()
                    }
                }
                .accessibilityIdentifier("notifications.enable")
            }
            .listRowBackground(SQColor.surface)
        case .denied?:
            Section {
                Label("Les notifications sont désactivées pour SignalQuest. Aucune alerte n’arrivera tant qu’elles ne sont pas réactivées dans les Réglages iOS.", systemImage: "bell.slash.fill")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ouvrir les réglages de notification") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(SQType.caption.weight(.semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(minHeight: 44)
            }
            .listRowBackground(SQColor.surface)
        default:
            EmptyView()
        }
    }

    private func preferenceToggle(
        _ title: LocalizedStringKey,
        _ keyPath: WritableKeyPath<NotificationPreferences, Bool?>
    ) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.prefs[keyPath: keyPath] ?? false },
            set: { model.setPreference(keyPath, to: $0) }
        ))
        .disabled(!model.prefsLoaded)
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
