import CryptoKit
import SwiftUI

/// Clé de ton compte (§2.3, D.12) : ses 30 chiffres, les mêmes sur tous tes
/// appareils. Un appareil approuvé reçoit la clé sans pouvoir la vérifier
/// seul : elle reste « non vérifiée » jusqu'à ce que tu compares ces chiffres
/// avec un autre de tes appareils.
@MainActor
final class E2EEV2AccountKeyViewModel: ObservableObject {
    struct Content: Equatable {
        /// Les 30 chiffres du compte (D.12).
        let digits: String
        let verified: Bool
        /// La clé publique dont les chiffres sont montrés.
        let uikX963: Data

        var groups: [String] { E2EEV2SafetyNumber.grouped(digits) }

        /// Pour VoiceOver : chiffre par chiffre, un zéro en tête n'est jamais perdu.
        var spokenGroups: String {
            groups.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
        }
    }

    enum State: Equatable {
        case loading
        case ready(Content)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var isActing = false
    @Published private(set) var actionError: String?

    private let ownUserId: String
    private let ownerNamespace: String
    private let store: E2EEV2AccountIdentityStore
    /// Seul le dernier chargement compte.
    private var loadGeneration = 0

    init(ownUserId: String, ownerNamespace: String, store: E2EEV2AccountIdentityStore) {
        self.ownUserId = ownUserId
        self.ownerNamespace = ownerNamespace
        self.store = store
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            guard let key = try store.load(ownerNamespace: ownerNamespace) else {
                state = .failed(String(localized: "Cet appareil n’a pas encore la clé de ton compte."))
                return
            }
            let verified = try store.isVerified(ownerNamespace: ownerNamespace)
            let uik = key.publicKey.x963Representation
            // 5 201 SHA-512 : hors du fil principal.
            let digits = await Task.detached { [ownUserId] in
                E2EEV2SafetyNumber.digits(uikX963: uik, userId: ownUserId)
            }.value
            guard generation == loadGeneration else { return }
            state = .ready(Content(digits: digits, verified: verified, uikX963: uik))
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed(String(localized: "Impossible de lire la clé de ton compte sur cet appareil."))
        }
    }

    /// Après comparaison : marque vérifiée la clé dont les chiffres étaient
    /// sous les yeux de l'utilisateur, jamais une autre.
    func markVerified(_ shown: Content) async {
        guard case .ready(let content) = state, content == shown, !content.verified, !isActing else { return }
        isActing = true
        actionError = nil
        defer { isActing = false }
        do {
            guard try store.load(ownerNamespace: ownerNamespace)?.publicKey.x963Representation == shown.uikX963 else {
                actionError = String(localized: "La clé de ton compte a changé sur cet appareil. Compare les nouveaux chiffres.")
                await load()
                return
            }
            try store.markVerified(ownerNamespace: ownerNamespace)
            await load()
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Clé du compte vérifiée"))
        } catch {
            actionError = String(localized: "Impossible d’enregistrer ce choix. Réessaie.")
        }
    }
}

struct E2EEV2AccountKeyView: View {
    @StateObject private var model: E2EEV2AccountKeyViewModel

    init(ownUserId: String, ownerNamespace: String, store: E2EEV2AccountIdentityStore = E2EEV2AccountIdentityStore()) {
        // Modèle créé dans l'autoclosure : jamais un modèle neuf à chaque rendu du parent.
        _model = StateObject(wrappedValue: E2EEV2AccountKeyViewModel(
            ownUserId: ownUserId, ownerNamespace: ownerNamespace, store: store
        ))
    }

    var body: some View {
        ScrollView {
            Group {
                switch model.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .accessibilityLabel(Text("Chargement de la clé de ton compte"))
                case .failed(let message):
                    VStack(spacing: SQSpace.md) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("accountKey.error")
                        GradientButton(String(localized: "Réessayer"), style: .secondary) {
                            Task { await model.load() }
                        }
                    }
                case .ready(let content):
                    E2EEV2AccountKeyContent(
                        content: content,
                        isActing: model.isActing,
                        actionError: model.actionError,
                        onMarkVerified: { Task { await model.markVerified(content) } }
                    )
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .navigationTitle(Text("Clé de ton compte"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}

/// Contenu de l'écran, sans défilement : rendu tel quel dans les tests.
struct E2EEV2AccountKeyContent: View {
    let content: E2EEV2AccountKeyViewModel.Content
    var isActing = false
    var actionError: String?
    var onMarkVerified: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                statusPill
                ViewThatFits(in: .horizontal) {
                    digitsGrid(columns: 3)
                    digitsGrid(columns: 2)
                    digitsGrid(columns: 1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Clé de ton compte"))
                .accessibilityValue(Text(verbatim: content.spokenGroups))
                .accessibilityIdentifier("accountKey.digits")
                Group {
                    if content.verified {
                        Text("Ces 30 chiffres identifient la clé de ton compte : ils sont les mêmes sur tous tes appareils. Compare-les quand tu en ajoutes un.")
                    } else {
                        Text("Cet appareil a reçu la clé de ton compte à son approbation, sans pouvoir la vérifier seul. Compare ces 30 chiffres avec ceux de la même page sur un autre de tes appareils.")
                    }
                }
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("accountKey.explanation")
            }
            .padding(SQSpace.lg + 2)
            .sqCardBackground()

            if !content.verified {
                GradientButton(String(localized: "Les chiffres sont identiques : marquer comme vérifiée"), systemImage: "checkmark.seal",
                               isBusy: isActing, style: .primary, allowsMultiline: true, action: onMarkVerified)
                    .disabled(isActing)
                    .accessibilityIdentifier("accountKey.markVerified")
                Text("S’ils diffèrent, ne marque rien : retire cet appareil depuis ton autre appareil, puis fais-le approuver de nouveau.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("accountKey.actionError")
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if content.verified {
            Label {
                Text("Vérifiée")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
            }
            .font(SQType.subhead)
            .foregroundStyle(SQColor.success)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs + 2)
            .background(SQColor.successSoft, in: Capsule(style: .continuous))
            .accessibilityIdentifier("accountKey.status.verified")
        } else {
            Label {
                Text("Non vérifiée")
            } icon: {
                Image(systemName: "seal")
            }
            .font(SQType.subhead)
            .foregroundStyle(SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs + 2)
            .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
            .accessibilityIdentifier("accountKey.status.unverified")
        }
    }

    private func digitsGrid(columns: Int) -> some View {
        let groups = content.groups
        let rows = stride(from: 0, to: groups.count, by: columns).map { start in
            Array(groups[start..<min(start + columns, groups.count)].enumerated()).map { (start + $0.offset, $0.element) }
        }
        return Grid(horizontalSpacing: SQSpace.lg, verticalSpacing: SQSpace.sm) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index], id: \.0) { _, group in
                        Text(verbatim: group)
                            .font(SQFont.display(22, .semibold, relativeTo: .title3).monospacedDigit())
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
    }
}

/// Démonstration (`--qa-account-key`, appareil approuvé ; `--qa-account-key-verified`,
/// premier appareil ; `--qa-account-key-missing`, sans clé) : clé fixe, trousseau
/// en mémoire, aucun réseau.
struct E2EEV2AccountKeyQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    private static let ownUserId = "user_alice_qa_01J7ABCD2345"
    private static let namespace = "qa-account-key"

    private let store: E2EEV2AccountIdentityStore = {
        let arguments = ProcessInfo.processInfo.arguments
        let store = E2EEV2AccountIdentityStore(tokenStore: InMemoryTokenStore()) { _ in true }
        if !arguments.contains("--qa-account-key-missing"),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32)) {
            try? store.install(key, ownerNamespace: E2EEV2AccountKeyQAScreen.namespace)
            if arguments.contains("--qa-account-key-verified") { try? store.markVerified(ownerNamespace: E2EEV2AccountKeyQAScreen.namespace) }
        }
        return store
    }()
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            E2EEV2AccountKeyView(ownUserId: Self.ownUserId, ownerNamespace: Self.namespace, store: store)
        }
        #else
        EmptyView()
        #endif
    }
}
