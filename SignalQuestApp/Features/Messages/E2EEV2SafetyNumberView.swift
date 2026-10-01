import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI
import UIKit

/// Numéro de sécurité avec un contact (§2.4, D.12) : les 60 chiffres et leur
/// QR, l'état de la vérification et les décisions de l'utilisateur. Le calcul
/// et l'épinglage restent dans l'annuaire de confiance.
@MainActor
final class E2EEV2SafetyNumberViewModel: ObservableObject {
    struct Content: Equatable {
        let peerName: String
        /// Les 60 chiffres, dans l'ordre des `userId` (D.12).
        let digits: String
        let status: E2EEV2SafetyNumberIdentity.Status
        /// L'UIK du contact dont le numéro est montré.
        let uikX963B64: String
        let qrImage: UIImage?

        var groups: [String] { E2EEV2SafetyNumber.grouped(digits) }

        /// Pour VoiceOver : chiffre par chiffre, un zéro en tête n'est jamais perdu.
        var spokenGroups: String {
            groups.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
        }

        static func == (lhs: Content, rhs: Content) -> Bool {
            lhs.peerName == rhs.peerName && lhs.digits == rhs.digits && lhs.status == rhs.status
                && lhs.uikX963B64 == rhs.uikX963B64
        }
    }

    enum State: Equatable {
        case loading
        case ready(Content)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var isLoading = false
    @Published private(set) var isActing = false
    @Published private(set) var actionError: String?

    let peerName: String
    private let peerUserId: String
    private let ownUserId: String
    private let ownAccountKey: () -> P256.Signing.PublicKey?
    private let trust: any E2EEV2SafetyNumberTrusting
    /// Seul le dernier chargement compte : un plus ancien qui finit après lui
    /// ne remplace jamais ce qui est affiché.
    private var loadGeneration = 0

    init(
        peerUserId: String,
        peerName: String,
        ownUserId: String,
        ownAccountKey: @escaping () -> P256.Signing.PublicKey?,
        trust: any E2EEV2SafetyNumberTrusting
    ) {
        self.peerUserId = peerUserId
        self.peerName = peerName
        self.ownUserId = ownUserId
        self.ownAccountKey = ownAccountKey
        self.trust = trust
    }

    func load(showingProgress: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        if showingProgress { state = .loading }
        defer { if generation == loadGeneration { isLoading = false } }
        guard let ownKey = ownAccountKey() else {
            state = .failed(String(localized: "Ce numéro n’est pas encore disponible : cet appareil n’a pas la clé de ton compte."))
            return
        }
        do {
            let identity = try await trust.safetyNumberIdentity(userId: peerUserId)
            guard let peerKey = Data(base64Encoded: identity.uikX963B64) else {
                throw E2EEV2TrustDirectory.SafetyNumberFailure.refused(.malformed)
            }
            // 2 × 5 201 SHA-512 : hors du fil principal.
            let digits = await Task.detached { [ownUserId, peerUserId, own = ownKey.x963Representation] in
                E2EEV2SafetyNumber.pair(userA: ownUserId, uikA: own, userB: peerUserId, uikB: peerKey)
            }.value
            guard generation == loadGeneration else { return }
            state = .ready(Content(
                peerName: peerName, digits: digits, status: identity.status, uikX963B64: identity.uikX963B64,
                qrImage: E2EEV2SafetyNumberQR.image(for: E2EEV2SafetyNumber.qrPayload(digits))
            ))
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed(loadMessage(for: error))
        }
    }

    /// Après comparaison : marque vérifiée l'UIK montrée, ou l'accepte
    /// vérifiée si elle vient de changer. `shown` : le contenu sous les yeux de
    /// l'utilisateur au moment du geste ; s'il a été remplacé, rien n'est fait.
    func markVerified(_ shown: Content) async {
        await act(shown, announcement: String(localized: "Numéro marqué comme vérifié")) { content, trust, userId in
            if case .changed = content.status {
                try await trust.acceptChangedIdentity(userId: userId, uikX963B64: content.uikX963B64, verified: true)
            } else {
                try await trust.setVerified(true, userId: userId, uikX963B64: content.uikX963B64)
            }
        }
    }

    func clearVerification(_ shown: Content) async {
        await act(shown, announcement: String(localized: "Vérification retirée")) { content, trust, userId in
            try await trust.setVerified(false, userId: userId, uikX963B64: content.uikX963B64)
        }
    }

    /// Changement vu, sans comparaison : seulement si l'ancienne UIK n'était
    /// pas vérifiée (§2.4).
    func acceptWithoutVerifying(_ shown: Content) async {
        await act(shown, announcement: String(localized: "Nouveau numéro accepté")) { content, trust, userId in
            try await trust.acceptChangedIdentity(userId: userId, uikX963B64: content.uikX963B64, verified: false)
        }
    }

    private func act(
        _ shown: Content,
        announcement: String,
        _ body: (Content, any E2EEV2SafetyNumberTrusting, String) async throws -> Void
    ) async {
        guard case .ready(let content) = state, content == shown, !isActing, !isLoading else { return }
        isActing = true
        actionError = nil
        defer { isActing = false }
        do {
            try await body(content, trust, peerUserId)
            await load()
            UIAccessibility.post(notification: .announcement, argument: announcement)
        } catch let failure as E2EEV2TrustDirectory.SafetyNumberFailure {
            // Choix refusé pour une raison qui tient à l'état : l'écran se recharge.
            actionError = actionMessage(for: failure)
            await load()
        } catch {
            actionError = String(localized: "Impossible d’enregistrer ce choix. Réessaie.")
        }
    }

    private func loadMessage(for error: Error) -> String {
        switch error as? E2EEV2TrustDirectory.SafetyNumberFailure {
        case .refused:
            return String(localized: "Le chiffrement avec \(peerName) n’a pas pu être vérifié : rien ne lui est envoyé pour l’instant. Réessaie plus tard.")
        case .ownAccount:
            return String(localized: "Ce numéro se compare avec un contact, pas avec ton propre compte.")
        case .numberChanged, .verificationRequired, nil:
            return String(localized: "Impossible de charger le numéro de sécurité. Vérifie ta connexion et réessaie.")
        }
    }

    private func actionMessage(for failure: E2EEV2TrustDirectory.SafetyNumberFailure) -> String {
        switch failure {
        case .numberChanged:
            return String(localized: "Le numéro vient de changer. Compare le nouveau numéro avant de continuer.")
        case .verificationRequired:
            return String(localized: "Tu avais vérifié l’ancien numéro : compare le nouveau avant de l’accepter.")
        case .refused:
            return String(localized: "Le chiffrement avec \(peerName) n’a pas pu être vérifié : rien ne lui est envoyé pour l’instant. Réessaie plus tard.")
        case .ownAccount:
            return String(localized: "Ce numéro se compare avec un contact, pas avec ton propre compte.")
        }
    }
}

enum E2EEV2SafetyNumberQR {
    @MainActor private static let context = CIContext()

    @MainActor
    static func image(for payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct E2EEV2SafetyNumberView: View {
    @StateObject private var model: E2EEV2SafetyNumberViewModel

    init(
        peerUserId: String,
        peerName: String,
        ownUserId: String,
        ownAccountKey: @escaping () -> P256.Signing.PublicKey?,
        trust: any E2EEV2SafetyNumberTrusting
    ) {
        // Modèle créé dans l'autoclosure : jamais un modèle neuf à chaque rendu du parent.
        _model = StateObject(wrappedValue: E2EEV2SafetyNumberViewModel(
            peerUserId: peerUserId, peerName: peerName, ownUserId: ownUserId,
            ownAccountKey: ownAccountKey, trust: trust
        ))
    }

    var body: some View {
        ScrollView {
            Group {
                switch model.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .accessibilityLabel(Text("Chargement du numéro de sécurité"))
                case .failed(let message):
                    VStack(spacing: SQSpace.md) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("safetyNumber.error")
                        GradientButton(String(localized: "Réessayer"), style: .secondary) {
                            Task { await model.load(showingProgress: true) }
                        }
                    }
                case .ready(let content):
                    // Chaque geste emporte le contenu affiché : rien n'est fait s'il a changé.
                    E2EEV2SafetyNumberContent(
                        content: content,
                        isActing: model.isActing || model.isLoading,
                        actionError: model.actionError,
                        onMarkVerified: { Task { await model.markVerified(content) } },
                        onClearVerification: { Task { await model.clearVerification(content) } },
                        onAcceptWithoutVerifying: { Task { await model.acceptWithoutVerifying(content) } }
                    )
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .navigationTitle(Text("Numéro de sécurité"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}

/// Contenu de l'écran, sans défilement : rendu tel quel dans les tests.
struct E2EEV2SafetyNumberContent: View {
    let content: E2EEV2SafetyNumberViewModel.Content
    var isActing = false
    var actionError: String?
    var onMarkVerified: () -> Void = {}
    var onClearVerification: () -> Void = {}
    var onAcceptWithoutVerifying: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            if case .changed(let wasVerified) = content.status {
                changedNotice(wasVerified: wasVerified)
            }
            numberCard
            actions
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("safetyNumber.actionError")
            }
            Text("Ce numéro ne change pas quand l’un de vous ajoute un appareil. Il change seulement si l’un de vous réinitialise son chiffrement.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func changedNotice(wasVerified: Bool) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Label {
                Text("\(content.peerName) a un nouveau numéro de sécurité")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(SQColor.warning)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("safetyNumber.changed.title")
            Text("Cela arrive quand \(content.peerName) réinitialise son chiffrement, par exemple après avoir perdu tous ses appareils. Cela peut aussi signaler une tentative d’interception : compare le nouveau numéro avec \(content.peerName).")
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if wasVerified {
                    Text("Tu avais vérifié l’ancien numéro : rien n’est envoyé à \(content.peerName) tant que tu n’as pas vérifié le nouveau.")
                } else {
                    Text("Rien n’est envoyé à \(content.peerName) tant que tu n’as pas accepté ce nouveau numéro.")
                }
            }
            .font(SQType.callout)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.warningSoft, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safetyNumber.changed")
    }

    private var numberCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            statusPill
            ViewThatFits(in: .horizontal) {
                digitsGrid(columns: 4)
                digitsGrid(columns: 3)
                digitsGrid(columns: 2)
                digitsGrid(columns: 1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Numéro de sécurité"))
            .accessibilityValue(Text(verbatim: content.spokenGroups))
            .accessibilityIdentifier("safetyNumber.digits")
            if let image = content.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200)
                    .padding(SQSpace.md)
                    // Le QR reste noir sur blanc dans tous les thèmes, pour être lu.
                    .background(Color.white, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Code QR du numéro de sécurité"))
            }
            Text("Compare ces chiffres avec ceux qui s’affichent chez \(content.peerName), en personne ou en vous appelant. S’ils sont identiques, personne ne s’interpose entre vous. S’ils diffèrent, ne marque pas ce numéro comme vérifié : quelqu’un pourrait lire vos échanges.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SQSpace.lg + 2)
        .sqCardBackground()
    }

    @ViewBuilder
    private var statusPill: some View {
        switch content.status {
        case .verified:
            Label {
                Text("Vérifié")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
            }
            .font(SQType.subhead)
            .foregroundStyle(SQColor.success)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs + 2)
            .background(SQColor.successSoft, in: Capsule(style: .continuous))
            .accessibilityIdentifier("safetyNumber.status.verified")
        case .unverified, .changed:
            Label {
                Text("Non vérifié")
            } icon: {
                Image(systemName: "seal")
            }
            .font(SQType.subhead)
            .foregroundStyle(SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs + 2)
            .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
            .accessibilityIdentifier("safetyNumber.status.unverified")
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

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: SQSpace.sm) {
            switch content.status {
            case .unverified:
                GradientButton(String(localized: "Marquer comme vérifié"), systemImage: "checkmark.seal", isBusy: isActing,
                               style: .primary, allowsMultiline: true, action: onMarkVerified)
                    .accessibilityIdentifier("safetyNumber.markVerified")
            case .verified:
                GradientButton(String(localized: "Retirer la vérification"), isBusy: isActing,
                               style: .secondary, allowsMultiline: true, action: onClearVerification)
                    .accessibilityIdentifier("safetyNumber.clearVerification")
            case .changed(let wasVerified):
                GradientButton(String(localized: "J’ai comparé : marquer comme vérifié"), systemImage: "checkmark.seal",
                               isBusy: isActing, style: .primary, allowsMultiline: true, action: onMarkVerified)
                    .accessibilityIdentifier("safetyNumber.markVerified")
                if !wasVerified {
                    GradientButton(String(localized: "Accepter sans vérifier"), isBusy: isActing,
                                   style: .ghost, allowsMultiline: true, action: onAcceptWithoutVerifying)
                        .accessibilityIdentifier("safetyNumber.acceptWithoutVerifying")
                }
            }
        }
        .disabled(isActing)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Annuaire de démonstration (`--qa-safety-number`, `--qa-safety-number-changed`,
/// `--qa-safety-number-changed-verified`) : clés fixes, aucun réseau.
actor E2EEV2SafetyNumberQATrust: E2EEV2SafetyNumberTrusting {
    static let ownUserId = "user_alice_qa_01J7ABCD2345"
    static let peerUserId = "user_bruno_qa_01J7ABCD2345"
    static let ownKey = key(0x11)
    private static let pinnedKey = key(0x22).x963Representation.base64EncodedString()
    private static let servedKey = key(0x33).x963Representation.base64EncodedString()

    private var pinned: String
    private var verified: Bool
    private let served: String

    init(arguments: [String]) {
        let changed = arguments.contains("--qa-safety-number-changed")
            || arguments.contains("--qa-safety-number-changed-verified")
        pinned = Self.pinnedKey
        verified = arguments.contains("--qa-safety-number-changed-verified")
        served = changed ? Self.servedKey : Self.pinnedKey
    }

    func safetyNumberIdentity(userId: String) -> E2EEV2SafetyNumberIdentity {
        if served != pinned {
            return E2EEV2SafetyNumberIdentity(userId: userId, uikX963B64: served, status: .changed(wasVerified: verified))
        }
        return E2EEV2SafetyNumberIdentity(userId: userId, uikX963B64: pinned, status: verified ? .verified : .unverified)
    }

    func setVerified(_ verified: Bool, userId: String, uikX963B64: String) throws {
        guard uikX963B64 == pinned, served == pinned else { throw E2EEV2TrustDirectory.SafetyNumberFailure.numberChanged }
        self.verified = verified
    }

    func acceptChangedIdentity(userId: String, uikX963B64: String, verified: Bool) throws {
        guard uikX963B64 == served, served != pinned else { throw E2EEV2TrustDirectory.SafetyNumberFailure.numberChanged }
        if self.verified && !verified { throw E2EEV2TrustDirectory.SafetyNumberFailure.verificationRequired }
        pinned = served
        self.verified = verified
    }

    private static func key(_ byte: UInt8) -> P256.Signing.PublicKey {
        // Scalaires fixes, valides (bien sous l'ordre de la courbe).
        (try? P256.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32)))?.publicKey
            ?? P256.Signing.PrivateKey().publicKey
    }
}
#endif

struct E2EEV2SafetyNumberQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    private let trust = E2EEV2SafetyNumberQATrust(arguments: ProcessInfo.processInfo.arguments)
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            E2EEV2SafetyNumberView(
                peerUserId: E2EEV2SafetyNumberQATrust.peerUserId,
                peerName: "Bruno",
                ownUserId: E2EEV2SafetyNumberQATrust.ownUserId,
                ownAccountKey: { E2EEV2SafetyNumberQATrust.ownKey },
                trust: trust
            )
        }
        #else
        EmptyView()
        #endif
    }
}
