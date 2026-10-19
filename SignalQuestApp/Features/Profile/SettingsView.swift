import SwiftUI
import AuthenticationServices
import CoreImage.CIFilterBuiltins
import UserNotifications
import UIKit

/// Enveloppe `Identifiable` autour de l'URL de l'archive exportée, pour piloter une
/// `.sheet(item:)` (l'URL seule n'est pas `Identifiable`).
struct ExportedDataFile: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Appareils E2EE v2

@MainActor
final class E2EEV2TrustedDevicesViewModel: ObservableObject {
    @Published private(set) var devices: [E2EEV2RemoteDevice] = []
    /// Plateforme lue dans le certificat de chaque appareil (liste signée).
    @Published private(set) var certifiedPlatforms: [String: String] = [:]
    @Published private(set) var currentDeviceId: String?
    /// Descripteur local : le QR d'approbation en montre la plateforme et l'empreinte.
    @Published private(set) var localDescriptor: E2EEV2DeviceDescriptor?
    @Published private(set) var activationEnabled = false
    /// Inventaire lu : un appareil local absent n'est alors pas encore enregistré.
    @Published private(set) var inventoryLoaded = false
    /// Approuvé côté serveur, mais la clé du compte n'est jamais arrivée ici
    /// (dépôt expiré ou déjà consommé) : seule la clé de récupération la rend.
    @Published private(set) var accountKeyMissing = false
    @Published private(set) var identityGeneration: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isActing = false
    @Published var errorMessage: String?
    @Published var confirmationMessage: String?
    @Published var approvalErrorMessage: String?
    @Published var generatedApproval: E2EEV2Approval?
    @Published var approvalDetail: E2EEV2ApprovalDetail?
    /// QR v3 lu pour `approvalDetail` : l'approbation signe ce que l'utilisateur a scanné.
    private var approvalQR: E2EEV2QRApprovalPayload?
    @Published var bootstrapChallenge: E2EEV2BootstrapEmailChallenge?

    private let identityStore: E2EEV2DeviceIdentityStore
    private let enrollment: E2EEV2DeviceEnrollmentCoordinator
    private let lifecycle: E2EEV2DeviceLifecycleCoordinator

    init(api: APIClient) {
        let identityStore = E2EEV2DeviceIdentityStore()
        self.identityStore = identityStore
        enrollment = E2EEV2DeviceEnrollmentCoordinator(api: api, identityStore: identityStore)
        let recovery = E2EEV2RecoveryCoordinatorV2(api: api, identityStore: identityStore)
        lifecycle = E2EEV2DeviceLifecycleCoordinator(
            api: api, identityStore: identityStore,
            deviceListChanged: { await recovery.resignActiveBundleIfStale() }
        )
    }

    var hasLocalIdentity: Bool { currentDeviceId != nil }

    /// À préparer : sans identité locale, ou avec une identité que le serveur
    /// n'a jamais reçue (enregistrement interrompu).
    var needsPreparation: Bool {
        !hasLocalIdentity || (inventoryLoaded && currentDevice == nil)
    }

    var currentDeviceCanRevoke: Bool {
        devices.contains {
            $0.descriptor.deviceId == currentDeviceId && $0.status == .approved
        }
    }

    var currentDevice: E2EEV2RemoteDevice? {
        devices.first { $0.descriptor.deviceId == currentDeviceId }
    }

    var identityEstablished: Bool { identityGeneration != nil }

    /// Le certificat fait foi ; sans lui (appareil en attente, liste illisible),
    /// la plateforme déclarée au registre.
    func platform(of device: E2EEV2RemoteDevice) -> String {
        certifiedPlatforms[device.descriptor.deviceId] ?? device.descriptor.platform
    }

    func load() async {
        isLoading = true
        activationEnabled = false
        inventoryLoaded = false
        errorMessage = nil
        defer { isLoading = false }
        do {
            localDescriptor = try identityStore.load()
            currentDeviceId = localDescriptor?.deviceId
        } catch {
            localDescriptor = nil
            currentDeviceId = nil
            devices = []
            errorMessage = String(localized: "L’identité locale E2EE v2 est illisible. Elle n’a pas été remplacée automatiquement.")
            return
        }
        guard currentDeviceId != nil else {
            devices = []
            activationEnabled = false
            identityGeneration = nil
            return
        }
        // Lot A1 : UIK d'une demande par QR restée en cours, reçue dès le chargement.
        if case .success(.approved)? = await lifecycle.resumePendingApproval() {
            confirmationMessage = String(localized: "Appareil approuvé. La clé du compte est installée sur cet appareil.")
        }
        switch await lifecycle.listDeviceInventory() {
        case .success(let inventory):
            devices = inventory.devices
            inventoryLoaded = true
            accountKeyMissing = currentDevice?.status == .approved
                && (try? E2EEV2AccountIdentityStore().load(ownerNamespace: LocalAccountScope.storageNamespace)) == nil
            certifiedPlatforms = await lifecycle.certifiedPlatforms() ?? [:]
            activationEnabled = inventory.activationEnabled
            identityGeneration = inventory.identity?.generation
            if inventory.activationEnabled, currentDeviceCanRevoke {
                E2EEV2NotificationContextEvents.requestRefresh(.identity)
                // §2.6 : clé d'accord de 30 jours ou plus, recertifiée en passant.
                if case .success(true) = await lifecycle.recertifyIfDue() { E2EEV2NotificationContextEvents.requestRefresh(.identity) }
                // §12 : document de capacités publié à chaque build et tous les 30 jours.
                _ = await lifecycle.publishCapabilitiesIfNeeded()
            }
        case .failed(let failure):
            devices = []
            errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible de charger la liste des appareils."))
        }
    }

    func prepareCurrentDevice() async {
        guard !isActing else { return }
        isActing = true
        errorMessage = nil
        defer { isActing = false }
        switch await enrollment.registerPendingDevice(label: UIDevice.current.model) {
        case .registered(_, let status, _):
            confirmationMessage = status == .approved
                ? String(localized: "Cet appareil est déjà approuvé.")
                : String(localized: "Appareil préparé. Une approbation reste nécessaire.")
            await load()
        case .failed(let failure):
            errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible de préparer cet appareil."))
        }
    }

    func revoke(_ device: E2EEV2RemoteDevice) async {
        guard !isActing,
              currentDeviceCanRevoke,
              device.descriptor.deviceId != currentDeviceId else { return }
        isActing = true
        errorMessage = nil
        defer { isActing = false }
        switch await lifecycle.revoke(deviceId: device.descriptor.deviceId, reason: "USER_REQUEST") {
        case .success:
            confirmationMessage = String(localized: "Appareil révoqué. Les conversations concernées devront renouveler leurs clés.")
            await load()
        case .failed(let failure):
            errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible de révoquer cet appareil."))
        }
    }

    func resetApproval() {
        approvalErrorMessage = nil
        generatedApproval = nil
        approvalDetail = nil
        approvalQR = nil
        bootstrapChallenge = nil
    }

    func requestApproval(_ method: E2EEV2ApprovalMethod) async {
        guard !isActing else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        switch await lifecycle.requestApproval(method) {
        case .success(let approval):
            generatedApproval = approval
        case .failed:
            approvalErrorMessage = String(localized: "Impossible de créer la demande d’approbation. Réessaie.")
        }
    }

    func requestBootstrapEmail() async {
        guard !isActing else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        switch await lifecycle.requestBootstrapEmailChallenge() {
        case .success(let challenge):
            bootstrapChallenge = challenge
        case .failed(let failure) where failure.statusCode == 429:
            approvalErrorMessage = String(localized: "Trop d’essais. Réessaie dans quelques minutes.")
        case .failed:
            approvalErrorMessage = String(localized: "Impossible d’envoyer le code de vérification.")
        }
    }

    func completeBootstrap(code: String) async {
        guard !isActing,
              let challenge = bootstrapChallenge,
              code.trimmingCharacters(in: .whitespacesAndNewlines).count == 6 else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        switch await lifecycle.bootstrapInitialDevice(.email(
            challengeId: challenge.challengeId,
            code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )) {
        case .success:
            resetApproval()
            confirmationMessage = String(localized: "Premier appareil approuvé.")
            await load()
        case .failed(let failure) where failure.code == "E2EE_IDENTITY_ALREADY_ESTABLISHED":
            approvalErrorMessage = String(localized: "Un autre appareil a déjà établi le chiffrement de ce compte. Fais approuver celui-ci en scannant son QR.")
            await load()
        case .failed(let failure) where failure.statusCode == 429:
            approvalErrorMessage = String(localized: "Trop d’essais. Réessaie dans quelques minutes.")
        case .failed(let failure) where failure.code == "E2EE_BOOTSTRAP_EMAIL_INVALID":
            // Un code ne sert qu'une fois, même faux : le retaper échouerait encore.
            approvalErrorMessage = String(localized: "Code incorrect ou expiré. Chaque code ne sert qu’une fois : touche « Renvoyer le code ».")
        case .failed:
            approvalErrorMessage = String(localized: "Le code est invalide, expiré ou ne correspond plus à cet appareil.")
        }
    }

    func resolveApproval(_ rawInput: String) async {
        // Le QR peut porter le lien universel (v0.4.34) : on en lit la chaîne v3.
        let input = E2EEV2DeviceApprovalContract.rawQRPayload(fromScanned: rawInput)
            ?? rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isActing, !input.isEmpty, currentDeviceCanRevoke else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        // Lot A1 : l'approbation passe seulement par le QR, qui porte l'empreinte comparée.
        guard input.hasPrefix("SQE2EE2|"), let qr = E2EEV2DeviceApprovalContract.parseQRPayload(input) else {
            approvalDetail = nil
            approvalErrorMessage = String(localized: "Scanne le QR affiché sur l’appareil à approuver.")
            return
        }
        switch await lifecycle.loadQRApproval(input) {
        case .success(let detail):
            approvalDetail = detail
            approvalQR = qr
        case .failed(let failure):
            approvalDetail = nil
            approvalQR = nil
            switch failure.message {
            case "e2ee-qr-platform-mismatch":
                approvalErrorMessage = String(localized: "Plateforme différente de celle affichée, approbation refusée.")
            case "e2ee-qr-device-mismatch":
                approvalErrorMessage = String(localized: "Cet appareil ne correspond pas au code affiché, approbation refusée.")
            default:
                approvalErrorMessage = String(localized: "Demande invalide, expirée ou incohérente avec le serveur.")
            }
        }
    }

    func loadPushApproval(_ approvalId: String) async {
        guard !isActing, currentDeviceCanRevoke else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        // Lot A1 : une demande par notification ne s'approuve plus ; son QR, oui.
        _ = approvalId
        approvalDetail = nil
        approvalErrorMessage = String(localized: "Pour approuver cet appareil, scanne le QR qu’il affiche.")
    }

    func approveResolvedDevice() async {
        guard !isActing, currentDeviceCanRevoke, let detail = approvalDetail, let qr = approvalQR else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        switch await lifecycle.approve(detail, comparedQR: qr) {
        case .success:
            resetApproval()
            confirmationMessage = String(localized: "Appareil approuvé. Les clés des conversations concernées seront renouvelées.")
            await load()
        case .failed(let failure):
            approvalErrorMessage = Self.approvalFailureMessage(failure)
        }
    }

    /// Lot A1 : les refus propres à la chaîne de confiance, sinon le message générique.
    private static func approvalFailureMessage(_ failure: E2EEV2TransportFailure) -> String {
        switch failure.code ?? failure.message {
        case "e2ee-account-key-unavailable":
            return String(localized: "Cet appareil n’a pas la clé du compte : il ne peut pas en approuver un autre.")
        case "e2ee-account-trust-refused", "e2ee-account-identity-unavailable", "E2EE_DEVICE_LIST_INVALID", "e2ee-device-list-stale":
            return String(localized: "La liste des appareils du compte n’a pas pu être vérifiée. Approbation refusée.")
        case "E2EE_IDENTITY_STATE_REPAIR_REQUIRED":
            return String(localized: "Le chiffrement de ce compte doit être réinitialisé avant d’approuver un appareil.")
        default:
            return String(localized: "Impossible d’approuver cet appareil. Actualise puis réessaie.")
        }
    }

    /// Appareil en attente, QR affiché : attend l'approbation, puis installe
    /// la clé du compte déposée pour lui (lot A1).
    func waitForApproval() async {
        guard let approvalId = generatedApproval?.id else { return }
        // 3 s entre deux relevés ; après un 429, 15 s (la valeur que le
        // serveur annonce aujourd'hui), puis le double, jusqu'à une minute.
        var delaySeconds: UInt64 = 3
        while !Task.isCancelled, generatedApproval?.id == approvalId {
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            guard !Task.isCancelled, generatedApproval?.id == approvalId else { return }
            let result = await lifecycle.receiveApprovedTrust(approvalId: approvalId)
            // Un QR plus récent ou la sortie de l'écran : ce résultat ne s'applique plus.
            guard !Task.isCancelled, generatedApproval?.id == approvalId else { return }
            switch result {
            case .success(.pending):
                delaySeconds = 3
                continue
            case .success(.approved):
                resetApproval()
                confirmationMessage = String(localized: "Appareil approuvé. La clé du compte est installée sur cet appareil.")
                await load()
                return
            case .success:
                generatedApproval = nil
                approvalErrorMessage = String(localized: "La demande a expiré ou a été refusée. Affiche un nouveau QR.")
                return
            case .failed(let failure) where failure.kind == .retryable:
                delaySeconds = failure.statusCode == 429 ? min(max(delaySeconds * 2, 15), 60) : 3
                continue
            case .failed:
                generatedApproval = nil
                approvalErrorMessage = String(localized: "La clé du compte n’a pas pu être reçue. Affiche un nouveau QR et fais-le scanner de nouveau.")
                return
            }
        }
    }

    private static func message(
        for failure: E2EEV2TransportFailure,
        fallback: String
    ) -> String {
        // Session déjà liée à un autre appareil (E.1, v0.4.19) : une nouvelle
        // connexion la délie, jamais un nouvel essai.
        if failure.code == "E2EE_DEVICE_SESSION_MISMATCH" {
            return String(localized: "La session a changé. Reconnecte-toi avant de gérer les appareils.")
        }
        switch failure.kind {
        case .authentication:
            return String(localized: "La session a changé. Reconnecte-toi avant de gérer les appareils.")
        case .retryable:
            return String(localized: "Le service est temporairement indisponible. Réessaie.")
        case .activationBlocked:
            return String(localized: "Le chiffrement des appareils n’est pas encore disponible sur ce compte.")
        case .permanent, .localState:
            return fallback
        }
    }
}

/// Quand proposer l'activation du chiffrement de bout en bout sur cet appareil
/// (1.0 (164), décision du 05/10) : porte serveur ouverte, appareil pas encore
/// entré en v2, et pas de « Plus tard » en cours. Le plein écran au lancement
/// et la carte de Messages partagent ce « Plus tard ».
enum E2EEV2ActivationPrompt {
    static let snoozeSeconds: TimeInterval = 7 * 24 * 3600

    @MainActor
    static func shouldPrompt(messaging: E2EEV2MessagingRuntime) -> Bool {
        guard messaging.writesEnabled, let session = LocalAccountScope.sessionSnapshot() else { return false }
        return messaging.lacksV2Readiness(session) && !isSnoozed(session)
    }

    static func isSnoozed(_ session: LocalAccountSession) -> Bool {
        Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: key(session))
    }

    static func snooze() {
        guard let session = LocalAccountScope.sessionSnapshot() else { return }
        UserDefaults.standard.set(Date().addingTimeInterval(snoozeSeconds).timeIntervalSince1970, forKey: key(session))
    }

    private static func key(_ session: LocalAccountSession) -> String {
        "sq.e2ee.v2.activation-snoozed.\(session.ownerNamespace)"
    }
}

/// Activation guidée au lancement (1.0 (164), décision du 05/10) : les étapes
/// de l'écran Appareils, sur place et dans l'ordre, sans passer par Réglages.
/// ① cet appareil se prépare ; ② code e-mail pour le premier appareil du
/// compte, ou QR à faire scanner par un appareil déjà approuvé ; ③ c'est prêt.
struct E2EEV2ActivationScreen: View {
    @StateObject private var model: E2EEV2TrustedDevicesViewModel
    @State private var code = ""
    @State private var showsRecovery = false
    private let api: APIClient
    let onFinish: () -> Void
    let onLater: () -> Void

    init(api: APIClient, onFinish: @escaping () -> Void, onLater: @escaping () -> Void) {
        _model = StateObject(wrappedValue: E2EEV2TrustedDevicesViewModel(api: api))
        self.api = api
        self.onFinish = onFinish
        self.onLater = onLater
    }

    private enum Step: Int { case prepare = 1, confirm, ready }

    private var step: Step {
        if model.needsPreparation { return .prepare }
        if model.currentDevice?.status == .approved && !model.accountKeyMissing { return .ready }
        return .confirm
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    Image(systemName: "lock.shield.fill")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(SQColor.brandRed)
                        .accessibilityHidden(true)
                    Text("Active le chiffrement de bout en bout")
                        .font(SQType.display)
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tes messages et tes appels ne seront lisibles que sur tes appareils.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        stepRow(1, String(localized: "Cet appareil se prépare"), done: step.rawValue > 1)
                        stepRow(2, model.identityEstablished
                                ? String(localized: "Ton autre appareil l’approuve")
                                : String(localized: "Code reçu par e-mail"), done: step.rawValue > 2)
                        stepRow(3, String(localized: "C’est prêt"), done: step == .ready)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SQSpace.lg)
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))

                    content

                    if let message = model.approvalErrorMessage ?? model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, SQSpace.xl)
                .padding(.vertical, SQSpace.lg)
                .sqReadableWidth()
            }
            .background(SQColor.bg.ignoresSafeArea())
            .toolbar {
                if step != .ready {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Plus tard") { onLater() }
                            .accessibilityIdentifier("e2ee-v2-activation-later")
                    }
                }
            }
            .navigationDestination(isPresented: $showsRecovery) { E2EEV2RecoveryResetView(api: api) }
        }
        .task { await model.load() }
        .task(id: model.generatedApproval?.id) { await model.waitForApproval() }
        // Compte déjà actif ailleurs : le QR s'affiche de lui-même.
        .task(id: autoQRKey) {
            if step == .confirm, model.identityEstablished, model.generatedApproval == nil, !model.isActing,
               !model.accountKeyMissing, model.currentDevice?.status == .pending {
                await model.requestApproval(.qr)
            }
        }
        .interactiveDismissDisabled()
    }

    private var autoQRKey: String {
        // `isActing` en fait partie : la préparation recharge l'inventaire
        // pendant qu'elle agit, et la tâche doit repartir une fois libre.
        "\(step.rawValue)-\(model.identityEstablished)-\(model.currentDevice?.status.rawValue ?? "-")-\(model.isActing)"
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .prepare:
            GradientButton(String(localized: "Activer maintenant"), systemImage: "lock.badge.plus", isBusy: model.isActing, style: .primary) {
                Task { await model.prepareCurrentDevice() }
            }
            .disabled(model.isActing || model.isLoading)
            .accessibilityIdentifier("e2ee-v2-activation-start")
        case .confirm where model.currentDevice == nil:
            // Inventaire pas encore lu, ou en échec : sans lui, impossible de
            // savoir si ce compte a déjà un appareil chiffré.
            if model.isLoading {
                SQSpinner()
                    .tint(SQColor.brandRed)
                    .frame(maxWidth: .infinity)
            } else {
                GradientButton(String(localized: "Réessayer"), systemImage: "arrow.clockwise", style: .primary) {
                    Task { await model.load() }
                }
            }
        case .confirm where model.currentDevice?.status == .revoked:
            Text("Cet appareil a été révoqué depuis un autre de tes appareils : il ne peut plus être approuvé tel quel.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .confirm where model.accountKeyMissing:
            Text("La clé du compte n’est pas arrivée sur cet appareil. Saisis ta clé de récupération, ou fais révoquer cet appareil depuis un autre puis approuve-le à nouveau.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Utiliser ma clé de récupération"), systemImage: "key.viewfinder", style: .primary) {
                showsRecovery = true
            }
        case .confirm where !model.identityEstablished:
            if let challenge = model.bootstrapChallenge {
                Text("Code envoyé à \(challenge.maskedEmail)")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                TextField("Code reçu", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .padding(SQSpace.md)
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .onChangeCompat(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                    .accessibilityIdentifier("e2ee-v2-activation-code")
                GradientButton(String(localized: "Valider"), systemImage: "checkmark.shield.fill", isBusy: model.isActing, style: .primary) {
                    Task { await model.completeBootstrap(code: code) }
                }
                .disabled(model.isActing || code.count != 6)
                // Code faux ou expiré : sans renvoi, seul « Plus tard » restait (AF-PROF-02).
                Button(String(localized: "Renvoyer le code")) {
                    code = ""
                    Task { await model.requestBootstrapEmail() }
                }
                .font(SQType.button)
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
                .disabled(model.isActing)
                .accessibilityIdentifier("e2ee-v2-activation-resend")
            } else {
                Text("C’est le premier appareil chiffré de ton compte : un code à usage unique, envoyé par e-mail, le confirme. Aucune clé privée ne quitte cet appareil.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                GradientButton(String(localized: "Recevoir le code par e-mail"), systemImage: "envelope.fill", isBusy: model.isActing, style: .primary) {
                    Task { await model.requestBootstrapEmail() }
                }
                .disabled(model.isActing)
            }
        case .confirm:
            Text("Ton compte est déjà chiffré sur un autre appareil. Sur celui-ci, ouvre Profil › Réglages › Compte et sécurité › Appareils, puis « Scanner le code », et vise ce QR.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let approval = model.generatedApproval, let device = model.localDescriptor,
               let payload = try? E2EEV2DeviceApprovalContract.encodeQRPayload(approval, device: device),
               let image = E2EEV2ActivationScreen.qrImage(payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .padding(SQSpace.md)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("QR temporaire d’approbation SignalQuest")
                Label("En attente de l’approbation…", systemImage: "hourglass")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            } else {
                GradientButton(String(localized: "Afficher le QR"), systemImage: "qrcode", isBusy: model.isActing, style: .primary) {
                    Task { await model.requestApproval(.qr) }
                }
                .disabled(model.isActing)
            }
        case .ready:
            Text("Le chiffrement de bout en bout est activé sur cet appareil.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Continuer"), systemImage: "checkmark", style: .primary) { onFinish() }
                .accessibilityIdentifier("e2ee-v2-activation-done")
        }
    }

    private func stepRow(_ number: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2.weight(.semibold))
                .foregroundStyle(done ? SQColor.success : SQColor.labelSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Étape \(number) sur 3 : \(title)"))
        .accessibilityValue(done ? String(localized: "Fait") : "")
    }

    static func qrImage(_ value: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Écrans ouverts depuis Appareils, poussés par valeur. Déclarés par la pile
/// qui ouvre Appareils (Réglages ou les feuilles du Profil), comme Mes lieux
/// l'est par Notifications plutôt que par Pannes près de mes lieux.
enum TrustedDevicesDestination: Hashable {
    case accountKey(ownUserId: String, ownerNamespace: String)
    case recovery
}

extension View {
    /// Destinations des liens d'Appareils, pour la pile qui l'affiche.
    func trustedDevicesDestinations(api: APIClient) -> some View {
        navigationDestination(for: TrustedDevicesDestination.self) { destination in
            switch destination {
            case let .accountKey(ownUserId, ownerNamespace):
                E2EEV2AccountKeyView(ownUserId: ownUserId, ownerNamespace: ownerNamespace)
            case .recovery:
                E2EEV2RecoveryResetView(api: api)
            }
        }
    }
}

struct E2EEV2TrustedDevicesView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: E2EEV2TrustedDevicesViewModel
    @State private var deviceToRevoke: E2EEV2RemoteDevice?
    @State private var approvalInput = ""
    @State private var initialApprovalConsumed = false
    @State private var showsApprovalScanner = false
    private let api: APIClient
    private let initialApprovalId: String?
    /// QR ouvert par le lien universel (appareil photo du système) : chargé
    /// pour comparaison, jamais approuvé sans geste.
    private let initialApprovalQR: String?

    init(api: APIClient, initialApprovalId: String? = nil, initialApprovalQR: String? = nil) {
        self.initialApprovalQR = initialApprovalQR
        _model = StateObject(wrappedValue: E2EEV2TrustedDevicesViewModel(api: api))
        self.api = api
        self.initialApprovalId = initialApprovalId
    }

    var body: some View {
        List {
            Section {
                if model.needsPreparation && !model.isLoading {
                    Label(model.hasLocalIdentity
                          ? String(localized: "Cet appareil n’est pas encore enregistré pour le chiffrement de bout en bout.")
                          : String(localized: "Cet appareil n’est pas encore prêt pour le chiffrement de bout en bout."),
                          systemImage: "iphone.gen3.badge.play")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                    Button {
                        Task { await model.prepareCurrentDevice() }
                    } label: {
                        Label("Préparer cet appareil", systemImage: "lock.badge.plus")
                            .frame(minHeight: 48)
                    }
                    .disabled(model.isActing)
                } else if !model.activationEnabled {
                    Label {
                        Text("Tes appareils sont listés ici. Le nouveau chiffrement de bout en bout s’activera quand il sera disponible sur iPhone, Android et le web.")
                            .font(SQType.body)
                    } icon: {
                        Image(systemName: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(SQColor.warning)
                    }
                } else {
                    Label("Le chiffrement de bout en bout est activé pour ce compte.", systemImage: "lock.shield.fill")
                        .foregroundStyle(SQColor.success)
                }
                if let generation = model.identityGeneration {
                    Text("Clé du compte · version \(generation)")
                        .font(.caption.monospaced())
                        .foregroundStyle(SQColor.labelSecondary)
                }
            } header: {
                Text("État")
            }

            E2EEV2RotationStatusSection(runtime: services.epochRotations)

            // D.12 : la clé du compte se compare entre ses appareils. L'écran
            // existait sans entrée en production (AF-PROF-09).
            if model.currentDevice?.status == .approved, !model.accountKeyMissing,
               let session = LocalAccountScope.sessionSnapshot() {
                Section {
                    NavigationLink(value: TrustedDevicesDestination.accountKey(
                        ownUserId: String(session.ownerScopeId.dropFirst("user:".count)),
                        ownerNamespace: session.ownerNamespace
                    )) {
                        Label("Clé de ton compte", systemImage: "key.horizontal")
                    }
                    .accessibilityIdentifier("e2ee.accountKey")
                }
            }

            if model.accountKeyMissing {
                Section {
                    Label("La clé du compte n’est pas arrivée sur cet appareil. Saisis ta clé de récupération plus bas, ou fais révoquer cet appareil depuis un autre puis approuve-le à nouveau.", systemImage: "key.slash")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }

            if let currentDevice = model.currentDevice,
               currentDevice.status == .pending,
               !model.identityEstablished {
                Section {
                    Text("Aucun appareil n’est encore approuvé. Un code e-mail à usage unique établit la première identité ; aucune clé privée ne quitte cet appareil.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                    if let challenge = model.bootstrapChallenge {
                        Label("Code envoyé à \(challenge.maskedEmail)", systemImage: "envelope.fill")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                        TextField("Code reçu", text: $approvalInput)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .onChangeCompat(of: approvalInput) { _, value in
                                approvalInput = String(value.filter(\.isNumber).prefix(6))
                            }
                        Button {
                            Task { await model.completeBootstrap(code: approvalInput) }
                        } label: {
                            Label("Valider ce premier appareil", systemImage: "checkmark.shield.fill")
                                .frame(minHeight: 48)
                        }
                        .disabled(model.isActing || approvalInput.count != 6)
                        Button {
                            approvalInput = ""
                            Task { await model.requestBootstrapEmail() }
                        } label: {
                            Label("Renvoyer le code", systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .disabled(model.isActing)
                    } else {
                        Button {
                            Task { await model.requestBootstrapEmail() }
                        } label: {
                            Label("Recevoir un code par e-mail", systemImage: "envelope.fill")
                                .frame(minHeight: 48)
                        }
                        .disabled(model.isActing)
                    }
                    approvalErrorRow
                } header: {
                    Text("Premier appareil")
                }
            }

            if let currentDevice = model.currentDevice,
               currentDevice.status == .pending,
               model.identityEstablished {
                Section {
                    Text("Affiche un QR temporaire et scanne-le depuis un appareil déjà approuvé.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                    if let approval = model.generatedApproval {
                        generatedApprovalView(approval)
                        Button("Annuler cette demande") {
                            model.resetApproval()
                        }
                        .frame(minHeight: 48)
                    } else {
                        Button {
                            Task { await model.requestApproval(.qr) }
                        } label: {
                            Label("Afficher un QR temporaire", systemImage: "qrcode")
                                .frame(minHeight: 48)
                        }
                    }
                    approvalErrorRow
                } header: {
                    Text("Faire approuver cet appareil")
                }
            }

            if model.currentDeviceCanRevoke {
                Section {
                    Text("Scanne le QR affiché sur l’appareil à approuver, navigateur compris. Sans caméra, colle son contenu ci-dessous.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                    if let detail = model.approvalDetail {
                        approvalPreview(detail)
                        if initialApprovalQR != nil {
                            // Ouvert par un lien : n'importe qui peut en envoyer un.
                            Label("N’approuve que si cet appareil est devant toi et que tu viens d’afficher ce QR toi-même.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(SQType.body)
                                .foregroundStyle(SQColor.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            Task { await model.approveResolvedDevice() }
                        } label: {
                            Label("Approuver cet appareil", systemImage: "checkmark.shield.fill")
                                .frame(minHeight: 48)
                        }
                        .disabled(model.isActing)
                        Button("Annuler") {
                            model.resetApproval()
                            approvalInput = ""
                        }
                        .frame(minHeight: 48)
                    } else {
                        Button {
                            showsApprovalScanner = true
                        } label: {
                            Label("Scanner le code", systemImage: "qrcode.viewfinder")
                                .frame(minHeight: 48)
                        }
                        .disabled(model.isActing)
                        .accessibilityIdentifier("devices.scanApproval")
                        TextField("Contenu du QR SignalQuest", text: $approvalInput, axis: .vertical)
                            .lineLimit(2...4)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            Task { await model.resolveApproval(approvalInput) }
                        } label: {
                            Label("Vérifier la demande", systemImage: "checkmark.seal")
                                .frame(minHeight: 48)
                        }
                        .disabled(model.isActing || approvalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    approvalErrorRow
                } header: {
                    Text("Approuver un appareil")
                }
            }

            if model.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Chargement des appareils…")
                        Spacer()
                    }
                    .frame(minHeight: 72)
                }
            } else if model.devices.isEmpty && model.hasLocalIdentity {
                Section {
                    Label("Aucun appareil v2 enregistré.", systemImage: "rectangle.stack.badge.questionmark")
                        .foregroundStyle(SQColor.labelSecondary)
                }
            } else if !model.devices.isEmpty {
                Section {
                    ForEach(model.devices, id: \.descriptor.deviceId) { device in
                        deviceRow(device)
                    }
                } header: {
                    Text("Appareils")
                } footer: {
                    Text("Une révocation est définitive pour cette identité et impose une rotation des clés des conversations concernées.")
                }
            }

            if model.hasLocalIdentity {
                Section {
                    NavigationLink(value: TrustedDevicesDestination.recovery) {
                        Label("Récupération et perte d’accès", systemImage: "key.viewfinder")
                            .frame(minHeight: 48)
                    }
                } header: {
                    Text("Récupération")
                } footer: {
                    Text("Créer une clé hors ligne, restaurer l’historique ou réinitialiser irréversiblement l’identité E2EE.")
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.dangerInk)
                    Button("Réessayer") { Task { await model.load() } }
                        .frame(minHeight: 48)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SQColor.bg.ignoresSafeArea())
        .tint(SQColor.brandRed)
        .navigationTitle("Appareils")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .sheet(isPresented: $showsApprovalScanner) {
            E2EEV2ApprovalScannerView { code in
                approvalInput = code
                Task { await model.resolveApproval(code) }
            }
        }
        .task(id: model.generatedApproval?.id) {
            await model.waitForApproval()
        }
        .task {
            await model.load()
            if !initialApprovalConsumed,
               let initialApprovalId,
               model.currentDeviceCanRevoke {
                initialApprovalConsumed = true
                await model.loadPushApproval(initialApprovalId)
            }
            if !initialApprovalConsumed, let initialApprovalQR, model.currentDeviceCanRevoke {
                initialApprovalConsumed = true
                approvalInput = initialApprovalQR
                await model.resolveApproval(initialApprovalQR)
            }
        }
        .alert("Révoquer cet appareil ?", isPresented: Binding(
            get: { deviceToRevoke != nil },
            set: { if !$0 { deviceToRevoke = nil } }
        )) {
            Button("Annuler", role: .cancel) { deviceToRevoke = nil }
            Button("Révoquer", role: .destructive) {
                guard let device = deviceToRevoke else { return }
                deviceToRevoke = nil
                Task { await model.revoke(device) }
            }
        } message: {
            Text("Cette identité ne pourra pas être réactivée. Les conversations concernées devront renouveler leurs clés.")
        }
        .alert("Appareils", isPresented: Binding(
            get: { model.confirmationMessage != nil },
            set: { if !$0 { model.confirmationMessage = nil } }
        )) {
            Button("OK") { model.confirmationMessage = nil }
        } message: {
            Text(model.confirmationMessage ?? "")
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: E2EEV2RemoteDevice) -> some View {
        let isCurrent = device.descriptor.deviceId == model.currentDeviceId
        let platform = model.platform(of: device)
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: platformIcon(platform))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 40, height: 40)
                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(device.descriptor.label ?? platformName(platform))
                        .font(SQType.heading)
                    // Un navigateur nommé se distingue encore d'un téléphone.
                    if platform == "web", device.descriptor.label != nil {
                        Text("Navigateur")
                            .font(SQFont.body(12, .bold, relativeTo: .caption2))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(SQColor.accentSoft, in: Capsule())
                    }
                    if isCurrent {
                        Text("Cet appareil")
                            .font(SQFont.body(12, .bold, relativeTo: .caption2))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(SQColor.accentSoft, in: Capsule())
                    }
                }
                Text(statusLabel(device.status))
                    .font(SQFont.body(12, .bold, relativeTo: .caption))
                    .foregroundStyle(statusColor(device.status))
                Text("Ajouté \(formattedDate(device.createdAt)) · vu \(formattedDate(device.lastSeenAt))")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                Text("Clé de signature · \(device.signingKeyFingerprint)")
                    .font(.caption.monospaced())
                    .foregroundStyle(SQColor.labelSecondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if !isCurrent && model.currentDeviceCanRevoke && device.status != .revoked {
                Button(role: .destructive) {
                    deviceToRevoke = device
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Révoquer \(device.descriptor.label ?? platformName(platform))")
                .disabled(model.isActing)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var approvalErrorRow: some View {
        if let message = model.approvalErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(SQType.body)
                .foregroundStyle(SQColor.dangerInk)
                .accessibilityLabel("Erreur d’approbation. \(message)")
        }
    }

    @ViewBuilder
    private func generatedApprovalView(_ approval: E2EEV2Approval) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            switch approval.method {
            case .push:
                Label(
                    "Une notification a été envoyée aux appareils déjà approuvés.",
                    systemImage: "bell.badge.fill"
                )
                .font(SQType.body)
            case .proximityCode:
                if let code = approval.proximityCode {
                    Text(groupedProximityCode(code))
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                        .textSelection(.enabled)
                        .accessibilityLabel("Code de proximité \(code.map(String.init).joined(separator: " "))")
                } else {
                    Label("Code indisponible. Crée une nouvelle demande.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.dangerInk)
                }
            case .qr:
                if let device = model.localDescriptor,
                   let payload = try? E2EEV2DeviceApprovalContract.encodeQRPayload(approval, device: device),
                   let image = qrCode(for: payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .padding(SQSpace.md)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .accessibilityLabel("QR temporaire d’approbation SignalQuest")
                    Text("Si la caméra n’est pas disponible, copie le contenu du QR depuis l’autre appareil.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                } else {
                    Label("QR indisponible. Crée une nouvelle demande.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.dangerInk)
                }
            }

            Text("Expire \(formattedExpiry(approval.expiresAt))")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .accessibilityElement(children: .contain)
    }

    private func approvalPreview(_ detail: E2EEV2ApprovalDetail) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            // Un navigateur se nomme par sa plateforme, lue dans le QR v3 ; le nom
            // qu'il se donne n'est qu'un nom (§2.7).
            Label(
                detail.pendingDevice.descriptor.platform == "web"
                    ? platformName("web")
                    : detail.pendingDevice.descriptor.label ?? platformName(detail.pendingDevice.descriptor.platform),
                systemImage: platformIcon(detail.pendingDevice.descriptor.platform)
            )
            .font(SQType.heading)
            if let name = E2EEV2ApprovalCopy.quotedName(
                platform: detail.pendingDevice.descriptor.platform, label: detail.pendingDevice.descriptor.label
            ) {
                Text(verbatim: name)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Text("Plateforme · \(platformName(detail.pendingDevice.descriptor.platform))")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Text("Clé de signature · \(detail.pendingDevice.signingKeyFingerprint)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Compare cette empreinte sur le nouvel appareil avant d’approuver.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.warning)
            Text("Demande \(methodLabel(detail.approval.method)) · expire \(formattedExpiry(detail.approval.expiresAt))")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            if detail.pendingDevice.descriptor.platform == "web" {
                Text(verbatim: E2EEV2ApprovalCopy.browserNotice())
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, SQSpace.xs)
        .accessibilityElement(children: .combine)
    }

    private func groupedProximityCode(_ raw: String) -> String {
        let normalized = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        return stride(from: 0, to: normalized.count, by: 4).map { offset in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            let end = normalized.index(start, offsetBy: min(4, normalized.distance(from: start, to: normalized.endIndex)))
            return String(normalized[start..<end])
        }.joined(separator: " ")
    }

    private func qrCode(for value: String) -> UIImage? {
        E2EEV2ActivationScreen.qrImage(value)
    }

    private func methodLabel(_ method: E2EEV2ApprovalMethod) -> String {
        switch method {
        case .push: return String(localized: "par notification")
        case .qr: return String(localized: "par QR")
        case .proximityCode: return String(localized: "par code")
        }
    }

    private func formattedExpiry(_ value: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? regular.date(from: value) else {
            return String(localized: "à une date inconnue")
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func statusLabel(_ status: E2EEV2RemoteDeviceStatus) -> String {
        switch status {
        case .pending: return String(localized: "En attente d’approbation")
        case .approved: return String(localized: "Approuvé")
        case .revoked: return String(localized: "Révoqué")
        }
    }

    private func statusColor(_ status: E2EEV2RemoteDeviceStatus) -> Color {
        switch status {
        case .pending: return SQColor.warning
        case .approved: return SQColor.success
        case .revoked: return SQColor.dangerInk
        }
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform {
        case "android": return "apps.iphone"
        case "web": return "globe"
        default: return "iphone"
        }
    }

    private func platformName(_ platform: String) -> String {
        switch platform {
        case "android": return "Android"
        case "web": return String(localized: "Navigateur web")
        default: return String(localized: "iPhone ou iPad")
        }
    }

    private func formattedDate(_ value: String?) -> String {
        guard let value else { return String(localized: "jamais") }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? regular.date(from: value) else { return String(localized: "date inconnue") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

@MainActor
private struct E2EEV2RotationStatusSection: View {
    @ObservedObject var runtime: E2EEV2EpochRotationRuntime

    var body: some View {
        if runtime.state.phase != .idle {
            Section {
                Text(message)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                if runtime.state.phase == .retryPending || runtime.state.phase == .needsAttention {
                    Button("Réessayer") { runtime.resume(manualRetry: true) }
                        .frame(minHeight: 48)
                }
            }
        }
    }

    private var message: String {
        switch runtime.state.phase {
        case .complete: return String(localized: "Les clés des conversations sont à jour.")
        case .waitingAuthorization: return String(localized: "Renouvellement des clés en attente de l’autorisation de sécurité.")
        case .retryPending, .needsAttention: return String(localized: "Renouvellement des clés différé. Réessaie à la reconnexion.")
        default: return String(localized: "Renouvellement des clés en attente.")
        }
    }
}

// MARK: - Récupération et reset E2EE v2

private enum E2EEV2RecoveryFlow {
    case menu
    case create
    case restore
    case reset
}

@MainActor
private final class E2EEV2RecoveryResetViewModel: ObservableObject {
    @Published private(set) var activationEnabled = false
    @Published private(set) var currentDeviceStatus: E2EEV2RemoteDeviceStatus?
    @Published private(set) var identityGeneration: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isBusy = false
    @Published var flow: E2EEV2RecoveryFlow = .menu
    @Published var errorMessage: String?
    @Published var confirmationMessage: String?
    @Published private(set) var recoveryKey: Data?
    @Published var recoveryKeyAcknowledged = false {
        // Après une bascule, la clé reste due tant que sa sauvegarde n'est pas
        // confirmée : quitter avant en crée une nouvelle au prochain passage.
        didSet { if recoveryKeyAcknowledged, recoveryKey != nil { Self.needsRecoveryAfterReset = false } }
    }
    @Published var recoveryInput = ""
    @Published private(set) var resetChallenge: E2EEV2IdentityResetEmailChallenge?
    @Published var resetCode = ""
    @Published var acknowledgesHistoryLoss = false
    @Published var acknowledgesDeviceRevocation = false
    @Published var acknowledgesRecoveryReplacement = false
    @Published private(set) var resetCompleted = false
    /// Demande faite ici, en attente de la bascule à son échéance (72 heures).
    @Published private(set) var pendingReset: E2EEV2IdentityResetStatus?
    /// Demande faite depuis un autre appareil du compte, que celui-ci peut refuser.
    @Published private(set) var resetToReview: E2EEV2PendingIdentityResetReview?
    @Published private(set) var resetNeedsRecovery = false
    private var recoveryRequestedAfterSwitch = false
    @Published var acknowledgedNoRecovery = false

    private let identityStore: E2EEV2DeviceIdentityStore
    private let lifecycle: E2EEV2DeviceLifecycleCoordinator
    private let recovery: E2EEV2RecoveryCoordinatorV2
    private let recoveryEpochs: E2EEV2RecoveryEpochCoordinator

    init(api: APIClient) {
        let identityStore = E2EEV2DeviceIdentityStore()
        self.identityStore = identityStore
        lifecycle = E2EEV2DeviceLifecycleCoordinator(api: api, identityStore: identityStore)
        recovery = E2EEV2RecoveryCoordinatorV2(api: api, identityStore: identityStore)
        recoveryEpochs = E2EEV2RecoveryEpochCoordinator(api: api, identityStore: identityStore)
    }

    var recoveryKeyText: String { recoveryKey?.base64EncodedString() ?? "" }
    var allResetAcknowledged: Bool {
        acknowledgesHistoryLoss && acknowledgesDeviceRevocation && acknowledgesRecoveryReplacement
    }
    var mustAcknowledgeSecret: Bool { recoveryKey != nil || resetNeedsRecovery }
    var mayLeaveSecret: Bool {
        !mustAcknowledgeSecret || recoveryKeyAcknowledged || acknowledgedNoRecovery
    }

    func load() async {
        isLoading = true
        activationEnabled = false
        errorMessage = nil
        defer { isLoading = false }
        // D'abord la demande faite ici : sa bascule change l'appareil local.
        let completed = await followPendingReset()
        let localDeviceId: String?
        do {
            localDeviceId = try identityStore.load()?.deviceId
        } catch {
            currentDeviceStatus = nil
            identityGeneration = nil
            errorMessage = String(localized: "L’identité locale E2EE v2 est illisible.")
            return
        }
        guard let localDeviceId else {
            currentDeviceStatus = nil
            identityGeneration = nil
            return
        }
        switch await lifecycle.listDeviceInventory() {
        case .success(let inventory):
            activationEnabled = inventory.activationEnabled
            identityGeneration = inventory.identity?.generation
            currentDeviceStatus = inventory.devices.first {
                $0.descriptor.deviceId == localDeviceId
            }?.status
            resetToReview = activationEnabled && currentDeviceStatus == .approved
                ? await lifecycle.pendingIdentityResetToReview() : nil
            if completed { await createRecoveryAfterSwitch() }
            if !completed, !resetNeedsRecovery, Self.needsRecoveryAfterReset {
                // Bascule faite lors d'un lancement précédent, clé jamais créée.
                flow = .reset
                resetCompleted = true
                resetNeedsRecovery = true
            }
        case .failed(let failure):
            currentDeviceStatus = nil
            identityGeneration = nil
            errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible de charger l’état de récupération."))
        }
    }

    func changeFlow(_ next: E2EEV2RecoveryFlow) {
        guard !isBusy, mayLeaveSecret else { return }
        if flow == .reset, next != .reset, !resetCompleted, pendingReset == nil {
            _ = lifecycle.discardIdentityResetCandidate()
        }
        wipeRecoveryKey()
        resetTransientState()
        flow = next
    }

    func createRecoveryKey() async {
        guard activationEnabled, currentDeviceStatus == .approved, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }
        await createRecoveryMaterial()
    }

    func restoreWithRecoveryKey() async {
        guard activationEnabled, !isBusy, var key = Self.strictRecoveryKey(recoveryInput) else {
            if !recoveryInput.isEmpty {
                errorMessage = String(localized: "Clé invalide : saisis la clé de récupération complète.")
            }
            return
        }
        defer { key.resetBytes(in: 0..<key.count) }
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }

        if currentDeviceStatus == .pending {
            switch await recovery.recover(recoveryKey: key) {
            case .success:
                await load()
            case .failed(let failure):
                errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible d’approuver cet appareil avec cette clé."))
                return
            }
        } else if currentDeviceStatus != .approved {
            errorMessage = String(localized: "Cet appareil ne peut pas utiliser la récupération.")
            return
        }

        let bundle: E2EEV2RecoveryBundleV2
        switch await recovery.loadActiveBundle() {
        case .success(let activeBundle):
            bundle = activeBundle
        case .failed(let failure):
            errorMessage = Self.message(for: failure, fallback: String(localized: "Le bundle de récupération actif est indisponible."))
            return
        }
        switch await recoveryEpochs.restoreAll(bundle: bundle, recoveryKey: key) {
        case .success(let summary):
            recoveryInput = ""
            confirmationMessage = String(localized: "Restauration terminée : \(summary.restoredEpochCount) clé(s) restaurée(s), \(summary.missingEpochCount) indisponible(s).")
        case .failure(let failure):
            errorMessage = Self.message(for: failure, fallback: String(localized: "La restauration de l’historique a échoué."))
        }
    }

    func requestResetEmail() async {
        guard activationEnabled, !isBusy, allResetAcknowledged, pendingReset == nil,
              let generation = identityGeneration else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        switch lifecycle.prepareIdentityReset(label: UIDevice.current.model) {
        case .success:
            break
        case .failed(let failure):
            errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible de préparer la nouvelle identité."))
            return
        }
        switch await lifecycle.requestIdentityResetEmailChallenge(expectedGeneration: generation) {
        case .success(let challenge):
            resetChallenge = challenge
        case .failed(let failure):
            _ = lifecycle.discardIdentityResetCandidate()
            errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible d’envoyer le code de réinitialisation."))
        }
    }

    func confirmReset() async {
        guard activationEnabled, !isBusy, let generation = identityGeneration,
              let challenge = resetChallenge,
              resetCode.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else { return }
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }
        switch await lifecycle.resetIdentity(
            expectedGeneration: generation,
            reauthentication: .email(challengeId: challenge.challengeId, code: resetCode)
        ) {
        case .success(let status):
            resetChallenge = nil
            resetCode = ""
            if status.state == .pending {
                pendingReset = status
                confirmationMessage = String(localized: "Demande enregistrée. Ton identité sera remplacée à l’échéance, sauf si l’un de tes appareils s’y oppose.")
            } else if apply(status) {
                // Une demande antérieure vient de basculer : l'appareil local a changé.
                await load()
                await createRecoveryAfterSwitch()
            }
        case .failed(let failure):
            errorMessage = Self.message(
                for: failure,
                fallback: String(localized: "La réinitialisation a échoué ; l’identité actuelle reste inchangée.")
            )
        }
    }

    func checkPendingReset() async {
        guard !isBusy, pendingReset != nil else { return }
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }
        if await followPendingReset() {
            await load()
            await createRecoveryAfterSwitch()
        }
    }

    /// Refuse, depuis cet appareil, la réinitialisation demandée ailleurs.
    func objectToReset() async {
        guard activationEnabled, !isBusy, let review = resetToReview else { return }
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }
        switch await lifecycle.objectIdentityReset(review) {
        case .success:
            resetToReview = nil
            confirmationMessage = String(localized: "Réinitialisation refusée. Ton identité actuelle est conservée.")
        case .failed(let failure):
            // L'issue déjà acquise (`details.status`) : une opposition dont la
            // réponse s'est perdue a réussi ; une bascule qui a gagné la course
            // révoque l'appareil qui s'oppose (403).
            let outcome: String? = if case .string(let value)? = failure.details?["status"] { value } else { nil }
            if failure.code == "E2EE_IDENTITY_RESET_NOT_PENDING", outcome == "objected" {
                resetToReview = nil
                confirmationMessage = String(localized: "Réinitialisation refusée. Ton identité actuelle est conservée.")
            } else if failure.code == "E2EE_IDENTITY_RESET_NOT_PENDING", outcome == "aborted" {
                resetToReview = nil
                confirmationMessage = String(localized: "La réinitialisation a été annulée, car l’état du compte a changé entre-temps.")
            } else if failure.code == "E2EE_IDENTITY_RESET_NOT_PENDING" || failure.code == "E2EE_DEVICE_REVOKED"
                        || failure.message == "e2ee-identity-reset-due" {
                resetToReview = nil
                errorMessage = String(localized: "Trop tard : l’échéance de cette réinitialisation est passée.")
            } else {
                errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible de refuser cette réinitialisation."))
            }
        }
    }

    /// Suit la demande faite ici. `true` : la bascule vient d'avoir lieu, la
    /// nouvelle clé de récupération reste à créer.
    private func followPendingReset() async -> Bool {
        switch await lifecycle.refreshIdentityReset() {
        case nil:
            pendingReset = nil
            return false
        case .success(let status)?:
            return apply(status)
        case .failed(let failure)?:
            errorMessage = Self.message(
                for: failure,
                fallback: failure.message == "e2ee-identity-reset-local-activation-pending"
                    ? String(localized: "Identité réinitialisée côté compte. La configuration locale reste en attente.")
                    : String(localized: "Impossible de vérifier la réinitialisation en attente.")
            )
            return false
        }
    }

    /// Montre l'état d'une demande faite ici. `true` : la bascule a eu lieu.
    private func apply(_ status: E2EEV2IdentityResetStatus) -> Bool {
            switch status.state {
            case .pending:
                pendingReset = status
                flow = .reset
                return false
            case .completed:
                pendingReset = nil
                flow = .reset
                resetCompleted = true
                resetNeedsRecovery = true
                Self.needsRecoveryAfterReset = true
                confirmationMessage = String(localized: "Identité réinitialisée. Création immédiate d’une nouvelle clé de récupération.")
                return true
            case .objected:
                pendingReset = nil
                errorMessage = String(localized: "La réinitialisation a été refusée depuis un autre de tes appareils. L’identité actuelle reste inchangée.")
                return false
            case .aborted:
                pendingReset = nil
                errorMessage = String(localized: "La réinitialisation a été annulée, car l’état du compte a changé entre-temps.")
                return false
            }
    }

    func retryRecoveryAfterReset() async {
        guard resetNeedsRecovery, activationEnabled, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        await createRecoveryMaterial()
    }

    func wipeTransientSecrets() {
        if resetNeedsRecovery, acknowledgedNoRecovery { Self.needsRecoveryAfterReset = false }
        wipeRecoveryKey()
        recoveryInput = ""
        resetCode = ""
        if flow == .reset, !resetCompleted, pendingReset == nil {
            _ = lifecycle.discardIdentityResetCandidate()
        }
    }

    /// Une seule clé par bascule, même si deux lectures la constatent.
    private func createRecoveryAfterSwitch() async {
        guard !recoveryRequestedAfterSwitch else { return }
        recoveryRequestedAfterSwitch = true
        await createRecoveryMaterial()
    }

    /// Après une bascule, la clé de récupération reste due d'un lancement à
    /// l'autre, jusqu'à sa création ou au renoncement explicite.
    private static var needsRecoveryAfterReset: Bool {
        get { UserDefaults.standard.bool(forKey: needsRecoveryKey) }
        set {
            if newValue { UserDefaults.standard.set(true, forKey: needsRecoveryKey) }
            else { UserDefaults.standard.removeObject(forKey: needsRecoveryKey) }
        }
    }

    private static var needsRecoveryKey: String {
        "SignalQuest.E2EE.resetNeedsRecovery.v1:" + LocalAccountScope.storageNamespace
    }

    private func createRecoveryMaterial() async {
        var material: E2EEV2RecoveryMaterialV2
        switch await recovery.createAndUploadBundle() {
        case .success(let created):
            material = created
        case .failed(let failure):
            resetNeedsRecovery = resetCompleted
            errorMessage = Self.message(for: failure, fallback: String(localized: "Impossible de créer la clé de récupération."))
            return
        }

        wipeRecoveryKey()
        recoveryKey = material.recoveryKey
        let ownBundle = material.bundle
        material.zeroize()
        recoveryKeyAcknowledged = false
        acknowledgedNoRecovery = false
        resetNeedsRecovery = false

        switch await recoveryEpochs.backfillAll(ownBundle: ownBundle) {
        case .success(let summary):
            confirmationMessage = String(localized: "Clé créée : \(summary.backedUpEpochCount) clé(s) d’historique sauvegardée(s), \(summary.missingParticipantUserIds.count) participant(s) sans clé disponible.")
        case .failure(let failure):
            confirmationMessage = String(localized: "La clé est créée, mais la sauvegarde de l’historique reste partielle.")
            errorMessage = Self.message(for: failure, fallback: String(localized: "Toutes les clés d’historique n’ont pas pu être sauvegardées."))
        }
    }

    private func wipeRecoveryKey() {
        recoveryKey?.resetBytes(in: 0..<(recoveryKey?.count ?? 0))
        recoveryKey = nil
    }

    private func resetTransientState() {
        recoveryKeyAcknowledged = false
        recoveryInput = ""
        resetChallenge = nil
        resetCode = ""
        acknowledgesHistoryLoss = false
        acknowledgesDeviceRevocation = false
        acknowledgesRecoveryReplacement = false
        resetCompleted = false
        resetNeedsRecovery = false
        acknowledgedNoRecovery = false
        errorMessage = nil
        confirmationMessage = nil
    }

    private static func strictRecoveryKey(_ value: String) -> Data? {
        let normalized = value.filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: normalized),
              decoded.count == 32,
              decoded.base64EncodedString() == normalized else { return nil }
        return decoded
    }

    private static func message(
        for failure: E2EEV2TransportFailure,
        fallback: String
    ) -> String {
        switch failure.kind {
        case .authentication:
            return String(localized: "La session a changé. Reconnecte-toi puis réessaie.")
        case .retryable:
            return String(localized: "Le service est temporairement indisponible. Réessaie.")
        case .activationBlocked:
            return String(localized: "Ces actions restent verrouillées jusqu’à la fin de la revue de sécurité.")
        case .permanent, .localState:
            return fallback
        }
    }
}

struct E2EEV2RecoveryResetView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: E2EEV2RecoveryResetViewModel
    @State private var revealRecoveryInput = false
    /// Présentée en feuille : le bouton de fermeture, retenu comme le retour
    /// tant que la clé affichée n'est pas sauvegardée.
    private let onClose: (() -> Void)?

    init(api: APIClient, onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: E2EEV2RecoveryResetViewModel(api: api))
        self.onClose = onClose
    }

    var body: some View {
        List {
            statusSection
            resetReviewSection
            E2EEV2RotationStatusSection(runtime: services.epochRotations)
                .listRowBackground(SQColor.surface)

            switch model.flow {
            case .menu:
                menuSection
            case .create:
                createSection
            case .restore:
                restoreSection
            case .reset:
                resetSection
            }

            if model.isBusy {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Opération sécurisée en cours…")
                        Spacer()
                    }
                    .frame(minHeight: 64)
                }
                .listRowBackground(SQColor.surface)
            }

            if let message = model.confirmationMessage {
                Section {
                    Label(message, systemImage: "checkmark.shield.fill")
                        .foregroundStyle(SQColor.success)
                        .accessibilityLabel("Confirmation. \(message)")
                }
                .listRowBackground(SQColor.surface)
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.dangerInk)
                        .accessibilityLabel("Erreur. \(error)")
                }
                .listRowBackground(SQColor.surface)
            }

            recoveryKeySection
        }
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Récupération E2EE")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!model.mayLeaveSecret)
        .interactiveDismissDisabled(!model.mayLeaveSecret)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK", action: onClose)
                        .disabled(!model.mayLeaveSecret)
                }
            }
        }
        .task { await model.load() }
        .onDisappear { model.wipeTransientSecrets() }
        // La clé de récupération peut être affichée en clair. Masquer aussi
        // cette vue dans l'aperçu système, même si le verrou local est désactivé.
        .background(AppSensitiveContentMarker())
    }

    @ViewBuilder
    private var resetReviewSection: some View {
        if let review = model.resetToReview {
            Section {
                Label("Réinitialisation demandée", systemImage: "exclamationmark.shield.fill")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.warning)
                Text("Un appareil a demandé à remplacer l’identité de chiffrement de ton compte. Sans refus, ce remplacement aura lieu le \(Self.resetDate(review.document.effectiveAtMs)) et tous tes appareils actuels seront révoqués. Si ce n’est pas toi, refuse-la.")
                Button(role: .destructive) {
                    Task { await model.objectToReset() }
                } label: {
                    Label("Refuser cette réinitialisation", systemImage: "hand.raised.fill")
                        .frame(minHeight: 48)
                }
                .disabled(!model.activationEnabled || model.isBusy)
            } header: {
                Text("Sécurité du compte")
            }
            .listRowBackground(SQColor.surface)
        }
    }

    private static func resetDate(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000).formatted(date: .long, time: .shortened)
    }

    private var statusSection: some View {
        Section {
            if model.isLoading {
                ProgressView("Chargement de l’état…")
                    .frame(minHeight: 48)
            } else if !model.activationEnabled {
                Label {
                    Text("Création, récupération et reset restent désactivés jusqu’à la validation de la revue cryptographique externe.")
                } icon: {
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(SQColor.warning)
                }
            } else {
                Label("Les actions de récupération sont disponibles.", systemImage: "lock.shield.fill")
                    .foregroundStyle(SQColor.success)
            }
        } header: {
            Text("État")
        }
        .listRowBackground(SQColor.surface)
    }

    private var menuSection: some View {
        Section {
            if model.currentDeviceStatus == .approved {
                Button {
                    model.changeFlow(.create)
                } label: {
                    Label("Créer ou remplacer la clé", systemImage: "key.fill")
                        .frame(minHeight: 48)
                }
                .disabled(!model.activationEnabled || model.isBusy)
            }
            if model.currentDeviceStatus == .pending || model.currentDeviceStatus == .approved {
                Button {
                    model.changeFlow(.restore)
                } label: {
                    Label(
                        model.currentDeviceStatus == .pending ? String(localized: "Approuver avec ma clé") : String(localized: "Restaurer l’historique"),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .frame(minHeight: 48)
                }
                .disabled(!model.activationEnabled || model.isBusy)
            }
            if model.identityGeneration != nil {
                Button(role: .destructive) {
                    model.changeFlow(.reset)
                } label: {
                    Label("Réinitialiser l’identité", systemImage: "lock.rotation")
                        .frame(minHeight: 48)
                }
                .disabled(!model.activationEnabled || model.isBusy)
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("La clé de récupération est créée sur cet appareil et n’est jamais conservée en clair par SignalQuest.")
        }
        .listRowBackground(SQColor.surface)
    }

    private var createSection: some View {
        Section {
            Text("Une nouvelle clé aléatoire de 256 bits remplacera l’ancienne. Elle ne sera affichée qu’une fois.")
                .foregroundStyle(SQColor.labelSecondary)
            if model.recoveryKey == nil {
                Button {
                    Task { await model.createRecoveryKey() }
                } label: {
                    Label("Créer une nouvelle clé", systemImage: "key.fill")
                        .frame(minHeight: 48)
                }
                .disabled(!model.activationEnabled || model.isBusy)
            }
            flowBackButton
        } header: {
            Text("Nouvelle clé")
        }
        .listRowBackground(SQColor.surface)
    }

    private var restoreSection: some View {
        Section {
            Text(model.currentDeviceStatus == .pending
                 ? "La clé approuvera cet appareil puis restaurera les clés d’historique disponibles."
                 : "La clé restaure les clés d’historique disponibles sur cet appareil approuvé.")
                .foregroundStyle(SQColor.labelSecondary)
            Group {
                if revealRecoveryInput {
                    TextField("Clé Base64", text: $model.recoveryInput, axis: .vertical)
                } else {
                    SecureField("Clé Base64", text: $model.recoveryInput)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            .accessibilityLabel("Clé de récupération")
            .privacySensitive()
            Button {
                revealRecoveryInput.toggle()
            } label: {
                Label(revealRecoveryInput ? String(localized: "Masquer la clé") : String(localized: "Afficher la clé"),
                      systemImage: revealRecoveryInput ? "eye.slash" : "eye")
                    .frame(minHeight: 48)
            }
            .disabled(model.isBusy)
            Button {
                Task { await model.restoreWithRecoveryKey() }
            } label: {
                Label("Vérifier et restaurer", systemImage: "lock.open.rotation")
                    .frame(minHeight: 48)
            }
            .disabled(!model.activationEnabled || model.isBusy || model.recoveryInput.isEmpty)
            flowBackButton
        } header: {
            Text("Restaurer")
        }
        .listRowBackground(SQColor.surface)
    }

    private var resetSection: some View {
        Section {
            Label("Action irréversible", systemImage: "exclamationmark.octagon.fill")
                .font(SQType.heading)
                .foregroundStyle(SQColor.dangerInk)
            Text("Tous les appareils actuels seront révoqués. L’historique non récupéré sera définitivement perdu.")
                .foregroundStyle(SQColor.dangerInk)

            if let pending = model.pendingReset {
                Label("Réinitialisation en attente", systemImage: "hourglass")
                    .font(SQType.heading)
                Text("Ton identité sera remplacée le \(Self.resetDate(pending.effectiveAtMs)). D’ici là, chacun de tes appareils actuels peut s’y opposer.")
                    .foregroundStyle(SQColor.labelSecondary)
                Button {
                    Task { await model.checkPendingReset() }
                } label: {
                    Label("Vérifier l’état", systemImage: "arrow.clockwise")
                        .frame(minHeight: 48)
                }
                .disabled(model.isBusy)
            } else if !model.resetCompleted && model.resetChallenge == nil {
                resetAcknowledgement(
                    "Je comprends que l’historique non récupéré pourra être perdu définitivement.",
                    isOn: $model.acknowledgesHistoryLoss
                )
                resetAcknowledgement(
                    "Je comprends que tous les appareils actuellement approuvés seront révoqués.",
                    isOn: $model.acknowledgesDeviceRevocation
                )
                resetAcknowledgement(
                    "Je comprends que l’ancienne clé sera remplacée et ne fonctionnera plus.",
                    isOn: $model.acknowledgesRecoveryReplacement
                )
                Button(role: .destructive) {
                    Task { await model.requestResetEmail() }
                } label: {
                    Label("Envoyer le code de confirmation", systemImage: "envelope.badge.shield.half.filled")
                        .frame(minHeight: 48)
                }
                .disabled(!model.activationEnabled || model.isBusy || !model.allResetAcknowledged)
            } else if let challenge = model.resetChallenge {
                Text("Code envoyé à \(challenge.maskedEmail)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                TextField("Code à 6 chiffres", text: $model.resetCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .privacySensitive()
                    .onChangeCompat(of: model.resetCode) { _, value in
                        model.resetCode = String(value.filter(\.isNumber).prefix(6))
                    }
                Button(role: .destructive) {
                    Task { await model.confirmReset() }
                } label: {
                    Label("Réinitialiser définitivement", systemImage: "lock.rotation")
                        .frame(minHeight: 48)
                }
                .disabled(!model.activationEnabled || model.isBusy || model.resetCode.count != 6)
            }

            if model.resetNeedsRecovery && model.recoveryKey == nil {
                Label("L’identité est réinitialisée, mais aucune nouvelle clé n’a encore été créée.",
                      systemImage: "key.slash.fill")
                    .foregroundStyle(SQColor.dangerInk)
                Button {
                    Task { await model.retryRecoveryAfterReset() }
                } label: {
                    Label("Réessayer de créer la clé", systemImage: "arrow.clockwise")
                        .frame(minHeight: 48)
                }
                .disabled(!model.activationEnabled || model.isBusy)
                Toggle("Je quitte en sachant que l’historique sera irrécupérable sans clé", isOn: $model.acknowledgedNoRecovery)
                    .tint(SQColor.danger)
                    .frame(minHeight: 48)
            }

            if !model.mustAcknowledgeSecret {
                flowBackButton
            }
        } header: {
            Text("Perte totale d’accès")
        }
        .listRowBackground(SQColor.surface)
    }

    @ViewBuilder
    private var recoveryKeySection: some View {
        if let key = model.recoveryKey {
            Section {
                Text(key.base64EncodedString())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .privacySensitive()
                    .accessibilityLabel("Clé de récupération de 256 bits affichée. Utilise le bouton Copier pour la sauvegarder.")
                Button {
                    UIPasteboard.general.setItems(
                        [["public.utf8-plain-text": model.recoveryKeyText]],
                        options: [
                            .localOnly: true,
                            .expirationDate: Date().addingTimeInterval(60),
                        ]
                    )
                    model.confirmationMessage = String(localized: "Clé copiée localement. Le presse-papiers l’effacera après 60 secondes.")
                } label: {
                    Label("Copier pendant 60 secondes", systemImage: "doc.on.doc")
                        .frame(minHeight: 48)
                }
                Toggle("J’ai sauvegardé cette clé dans un endroit sûr", isOn: $model.recoveryKeyAcknowledged)
                    .tint(SQColor.success)
                    .frame(minHeight: 48)
                if model.recoveryKeyAcknowledged {
                    Button {
                        model.wipeTransientSecrets()
                        model.flow = .menu
                    } label: {
                        Label("Effacer la clé de cet écran", systemImage: "eye.slash.fill")
                            .frame(minHeight: 48)
                    }
                }
            } header: {
                Text("À sauvegarder maintenant")
            } footer: {
                Text("SignalQuest ne pourra pas réafficher cette clé. Sans appareil approuvé ni cette clé, l’ancien historique chiffré sera perdu.")
            }
            .listRowBackground(SQColor.surface)
        }
    }

    private var flowBackButton: some View {
        Button("Retour aux actions") {
            model.changeFlow(.menu)
        }
        .frame(minHeight: 48)
        .disabled(model.isBusy || !model.mayLeaveSecret)
    }

    private func resetAcknowledgement(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .tint(SQColor.danger)
            .frame(minHeight: 48)
            .disabled(model.isBusy)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isExporting = false
    @Published var deletionPreview: AccountDeletionPreview?
    @Published var isDeletionPreviewLoading = false
    @Published var deletionError: String?
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

    func deleteAccount(using proof: AccountDeletionProof) async -> Bool {
        deletionError = nil
        guard let expectedSession = LocalAccountScope.sessionSnapshot() else { return false }
        do {
            let receipt = try await userService.deleteAccount(using: proof, expectedSession: expectedSession)
            guard receipt.success else { throw APIError.transport("account-deletion-not-confirmed") }
            await authService.eraseDeletedAccountVault(ownerScopeId: expectedSession.ownerScopeId)
            deletedOwnerScopeId = expectedSession.ownerScopeId
            return true
        } catch {
            if !error.isCancellation { deletionError = error.userFacingMessage }
            return false
        }
    }
}

/// Écrans ouverts depuis les Réglages, poussés par valeur.
private enum SettingsDestination: Hashable {
    case password, devices, privacy, notifications, glossary, bugs
}

struct SettingsView: View {
    @StateObject private var model: SettingsViewModel
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var services: AppServices
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
        case .devices: E2EEV2TrustedDevicesView(api: services.api)
        case .privacy: PrivacySettingsView(service: services.privacy)
        case .notifications: NotificationSettingsView(userService: services.users)
        case .glossary: SQGlossaryView()
        case .bugs: BugReportsListView()
        }
    }

    var body: some View {
        Form {
            Section {
                SQSettingsHeader(title: "Réglages", backIdentifier: "settings.back")
            }
            // Marge basse : la cellule, même transparente, garde ses coins
            // arrondis, qui rogneraient le bas du texte.
            .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.md, trailing: 0))
            .listRowBackground(Color.clear)

            Section {
                NavigationLink(value: SettingsDestination.password) {
                    SQSettingsRowLabel("Mot de passe", systemImage: "key")
                }
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
                    NavigationLink(value: SettingsDestination.devices) {
                        SQSettingsRowLabel("Appareils", systemImage: "lock.shield")
                    }
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
                NavigationLink(value: SettingsDestination.privacy) {
                    SQSettingsRowLabel("Confidentialité", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("settings.privacy")
                // Notifications, appels et antennes suivies : un écran à part,
                // qui enregistre chaque réglage au geste (TRX-03) et que le lien
                // « Réglages de notifications » d'iOS ouvre directement (TRX-21).
                NavigationLink(value: SettingsDestination.notifications) {
                    SQSettingsRowLabel("Notifications", systemImage: "bell")
                }
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
                NavigationLink(value: SettingsDestination.glossary) {
                    SQSettingsRowLabel("Aide et glossaire", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("settings.glossary")
                NavigationLink(value: SettingsDestination.bugs) {
                    SQSettingsRowLabel("Bugs et idées", systemImage: "ladybug",
                                       subtitle: String(localized: "Signaler un problème, proposer une amélioration"))
                }
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
        // Par valeur, comme le Profil : la destination n'est plus recréée à chaque rendu (iOS 16).
        .navigationDestination(for: SettingsDestination.self) { destination(for: $0) }
        .trustedDevicesDestinations(api: services.api)
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
                    .accessibilityIdentifier("settings.label.\(title)")
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
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
        let current = model.preferencesLoaded ? model.preferences.unitsSystem : unitsStore.system
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
