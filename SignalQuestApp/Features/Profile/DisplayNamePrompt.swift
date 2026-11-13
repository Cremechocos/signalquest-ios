import SwiftUI

/// Identité membre v1 : le nom affiché, facultatif, se propose à l'arrivée dans Communauté (fil
/// et messagerie), où les autres le lisent. Refermée sans nom, la proposition revient au plus
/// une fois par semaine ; jamais une fois le nom rempli, ni avant « Ton nom d'utilisateur ».
enum DisplayNamePromptPolicy {
    static let interval: TimeInterval = 7 * 24 * 3600

    static func shouldPresent(user: AuthUser, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard MemberIdentity.name(user.name, handle: nil) == nil, !user.needsHandleConfirmation else { return false }
        guard let last = defaults.object(forKey: key(for: user.id)) as? Date else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    static func markPresented(userID: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now, forKey: key(for: userID))
    }

    private static func key(for userID: String) -> String { "sq.displayNamePrompt.lastShown.\(userID)" }
}

struct DisplayNamePromptView: View {
    let user: AuthUser
    /// Profil renvoyé par le serveur une fois le nom enregistré.
    let save: (UserProfilePatch) async throws -> AuthUser
    let onSaved: (AuthUser) -> Void
    let onLater: () -> Void

    @State private var name = ""
    @State private var isBusy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Text("Ajoute un nom affiché")
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                Group {
                    if let handle = user.handle, !handle.isEmpty {
                        Text("Il apparaît sur ton profil, dans le fil et les messages. Il n’a pas besoin d’être unique. Laissé vide, c’est ton nom d’utilisateur, \(handle), qui s’affiche.")
                    } else {
                        Text("Il apparaît sur ton profil, dans le fil et les messages. Il n’a pas besoin d’être unique.")
                    }
                }
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

                AuthFieldGroup {
                    AuthFieldRow("Nom affiché", isFocused: focused) {
                        TextField("Nom affiché", text: $name, prompt: SQFormPrompt.text("Par exemple : Alexandre G."))
                            .textContentType(.name)
                            .submitLabel(.done)
                            .focused($focused)
                            .onSubmit { Task { await submit() } }
                            .accessibilityLabel("Nom affiché")
                            .accessibilityIdentifier("displayName.prompt.field")
                    } onTap: { focused = true }
                }

                if let error {
                    SQNotice(message: error, systemImage: "exclamationmark.triangle", tone: .danger)
                        .sqAnnounce(error)
                }

                VStack(spacing: SQSpace.sm) {
                    GradientButton("Enregistrer", isBusy: isBusy) { Task { await submit() } }
                        .disabled(trimmed.isEmpty || isBusy)
                        .accessibilityIdentifier("displayName.prompt.save")
                    GradientButton(String(localized: "Plus tard"), style: .ghost) { onLater() }
                        .disabled(isBusy)
                        .accessibilityIdentifier("displayName.prompt.later")
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth(560)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(SQColor.bg.ignoresSafeArea())
        .accessibilityIdentifier("displayName.prompt")
    }

    private func submit() async {
        guard !trimmed.isEmpty, !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let updated = try await save(UserProfilePatch(name: trimmed, handle: nil, bio: nil, avatarUrl: nil))
            Haptics.success()
            onSaved(updated)
        } catch {
            Haptics.error()
            self.error = error.userFacingMessage
        }
    }
}

/// `--qa-display-name-prompt` : la proposition sans réseau, pour un compte sans nom affiché.
struct DisplayNamePromptQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @State private var result: String?

    var body: some View {
        if let result {
            Text(verbatim: result).accessibilityIdentifier("displayName.prompt.qaResult")
        } else {
            DisplayNamePromptView(
                user: try! JSONDecoder().decode(AuthUser.self, from: Data(
                    #"{"id":"qa-user","email":"synthetic@example.invalid","name":null,"handle":"alex38","handleConfirmedAt":"2026-11-13T00:00:00.000Z"}"#.utf8)),
                save: { patch in
                    try await Task.sleep(nanoseconds: 300_000_000)
                    return try JSONDecoder().decode(AuthUser.self, from: JSONSerialization.data(withJSONObject: [
                        "id": "qa-user", "name": patch.name ?? "", "handle": "alex38",
                        "handleConfirmedAt": "2026-11-13T00:00:00.000Z",
                    ]))
                },
                onSaved: { result = "saved \($0.name ?? "-")" },
                onLater: { result = "later" }
            )
        }
    }
    #else
    var body: some View { EmptyView() }
    #endif
}
