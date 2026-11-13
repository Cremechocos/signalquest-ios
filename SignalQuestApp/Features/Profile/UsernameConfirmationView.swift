import SwiftUI

/// Identité membre v1, point 2 : l'écran « Ton nom d'utilisateur », qui explique les deux noms.
/// Il ne se repousse pas : avec un nom d'utilisateur on le garde (`confirmHandle`) ou on le
/// change, gratuitement cette fois-ci ; sans nom d'utilisateur on doit en choisir un. Le nom
/// affiché, facultatif, s'enregistre avec le même bouton.
struct UsernameConfirmationView: View {
    let user: AuthUser
    /// Profil renvoyé par le serveur une fois le choix enregistré.
    let save: (UserProfilePatch) async throws -> AuthUser
    let onSaved: (AuthUser) -> Void

    @StateObject private var username: UsernameAvailabilityModel
    @State private var changing: Bool
    @State private var displayName: String
    @State private var isBusy = false
    @State private var error: String?
    private enum Field { case username, displayName }
    @FocusState private var focus: Field?

    init(user: AuthUser,
         check: @escaping @Sendable (String) async throws -> HandleAvailability,
         save: @escaping (UserProfilePatch) async throws -> AuthUser,
         onSaved: @escaping (AuthUser) -> Void) {
        self.user = user
        self.save = save
        self.onSaved = onSaved
        let current = Self.trimmed(user.handle)
        _username = StateObject(wrappedValue: UsernameAvailabilityModel(current: current, check: check))
        _changing = State(initialValue: current == nil)
        _displayName = State(initialValue: user.name ?? "")
    }

    private var current: String? { Self.trimmed(user.handle) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Ton compte").sqKicker()
                    Text("Ton nom d’utilisateur")
                        .font(SQType.display)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .sqHeader()
                }
                Text("SignalQuest distingue désormais deux noms. Le **nom d’utilisateur** est unique : on te trouve et on te mentionne avec lui. Le **nom affiché**, facultatif, est celui que les autres lisent.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if changing {
                    changeSection
                } else if let current {
                    currentCard(current)
                }

                Text(freeChangeNote)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(SQColor.separator)

                displayNameSection

                if let error {
                    SQNotice(message: error, systemImage: "exclamationmark.triangle", tone: .danger)
                        .sqAnnounce(error)
                }

                actions
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth(560)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(SQColor.bg.ignoresSafeArea())
        .accessibilityIdentifier("username.confirmation")
    }

    // MARK: - Nom d'utilisateur

    private func currentCard(_ handle: String) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xxs) {
            Text(verbatim: handle)
                .font(SQFont.body(20, .bold, relativeTo: .title3))
                .foregroundStyle(SQColor.label)
            Text(verbatim: UserHandle.profileLink(handle))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("username.confirmation.current")
    }

    private var changeSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            AuthFieldGroup {
                AuthFieldRow(current == nil ? "Nom d’utilisateur" : "Nouveau nom d’utilisateur",
                             isFocused: focus == .username, isError: username.isNegative) {
                    UsernameTextField(text: $username.input, identifier: "username.confirmation.field")
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .displayName }
                } onTap: { focus = .username }
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    UsernameStatusLine(model: username)
                    if username.canSubmit {
                        Text(verbatim: UserHandle.profileLink(username.normalized))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .padding(.horizontal, SQSpace.md2)
                .padding(.bottom, SQSpace.sm2)
            }
            if let current {
                Text("L’ancien lien \(UserHandle.profileLink(current)) mènera toujours à ton profil.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var freeChangeNote: String {
        current == nil
            ? String(localized: "Tu pourras le changer ensuite, avec 30 jours d’attente entre deux changements.")
            : String(localized: "Le changer est gratuit cette fois-ci. Ensuite, il faudra attendre 30 jours entre deux changements.")
    }

    // MARK: - Nom affiché

    /// Le nom d'utilisateur qui s'affichera si le nom affiché reste vide.
    private var shownHandle: String? {
        changing ? (username.canSubmit ? username.normalized : nil) : current
    }

    private var displayNameSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            AuthFieldGroup {
                AuthFieldRow("Nom affiché (facultatif)", isFocused: focus == .displayName) {
                    TextField("Nom affiché", text: $displayName, prompt: SQFormPrompt.text("Par exemple : Alexandre G."))
                        .textContentType(.name)
                        .submitLabel(.done)
                        .focused($focus, equals: .displayName)
                        .accessibilityLabel("Nom affiché, facultatif")
                        .accessibilityIdentifier("username.confirmation.displayName")
                } onTap: { focus = .displayName }
            }
            Group {
                if let shownHandle {
                    Text("Il apparaît sur ton profil, dans le fil et les messages. Il n’a pas besoin d’être unique. Laissé vide, c’est ton nom d’utilisateur, \(shownHandle), qui s’affiche.")
                } else {
                    Text("Il apparaît sur ton profil, dans le fil et les messages. Il n’a pas besoin d’être unique.")
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: SQSpace.sm) {
            if changing {
                GradientButton(verbatim: String(localized: "Enregistrer \(username.normalized.isEmpty ? "…" : username.normalized)"),
                               isBusy: isBusy, allowsMultiline: true) {
                    Task { await submit(handle: username.normalized) }
                }
                .disabled(!username.canSubmit || isBusy)
                .accessibilityIdentifier("username.confirmation.save")
                if let current {
                    GradientButton(verbatim: String(localized: "Garder \(current)"), style: .ghost, allowsMultiline: true) {
                        changing = false
                        error = nil
                        focus = nil
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("username.confirmation.cancelChange")
                }
            } else {
                GradientButton(String(localized: "Garder ce nom d’utilisateur"), isBusy: isBusy, allowsMultiline: true) {
                    Task { await submit(handle: nil) }
                }
                .disabled(isBusy)
                .accessibilityIdentifier("username.confirmation.keep")
                GradientButton(String(localized: "Choisir un autre nom d’utilisateur"), style: .ghost, allowsMultiline: true) {
                    changing = true
                    error = nil
                    focus = .username
                }
                .disabled(isBusy)
                .accessibilityIdentifier("username.confirmation.change")
            }
        }
    }

    /// `handle == nil` : garder le nom actuel. Le nom affiché part avec, seulement s'il a changé ;
    /// vidé, il part en `""` (le serveur l'enregistre à `null`).
    private func submit(handle: String?) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        let patch = Self.patch(handle: handle, displayName: displayName, previousName: user.name)
        do {
            let updated = try await save(patch)
            Haptics.success()
            onSaved(updated)
        } catch let APIError.http(_, code, _, _, _) where code == "HANDLE_ALREADY_USED" || code == "HANDLE_INVALID" {
            username.reject(code: code)
            focus = .username
        } catch {
            Haptics.error()
            self.error = error.userFacingMessage
        }
    }

    static func patch(handle: String?, displayName: String, previousName: String?) -> UserProfilePatch {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = (previousName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return UserProfilePatch(name: name == previous ? nil : name, handle: handle, bio: nil, avatarUrl: nil,
                                confirmHandle: handle == nil ? true : nil)
    }

    private static func trimmed(_ handle: String?) -> String? {
        guard let value = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// `--qa-username-confirmation` (nom d'utilisateur à garder) ou `--qa-username-confirmation-none`
/// (aucun nom d'utilisateur) : l'écran sans réseau, « pris » répondu pour « alex ».
struct UsernameConfirmationQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @State private var saved: AuthUser?

    var body: some View {
        if let saved {
            Text(verbatim: "saved \(saved.handle ?? "-") / \(saved.name ?? "-")")
                .accessibilityIdentifier("username.confirmation.qaSaved")
        } else {
            UsernameConfirmationView(
                user: Self.user,
                check: { handle in
                    try await Task.sleep(nanoseconds: 150_000_000)
                    let taken = handle == "alex"
                    return HandleAvailability(handle: handle, available: !taken, current: false, cooldownActive: false,
                                              remainingDays: nil, code: taken ? "HANDLE_ALREADY_USED" : nil)
                },
                save: { patch in
                    try await Task.sleep(nanoseconds: 300_000_000)
                    var object: [String: Any] = ["id": Self.user.id, "handleConfirmedAt": "2026-11-13T00:00:00.000Z"]
                    if let name = patch.name ?? Self.user.name, !name.isEmpty { object["name"] = name }
                    if let handle = patch.handle ?? Self.user.handle { object["handle"] = handle }
                    let data = try JSONSerialization.data(withJSONObject: object)
                    return try JSONDecoder().decode(AuthUser.self, from: data)
                },
                onSaved: { saved = $0 }
            )
        }
    }

    private static var user: AuthUser {
        let none = AppEnvironment.hasQAFlag("username-confirmation-none")
        let json = none
            ? #"{"id":"qa-user","email":"synthetic@example.invalid","name":"Camille","handle":null}"#
            : #"{"id":"qa-user","email":"synthetic@example.invalid","name":null,"handle":"alex38"}"#
        return try! JSONDecoder().decode(AuthUser.self, from: Data(json.utf8))
    }
    #else
    var body: some View { EmptyView() }
    #endif
}
