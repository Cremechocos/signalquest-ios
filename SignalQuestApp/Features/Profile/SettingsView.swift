import SwiftUI
import AuthenticationServices
import UserNotifications
import UIKit

/// Enveloppe `Identifiable` autour de l'URL de l'archive exportée, pour piloter une
/// `.sheet(item:)` (l'URL seule n'est pas `Identifiable`).
struct ExportedDataFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isExporting = false
    @Published var deletionPreview: AccountDeletionPreview?
    @Published var isDeletionPreviewLoading = false
    @Published var deletionError: String?
    /// Le serveur a signalé un abonnement payé que l'écran ne montrait pas encore
    /// (409 ACTIVE_PAID_SUBSCRIPTION) : la confirmation suivante l'acquitte.
    @Published var deletionSubscriptionConflict = false
    private(set) var deletedOwnerScopeId: String?
    /// Renseigné quand l'archive RGPD est prête → déclenche la feuille de partage.
    @Published var exportedFile: ExportedDataFile?

    private let userService: UserServicing
    private let authService: AuthServicing
    private let exportDirectory: URL
    private var exportSession: LocalAccountSession?
    private var exportURL: URL?

    init(userService: UserServicing, authService: AuthServicing,
         exportDirectory: URL = FileManager.default.temporaryDirectory) {
        self.userService = userService
        self.authService = authService
        self.exportDirectory = exportDirectory
    }

    func exportData() async {
        guard !isExporting, let expectedSession = LocalAccountScope.sessionSnapshot() else { return }
        clearExport()
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        var pendingURL: URL?
        do {
            let data = try await userService.exportPersonalData()
            guard !Task.isCancelled, expectedSession.isCurrent else { return }
            let url = exportDirectory
                .appendingPathComponent("signalquest-mes-donnees-\(UUID().uuidString).json")
            pendingURL = url
            // Un export volumineux ne doit pas figer le thread de l'interface.
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
            }.value
            guard !Task.isCancelled, expectedSession.isCurrent else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            exportSession = expectedSession
            exportURL = url
            exportedFile = ExportedDataFile(url: url)
            pendingURL = nil
            Haptics.success()
        } catch {
            if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
            if error.isCancellation || !expectedSession.isCurrent { return }
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }

    func clearExport() {
        exportedFile = nil
        exportSession = nil
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }

    func clearExportIfAccountChanged(_ state: AuthSessionViewModel.State) {
        guard let exportSession else { return }
        if case .authenticated(let user) = state,
           exportSession.ownerScopeId == "user:\(user.id)", exportSession.isCurrent { return }
        clearExport()
    }

    func loadAccountDeletionPreview() async {
        isDeletionPreviewLoading = true
        deletionError = nil
        defer { isDeletionPreviewLoading = false }
        do {
            deletionPreview = try await userService.accountDeletionPreview()
        } catch {
            if error.isCancellation { return }
            deletionError = error.userFacingMessage
        }
    }

    func requestAccountDeletionEmailCode() async -> AccountDeletionEmailChallenge? {
        deletionError = nil
        do {
            return try await userService.requestAccountDeletionEmailCode()
        } catch {
            if !error.isCancellation { deletionError = error.userFacingMessage }
            return nil
        }
    }

    func deleteAccount(using proof: AccountDeletionProof, acknowledgingActiveSubscriptions: Bool = false) async -> Bool {
        deletionError = nil
        guard let expectedSession = LocalAccountScope.sessionSnapshot() else { return false }
        do {
            let receipt = try await userService.deleteAccount(
                using: proof, expectedSession: expectedSession,
                acknowledgingActiveSubscriptions: acknowledgingActiveSubscriptions || deletionSubscriptionConflict
            )
            guard receipt.success else { throw APIError.transport("account-deletion-not-confirmed") }
            await authService.eraseDeletedAccountVault(ownerScopeId: expectedSession.ownerScopeId)
            deletedOwnerScopeId = expectedSession.ownerScopeId
            return true
        } catch {
            if case APIError.http(409, "ACTIVE_PAID_SUBSCRIPTION", _, _, _) = error {
                deletionSubscriptionConflict = true
            }
            if !error.isCancellation { deletionError = error.userFacingMessage }
            return false
        }
    }
}

/// Écrans ouverts depuis les Réglages, poussés par `pushed`.
private enum SettingsDestination: Hashable {
    case password, devices, privacy, notifications, glossary, bugs
}

struct SettingsView: View {
    @StateObject private var model: SettingsViewModel
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var services: AppServices
    /// Écran poussé depuis une ligne des Réglages.
    @State private var pushed: SettingsDestination?

    private func push(_ destination: SettingsDestination) {
        MainThreadHangProbe.mark("settings.push.\(destination)")
        pushed = destination
    }
    @State private var twoFactorEnrollment: TwoFactorEnrollmentService?
    @State private var twoFactorDisable: TwoFactorEnrollmentService?
    @State private var isDisabling2FA = false
    @State private var show2FADisable = false
    @State private var disable2FACode = ""
    @State private var showDeleteConfirm = false
    @AppStorage(MapBackdrop.storageKey) private var mapBackdropRaw = MapBackdrop.applePlan.rawValue
    @AppStorage(AppLockSettings.enabledKey) private var appLockEnabled = false
    @State private var canAuthenticateDeviceOwner = BiometricAuth.canAuthenticateDeviceOwner
    @StateObject private var appLockSetup = AppLockSetupController()
    @AppStorage(AppLockSettings.lockGraceKey) private var lockGraceSeconds = 0.0
    @AppStorage(SQOledPalette.storageKey) private var pureBlack = false
    @AppStorage(SQFieldMode.storageKey) private var fieldMode = false
    /// Désactivé par défaut : une alerte non sollicitée au volant est au mieux
    /// une nuisance, et personne ne doit la découvrir en sursautant.
    @AppStorage(CarPlayAlertSettings.coverageAlertsKey) private var carPlayCoverageAlerts = false
    @AppStorage(AppLockSettings.autoLogoutKey) private var autoLogoutSeconds = 0.0
    @AppStorage(E2EEBiometric.enabledKey) private var e2eeBiometricEnabled = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var appleError: String?
    @State private var showUnlinkAppleConfirm = false
    @State private var showAppleSheet = false

    private var appleLinked: Bool {
        if case .authenticated(let user) = session.state { return user.appleLinked == true }
        return false
    }

    /// État 2FA de l'utilisateur courant (SETTINGS-SEC-01).
    private var twoFactorEnabled: Bool {
        if case .authenticated(let user) = session.state { return user.twoFactorEnabled == true }
        return false
    }

    /// Vrai tant que le profil n'a pas dit si la 2FA est active. Proposer
    /// « Activer la 2FA » dans cet état trompait un compte qui l'a déjà (TRX-33).
    private var twoFactorStateUnknown: Bool {
        if case .authenticated(let user) = session.state { return user.twoFactorEnabled == nil }
        return false
    }

    init(userService: UserServicing, authService: AuthServicing) {
        _model = StateObject(wrappedValue: SettingsViewModel(userService: userService, authService: authService))
    }

    @ViewBuilder
    private func destination(for destination: SettingsDestination) -> some View {
        switch destination {
        case .password: ChangePasswordView(appleLinked: appleLinked)
        case .devices:
            // E2EE-AUTO §4 : les appareils viennent du journal vérifié ; l'écran
            // v2 (révocation et réinitialisation v2) n'est plus proposé
            // (E2EE-REVOKE-SYNC r1, 09/11).
            E2EEAutoDevicesView(api: services.api)
        case .privacy: PrivacySettingsView(service: services.privacy)
        case .notifications: NotificationSettingsView(userService: services.users)
        case .glossary: SQGlossaryView()
        case .bugs: BugReportsListView()
        }
    }

    var body: some View {
        let _ = SQRenderProbe.hit("settings")
        Form {
            Section {
                SQSettingsHeader(title: "Réglages", backIdentifier: "settings.back")
            }
            // Marge basse : la cellule, même transparente, garde ses coins
            // arrondis, qui rogneraient le bas du texte.
            .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.md, trailing: 0))
            .listRowBackground(Color.clear)

            Section {
                Button { push(SettingsDestination.password) } label: {
                    SQSettingsRowLabel("Mot de passe", systemImage: "key", showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.password")
                twoFactorRow
                Button {
                    appleError = nil
                    showAppleSheet = true
                } label: {
                    SQSettingsRowLabel("Compte Apple", systemImage: "applelogo",
                                       value: appleLinked ? String(localized: "Associé") : String(localized: "Non associé"),
                                       showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.apple")
                // Masqué tant que la v2 dort : l'écran créait une identité locale
                // pour un chiffrement qui ne peut encore ni envoyer ni lire (E2E-03).
                if E2EEV2RuntimeWriteGate.enabled {
                    Button { push(SettingsDestination.devices) } label: {
                        SQSettingsRowLabel("Appareils", systemImage: "lock.shield", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Compte").sqKicker()
                    .accessibilityIdentifier("settings.header.account")
            }
            .listRowBackground(SQColor.surface)

            Section {
                Toggle(isOn: Binding(
                    get: { appLockEnabled },
                    set: { newValue in
                        appLockSetup.setEnabled(newValue, credentials: services.api.credentials)
                    }
                )) {
                    SQSettingsRowLabel("Verrouiller SignalQuest", systemImage: "lock",
                                       subtitle: String(localized: "Demande \(BiometricAuth.kind.label) à l’ouverture"))
                }
                .accessibilityIdentifier("settings.app-lock")
                .accessibilityHint("Protège l’ouverture avec la biométrie ou le code de l’appareil après le délai choisi. Le contenu est masqué dans le sélecteur d’apps, même pendant ce délai.")
                .disabled(appLockSetup.isConfirming || (!canAuthenticateDeviceOwner && !appLockEnabled))
                if !canAuthenticateDeviceOwner && !appLockEnabled {
                    Text("Configure un code pour l’appareil dans les Réglages iOS afin d’activer le verrouillage.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let appLockError = appLockSetup.errorMessage {
                    Text(appLockError).font(SQType.caption).foregroundStyle(SQColor.dangerInk)
                }
                if appLockEnabled {
                    SQSettingsMenuRow("Verrouillage", systemImage: "clock", selection: $lockGraceSeconds,
                                      valueLabel: Self.lockGraceLabel(lockGraceSeconds)) {
                        Text("Immédiat").tag(0.0)
                        Text("Après 1 min").tag(60.0)
                        Text("Après 5 min").tag(300.0)
                        Text("Après 15 min").tag(900.0)
                    }
                    SQSettingsMenuRow("Déconnexion auto", systemImage: "rectangle.portrait.and.arrow.right",
                                      selection: $autoLogoutSeconds,
                                      valueLabel: Self.autoLogoutLabel(autoLogoutSeconds)) {
                        Text("Jamais").tag(0.0)
                        Text("Après 15 min").tag(900.0)
                        Text("Après 1 h").tag(3600.0)
                        Text("Après 8 h").tag(28800.0)
                    }
                    .accessibilityHint("La déconnexion automatique efface la session après une inactivité prolongée.")
                }
                // Désactivation de la mémorisation E2EE par biométrie (l'activation
                // se fait depuis la feuille de déverrouillage chiffré).
                if e2eeBiometricEnabled {
                    Toggle(isOn: Binding(
                        get: { e2eeBiometricEnabled },
                        set: { newValue in
                            e2eeBiometricEnabled = newValue
                            if !newValue { E2EEBiometric.clear() }
                        }
                    )) {
                        SQSettingsRowLabel("Messagerie chiffrée via \(BiometricAuth.kind.label)",
                                           systemImage: "lock.shield",
                                           localizedTitle: "Messagerie chiffrée via \(BiometricAuth.kind.label)")
                    }
                }
            } header: {
                Text("Sécurité").sqKicker()
                    .accessibilityIdentifier("settings.header.security")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            // Piège : un NavigationLink à fermeture traînante en tête de
            // `Section` fait résoudre vers TableRowContent ; le modificateur qui
            // le suit ancre la résolution côté vues.
            Section {
                Button { push(SettingsDestination.privacy) } label: {
                    SQSettingsRowLabel("Confidentialité", systemImage: "hand.raised", showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.privacy")
                // Notifications, appels et antennes suivies : un écran à part,
                // qui enregistre chaque réglage au geste (TRX-03) et que le lien
                // « Réglages de notifications » d'iOS ouvre directement (TRX-21).
                Button { push(SettingsDestination.notifications) } label: {
                    SQSettingsRowLabel("Notifications", systemImage: "bell", showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.notifications")
            }
            .listRowBackground(SQColor.surface)

            Section {
                Toggle(isOn: $fieldMode) {
                    SQSettingsRowLabel("Mode terrain", systemImage: "sun.max",
                                       subtitle: String(localized: "Contraste et textes renforcés dehors"))
                }
                .accessibilityHint("Renforce le contraste, la graisse des textes et la taille des contrôles pour une lecture plus fiable en extérieur.")
                .accessibilityIdentifier("settings.fieldMode")
                Toggle(isOn: $pureBlack) {
                    SQSettingsRowLabel("Noir intense", systemImage: "circle.lefthalf.filled",
                                       subtitle: String(localized: "Fonds noirs purs en thème sombre"))
                }
                .accessibilityHint("Sur un écran OLED, un pixel noir est éteint : l'affichage consomme moins. Sans effet en thème clair.")
                .accessibilityIdentifier("settings.oled")
                SQUnitsSettingRow(service: services.privacy)
                SQDefaultMarketRow(service: services.privacy, markets: services.markets)
                SQAddressFormRow()
                SQSettingsMenuRow("Fond de carte", systemImage: "map", selection: Binding(
                    get: { MapBackdrop.resolve(mapBackdropRaw) },
                    set: { option in
                        mapBackdropRaw = option.rawValue
                        Haptics.selection()
                    }
                ), valueLabel: MapBackdrop.resolve(mapBackdropRaw).label) {
                    ForEach(MapBackdrop.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .accessibilityIdentifier("settings.mapBackdrop")
            } header: {
                Text("Affichage").sqKicker()
                    .accessibilityIdentifier("settings.header.display")
            } footer: {
                Text("Le fond de carte choisi reçoit la zone consultée : Apple, OpenStreetMap ou OpenTopoMap.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            Section {
                Toggle(isOn: $carPlayCoverageAlerts) {
                    SQSettingsRowLabel("Alerte zone mal couverte", systemImage: "car",
                                       subtitle: String(localized: "Une alerte au plus toutes les 10 min"))
                }
                .accessibilityHint("Sur l'écran de la voiture, te signale quand tu traverses une zone où le réseau est mauvais. Jamais deux fois la même zone, et rien pendant une manœuvre annoncée.")
            } header: {
                Text("CarPlay").sqKicker()
                    .accessibilityIdentifier("settings.header.carplay")
            }
            .tint(SQColor.brandRed)
            .listRowBackground(SQColor.surface)

            Section {
                Button { push(SettingsDestination.glossary) } label: {
                    SQSettingsRowLabel("Aide et glossaire", systemImage: "questionmark.circle", showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.glossary")
                Button { push(SettingsDestination.bugs) } label: {
                    SQSettingsRowLabel("Bugs et idées", systemImage: "ladybug",
                                       subtitle: String(localized: "Signaler un problème, proposer une amélioration"),
                                       showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.bugs")
                if let contact = AppConfig.current.contactMailtoURL {
                    Link(destination: contact) {
                        SQSettingsRowLabel("Contact et signalement", systemImage: "envelope",
                                           subtitle: String(localized: "Modération et données personnelles, par e-mail"),
                                           showsChevron: true)
                    }
                }
                Button {
                    Task { await model.exportData() }
                } label: {
                    HStack {
                        SQSettingsRowLabel("Télécharger mes données", systemImage: "square.and.arrow.down",
                                           subtitle: String(localized: "Fichier JSON (RGPD)"))
                        if model.isExporting {
                            SQSpinner().tint(SQColor.brandRed)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isExporting)
                .accessibilityIdentifier("settings.export")
            } header: {
                Text("Aide").sqKicker()
                    .accessibilityIdentifier("settings.header.help")
            } footer: {
                Text(legalLinks)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.label)
                    .tint(SQColor.label)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, SQSpace.md)
                    .accessibilityIdentifier("settings.legal")
            }
            .listRowBackground(SQColor.surface)

            Section {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    SQSettingsRowLabel("Supprimer mon compte", systemImage: "trash", tone: .danger, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.deleteAccount")
            } footer: {
                Text(verbatim: SQSettingsHeader.versionLine)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, SQSpace.sm)
            }
            .listRowBackground(SQColor.surface)
        }
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Réglages")
        // Push par état, comme le Profil : sous iOS 16.7, les NavigationLink du
        // Profil gelaient l'app (voir ProfileView).
        .navigationDestinationItemCompat($pushed) { destination(for: $0) }
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        // L'échec d'une action (export, double authentification) s'affichait
        // tout en bas du formulaire, hors de vue (AF-PROF-06).
        .alert(
            "Action impossible",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("Fermer", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            canAuthenticateDeviceOwner = BiometricAuth.canAuthenticateDeviceOwner
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            appLockSetup.cancel()
        }
        .onChangeCompat(of: session.state) { _, _ in
            appLockSetup.cancelIfSessionChanged()
        }
        .onDisappear { appLockSetup.cancel() }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $twoFactorEnrollment) { enrollment in
            NavigationStack {
                TwoFactorSetupView(service: enrollment, acknowledge: {
                    try session.acknowledgeTwoFactorState(expectedUserID: enrollment.scope.userID,
                        isCurrent: enrollment.isCurrent)
                }, refreshProfile: {
                    try await session.refreshUser(expectedUserID: enrollment.scope.userID,
                        isCurrent: enrollment.isCurrent, fetchUser: {
                            let user = try await enrollment.profile()
                            guard user.twoFactorEnabled == true else { throw TwoFactorEnrollmentError.profileNotReady }
                            return user
                        })
                })
            }
        }
        .onChangeCompat(of: session.state) { _, _ in
            if let enrollment = twoFactorEnrollment, !enrollment.isCurrent() { twoFactorEnrollment = nil }
            if let operation = twoFactorDisable, !operation.isCurrent() {
                show2FADisable = false
                disable2FACode = ""
                twoFactorDisable = nil
            }
        }
        .alert("Désactiver la 2FA ?", isPresented: $show2FADisable) {
            TextField("Code à 6 chiffres", text: $disable2FACode)
                .keyboardType(.numberPad)
            Button("Annuler", role: .cancel) { disable2FACode = ""; twoFactorDisable = nil }
            Button("Désactiver", role: .destructive) {
                let code = disable2FACode
                disable2FACode = ""
                guard let operation = twoFactorDisable, !isDisabling2FA else { return }
                isDisabling2FA = true
                model.errorMessage = nil
                Task { @MainActor in
                    defer { isDisabling2FA = false; twoFactorDisable = nil }
                    do {
                        try await operation.disable(code: code)
                        try session.acknowledgeTwoFactorState(enabled: false,
                            expectedUserID: operation.scope.userID, isCurrent: operation.isCurrent)
                    } catch {
                        if operation.isCurrent() { model.errorMessage = error.userFacingMessage }
                    }
                }
            }
        } message: {
            Text("Saisis un code de ton application d'authentification pour confirmer la désactivation.")
        }
        .sheet(isPresented: $showAppleSheet) { appleSheet }
        .sheet(item: $model.exportedFile, onDismiss: { model.clearExport() }) { file in
            ShareSheet(items: [file.url])
        }
        .onChangeCompat(of: session.state) { _, state in
            model.clearExportIfAccountChanged(state)
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteAccountSheet(model: model) {
                guard let deletedOwner = model.deletedOwnerScopeId else { return }
                var cleanupWarning: String?
                // Le reçu serveur concerne ce propriétaire, même si un autre
                // compte a été ouvert entre-temps. Ne jamais effacer son voisin.
                do { try await services.favoriteAntennas.eraseLocalDataForDeletedAccount(ownerScopeID: deletedOwner) }
                catch {
                    cleanupWarning = String(localized: "Le compte est supprimé, mais le nettoyage des favoris locaux a échoué sur cet appareil.")
                    model.deletionError = cleanupWarning
                }
                guard deletedOwner == LocalAccountScope.currentOwnerScopeId else { return }
                await services.push.unregister()
                guard deletedOwner == LocalAccountScope.currentOwnerScopeId else { return }
                await session.logout()
                guard case .loggedOut = session.state else { return }
                if let cleanupWarning {
                    session.errorMessage = cleanupWarning
                } else {
                    // Même canal que « session expirée » / « compte suspendu ».
                    session.infoMessage = String(localized: "Ton compte a été supprimé.")
                }
            }
        }
    }

    /// Double authentification : une ligne avec son état. Activée, elle mène
    /// à la désactivation (code demandé) ; désactivée, à l'activation.
    @ViewBuilder
    private var twoFactorRow: some View {
        if twoFactorStateUnknown {
            HStack(spacing: SQSpace.sm) {
                SQSettingsRowLabel("Double authentification", systemImage: "checkmark.shield")
                SQSpinner()
                    .accessibilityLabel(Text("Vérification de la double authentification"))
            }
            .task { await session.refreshUser() }
        } else {
            Button {
                guard case .authenticated(let user) = session.state,
                      let operation = TwoFactorEnrollmentService(api: services.api, userID: user.id) else {
                    model.errorMessage = TwoFactorEnrollmentError.sessionChanged.localizedDescription
                    return
                }
                if twoFactorEnabled {
                    twoFactorDisable = operation
                    show2FADisable = true
                } else {
                    twoFactorEnrollment = operation
                }
            } label: {
                SQSettingsRowLabel("Double authentification", systemImage: "checkmark.shield",
                                   value: twoFactorEnabled ? String(localized: "Activée") : String(localized: "Désactivée"),
                                   showsChevron: true)
            }
            .buttonStyle(.plain)
            .disabled(isDisabling2FA)
            .accessibilityHint(twoFactorEnabled ? "Désactive la double authentification" : "Active la double authentification")
            .accessibilityIdentifier("settings.twoFactor")
        }
    }

    /// Conditions, confidentialité et mentions légales sur une ligne de liens.
    private var legalLinks: AttributedString {
        let links: [(String, URL)] = [
            (String(localized: "Conditions d’utilisation"), AppConfig.current.termsURL),
            (String(localized: "Confidentialité"), AppConfig.current.privacyURL),
            (String(localized: "Mentions légales"), AppConfig.current.legalURL),
        ]
        var text = AttributedString()
        for (index, link) in links.enumerated() {
            if index > 0 { text.append(AttributedString(" · ")) }
            var part = AttributedString(link.0)
            part.link = link.1
            part.underlineStyle = .single
            text.append(part)
        }
        return text
    }

    private static func lockGraceLabel(_ seconds: Double) -> String {
        switch seconds {
        case ..<1: String(localized: "Immédiat")
        case ..<61: String(localized: "Après 1 min")
        case ..<301: String(localized: "Après 5 min")
        default: String(localized: "Après 15 min")
        }
    }

    private static func autoLogoutLabel(_ seconds: Double) -> String {
        switch seconds {
        case ..<1: String(localized: "Jamais")
        case ..<901: String(localized: "Après 15 min")
        case ..<3601: String(localized: "Après 1 h")
        default: String(localized: "Après 8 h")
        }
    }

    /// Compte Apple : une feuille courte qui explique l'association et porte le
    /// bouton officiel, ou la dissociation quand le compte est déjà associé.
    private var appleSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text("Compte").sqKicker()
                        Text(appleLinked ? "Compte Apple associé" : "Associer ton compte Apple")
                            .font(SQFont.display(22, .bold, relativeTo: .title2))
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .sqHeader()
                    }
                    Spacer(minLength: SQSpace.sm)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "settings.apple.close") {
                        showAppleSheet = false
                    }
                }
                Text(appleLinked
                     ? "Tu peux te connecter avec Apple, même en masquant ton e-mail."
                     : "Tu pourras te connecter en un geste, même avec « Masquer mon e-mail ». Ton mot de passe actuel reste valable.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.apple.footer")
                if let appleError {
                    SQNotice(message: appleError, systemImage: "exclamationmark.triangle", tone: .danger)
                }
                if appleLinked {
                    GradientButton("Dissocier le compte Apple", systemImage: "minus.circle", style: .destructive) {
                        showUnlinkAppleConfirm = true
                    }
                    .accessibilityIdentifier("settings.apple.unlink")
                } else {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in handleAppleLink(result) }
                    .signInWithAppleButtonStyle(SQOledPalette.appleButtonStyle(colorScheme))
                    .frame(height: 50)
                    .clipShape(Capsule(style: .continuous))
                    .accessibilityIdentifier("settings.apple.link")
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.xl)
            .padding(.bottom, SQSpace.lg)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.medium, .large])
        .sqSheet(background: SQColor.surface)
        .alert("Dissocier le compte Apple ?", isPresented: $showUnlinkAppleConfirm) {
            Button("Annuler", role: .cancel) {}
            Button("Dissocier", role: .destructive) { unlinkApple() }
        } message: {
            Text("Tu ne pourras plus te connecter via Apple. Si ton compte a été créé avec Apple, définis d'abord un mot de passe via « Mot de passe oublié » pour ne pas perdre l'accès.")
        }
    }

    /// Associe l'Apple ID : extrait le jeton du flux ASAuthorization et appelle
    /// le backend, puis recharge l'utilisateur pour rafraîchir l'état « lié ».
    private func handleAppleLink(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                appleError = String(localized: "Jeton Apple manquant. Réessaie.")
                return
            }
            Task {
                appleError = nil
                do {
                    try await services.auth.linkApple(identityToken: token)
                    await session.refreshUser()
                    Haptics.success()
                    showAppleSheet = false
                } catch {
                    appleError = error.userFacingMessage
                    Haptics.error()
                }
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appleError = String(localized: "Association Apple impossible. Réessaie.")
        }
    }

    private func unlinkApple() {
        Task {
            appleError = nil
            do {
                try await services.auth.unlinkApple()
                await session.refreshUser()
                Haptics.success()
                showAppleSheet = false
            } catch {
                appleError = error.userFacingMessage
                Haptics.error()
            }
        }
    }
}

/// En-tête Halo des pages de réglages : retour rond, grand titre, une phrase.
/// La barre de navigation est masquée par la page, qui garde le balayage retour.
struct SQSettingsHeader: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let backIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: backIdentifier) { dismiss() }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(title)
                    .font(SQFont.display(30, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                if let subtitle {
                    Text(subtitle)
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « SignalQuest 1.0 (169) », comme dans les réglages d'iOS.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "SignalQuest \(version) (\(build))"
    }
}

/// Ligne qui pousse un écran par un Button : le chevron qu'un NavigationLink
/// dessinait, à droite de son libellé.
struct SQPushRowLabel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            content
            Spacer(minLength: 0)
            // Même chevron que celui des NavigationLink du système.
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// Libellé d'une ligne de réglage Halo : petite icône, titre, sous-titre court,
/// valeur à droite et chevron facultatifs. Sert de `label` aux Toggle, Picker
/// et NavigationLink natifs, qui ajoutent leur propre commande.
struct SQSettingsRowLabel: View {
    enum Tone { case neutral, danger }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let systemImage: String
    var localizedTitle: LocalizedStringKey?
    var subtitle: String?
    var value: String?
    var tone: Tone = .neutral
    /// Pour un Button ou un Link : le NavigationLink dessine déjà le sien.
    var showsChevron = false

    init(_ title: String, systemImage: String, localizedTitle: LocalizedStringKey? = nil, subtitle: String? = nil,
         value: String? = nil, tone: Tone = .neutral, showsChevron: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.localizedTitle = localizedTitle
        self.subtitle = subtitle
        self.value = value
        self.tone = tone
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: SQSpace.md) {
            if !dynamicTypeSize.isAccessibilitySize {
                ProfileMenuIcon(systemImage: systemImage,
                                tint: tone == .danger ? SQColor.dangerInk : SQColor.labelSecondary,
                                fill: tone == .danger ? SQColor.dangerSoft : SQColor.surfaceMuted)
            }
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(localizedTitle ?? LocalizedStringKey(title))
                    .font(SQFont.body(16, .semibold, relativeTo: .body))
                    .foregroundStyle(tone == .danger ? SQColor.dangerInk : SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    // Plafonné à AX3 : en AX5, un mot long dépasse la rangée et se coupe (DEV-01).
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .accessibilityIdentifier("settings.label.\(title)")
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // En très grand texte, la valeur passe sous le titre.
                if let value, dynamicTypeSize.isAccessibilitySize {
                    Text(verbatim: value)
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value, !dynamicTypeSize.isAccessibilitySize {
                Text(verbatim: value)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                    // La valeur reste entière ; c'est le titre qui passe à la ligne.
                    .layoutPriority(1)
            }
            if showsChevron {
                // Même chevron que celui des NavigationLink du système.
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Réglage à choix : la valeur reste à droite du libellé, sur une ligne, et
/// ouvre un menu natif. Un `Picker` en style menu renvoie sa valeur sous un
/// libellé un peu long.
struct SQSettingsMenuRow<Value: Hashable, Options: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    @Binding var selection: Value
    let valueLabel: String
    @ViewBuilder let options: Options

    init(_ title: String, systemImage: String, subtitle: String? = nil, selection: Binding<Value>,
         valueLabel: String, @ViewBuilder options: () -> Options) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        _selection = selection
        self.valueLabel = valueLabel
        self.options = options()
    }

    var body: some View {
        Menu {
            Picker(selection: $selection) { options } label: { Text(LocalizedStringKey(title)) }
                .pickerStyle(.inline)
        } label: {
            HStack(spacing: SQSpace.xs) {
                SQSettingsRowLabel(title, systemImage: systemImage, subtitle: subtitle, value: valueLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
        }
        .tint(SQColor.label)
    }
}

/// Unités de distance : un menu natif. Le choix suit le compte (web, Android),
/// d'où le passage par les préférences serveur, comme avant dans Confidentialité.
struct SQUnitsSettingRow: View {
    @StateObject private var model: PrivacySettingsViewModel
    @EnvironmentObject private var unitsStore: SQUnitsStore

    init(service: PrivacyServicing) {
        _model = StateObject(wrappedValue: PrivacySettingsViewModel(service: service))
    }

    var body: some View {
        // Les unités effectives : celles du compte, ou de la région sans choix.
        let current = unitsStore.system
        SQSettingsMenuRow("Unités", systemImage: "ruler", subtitle: model.preferencesError,
                          selection: Binding(
                              get: { current },
                              set: { value in Task { await model.setUnits(value) } }
                          ), valueLabel: current.label) {
            ForEach(SQUnitsSystem.allCases, id: \.self) { system in
                Text(system.label).tag(system)
            }
        }
        .disabled(!model.preferencesLoaded || model.isLoadingPreferences || model.isSavingPreferences || !model.isSessionCurrent)
        .accessibilityHint("\(unitsStore.system.hint). Le réglage s'applique partout dans l'app et suit ton compte sur le web et Android.")
        .accessibilityIdentifier("settings.units")
        .task {
            // Le modèle propage l'unité au reste de l'app via ce miroir.
            model.unitsStore = unitsStore
            if !model.preferencesLoaded { await model.loadPreferences() }
        }
    }
}

/// « Mon pays » (`defaultMarket` du compte) : le pays de la carte quand la
/// position n'est pas disponible, avant le dernier pays vu et la région de
/// l'iPhone. « Automatique » revient au pays déduit.
struct SQDefaultMarketRow: View {
    @StateObject private var model: PrivacySettingsViewModel
    @EnvironmentObject private var unitsStore: SQUnitsStore
    let markets: MarketRegistryServicing
    @State private var entries: [MarketRegistryEntry] = []

    init(service: PrivacyServicing, markets: MarketRegistryServicing) {
        _model = StateObject(wrappedValue: PrivacySettingsViewModel(service: service))
        self.markets = markets
    }

    private static func code(_ entry: MarketRegistryEntry) -> String {
        entry.marketCode.isEmpty ? entry.code : entry.marketCode
    }

    var body: some View {
        let current = model.preferences.defaultMarket ?? ""
        let selected = entries.first { Self.code($0).caseInsensitiveCompare(current) == .orderedSame }
        SQSettingsMenuRow("Mon pays", systemImage: "globe.europe.africa", subtitle: model.preferencesError,
                          selection: Binding(
                              get: { selected.map(Self.code) ?? "" },
                              set: { value in Task { await model.setDefaultMarket(value.isEmpty ? nil : value) } }
                          ), valueLabel: selected.map(MapMarketNaming.name) ?? String(localized: "Automatique")) {
            Text("Automatique").tag("")
            ForEach(entries) { entry in
                Text(MapMarketNaming.title(entry)).tag(Self.code(entry))
            }
        }
        .disabled(!model.preferencesLoaded || entries.isEmpty || model.isLoadingPreferences
                  || model.isSavingPreferences || !model.isSessionCurrent)
        .accessibilityHint("Pays de la carte quand ta position n'est pas disponible. Le réglage suit ton compte.")
        .accessibilityIdentifier("settings.defaultMarket")
        .task {
            model.unitsStore = unitsStore
            if entries.isEmpty { entries = await markets.registry().markets.filter(\.publicSelectable) }
            if !model.preferencesLoaded { await model.loadPreferences() }
        }
    }
}

/// Tutoiement ou vouvoiement : un menu natif, comme les unités. Le choix suit le
/// compte ; la ligne n'existe qu'en français et seulement si le serveur expose le
/// réglage (`addressFormChosen` présent), sinon elle promettrait un choix que rien
/// ne retiendrait.
struct SQAddressFormRow: View {
    @EnvironmentObject private var addressStore: SQAddressStore
    @EnvironmentObject private var services: AppServices

    var body: some View {
        if SQAddress.appIsFrench, addressStore.chosen != nil {
            SQSettingsMenuRow("Tutoiement / Vouvoiement", systemImage: "text.bubble", subtitle: addressStore.saveError,
                              selection: Binding(
                                  get: { addressStore.form },
                                  set: { form in Task { await addressStore.choose(form, using: services.privacy) } }
                              ), valueLabel: addressStore.form.label) {
                ForEach(SQAddressForm.allCases, id: \.self) { form in
                    Text(form.label).tag(form)
                }
            }
            .disabled(addressStore.isSaving)
            .accessibilityHint("Choisit comment l’app s’adresse à toi : « tu » ou « vous ». Le réglage suit ton compte.")
            .accessibilityIdentifier("settings.addressForm")
        }
    }
}

extension SQAddressForm {
    /// Nom du ton. Identique dans les deux tons : il désigne le choix, pas l'adresse.
    var label: String {
        switch self {
        case .informal: return String(localized: "Tutoiement")
        case .formal: return String(localized: "Vouvoiement")
        }
    }
}

/// La question du ton, posée au plus une fois par jour et par appareil au membre
/// dont le compte n'a encore rien choisi. Un calque plein écran comme l'activation
/// du chiffrement : une feuille pourrait masquer ou être masquée par l'écran
/// d'appel. « Plus tard » n'écrit rien ; seul un choix part au serveur.
struct SQAddressFormPrompt: View {
    @EnvironmentObject private var addressStore: SQAddressStore
    @EnvironmentObject private var services: AppServices
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Image(systemName: "text.bubble.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Text("Tu préfères qu’on te tutoie ou qu’on vous vouvoie ?")
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ton choix suit ton compte, sur tous tes appareils. Tu pourras le changer dans Réglages.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Les exemples montrent chacun leur ton : ils restent tels quels, quel
                // que soit le ton en cours.
                choice(.informal, example: "« Ton test est terminé : voici tes résultats. »")
                choice(.formal, example: "« Votre test est terminé : voici vos résultats. »")

                if let message = addressStore.saveError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GradientButton(String(localized: "Plus tard"), style: .ghost) { onClose() }
                    .disabled(addressStore.isSaving)
                    .accessibilityIdentifier("address-form-later")
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
    }

    private func choice(_ form: SQAddressForm, example: String) -> some View {
        Button {
            Task {
                if await addressStore.choose(form, using: services.privacy) { onClose() }
            }
        } label: {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(form.label)
                    .font(SQFont.body(17, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.label)
                Text(verbatim: example)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(SQSpace.lg)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(addressStore.isSaving)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(form.label))
        .accessibilityValue(Text(verbatim: example))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("address-form-\(form.rawValue)")
    }
}

struct ChangePasswordView: View {
    /// Un compte créé avec Apple n'a pas de mot de passe connu de son titulaire :
    /// l'écran dit comment en choisir un plutôt que d'exiger l'actuel (AF-PROF-05).
    var appleLinked = false
    @EnvironmentObject private var services: AppServices
    private enum Field { case current, new }
    @FocusState private var focus: Field?
    @State private var current = ""
    @State private var newValue = ""
    @State private var error: String?
    @State private var isBusy = false
    @State private var success = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Mot de passe",
                                 subtitle: "Choisis un nouveau mot de passe d’au moins 8 caractères.",
                                 backIdentifier: "settings.password.back")
                if appleLinked {
                    SQNotice(message: "Compte créé avec Apple ? Il n’a pas de mot de passe que tu connais. Pour en choisir un, déconnecte-toi puis touche « Mot de passe oublié ? » sur l’écran de connexion.",
                             systemImage: "applelogo", tone: .neutral)
                        .accessibilityIdentifier("settings.password.appleHint")
                }
                AuthFieldGroup {
                    AuthFieldRow("Mot de passe actuel", isFocused: focus == .current) {
                        AuthPasswordInput(label: "Mot de passe actuel", text: $current, contentType: .password,
                                          identifier: "settings.password.current")
                            .submitLabel(.next)
                            .focused($focus, equals: .current)
                            .onSubmit { focus = .new }
                    } onTap: { focus = .current }
                    AuthFieldDivider()
                    // `.newPassword` : le trousseau propose un mot de passe fort et
                    // l'enregistre, au lieu de traiter ce champ comme une connexion.
                    AuthFieldRow("Nouveau mot de passe", isFocused: focus == .new) {
                        AuthPasswordInput(label: "Nouveau mot de passe", text: $newValue, contentType: .newPassword,
                                          identifier: "settings.password.new")
                            .submitLabel(.done)
                            .focused($focus, equals: .new)
                            .onSubmit { if canSubmit { Task { await save() } } }
                    } onTap: { focus = .new }
                }
                Label {
                    Text("8 caractères minimum")
                } icon: {
                    Image(systemName: newValue.count >= 8 ? "checkmark" : "info.circle")
                }
                .font(SQType.caption(newValue.count >= 8 ? .semibold : .regular))
                .foregroundStyle(newValue.count >= 8 ? SQColor.success : SQColor.labelSecondary)
                .padding(.leading, SQSpace.xs)
                .padding(.top, -SQSpace.sm)
                if let error {
                    SQNotice(message: error, systemImage: "exclamationmark.triangle", tone: .danger)
                        .accessibilityIdentifier("settings.password.error")
                }
                if success {
                    SQNotice(message: "Mot de passe modifié", systemImage: "checkmark.circle", tone: .success)
                        .accessibilityIdentifier("settings.password.success")
                }
                GradientButton("Mettre à jour", isBusy: isBusy) {
                    Task { await save() }
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("settings.password.submit")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .signalQuestBackground()
        .navigationTitle("Mot de passe")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
    }

    private var canSubmit: Bool {
        newValue.count >= 8 && !current.isEmpty && !isBusy
    }

    private func save() async {
        isBusy = true
        // Un essai efface le verdict du précédent : erreur et succès ne
        // s'affichent plus ensemble (AF-PROF-05).
        error = nil
        success = false
        defer { isBusy = false }
        do {
            try await services.auth.changePassword(currentPassword: current, newPassword: newValue)
            success = true
            current = ""
            newValue = ""
            focus = nil
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Mot de passe modifié"))
        } catch {
            self.error = error.userFacingMessage
            UIAccessibility.post(notification: .announcement, argument: error.userFacingMessage)
        }
    }
}

/// Suppression de compte : le serveur fournit l'inventaire réel et les méthodes
/// de réauthentification disponibles. La suppression n'est déclenchée qu'après
/// consentement explicite et preuve mot de passe, Apple ou code e-mail.
private struct DeleteAccountSheet: View {
    private enum ReauthMethod: String, Identifiable {
        case password
        case apple
        case email

        var id: String { rawValue }
        var title: String {
            switch self {
            case .password: String(localized: "Mot de passe")
            case .apple: "Apple"
            case .email: String(localized: "Code e-mail")
            }
        }
    }

    @ObservedObject var model: SettingsViewModel
    let onDeleted: () async -> Void

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// Groupes chiffrés dont ce compte est le seul admin (D.4) : leur membre le
    /// plus ancien est nommé admin juste avant la suppression.
    @State private var soleAdminGroups: [MessageConversation] = []
    @State private var password = ""
    @State private var emailCode = ""
    @State private var emailChallenge: AccountDeletionEmailChallenge?
    @State private var selectedMethod: ReauthMethod?
    @State private var hasAcknowledged = false
    @State private var isBusy = false
    @FocusState private var passwordFocused: Bool
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    Spacer(minLength: 0)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "settings.delete.close") {
                        dismiss()
                    }
                    .disabled(isBusy)
                }
                Image(systemName: "trash")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(SQColor.dangerInk)
                    .frame(width: 48, height: 48)
                    .background(SQColor.dangerSoft, in: Circle())
                    .accessibilityHidden(true)
                    .padding(.top, -SQSpace.md)
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Supprimer ton compte")
                        .font(SQFont.display(30, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .sqHeader()
                    Text("C’est définitif. Voici ce qui se passe pour tes données.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.isDeletionPreviewLoading && model.deletionPreview == nil {
                    HStack(spacing: SQSpace.sm) {
                        SQSpinner().tint(SQColor.brandRed)
                        Text("Vérification des données concernées…")
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let preview = model.deletionPreview {
                    AccountDeletionSubscriptionNotice(store: services.entitlements)
                    deletionInventory(preview)
                    if !soleAdminGroups.isEmpty {
                        Label(
                            String(localized: "Tu es le seul admin de \(soleAdminGroups.count) groupe(s) chiffré(s) : leur membre le plus ancien sera nommé admin."),
                            systemImage: "person.badge.shield.checkmark"
                        )
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    reauthentication(preview)
                } else {
                    SQNotice(message: String(localized: "Impossible de charger le détail de la suppression. Aucun compte ne sera supprimé tant que cette vérification échoue."),
                             systemImage: "exclamationmark.triangle", tone: .danger)
                    GradientButton("Réessayer", systemImage: "arrow.clockwise", style: .secondary) {
                        Task { await loadPreview() }
                    }
                }

                if let error = model.deletionError {
                    SQNotice(message: error, systemImage: "exclamationmark.triangle", tone: .danger)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await loadPreview() }
        .task { await loadSoleAdminGroups() }
        // D4 : l'abonnement en cours se lit dès l'ouverture, le 409 n'est qu'un filet.
        .task { await services.entitlements.refreshBackendSnapshot() }
        .onChangeCompat(of: model.deletionSubscriptionConflict) { _, conflict in
            if conflict { Task { await services.entitlements.refreshBackendSnapshot() } }
        }
        .presentationDetents([.large])
        .sqSheet(background: SQColor.bg)
        .interactiveDismissDisabled(isBusy)
    }

    @ViewBuilder
    private func deletionInventory(_ preview: AccountDeletionPreview) -> some View {
        if !preview.warning.isEmpty {
            Text(preview.warning)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        inventoryGroup(
            title: "Sera supprimé",
            color: SQColor.dangerInk,
            values: preview.willBeDeleted
        )
        inventoryGroup(
            title: "Sera anonymisé et conservé",
            color: SQColor.labelSecondary,
            values: preview.willBeAnonymized
        )

        Button { hasAcknowledged.toggle() } label: {
            HStack(alignment: .top, spacing: SQSpace.sm2) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hasAcknowledged ? SQColor.brandRed : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(hasAcknowledged ? SQColor.brandRed : SQColor.labelSecondary, lineWidth: 1.5)
                    }
                    .overlay {
                        if hasAcknowledged {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(SQColor.onAccent)
                        }
                    }
                    .frame(width: 22, height: 22)
                Text("J’ai compris que cette action est irréversible et que mes contributions listées ci-dessus resteront anonymisées.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(hasAcknowledged ? Text("Cochée") : Text("Non cochée"))
        .accessibilityAddTraits(hasAcknowledged ? .isSelected : [])
        .accessibilityIdentifier("settings.delete.acknowledge")
    }

    private func inventoryGroup(
        title: LocalizedStringKey,
        color: Color,
        values: [String: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title)
                .font(SQType.callout(.bold))
                .foregroundStyle(color)
                .sqHeader()
            ForEach(values.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
                    Text(verbatim: item.value)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(SQSpace.md2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func reauthentication(_ preview: AccountDeletionPreview) -> some View {
        let methods = availableMethods(preview)
        if !methods.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Confirmer ton identité")
                    .sqKicker()
                    .sqHeader()

                if methods.count > 1 {
                    Picker("Méthode", selection: $selectedMethod) {
                        ForEach(methods) { method in
                            Text(method.title).tag(Optional(method))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch selectedMethod ?? methods.first {
                case .password:
                    passwordConfirmation
                case .apple:
                    appleConfirmation
                case .email:
                    emailConfirmation(preview)
                case nil:
                    EmptyView()
                }
            }
        } else {
            Label("Aucune méthode de réauthentification disponible.", systemImage: "lock.trianglebadge.exclamationmark")
                .font(SQType.body)
                .foregroundStyle(SQColor.dangerInk)
        }
    }

    private var passwordConfirmation: some View {
        VStack(spacing: SQSpace.md) {
            AuthFieldGroup {
                AuthFieldRow("Mot de passe", isFocused: passwordFocused) {
                    AuthPasswordInput(label: "Mot de passe", text: $password, contentType: .password,
                                      identifier: "settings.delete.password")
                        .focused($passwordFocused)
                } onTap: { passwordFocused = true }
            }
            destructiveButton(disabled: password.isEmpty) {
                await delete(using: .password(password))
            }
        }
    }

    private var appleConfirmation: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Apple te demandera de confirmer l’identité liée à ce compte.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                handleAppleReauthentication(result)
            }
            .signInWithAppleButtonStyle(SQOledPalette.appleButtonStyle(colorScheme))
            .frame(height: 50)
            .clipShape(Capsule(style: .continuous))
            .disabled(!hasAcknowledged || isBusy)
            .opacity(hasAcknowledged && !isBusy ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private func emailConfirmation(_ preview: AccountDeletionPreview) -> some View {
        if let challenge = emailChallenge {
            Text("Code envoyé à \(challenge.maskedEmail). Il expire dans 10 minutes et ne peut être utilisé qu’une fois.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            AuthFieldGroup {
                AuthFieldRow("Code à 6 chiffres", isFocused: codeFocused) {
                    TextField("Code à 6 chiffres", text: $emailCode, prompt: Text(verbatim: ""))
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .autocorrectionDisabled()
                        .focused($codeFocused)
                        .accessibilityIdentifier("settings.delete.code")
                        .onChangeCompat(of: emailCode) { _, value in
                            emailCode = String(value.filter(\.isNumber).prefix(6))
                        }
                } onTap: { codeFocused = true }
            }
            destructiveButton(disabled: emailCode.count != 6) {
                await delete(using: .email(challengeId: challenge.challengeId, code: emailCode))
            }
            // Code expiré (10 min) ou perdu : sans renvoi, il fallait fermer la feuille.
            Button(String(localized: "Renvoyer le code")) {
                Task { await requestEmailCode() }
            }
            .font(SQType.button)
            .foregroundStyle(SQColor.accentInk)
            .frame(minHeight: 44)
            .disabled(isBusy)
        } else {
            Text("Un code à usage unique sera envoyé à \(preview.maskedEmail).")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            GradientButton("Envoyer le code", systemImage: "envelope.badge", style: .accent) {
                Task { await requestEmailCode() }
            }
            .disabled(!hasAcknowledged || isBusy)
        }
    }

    private func destructiveButton(
        disabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        GradientButton("Supprimer définitivement", systemImage: "trash", isBusy: isBusy, style: .destructive) {
            Task { await action() }
        }
        .disabled(disabled || !hasAcknowledged || isBusy)
    }

    private func availableMethods(_ preview: AccountDeletionPreview) -> [ReauthMethod] {
        var result: [ReauthMethod] = []
        if preview.reauthMethods.password { result.append(.password) }
        if preview.reauthMethods.apple { result.append(.apple) }
        if preview.reauthMethods.email { result.append(.email) }
        return result
    }

    private func loadPreview() async {
        await model.loadAccountDeletionPreview()
        guard selectedMethod == nil, let preview = model.deletionPreview else { return }
        selectedMethod = availableMethods(preview).first
    }

    private func requestEmailCode() async {
        isBusy = true
        defer { isBusy = false }
        // Un renvoi qui échoue garde le code précédent (l'erreur s'affiche).
        guard let challenge = await model.requestAccountDeletionEmailCode() else { return }
        emailChallenge = challenge
        emailCode = ""
    }

    private func loadSoleAdminGroups() async {
        let v2 = services.e2eeV2Messaging
        guard v2.writesEnabled, let conversations = try? await services.messages.conversations() else { return }
        soleAdminGroups = conversations.filter { conversation in
            guard conversation.isGroup, case .mustName = v2.successorNeed(conversationId: conversation.id) else { return false }
            return true
        }
    }

    private func delete(using proof: AccountDeletionProof) async {
        isBusy = true
        // D.4 : le successeur d'abord, signé par cet appareil ; jamais bloquant.
        if !soleAdminGroups.isEmpty {
            _ = await services.e2eeV2Messaging.promoteSuccessorsBeforeDeletion(soleAdminGroups)
        }
        let warned = AccountDeletionSubscriptionNotice.running(in: services.entitlements.serverState.snapshot)
        let succeeded = await model.deleteAccount(using: proof, acknowledgingActiveSubscriptions: !warned.isEmpty)
        if succeeded {
            Haptics.success()
            await onDeleted()
            dismiss()
        } else {
            Haptics.error()
        }
        isBusy = false
    }

    private func handleAppleReauthentication(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                model.deletionError = String(localized: "Jeton Apple manquant. Réessaie.")
                return
            }
            Task { await delete(using: .apple(identityToken: identityToken)) }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            model.deletionError = String(localized: "Réauthentification Apple impossible. Réessaie.")
        }
    }
}
