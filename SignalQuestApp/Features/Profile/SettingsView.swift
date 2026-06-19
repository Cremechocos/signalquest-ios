import SwiftUI

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

    func deleteAccount(password: String) async -> Bool {
        do { try await userService.deleteAccount(password: password); return true }
        catch { errorMessage = error.localizedDescription; return false }
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
    @AppStorage(MapBackdrop.storageKey) private var mapBackdropRaw = MapBackdrop.carto.rawValue

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
        .sheet(item: $model.exportedFile) { file in
            ShareSheet(items: [file.url])
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteAccountSheet { password in
                let ok = await model.deleteAccount(password: password)
                if ok { await session.logout() }
                return ok
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

/// Suppression de compte (PROFILE-UX-12) : feuille dédiée avec avertissement clair
/// + champ mot de passe, au lieu d'un SecureField dans une alert.
private struct DeleteAccountSheet: View {
    /// Renvoie `true` si la suppression a réussi (la session se ferme alors d'elle-même).
    let onDelete: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isBusy = false
    @State private var error: String?

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
                    Text("Cette action est irréversible. Ton compte et tes données personnelles (e-mail, mot de passe, profil) seront supprimés. Tes contributions — speedtests, validations, photos — seront anonymisées et resteront sur la carte communautaire.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Mot de passe", text: $password)
                        .textContentType(.password)
                        .textFieldStyle(SQTextFieldStyle())
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                    }
                    GradientButton("Supprimer définitivement", systemImage: "trash", isBusy: isBusy) {
                        Task {
                            isBusy = true
                            error = nil
                            let ok = await onDelete(password)
                            isBusy = false
                            if !ok { error = "Suppression impossible. Vérifie ton mot de passe." }
                        }
                    }
                    .disabled(password.isEmpty || isBusy)
                    .opacity(password.isEmpty ? 0.5 : 1)
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
        .presentationDetents([.medium, .large])
    }
}

