import SwiftUI
import AuthenticationServices

/// Enveloppe `Identifiable` autour de l'URL de l'archive exportée, pour piloter une
/// `.sheet(item:)` (l'URL seule n'est pas `Identifiable`).
struct ExportedDataFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var prefs: NotificationPreferences = NotificationPreferences(
        notifyPhotoCommentsEmail: nil, notifyPhotoCommentsPush: nil, notifyPhotoCommentsInApp: nil,
        notifyPhotoLikesEmail: nil, notifyPhotoLikesPush: nil, notifyPhotoLikesInApp: nil,
        notifyPhotoMentionsEmail: nil, notifyPhotoMentionsPush: nil, notifyPhotoMentionsInApp: nil,
        notifyPhotoRepliesEmail: nil, notifyPhotoRepliesPush: nil, notifyPhotoRepliesInApp: nil,
        notifyMessagesEmail: nil, notifyMessagesPush: nil, notifyMessagesInApp: nil,
        notifyAnfrUpdatesPush: nil, notifyAnfrUpdatesEmail: nil,
        callsDoNotDisturb: nil
    )
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var isExporting = false
    @Published var deletionPreview: AccountDeletionPreview?
    @Published var isDeletionPreviewLoading = false
    @Published var deletionError: String?
    /// Renseigné quand l'archive RGPD est prête → déclenche la feuille de partage.
    @Published var exportedFile: ExportedDataFile?

    private let userService: UserServicing
    private let authService: AuthServicing
    init(userService: UserServicing, authService: AuthServicing) {
        self.userService = userService
        self.authService = authService
    }

    func exportData() async {
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let data = try await userService.exportPersonalData()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("signalquest-mes-donnees.json")
            try data.write(to: url, options: .atomic)
            exportedFile = ExportedDataFile(url: url)
            Haptics.success()
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func load() async {
        do { prefs = try await userService.notificationPreferences() } catch { errorMessage = error.localizedDescription }
    }

    func save() async {
        isBusy = true
        defer { isBusy = false }
        do { prefs = try await userService.updateNotificationPreferences(prefs) } catch { errorMessage = error.localizedDescription }
    }

    func disable2FA(code: String) async {
        do { try await authService.disable2FA(code: code) } catch { errorMessage = error.localizedDescription }
    }

    func loadAccountDeletionPreview() async {
        isDeletionPreviewLoading = true
        deletionError = nil
        defer { isDeletionPreviewLoading = false }
        do {
            deletionPreview = try await userService.accountDeletionPreview()
        } catch {
            if error.isCancellation { return }
            deletionError = error.localizedDescription
        }
    }

    func requestAccountDeletionEmailCode() async -> AccountDeletionEmailChallenge? {
        deletionError = nil
        do {
            return try await userService.requestAccountDeletionEmailCode()
        } catch {
            if !error.isCancellation { deletionError = error.localizedDescription }
            return nil
        }
    }

    func deleteAccount(using proof: AccountDeletionProof) async -> Bool {
        deletionError = nil
        do {
            _ = try await userService.deleteAccount(using: proof)
            return true
        } catch {
            if !error.isCancellation { deletionError = error.localizedDescription }
            return false
        }
    }
}

struct SettingsView: View {
    @StateObject private var model: SettingsViewModel
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var services: AppServices
    @State private var show2FASetup = false
    @State private var show2FADisable = false
    @State private var disable2FACode = ""
    @State private var showDeleteConfirm = false
    @AppStorage(MapBackdrop.storageKey) private var mapBackdropRaw = MapBackdrop.applePlan.rawValue
    @AppStorage(AppLockSettings.enabledKey) private var appLockEnabled = false
    @AppStorage(AppLockSettings.lockGraceKey) private var lockGraceSeconds = 0.0
    @AppStorage(AppLockSettings.autoLogoutKey) private var autoLogoutSeconds = 0.0
    @AppStorage(E2EEBiometric.enabledKey) private var e2eeBiometricEnabled = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var appleError: String?
    @State private var showUnlinkAppleConfirm = false

    private var appleLinked: Bool {
        if case .authenticated(let user) = session.state { return user.appleLinked == true }
        return false
    }

    /// État 2FA de l'utilisateur courant (SETTINGS-SEC-01).
    private var twoFactorEnabled: Bool {
        if case .authenticated(let user) = session.state { return user.twoFactorEnabled == true }
        return false
    }

    init(userService: UserServicing, authService: AuthServicing) {
        _model = StateObject(wrappedValue: SettingsViewModel(userService: userService, authService: authService))
    }

    var body: some View {
        Form {
            Section {
                if twoFactorEnabled {
                    Button(role: .destructive) {
                        show2FADisable = true
                    } label: {
                        settingsLabel("Désactiver la 2FA", systemImage: "lock.open")
                    }
                } else {
                    Button {
                        show2FASetup = true
                    } label: {
                        settingsLabel("Activer la 2FA", systemImage: "lock.shield")
                    }
                }
                NavigationLink {
                    ChangePasswordView()
                } label: { settingsLabel("Changer le mot de passe", systemImage: "key.fill") }
            } header: {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Préférences").sqKicker()
                    Text("Sécurité")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .listRowBackground(SQColor.surface)
            if BiometricAuth.isAvailable {
                Section {
                    Toggle(isOn: Binding(
                        get: { appLockEnabled },
                        set: { newValue in
                            guard newValue else { appLockEnabled = false; return }
                            // Confirme par biométrie avant d'activer (évite de se
                            // verrouiller dehors si Face ID ne marche pas).
                            Task {
                                let ok = await BiometricAuth.authenticate(
                                    reason: "Confirme \(BiometricAuth.kind.label) pour activer le verrouillage"
                                )
                                appLockEnabled = ok
                            }
                        }
                    )) {
                        settingsLabel("Verrouiller avec \(BiometricAuth.kind.label)", systemImage: BiometricAuth.kind.systemImage)
                    }
                    if appLockEnabled {
                        Picker(selection: $lockGraceSeconds) {
                            Text("Immédiat").tag(0.0)
                            Text("Après 1 min").tag(60.0)
                            Text("Après 5 min").tag(300.0)
                            Text("Après 15 min").tag(900.0)
                        } label: { settingsLabel("Verrouillage", systemImage: "clock") }
                        Picker(selection: $autoLogoutSeconds) {
                            Text("Jamais").tag(0.0)
                            Text("Après 15 min").tag(900.0)
                            Text("Après 1 h").tag(3600.0)
                            Text("Après 8 h").tag(28800.0)
                        } label: { settingsLabel("Déconnexion auto", systemImage: "rectangle.portrait.and.arrow.right") }
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
                            settingsLabel("Messagerie chiffrée via \(BiometricAuth.kind.label)", systemImage: "lock.shield")
                        }
                    }
                } header: {
                    Text("Verrouillage")
                } footer: {
                    Text("Exige \(BiometricAuth.kind.label) à l’ouverture après le délai d’inactivité choisi. La déconnexion automatique efface la session après une inactivité prolongée.")
                        .font(SQType.caption)
                }
                .tint(SQColor.brandRed)
                .foregroundStyle(SQColor.label)
                .listRowBackground(SQColor.surface)
            }
            Section {
                if appleLinked {
                    HStack(spacing: SQSpace.md) {
                        settingsLabel("Compte Apple associé", systemImage: "applelogo")
                        Spacer()
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(SQColor.success)
                    }
                    Button(role: .destructive) {
                        showUnlinkAppleConfirm = true
                    } label: { settingsLabel("Dissocier le compte Apple", systemImage: "minus.circle") }
                } else {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in handleAppleLink(result) }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                }
                if let appleError {
                    Text(appleError).font(.caption).foregroundStyle(SQColor.danger)
                }
            } header: {
                Text("Compte Apple")
            } footer: {
                Text(appleLinked
                     ? "Tu peux te connecter avec Apple, même en masquant ton e-mail."
                     : "Associe ton Apple ID pour te connecter en un geste, même avec « Masquer mon e-mail ».")
                    .font(SQType.caption)
            }
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)
            Section("Notifications") {
                Toggle("Messages (push)", isOn: bind(\.notifyMessagesPush))
                Toggle("Messages (in-app)", isOn: bind(\.notifyMessagesInApp))
                Toggle("Mises à jour ANFR (push)", isOn: bind(\.notifyAnfrUpdatesPush))
                Toggle("Likes & commentaires (push)", isOn: bind(\.notifyPhotoLikesPush))
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)
            Section("Appels") {
                Toggle("Ne pas déranger", isOn: bind(\.callsDoNotDisturb))
            }
            .tint(SQColor.brandRed)
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)
            Section {
                ForEach(MapBackdrop.allCases) { option in
                    Button {
                        mapBackdropRaw = option.rawValue
                        Haptics.selection()
                    } label: {
                        HStack(spacing: SQSpace.md) {
                            Image(systemName: option.systemImage)
                                .foregroundStyle(SQColor.brandRed)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).foregroundStyle(SQColor.label)
                                Text(option.subtitle)
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                            Spacer()
                            if mapBackdropRaw == option.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.bold))
                                    .foregroundStyle(SQColor.brandRed)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Fond de carte")
            } footer: {
                Text("OpenStreetMap, Relief et Satellite utilisent des serveurs de tuiles tiers : la zone de carte consultée leur est transmise.")
                    .font(SQType.caption)
            }
            .sqAnimation(SQMotion.snappy, value: mapBackdropRaw)
            .listRowBackground(SQColor.surface)
            Section {
                GradientButton("Enregistrer", systemImage: "checkmark.circle.fill", isBusy: model.isBusy) {
                    Task { await model.save() }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Section("Informations légales") {
                Link(destination: AppConfig.current.termsURL) {
                    settingsLabel("Conditions d’utilisation", systemImage: "doc.text")
                }
                Link(destination: AppConfig.current.privacyURL) {
                    settingsLabel("Politique de confidentialité", systemImage: "hand.raised")
                }
                Link(destination: AppConfig.current.legalURL) {
                    settingsLabel("Mentions légales", systemImage: "building.columns")
                }
                if let contact = AppConfig.current.contactMailtoURL {
                    Link(destination: contact) {
                        settingsLabel("Contact & signalement", systemImage: "envelope")
                    }
                }
                Button {
                    Task { await model.exportData() }
                } label: {
                    HStack {
                        settingsLabel("Télécharger mes données (RGPD)", systemImage: "square.and.arrow.down")
                        if model.isExporting {
                            Spacer()
                            ProgressView().tint(SQColor.brandRed)
                        }
                    }
                }
                .disabled(model.isExporting)
            }
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)
            Section {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Supprimer mon compte", systemImage: "trash")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.danger)
                        .frame(maxWidth: .infinity)
                }
            }
            .listRowBackground(SQColor.danger.opacity(0.10))
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(SQColor.danger) }
                    .listRowBackground(SQColor.danger.opacity(0.10))
            }
        }
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Réglages")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .sheet(isPresented: $show2FASetup) {
            NavigationStack { TwoFactorSetupView(service: services.auth) }
        }
        .alert("Désactiver la 2FA ?", isPresented: $show2FADisable) {
            TextField("Code à 6 chiffres", text: $disable2FACode)
                .keyboardType(.numberPad)
            Button("Annuler", role: .cancel) { disable2FACode = "" }
            Button("Désactiver", role: .destructive) {
                let code = disable2FACode
                disable2FACode = ""
                Task {
                    await model.disable2FA(code: code)
                    await session.refreshUser()
                }
            }
        } message: {
            Text("Saisis un code de ton application d'authentification pour confirmer la désactivation.")
        }
        .alert("Dissocier le compte Apple ?", isPresented: $showUnlinkAppleConfirm) {
            Button("Annuler", role: .cancel) {}
            Button("Dissocier", role: .destructive) { unlinkApple() }
        } message: {
            Text("Tu ne pourras plus te connecter via Apple. Si ton compte a été créé avec Apple, définis d'abord un mot de passe via « Mot de passe oublié » pour ne pas perdre l'accès.")
        }
        .sheet(item: $model.exportedFile) { file in
            ShareSheet(items: [file.url])
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteAccountSheet(model: model) {
                await services.push.unregister()
                await session.logout()
            }
        }
    }

    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(SQColor.label)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(SQColor.brandRed)
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
                appleError = "Jeton Apple manquant. Réessaie."
                return
            }
            Task {
                appleError = nil
                do {
                    try await services.auth.linkApple(identityToken: token)
                    await session.refreshUser()
                    Haptics.success()
                } catch {
                    appleError = error.localizedDescription
                    Haptics.error()
                }
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appleError = "Association Apple impossible. Réessaie."
        }
    }

    private func unlinkApple() {
        Task {
            appleError = nil
            do {
                try await services.auth.unlinkApple()
                await session.refreshUser()
                Haptics.success()
            } catch {
                appleError = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func bind(_ keyPath: WritableKeyPath<NotificationPreferences, Bool?>) -> Binding<Bool> {
        Binding(
            get: { model.prefs[keyPath: keyPath] ?? false },
            set: { newValue in
                var copy = model.prefs
                copy[keyPath: keyPath] = newValue
                model.prefs = copy
            }
        )
    }
}

struct ChangePasswordView: View {
    @EnvironmentObject private var services: AppServices
    @State private var current = ""
    @State private var newValue = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var isBusy = false
    @State private var success = false

    var body: some View {
        Form {
            Section("Mot de passe actuel") {
                SecureField("Mot de passe", text: $current)
                    .foregroundStyle(SQColor.label)
            }
            .listRowBackground(SQColor.surface)
            Section("Nouveau mot de passe") {
                SecureField("Au moins 8 caractères", text: $newValue)
                    .foregroundStyle(SQColor.label)
                SecureField("Confirmer", text: $confirm)
                    .foregroundStyle(SQColor.label)
            }
            .listRowBackground(SQColor.surface)
            if let error {
                Section { Text(error).foregroundStyle(SQColor.danger) }
                    .listRowBackground(SQColor.danger.opacity(0.10))
            }
            if success {
                Section { Label("Mot de passe modifié", systemImage: "checkmark.circle").foregroundStyle(SQColor.success) }
                    .listRowBackground(SQColor.success.opacity(0.10))
            }
            Section {
                GradientButton("Mettre à jour", systemImage: "key.fill", isBusy: isBusy) {
                    Task { await save() }
                }
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.5)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Mot de passe")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canSubmit: Bool {
        newValue.count >= 8 && newValue == confirm && !current.isEmpty && !isBusy
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await services.auth.changePassword(currentPassword: current, newPassword: newValue)
            success = true
        } catch {
            self.error = error.localizedDescription
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
            case .password: "Mot de passe"
            case .apple: "Apple"
            case .email: "Code e-mail"
            }
        }
    }

    @ObservedObject var model: SettingsViewModel
    let onDeleted: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var password = ""
    @State private var emailCode = ""
    @State private var emailChallenge: AccountDeletionEmailChallenge?
    @State private var selectedMethod: ReauthMethod?
    @State private var hasAcknowledged = false
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(SQColor.danger)
                    Text("Supprimer ton compte")
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)

                    if model.isDeletionPreviewLoading && model.deletionPreview == nil {
                        HStack(spacing: SQSpace.sm) {
                            ProgressView().tint(SQColor.brandRed)
                            Text("Vérification des données concernées…")
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let preview = model.deletionPreview {
                        deletionInventory(preview)
                        reauthentication(preview)
                    } else {
                        Text("Impossible de charger le détail de la suppression. Aucun compte ne sera supprimé tant que cette vérification échoue.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.labelSecondary)
                        Button("Réessayer") {
                            Task { await loadPreview() }
                        }
                        .buttonStyle(.bordered)
                        .tint(SQColor.brandRed)
                    }

                    if let error = model.deletionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                    }
                }
                .padding(SQSpace.xl)
            }
            .signalQuestBackground()
            .navigationTitle("Suppression")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }.tint(SQColor.brandRed)
                }
            }
        }
        .task { await loadPreview() }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isBusy)
    }

    @ViewBuilder
    private func deletionInventory(_ preview: AccountDeletionPreview) -> some View {
        Text(preview.warning)
            .font(SQType.body)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)

        inventoryGroup(
            title: "Sera supprimé",
            systemImage: "trash",
            color: SQColor.danger,
            values: preview.willBeDeleted
        )
        inventoryGroup(
            title: "Sera anonymisé et conservé",
            systemImage: "person.crop.circle.badge.questionmark",
            color: SQColor.warning,
            values: preview.willBeAnonymized
        )

        Toggle(isOn: $hasAcknowledged) {
            Text("J’ai compris que cette action est irréversible et que mes contributions listées ci-dessus resteront anonymisées.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.label)
        }
        .tint(SQColor.brandRed)
    }

    private func inventoryGroup(
        title: String,
        systemImage: String,
        color: Color,
        values: [String: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Label(title, systemImage: systemImage)
                .font(SQType.heading)
                .foregroundStyle(color)
            ForEach(values.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                Text("• \(item.value)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func reauthentication(_ preview: AccountDeletionPreview) -> some View {
        let methods = availableMethods(preview)
        if !methods.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Confirmer ton identité")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)

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
                .foregroundStyle(SQColor.danger)
        }
    }

    private var passwordConfirmation: some View {
        VStack(spacing: SQSpace.md) {
            SecureField("Mot de passe", text: $password)
                .textContentType(.password)
                .textFieldStyle(SQTextFieldStyle())
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
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
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
            TextField("Code à 6 chiffres", text: $emailCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(SQTextFieldStyle())
                .onChange(of: emailCode) { value in
                    emailCode = String(value.filter(\.isNumber).prefix(6))
                }
            destructiveButton(disabled: emailCode.count != 6) {
                await delete(using: .email(challengeId: challenge.challengeId, code: emailCode))
            }
        } else {
            Text("Un code à usage unique sera envoyé à \(preview.maskedEmail).")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Button {
                Task { await requestEmailCode() }
            } label: {
                Label("Envoyer le code", systemImage: "envelope.badge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(SQColor.brandRed)
            .disabled(!hasAcknowledged || isBusy)
        }
    }

    private func destructiveButton(
        disabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        GradientButton("Supprimer définitivement", systemImage: "trash", isBusy: isBusy) {
            Task { await action() }
        }
        .disabled(disabled || !hasAcknowledged || isBusy)
        .opacity(disabled || !hasAcknowledged ? 0.5 : 1)
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
        emailChallenge = await model.requestAccountDeletionEmailCode()
    }

    private func delete(using proof: AccountDeletionProof) async {
        isBusy = true
        let succeeded = await model.deleteAccount(using: proof)
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
                model.deletionError = "Jeton Apple manquant. Réessaie."
                return
            }
            Task { await delete(using: .apple(identityToken: identityToken)) }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            model.deletionError = "Réauthentification Apple impossible. Réessaie."
        }
    }
}
