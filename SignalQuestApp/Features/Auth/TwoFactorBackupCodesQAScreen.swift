import SwiftUI

/// Banc des codes de secours 2FA, sans réseau ni compte : `--qa-two-factor-backup-codes` (la
/// fenêtre des codes), `-regenerate` et `-disable` (la feuille de preuve), `-settings` (les états
/// de la rubrique), `-login` (la connexion, un code de secours refusé) et `-last` (règle B).
struct TwoFactorBackupCodesQAScreen: View {
    let variant: String
    #if DEBUG && targetEnvironment(simulator)
    @StateObject private var session = AuthSessionViewModel(service: TwoFactorBackupQAAuthService())

    var body: some View {
        switch variant {
        case "regenerate", "disable":
            NavigationStack {
                TwoFactorProofSheet(purpose: variant == "disable" ? .disable : .regenerate,
                                    operation: TwoFactorBackupQAOperations(), previousGeneratedAt: nil,
                                    onDisabled: {}, onCodesChanged: {})
            }
        case "settings":
            settings
        case "login", "last":
            Group {
                if case .authenticated = session.state {
                    Color.clear
                        .signalQuestBackground()
                        .modifier(LastBackupCodeNoticeModifier(isPresented: $session.lastBackupCodeNotice, openSecurity: {}))
                } else {
                    LoginView()
                }
            }
            .environmentObject(session)
            .task {
                await session.login(identifier: "qa", password: "qa")
                if variant == "last" { await session.verify2FA(proof: .backup(TwoFactorBackupQAAuthService.lastCode)) }
            }
        default:
            NavigationStack {
                ScrollView {
                    TwoFactorBackupCodesPanel(batch: TwoFactorBackupQAOperations.batch) {}
                        .frame(maxWidth: 560, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(SQSpace.xl)
                }
                .signalQuestBackground()
                .navigationTitle(String(localized: "Générer de nouveaux codes"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// Les états de la ligne des Réglages : non confirmés, aucun code, un code, plusieurs codes.
    private var settings: some View {
        let states: [(TwoFactorBackupCodeStatus?, Bool)] = [
            (TwoFactorBackupCodeStatus(remaining: 7, generatedAt: "2026-11-15T21:37:00.000Z"), true),
            (TwoFactorBackupCodeStatus(remaining: 0, generatedAt: "2026-11-15T21:37:00.000Z"), false),
            (TwoFactorBackupCodeStatus(remaining: 1, generatedAt: "2026-11-15T21:37:00.000Z"), false),
            (TwoFactorBackupCodeStatus(remaining: 7, generatedAt: "2026-11-15T21:37:00.000Z"), false),
        ]
        return NavigationStack {
            Form {
                ForEach(states.indices, id: \.self) { index in
                    Section {
                        SQSettingsRowLabel("Double authentification", systemImage: "checkmark.shield",
                                           value: String(localized: "Activée"), showsChevron: true)
                        SQSettingsRowLabel("Générer de nouveaux codes", systemImage: "key",
                                           subtitle: TwoFactorBackupCodes.stateText(status: states[index].0,
                                                                                    unconfirmed: states[index].1),
                                           showsChevron: true)
                    } header: {
                        Text("Compte").sqKicker()
                    }
                    .listRowBackground(SQColor.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
        }
    }
    #else
    var body: some View { EmptyView() }
    #endif
}

#if DEBUG && targetEnvironment(simulator)
/// Codes, désactivation et état factices.
private struct TwoFactorBackupQAOperations: TwoFactorSecondFactorOperations {
    static let batch = TwoFactorBackupCodeBatch(codes: [
        "7K2QM-9XW4D", "H3TNA-6RVJC", "PZ8E1-W5MKX", "4DQ9F-T2HBN", "XG7RS-3MCPA",
        "B6WJK-8NZ4E", "R1VYT-Q7HD5", "M9CXP-2KA6G", "FN3ZW-5TBQ8", "E4HJR-Y9SM2",
    ], generatedAt: "2026-11-15T21:37:00.000Z")

    let scope = TwoFactorEnrollmentScope(userID: "qa-two-factor",
        account: LocalAccountSession(ownerScopeId: "user:qa-two-factor", sessionId: "qa"), credentialSessionID: UUID())
    func isCurrent() -> Bool { true }
    func disable(proof: TwoFactorProof) async throws { try await Task.sleep(nanoseconds: 300_000_000) }
    func regenerateBackupCodes(proof: TwoFactorProof) async throws -> TwoFactorBackupCodeBatch? {
        try await Task.sleep(nanoseconds: 300_000_000)
        guard proof.backupCode == nil || proof.backupCode == TwoFactorBackupQAAuthService.lastCode else {
            throw TwoFactorEnrollmentError.invalidBackupCode
        }
        return Self.batch
    }
    func backupCodeStatus() async throws -> TwoFactorBackupCodeStatus {
        TwoFactorBackupCodeStatus(remaining: 10, generatedAt: Self.batch.generatedAt)
    }
}

/// Connexion factice : le mot de passe demande la 2FA ; seul `lastCode` passe, et c'était le dernier.
private final class TwoFactorBackupQAAuthService: AuthServicing, @unchecked Sendable {
    static let lastCode = "QA000-00000"
    private var user: AuthUser?

    func login(identifier: String, password: String) async throws -> LoginResponse {
        LoginResponse(user: nil, requires2FA: true, tempToken: "qa-temporary")
    }
    func verify2FA(tempToken: String, proof: TwoFactorProof) async throws -> LoginResponse {
        try await Task.sleep(nanoseconds: 300_000_000)
        guard proof.backupCode == Self.lastCode else {
            throw APIError.http(status: 400, code: proof.backupCode == nil ? "INVALID_2FA_CODE" : "INVALID_BACKUP_CODE",
                                message: "", requestId: nil, retryAfter: nil)
        }
        return LoginResponse(user: .mock, requires2FA: nil, tempToken: nil, backupCodesRemaining: 0)
    }
    func me() async throws -> AuthUser { .mock }
    func cacheUser(_ user: AuthUser) { self.user = user }
    func cachedUser() -> AuthUser? { user }
    func hasStoredCredentials() -> Bool { false }
    func credentialsAreUnreadable() -> Bool { false }
    func credentialSessionID() -> UUID? { nil }
    func wipeE2EEIfIdentityChanged(to userId: String) async {}
    func installAuthTokenForDebugQA(_ token: String) {}
    func clearLocalSessionForDebugQA() async {}
    func clearLocalSession() async {}
    func eraseDeletedAccountVault(ownerScopeId: String) async {}

    // Non exercées par le banc.
    func signup(email: String, password: String, handle: String, acceptedTerms: Bool, turnstileToken: String?) async throws -> CredentialResponse<LoginResponse> { throw APIError.cancelled }
    func signInWithApple(identityToken: String, fullName: String?, handle: String?, acceptedTerms: Bool) async throws -> LoginResponse { throw APIError.cancelled }
    func linkApple(identityToken: String) async throws { throw APIError.cancelled }
    func unlinkApple() async throws { throw APIError.cancelled }
    func setup2FA() async throws -> TwoFactorSetupResponse { throw APIError.cancelled }
    func confirm2FA(secret: String, code: String) async throws { throw APIError.cancelled }
    func disable2FA(code: String) async throws { throw APIError.cancelled }
    func forgotPassword(email: String, turnstileToken: String?) async throws { throw APIError.cancelled }
    func resetPassword(token: String, newPassword: String) async throws { throw APIError.cancelled }
    func changePassword(currentPassword: String, newPassword: String) async throws { throw APIError.cancelled }
    func refresh() async throws { throw APIError.cancelled }
    func logout() async throws {}
}
#endif
