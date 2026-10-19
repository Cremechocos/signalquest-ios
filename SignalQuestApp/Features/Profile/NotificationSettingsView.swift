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
            errorMessage = nil
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
        prefs.notifySiteFollowsPush = true
        prefs.notifyAnfrUpdatesPush = false
        prefs.notifyAntennaReportsEmail = true
        prefs.callsDoNotDisturb = false
        return prefs
    }
}

/// « Antennes suivies » avec leur nombre : le service est observé, et le compteur reste
/// masqué tant que les favoris ne sont pas chargés (sinon il affichait « 0 »).
private struct FavoriteCountSettingsRow: View {
    @ObservedObject var favorites: FavoriteAntennasService

    var body: some View {
        SQSettingsRowLabel("Antennes suivies", systemImage: "star",
                           value: favorites.hasLoaded ? favorites.favorites.count.formatted() : nil)
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
            Section {
                SQSettingsHeader(title: "Notifications",
                                 subtitle: "Chaque réglage s’enregistre dès que tu le changes.",
                                 backIdentifier: "notifications.back")
            }
            .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.md, trailing: 0))
            .listRowBackground(Color.clear)

            // En tête : en bas de liste, l'erreur d'un interrupteur restait hors écran.
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityIdentifier("notifications.error")
                    // Préférences jamais chargées : interrupteurs grisés sans
                    // issue, il fallait quitter l'écran (AF-PROF-07).
                    if !model.prefsLoaded {
                        Button("Réessayer") { Task { await model.load() } }
                            .foregroundStyle(SQColor.accentInk)
                            .accessibilityIdentifier("notifications.retry")
                    }
                }
                .listRowBackground(SQColor.dangerSoft)
            }

            authorizationSection

            Section {
                preferenceToggle("Messages privés", systemImage: "bubble.left", \.notifyMessagesPush)
                SQSettingsMenuRow("Aperçu des messages", systemImage: "eye",
                                  subtitle: String(localized: "Conversations chiffrées"),
                                  selection: Binding(
                    get: { e2eeNotificationPrivacy },
                    set: { value in
                        if E2EEV2NotificationPrivacyStore.set(value) {
                            e2eeNotificationPrivacy = value
                            Haptics.selection()
                        } else {
                            model.errorMessage = String(localized: "Impossible de modifier les aperçus. Réessaie ou désactive les notifications dans les Réglages iOS.")
                        }
                    }
                ), valueLabel: previewLabel) {
                    Text("Contenu complet").tag(E2EEV2NotificationPrivacy.full)
                    Text("Expéditeur seulement").tag(E2EEV2NotificationPrivacy.senderOnly)
                    Text("Tout masquer").tag(E2EEV2NotificationPrivacy.hidden)
                }
                E2EEV2NotificationPreviewNotice(showReminder: true) { e2eeNotificationPrivacy = $0 }
                preferenceToggle("Bannière dans l’app", systemImage: "app.badge", \.notifyMessagesInApp,
                                 hint: "Une bannière s’affiche quand un message arrive pendant que l’app est ouverte.")
                preferenceToggle("Appels : ne pas déranger", systemImage: "phone", \.callsDoNotDisturb)
            } header: {
                Text("Messages et appels").sqKicker()
                    .accessibilityIdentifier("notifications.header.messages")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)
            .opacity(isDenied ? 0.45 : 1)

            Section {
                // Le fil PUBLIC, séparé des messages privés : un seul interrupteur
                // « Messages » coupait aussi commentaires, réponses et mentions.
                preferenceToggle("Commentaires et réponses", systemImage: "person.2", \.notifySocialPush)
                preferenceToggle("J’aime sur mes photos", systemImage: "photo", \.notifyPhotoLikesPush,
                                 subtitle: String(localized: "Commentaires compris"))
            } header: {
                Text("Communauté").sqKicker()
                    .accessibilityIdentifier("notifications.header.community")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)
            .opacity(isDenied ? 0.45 : 1)

            Section {
                preferenceToggle("Pannes de la communauté", systemImage: "exclamationmark.triangle",
                                 \.notifyCommunityOutagesPush)
                // Plan 3, vague 2 : ce qui déclenche l'alerte près de ses lieux.
                if model.prefs.notifyCommunityOutagesPush == true {
                    NavigationLink {
                        ZoneAlertSettingsView(service: ZoneAlertService(api: services.api))
                    } label: {
                        SQSettingsRowLabel("Pannes près de mes lieux", systemImage: "mappin.and.ellipse")
                    }
                    .accessibilityIdentifier("notifications.zoneAlerts")
                }
                NavigationLink {
                    FavoriteAntennasView(favorites: services.favoriteAntennas)
                } label: {
                    FavoriteCountSettingsRow(favorites: services.favoriteAntennas)
                }
                preferenceToggle("Activité des antennes suivies", systemImage: "star.bubble", \.notifySiteFollowsPush,
                                 subtitle: String(localized: "Messages, activations et nouvelles bandes"))
                HStack(spacing: SQSpace.sm) {
                    preferenceToggle("Mises à jour ANFR", systemImage: "antenna.radiowaves.left.and.right",
                                     \.notifyAnfrUpdatesPush)
                    SQInfoButton(term: .anfr)
                }
                preferenceToggle("Réponses à mes signalements", systemImage: "envelope", \.notifyAntennaReportsEmail,
                                 subtitle: String(localized: "Par e-mail"))
            } header: {
                Text("Antennes et réseau").sqKicker()
                    .accessibilityIdentifier("notifications.header.antennas")
            } footer: {
                Text("Pour une antenne suivie, l’alerte arrive dès le premier signalement, sans attendre que la communauté confirme.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityIdentifier("notifications.footer.antennas")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)
            .opacity(isDenied ? 0.45 : 1)
        }
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Notifications")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .refreshable { await model.load() }
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

    private var isDenied: Bool { authorization == .denied }

    private var previewLabel: String {
        switch e2eeNotificationPrivacy {
        case .full: String(localized: "Contenu complet")
        case .senderOnly: String(localized: "Expéditeur seulement")
        case .hidden: String(localized: "Tout masquer")
        }
    }

    @ViewBuilder
    private var authorizationSection: some View {
        switch authorization {
        case .notDetermined?:
            authorizationCard(
                title: "Notifications pas encore activées", systemImage: "bell",
                message: "SignalQuest ne peut pas encore t’envoyer de notifications. Active-les pour être prévenu des messages, des réponses et des pannes.",
                button: GradientButton("Activer les notifications", systemImage: "bell.fill") {
                    Task {
                        await services.push.requestAuthorizationAndRegister()
                        await refreshAuthorization()
                    }
                }
                .accessibilityIdentifier("notifications.enable")
            )
        case .denied?:
            authorizationCard(
                title: "Notifications coupées", systemImage: "bell.slash",
                message: "Aucune alerte n’arrive tant qu’elles sont désactivées dans les réglages de l’iPhone : messages, pannes, réponses.",
                button: GradientButton("Ouvrir les réglages de l’iPhone") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .accessibilityIdentifier("notifications.openSettings")
            )
        default:
            EmptyView()
        }
    }

    /// Carte d'état en tête d'écran : sans autorisation iOS, aucun interrupteur
    /// plus bas ne fait arriver d'alerte (UXP-02).
    private func authorizationCard(title: LocalizedStringKey, systemImage: String, message: LocalizedStringKey,
                                   button: some View) -> some View {
        Section {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack(spacing: SQSpace.sm2) {
                    ProfileMenuIcon(systemImage: systemImage, tint: SQColor.accentInk, fill: SQColor.surface)
                    Text(title)
                        .font(SQFont.body(16, .bold, relativeTo: .body))
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .sqHeader()
                }
                // Encre pleine : le gris secondaire manque de contraste sur le fond teinté.
                Text(message)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                button
            }
            .padding(.vertical, SQSpace.xs)
        }
        .listRowBackground(SQColor.accentSoft)
    }

    private func preferenceToggle(
        _ title: String,
        systemImage: String,
        _ keyPath: WritableKeyPath<NotificationPreferences, Bool?>,
        subtitle: String? = nil,
        hint: LocalizedStringKey? = nil
    ) -> some View {
        Toggle(isOn: Binding(
            get: { model.prefs[keyPath: keyPath] ?? false },
            set: { model.setPreference(keyPath, to: $0) }
        )) {
            SQSettingsRowLabel(title, systemImage: systemImage, subtitle: subtitle)
        }
        .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
        .disabled(!model.prefsLoaded)
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
