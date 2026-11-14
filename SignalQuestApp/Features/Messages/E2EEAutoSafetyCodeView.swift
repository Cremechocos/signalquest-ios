import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI
import UIKit

// MARK: - Code de sécurité d'un contact (E2EE-AUTO §7)

/// Les 60 chiffres et leur QR, tirés des deux journaux vérifiés, avec la marque
/// « vérifié » gardée sur cet appareil. Un code qui a changé depuis la
/// vérification est signalé ; l'envoi n'est jamais bloqué (modèle B).
@MainActor
final class E2EEAutoSafetyCodeViewModel: ObservableObject {
    enum Status: Equatable {
        case unverified
        case verified
        /// Vérifié autrefois, différent aujourd'hui : un appareil ajouté ou retiré.
        case changed
    }

    struct Content: Equatable {
        let code: E2EEAutoSafetyCode.Code
        let status: Status
        let qrImage: UIImage?

        /// Pour VoiceOver : chiffre par chiffre, un zéro en tête n'est jamais perdu.
        var spokenGroups: String {
            code.groups.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
        }

        static func == (lhs: Content, rhs: Content) -> Bool {
            lhs.code == rhs.code && lhs.status == rhs.status
        }
    }

    enum State: Equatable {
        case loading
        case ready(Content)
        case failed(String)
    }

    enum ScanResult: Equatable {
        case match
        case mismatch
        case notACode
    }

    struct Dependencies {
        var readAccounts: () async -> E2EEAutoSafetyCode.AccountsRead
        var verifications = E2EEAutoSafetyCodeVerifications()
        var ownerNamespace: String
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var scanResult: ScanResult?

    let peerUserId: String
    let peerName: String
    private let dependencies: Dependencies
    /// Seul le dernier chargement compte.
    private var loadGeneration = 0

    init(peerUserId: String, peerName: String, dependencies: Dependencies) {
        self.peerUserId = peerUserId
        self.peerName = peerName
        self.dependencies = dependencies
    }

    func load(showingProgress: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        if showingProgress { state = .loading }
        let read = await dependencies.readAccounts()
        guard generation == loadGeneration else { return }
        switch read {
        case .verified(let own, let peer):
            guard let code = E2EEAutoSafetyCode.code(own, peer) else {
                state = .failed(String(localized: "Ce code se compare avec un contact, pas avec ton propre compte."))
                return
            }
            state = .ready(content(code))
        case .refused:
            state = .failed(String(localized: "Le code de sécurité avec \(peerName) n’a pas pu être vérifié pour l’instant. Réessaie plus tard."))
        case .inconclusive:
            state = .failed(String(localized: "Impossible de charger le code de sécurité. Vérifie ta connexion et réessaie."))
        }
    }

    /// `shown` : le code sous les yeux de l'utilisateur ; s'il a été remplacé, rien n'est fait.
    func markVerified(_ shown: Content) {
        guard case .ready(let content) = state, content == shown else { return }
        setVerified(content.code.digits, announcement: String(localized: "Code marqué comme vérifié"))
    }

    func clearVerification(_ shown: Content) {
        guard case .ready(let content) = state, content == shown else { return }
        setVerified(nil, announcement: String(localized: "Vérification retirée"))
    }

    /// QR scanné chez le contact : le même code des deux côtés vaut vérification.
    func scanned(_ text: String) {
        guard case .ready(let content) = state else { return }
        guard let digits = E2EEAutoSafetyCode.parseQR(text) else {
            scanResult = .notACode
            return
        }
        guard digits == content.code.digits else {
            scanResult = .mismatch
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Les codes sont différents"))
            return
        }
        setVerified(digits, announcement: String(localized: "Les codes sont identiques : code vérifié"))
        scanResult = .match
    }

    private func setVerified(_ digits: String?, announcement: String) {
        guard case .ready(let content) = state else { return }
        dependencies.verifications.setVerified(digits, peerUserId: peerUserId, ownerNamespace: dependencies.ownerNamespace)
        scanResult = nil
        state = .ready(self.content(content.code))
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func content(_ code: E2EEAutoSafetyCode.Code) -> Content {
        let verified = dependencies.verifications.verifiedDigits(peerUserId: peerUserId, ownerNamespace: dependencies.ownerNamespace)
        let status: Status = verified == nil ? .unverified : verified == code.digits ? .verified : .changed
        return Content(code: code, status: status, qrImage: E2EEAutoSafetyCodeQR.image(for: code.qr))
    }
}

extension E2EEAutoSafetyCodeViewModel {
    /// Pour la session courante ; sans journal lisible, l'écran le dit.
    static func live(api: APIClient, peerUserId: String, peerName: String) -> E2EEAutoSafetyCodeViewModel {
        guard let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api) else {
            return E2EEAutoSafetyCodeViewModel(
                peerUserId: peerUserId, peerName: peerName,
                dependencies: .init(readAccounts: { .inconclusive }, ownerNamespace: "")
            )
        }
        let ownUserId = String(session.ownerScopeId.dropFirst("user:".count))
        return E2EEAutoSafetyCodeViewModel(
            peerUserId: peerUserId, peerName: peerName,
            dependencies: .init(
                readAccounts: { await E2EEAutoSafetyCode.accounts(reader: reader, ownUserId: ownUserId, peerUserId: peerUserId) },
                ownerNamespace: session.ownerNamespace
            )
        )
    }
}

extension E2EEV2ApprovalScannerView.Copy {
    static let safetyCode = Self(
        title: { String(localized: "Scanner un code de sécurité") },
        hint: { String(localized: "Vise le code de sécurité affiché chez ton contact.") },
        denied: { String(localized: "SignalQuest n’a pas accès à la caméra. Autorise-la dans les Réglages d’iOS, ou compare les chiffres à l’œil.") },
        unavailable: { String(localized: "Aucune caméra n’est disponible. Compare les chiffres à l’œil.") }
    )
}

struct E2EEAutoSafetyCodeView: View {
    @StateObject private var model: E2EEAutoSafetyCodeViewModel
    @State private var showsScanner = false
    private let onClose: (() -> Void)?

    init(api: APIClient, peerUserId: String, peerName: String, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        // Modèle créé dans l'autoclosure : jamais un modèle neuf à chaque rendu du parent.
        _model = StateObject(wrappedValue: E2EEAutoSafetyCodeViewModel.live(api: api, peerUserId: peerUserId, peerName: peerName))
    }

    init(model: @autoclosure @escaping () -> E2EEAutoSafetyCodeViewModel, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                if let onClose {
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "safetyCode.close") { onClose() }
                }
                Text("Code de sécurité")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                switch model.state {
                case .loading:
                    SQSpinner()
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .accessibilityLabel(Text("Chargement du code de sécurité"))
                case .failed(let message):
                    VStack(spacing: SQSpace.md) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("safetyCode.error")
                        GradientButton(String(localized: "Réessayer"), style: .secondary) {
                            Task { await model.load(showingProgress: true) }
                        }
                    }
                case .ready(let content):
                    E2EEAutoSafetyCodeContent(
                        content: content,
                        peerName: model.peerName,
                        scanResult: model.scanResult,
                        onScan: { showsScanner = true },
                        onMarkVerified: { model.markVerified(content) },
                        onClearVerification: { model.clearVerification(content) }
                    )
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .sheet(isPresented: $showsScanner) {
            E2EEV2ApprovalScannerView(copy: .safetyCode) { model.scanned($0) }
        }
    }
}

/// Contenu de l'écran, sans défilement : rendu tel quel dans les tests.
struct E2EEAutoSafetyCodeContent: View {
    let content: E2EEAutoSafetyCodeViewModel.Content
    let peerName: String
    var scanResult: E2EEAutoSafetyCodeViewModel.ScanResult?
    var onScan: () -> Void = {}
    var onMarkVerified: () -> Void = {}
    var onClearVerification: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            Text("Compare ces chiffres avec ceux qui s’affichent chez \(peerName), en personne ou en vous appelant, ou scanne son code. S’ils sont identiques, personne ne s’interpose entre vous.")
                .font(SQType.callout)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if content.status == .changed {
                changedNotice
            }
            if let scanResult {
                scanNotice(scanResult)
            }
            codeCard
            actions
            Text("Ce code change quand l’un de vous ajoute ou retire un appareil.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var changedNotice: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Label {
                Text("Le code a changé depuis ta vérification")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(SQColor.warning)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text("L’un de vous a ajouté ou retiré un appareil. Tes messages continuent de partir ; compare le nouveau code avec \(peerName) pour le vérifier à nouveau.")
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.warningSoft, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safetyCode.changed")
    }

    @ViewBuilder
    private func scanNotice(_ result: E2EEAutoSafetyCodeViewModel.ScanResult) -> some View {
        switch result {
        case .match:
            Label("Les codes sont identiques : code vérifié.", systemImage: "checkmark.seal.fill")
                .font(SQType.body)
                .foregroundStyle(SQColor.success)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("safetyCode.scan.match")
        case .mismatch:
            Label {
                Text("Les codes sont différents. L’un de vous n’a peut-être pas encore vu un appareil ajouté ou retiré : rouvrez tous les deux cet écran, puis recommencez. S’ils diffèrent encore, quelqu’un pourrait s’interposer entre vous.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(SQType.body)
            .foregroundStyle(SQColor.dangerInk)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("safetyCode.scan.mismatch")
        case .notACode:
            Label("Ce QR n’est pas un code de sécurité SignalQuest.", systemImage: "qrcode")
                .font(SQType.body)
                .foregroundStyle(SQColor.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("safetyCode.scan.notACode")
        }
    }

    private var codeCard: some View {
        VStack(spacing: SQSpace.lg) {
            ViewThatFits(in: .horizontal) {
                digitsGrid(columns: 4)
                digitsGrid(columns: 3)
                digitsGrid(columns: 2)
                digitsGrid(columns: 1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Code de sécurité"))
            .accessibilityValue(Text(verbatim: content.spokenGroups))
            .accessibilityIdentifier("safetyCode.digits")
            if let image = content.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 160)
                    .padding(SQSpace.md)
                    // Le QR reste noir sur blanc dans tous les thèmes, pour être lu.
                    .background(Color.white, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("Code QR du code de sécurité"))
            }
            statusPill
        }
        .frame(maxWidth: .infinity)
        .padding(SQSpace.cardPadding)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
    }

    @ViewBuilder
    private var statusPill: some View {
        if content.status == .verified {
            Label {
                Text("Vérifié")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
            }
            .font(SQType.subhead)
            .foregroundStyle(SQColor.success)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs2)
            .background(SQColor.successSoft, in: Capsule(style: .continuous))
            .accessibilityIdentifier("safetyCode.status.verified")
        } else {
            Label {
                Text("Non vérifié")
            } icon: {
                Image(systemName: "seal")
            }
            .font(SQType.subhead)
            .foregroundStyle(SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs2)
            .background(SQColor.chip, in: Capsule(style: .continuous))
            .accessibilityIdentifier("safetyCode.status.unverified")
        }
    }

    private func digitsGrid(columns: Int) -> some View {
        let groups = content.code.groups
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
                            .sqSingleLine()
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: SQSpace.sm) {
            GradientButton(String(localized: "Scanner son code"), systemImage: "qrcode.viewfinder",
                           style: content.status == .verified ? .secondary : .primary, allowsMultiline: true, action: onScan)
                .accessibilityIdentifier("safetyCode.scan")
            if content.status == .verified {
                GradientButton(String(localized: "Retirer la vérification"), style: .ghost, allowsMultiline: true, action: onClearVerification)
                    .accessibilityIdentifier("safetyCode.clearVerification")
            } else {
                GradientButton(String(localized: "Marquer comme vérifié"), systemImage: "checkmark.seal",
                               style: .secondary, allowsMultiline: true, action: onMarkVerified)
                    .accessibilityIdentifier("safetyCode.markVerified")
            }
        }
    }
}

/// Banc visuel (simulateur Debug) : `--qa-auto-safety-code`, avec
/// `--qa-auto-safety-code-changed` (vérifié autrefois sur un autre code) ou
/// `--qa-auto-safety-code-verified`.
struct E2EEAutoSafetyCodeQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    static func model() -> E2EEAutoSafetyCodeViewModel {
        func account(_ userId: String, seeds: [UInt8]) -> E2EEAutoLog.AccountState {
            var account = E2EEAutoLog.AccountState(userId: userId, accountSaltB64: Data(count: 16).base64EncodedString())
            for seed in seeds {
                let signing = (try? P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))?
                    .publicKey.x963Representation.base64EncodedString() ?? ""
                let id = "device_qa_\(userId.suffix(4))_\(seed)_000000"
                account.devices[id] = E2EEAutoLog.DeviceState(
                    deviceId: id, platform: .ios, identityKeyB64: signing, signingKeyB64: signing, keyVersion: 1, status: .active,
                    addedAtMs: 0, activatedAtMs: 0, addEntryHash: E2EEAutoLog.digest(id), identityKeys: []
                )
            }
            return account
        }
        let own = account("user_alice_qa_01J7ABCD2345", seeds: [0x11, 0x12])
        let peer = account("user_bruno_qa_01J7ABCD2345", seeds: [0x21])
        let verifications = E2EEAutoSafetyCodeVerifications(defaults: UserDefaults(suiteName: "qa.safety-code") ?? .standard)
        verifications.setVerified(nil, peerUserId: peer.userId, ownerNamespace: "qa")
        if AppEnvironment.hasQAFlag("auto-safety-code-changed") {
            let before = E2EEAutoSafetyCode.code(account(own.userId, seeds: [0x11]), peer)?.digits
            verifications.setVerified(before, peerUserId: peer.userId, ownerNamespace: "qa")
        } else if AppEnvironment.hasQAFlag("auto-safety-code-verified") {
            verifications.setVerified(E2EEAutoSafetyCode.code(own, peer)?.digits, peerUserId: peer.userId, ownerNamespace: "qa")
        }
        return E2EEAutoSafetyCodeViewModel(
            peerUserId: peer.userId, peerName: "Bruno",
            dependencies: .init(readAccounts: { .verified(own: own, peer: peer) }, verifications: verifications, ownerNamespace: "qa")
        )
    }
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            E2EEAutoSafetyCodeView(model: Self.model())
        }
        #else
        EmptyView()
        #endif
    }
}

/// QR du code de sécurité, à scanner par l'autre appareil.
enum E2EEAutoSafetyCodeQR {
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
