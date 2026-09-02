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
    @Published private(set) var currentDeviceId: String?
    @Published private(set) var activationEnabled = false
    @Published private(set) var identityGeneration: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isActing = false
    @Published var errorMessage: String?
    @Published var confirmationMessage: String?
    @Published var approvalErrorMessage: String?
    @Published var generatedApproval: E2EEV2Approval?
    @Published var approvalDetail: E2EEV2ApprovalDetail?
    @Published var bootstrapChallenge: E2EEV2BootstrapEmailChallenge?

    private let identityStore: E2EEV2DeviceIdentityStore
    private let enrollment: E2EEV2DeviceEnrollmentCoordinator
    private let lifecycle: E2EEV2DeviceLifecycleCoordinator

    init(api: APIClient) {
        let identityStore = E2EEV2DeviceIdentityStore()
        self.identityStore = identityStore
        enrollment = E2EEV2DeviceEnrollmentCoordinator(api: api, identityStore: identityStore)
        lifecycle = E2EEV2DeviceLifecycleCoordinator(api: api, identityStore: identityStore)
    }

    var hasLocalIdentity: Bool { currentDeviceId != nil }

    var currentDeviceCanRevoke: Bool {
        devices.contains {
            $0.descriptor.deviceId == currentDeviceId && $0.status == .approved
        }
    }

    var currentDevice: E2EEV2RemoteDevice? {
        devices.first { $0.descriptor.deviceId == currentDeviceId }
    }

    var identityEstablished: Bool { identityGeneration != nil }

    func load() async {
        isLoading = true
        activationEnabled = false
        errorMessage = nil
        defer { isLoading = false }
        do {
            currentDeviceId = try identityStore.load()?.deviceId
        } catch {
            currentDeviceId = nil
            devices = []
            errorMessage = "L’identité locale E2EE v2 est illisible. Elle n’a pas été remplacée automatiquement."
            return
        }
        guard currentDeviceId != nil else {
            devices = []
            activationEnabled = false
            identityGeneration = nil
            return
        }
        switch await lifecycle.listDeviceInventory() {
        case .success(let inventory):
            devices = inventory.devices
            activationEnabled = inventory.activationEnabled
            identityGeneration = inventory.identity?.generation
            if inventory.activationEnabled, currentDeviceCanRevoke {
                E2EEV2NotificationContextEvents.requestRefresh(.identity)
            }
        case .failed(let failure):
            devices = []
            errorMessage = Self.message(for: failure, fallback: "Impossible de charger le registre E2EE v2.")
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
                ? "Cet appareil est déjà approuvé."
                : "Appareil préparé. Une approbation reste nécessaire."
            await load()
        case .failed(let failure):
            errorMessage = Self.message(for: failure, fallback: "Impossible de préparer cet appareil.")
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
            confirmationMessage = "Appareil révoqué. Les conversations concernées devront renouveler leurs clés."
            await load()
        case .failed(let failure):
            errorMessage = Self.message(for: failure, fallback: "Impossible de révoquer cet appareil.")
        }
    }

    func resetApproval() {
        approvalErrorMessage = nil
        generatedApproval = nil
        approvalDetail = nil
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
            approvalErrorMessage = "Impossible de créer la demande d’approbation. Réessayez."
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
        case .failed:
            approvalErrorMessage = "Impossible d’envoyer le code de vérification."
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
            confirmationMessage = "Premier appareil approuvé."
            await load()
        case .failed:
            approvalErrorMessage = "Le code est invalide, expiré ou ne correspond plus à cet appareil."
        }
    }

    func resolveApproval(_ rawInput: String) async {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isActing, !input.isEmpty, currentDeviceCanRevoke else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        let result: E2EEV2DeviceLifecycleResult<E2EEV2ApprovalDetail>
        if input.hasPrefix("SQE2EE2|") {
            result = await lifecycle.loadQRApproval(input)
        } else {
            result = await lifecycle.resolveProximityCode(input)
        }
        switch result {
        case .success(let detail):
            approvalDetail = detail
        case .failed:
            approvalDetail = nil
            approvalErrorMessage = "Demande invalide, expirée ou incohérente avec le serveur."
        }
    }

    func loadPushApproval(_ approvalId: String) async {
        guard !isActing, currentDeviceCanRevoke else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        switch await lifecycle.loadApproval(approvalId) {
        case .success(let detail)
            where detail.approval.method == .push && detail.approval.status == .pending:
            approvalDetail = detail
        case .success, .failed:
            approvalDetail = nil
            approvalErrorMessage = "Cette demande par notification est invalide ou a expiré."
        }
    }

    func approveResolvedDevice() async {
        guard !isActing, currentDeviceCanRevoke, let detail = approvalDetail else { return }
        isActing = true
        approvalErrorMessage = nil
        defer { isActing = false }
        switch await lifecycle.approve(detail) {
        case .success:
            resetApproval()
            confirmationMessage = "Appareil approuvé. La rotation de clés requise a été enregistrée."
            await load()
        case .failed:
            approvalErrorMessage = "Impossible d’approuver cet appareil. Actualisez puis réessayez."
        }
    }

    private static func message(
        for failure: E2EEV2TransportFailure,
        fallback: String
    ) -> String {
        switch failure.kind {
        case .authentication:
            return "La session a changé. Reconnectez-vous avant de gérer les appareils."
        case .retryable:
            return "Le service est temporairement indisponible. Réessayez."
        case .activationBlocked:
            return "La gestion E2EE v2 reste verrouillée jusqu’à la fin de la revue de sécurité."
        case .permanent, .localState:
            return fallback
        }
    }
}

struct E2EEV2TrustedDevicesView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: E2EEV2TrustedDevicesViewModel
    @State private var deviceToRevoke: E2EEV2RemoteDevice?
    @State private var approvalInput = ""
    @State private var initialApprovalConsumed = false
    private let api: APIClient
    private let initialApprovalId: String?

    init(api: APIClient, initialApprovalId: String? = nil) {
        _model = StateObject(wrappedValue: E2EEV2TrustedDevicesViewModel(api: api))
        self.api = api
        self.initialApprovalId = initialApprovalId
    }

    var body: some View {
        List {
            Section {
                if !model.hasLocalIdentity && !model.isLoading {
                    Label("Cet appareil n’a pas encore d’identité locale E2EE v2.", systemImage: "iphone.gen3.badge.play")
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
                        Text("Le registre v2 est consultable, mais aucun message n’est présenté comme E2EE v2 avant la fin de la revue de sécurité externe.")
                            .font(SQType.body)
                    } icon: {
                        Image(systemName: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(SQColor.warning)
                    }
                } else {
                    Label("Le chiffrement E2EE v2 est activé pour ce compte.", systemImage: "lock.shield.fill")
                        .foregroundStyle(SQColor.success)
                }
                if let generation = model.identityGeneration {
                    Text("Identité du compte · génération \(generation)")
                        .font(.caption.monospaced())
                        .foregroundStyle(SQColor.labelSecondary)
                }
            } header: {
                Text("État")
            }

            E2EEV2RotationStatusSection(runtime: services.epochRotations)

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
                    Text("Choisissez une preuve temporaire à transmettre à un appareil déjà approuvé.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                    if let approval = model.generatedApproval {
                        generatedApprovalView(approval)
                        Button("Choisir une autre méthode") {
                            model.resetApproval()
                        }
                        .frame(minHeight: 48)
                    } else {
                        Button {
                            Task { await model.requestApproval(.push) }
                        } label: {
                            Label("Envoyer une notification", systemImage: "bell.badge.fill")
                                .frame(minHeight: 48)
                        }
                        Button {
                            Task { await model.requestApproval(.qr) }
                        } label: {
                            Label("Afficher un QR temporaire", systemImage: "qrcode")
                                .frame(minHeight: 48)
                        }
                        Button {
                            Task { await model.requestApproval(.proximityCode) }
                        } label: {
                            Label("Afficher un code de proximité", systemImage: "number.square.fill")
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
                    Text("Collez le contenu du QR SignalQuest ou saisissez le code affiché sur le nouvel appareil.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                    if let detail = model.approvalDetail {
                        approvalPreview(detail)
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
                        TextField("QR SignalQuest ou code de proximité", text: $approvalInput, axis: .vertical)
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
                    Text("Approuver un nouvel appareil")
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
                    NavigationLink {
                        E2EEV2RecoveryResetView(api: api)
                    } label: {
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
                        .foregroundStyle(SQColor.danger)
                    Button("Réessayer") { Task { await model.load() } }
                        .frame(minHeight: 48)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SQColor.bg.ignoresSafeArea())
        .tint(SQColor.brandRed)
        .navigationTitle("Appareils E2EE v2")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task {
            await model.load()
            if !initialApprovalConsumed,
               let initialApprovalId,
               model.currentDeviceCanRevoke {
                initialApprovalConsumed = true
                await model.loadPushApproval(initialApprovalId)
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
        .alert("Appareils E2EE v2", isPresented: Binding(
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
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: platformIcon(device.descriptor.platform))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 40, height: 40)
                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(device.descriptor.label ?? platformName(device.descriptor.platform))
                        .font(SQType.heading)
                    if isCurrent {
                        Text("Cet appareil")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(SQColor.accentSoft, in: Capsule())
                    }
                }
                Text(statusLabel(device.status))
                    .font(.caption.bold())
                    .foregroundStyle(statusColor(device.status))
                Text("Ajouté \(formattedDate(device.createdAt)) · vu \(formattedDate(device.lastSeenAt))")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                Text("Clé de signature · \(device.signingKeyFingerprint)")
                    .font(.caption2.monospaced())
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
                .accessibilityLabel("Révoquer \(device.descriptor.label ?? platformName(device.descriptor.platform))")
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
                .foregroundStyle(SQColor.danger)
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
                    Label("Code indisponible. Créez une nouvelle demande.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.danger)
                }
            case .qr:
                if let payload = try? E2EEV2DeviceApprovalContract.encodeQRPayload(approval),
                   let image = qrCode(for: payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .padding(SQSpace.md)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("QR temporaire d’approbation SignalQuest")
                    Text("Si la caméra n’est pas disponible, copiez le contenu du QR depuis l’autre appareil.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                } else {
                    Label("QR indisponible. Créez une nouvelle demande.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.danger)
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
            Label(
                detail.pendingDevice.descriptor.label ?? platformName(detail.pendingDevice.descriptor.platform),
                systemImage: platformIcon(detail.pendingDevice.descriptor.platform)
            )
            .font(SQType.heading)
            Text("Plateforme · \(platformName(detail.pendingDevice.descriptor.platform))")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Text("Clé de signature · \(detail.pendingDevice.signingKeyFingerprint)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Comparez cette empreinte sur le nouvel appareil avant d’approuver.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.warning)
            Text("Demande \(detail.approval.method.rawValue) · expire \(formattedExpiry(detail.approval.expiresAt))")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
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
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    private func formattedExpiry(_ value: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? regular.date(from: value) else {
            return "à une date inconnue"
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func statusLabel(_ status: E2EEV2RemoteDeviceStatus) -> String {
        switch status {
        case .pending: return "En attente d’approbation"
        case .approved: return "Approuvé"
        case .revoked: return "Révoqué"
        }
    }

    private func statusColor(_ status: E2EEV2RemoteDeviceStatus) -> Color {
        switch status {
        case .pending: return SQColor.warning
        case .approved: return SQColor.success
        case .revoked: return SQColor.danger
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
        case "web": return "Navigateur web"
        default: return "iPhone ou iPad"
        }
    }

    private func formattedDate(_ value: String?) -> String {
        guard let value else { return "jamais" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? regular.date(from: value) else { return "date inconnue" }
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
        case .retryPending, .needsAttention: return String(localized: "Renouvellement des clés différé. Réessayez à la reconnexion.")
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
    @Published var recoveryKeyAcknowledged = false
    @Published var recoveryInput = ""
    @Published private(set) var resetChallenge: E2EEV2IdentityResetEmailChallenge?
    @Published var resetCode = ""
    @Published var acknowledgesHistoryLoss = false
    @Published var acknowledgesDeviceRevocation = false
    @Published var acknowledgesRecoveryReplacement = false
    @Published private(set) var resetCompleted = false
    @Published private(set) var resetNeedsRecovery = false
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
        let localDeviceId: String?
        do {
            localDeviceId = try identityStore.load()?.deviceId
        } catch {
            currentDeviceStatus = nil
            identityGeneration = nil
            errorMessage = "L’identité locale E2EE v2 est illisible."
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
        case .failed(let failure):
            currentDeviceStatus = nil
            identityGeneration = nil
            errorMessage = Self.message(for: failure, fallback: "Impossible de charger l’état de récupération.")
        }
    }

    func changeFlow(_ next: E2EEV2RecoveryFlow) {
        guard !isBusy, mayLeaveSecret else { return }
        if flow == .reset, next != .reset, !resetCompleted {
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
                errorMessage = "Clé invalide : saisissez la clé Base64 complète de 256 bits."
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
                errorMessage = Self.message(for: failure, fallback: "Impossible d’approuver cet appareil avec cette clé.")
                return
            }
        } else if currentDeviceStatus != .approved {
            errorMessage = "Cet appareil ne peut pas utiliser la récupération."
            return
        }

        let bundle: E2EEV2RecoveryBundleV2
        switch await recovery.loadActiveBundle() {
        case .success(let activeBundle):
            bundle = activeBundle
        case .failed(let failure):
            errorMessage = Self.message(for: failure, fallback: "Le bundle de récupération actif est indisponible.")
            return
        }
        switch await recoveryEpochs.restoreAll(bundle: bundle, recoveryKey: key) {
        case .success(let summary):
            recoveryInput = ""
            confirmationMessage = "Restauration terminée : \(summary.restoredEpochCount) clé(s) restaurée(s), \(summary.missingEpochCount) indisponible(s)."
        case .failure(let failure):
            errorMessage = Self.message(for: failure, fallback: "La restauration de l’historique a échoué.")
        }
    }

    func requestResetEmail() async {
        guard activationEnabled, !isBusy, allResetAcknowledged,
              let generation = identityGeneration else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        switch lifecycle.prepareIdentityReset(label: UIDevice.current.model) {
        case .success:
            break
        case .failed(let failure):
            errorMessage = Self.message(for: failure, fallback: "Impossible de préparer la nouvelle identité.")
            return
        }
        switch await lifecycle.requestIdentityResetEmailChallenge(expectedGeneration: generation) {
        case .success(let challenge):
            resetChallenge = challenge
        case .failed(let failure):
            _ = lifecycle.discardIdentityResetCandidate()
            errorMessage = Self.message(for: failure, fallback: "Impossible d’envoyer le code de réinitialisation.")
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
        case .success:
            resetCompleted = true
            resetChallenge = nil
            resetCode = ""
            resetNeedsRecovery = true
            confirmationMessage = "Identité réinitialisée. Création immédiate d’une nouvelle clé de récupération."
            await load()
            await createRecoveryMaterial()
        case .failed(let failure):
            errorMessage = Self.message(
                for: failure,
                fallback: failure.message == "e2ee-identity-reset-local-activation-pending"
                    ? String(localized: "Identité réinitialisée côté compte. La configuration locale reste en attente.")
                    : "La réinitialisation a échoué ; l’identité actuelle reste inchangée."
            )
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
        wipeRecoveryKey()
        recoveryInput = ""
        resetCode = ""
        if flow == .reset, !resetCompleted {
            _ = lifecycle.discardIdentityResetCandidate()
        }
    }

    private func createRecoveryMaterial() async {
        var material: E2EEV2RecoveryMaterialV2
        switch await recovery.createAndUploadBundle() {
        case .success(let created):
            material = created
        case .failed(let failure):
            resetNeedsRecovery = resetCompleted
            errorMessage = Self.message(for: failure, fallback: "Impossible de créer la clé de récupération.")
            return
        }

        wipeRecoveryKey()
        recoveryKey = material.recoveryKey
        material.zeroize()
        recoveryKeyAcknowledged = false
        acknowledgedNoRecovery = false
        resetNeedsRecovery = false

        switch await recoveryEpochs.backfillAll() {
        case .success(let summary):
            confirmationMessage = "Clé créée : \(summary.backedUpEpochCount) clé(s) d’historique sauvegardée(s), \(summary.missingParticipantUserIds.count) participant(s) sans clé disponible."
        case .failure(let failure):
            confirmationMessage = "La clé est créée, mais la sauvegarde de l’historique reste partielle."
            errorMessage = Self.message(for: failure, fallback: "Toutes les clés d’historique n’ont pas pu être sauvegardées.")
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
            return "La session a changé. Reconnectez-vous puis réessayez."
        case .retryable:
            return "Le service est temporairement indisponible. Réessayez."
        case .activationBlocked:
            return "Ces actions restent verrouillées jusqu’à la fin de la revue de sécurité."
        case .permanent, .localState:
            return fallback
        }
    }
}

private struct E2EEV2RecoveryResetView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: E2EEV2RecoveryResetViewModel
    @State private var revealRecoveryInput = false

    init(api: APIClient) {
        _model = StateObject(wrappedValue: E2EEV2RecoveryResetViewModel(api: api))
    }

    var body: some View {
        List {
            statusSection
            E2EEV2RotationStatusSection(runtime: services.epochRotations)

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
            }

            if let message = model.confirmationMessage {
                Section {
                    Label(message, systemImage: "checkmark.shield.fill")
                        .foregroundStyle(SQColor.success)
                        .accessibilityLabel("Confirmation. \(message)")
                }
            }

            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.danger)
                        .accessibilityLabel("Erreur. \(error)")
                }
            }

            recoveryKeySection
        }
        .navigationTitle("Récupération E2EE")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!model.mayLeaveSecret)
        .task { await model.load() }
        .onDisappear { model.wipeTransientSecrets() }
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
                        model.currentDeviceStatus == .pending ? "Approuver avec ma clé" : "Restaurer l’historique",
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
            Button {
                revealRecoveryInput.toggle()
            } label: {
                Label(revealRecoveryInput ? "Masquer la clé" : "Afficher la clé",
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
    }

    private var resetSection: some View {
        Section {
            Label("Action irréversible", systemImage: "exclamationmark.octagon.fill")
                .font(SQType.heading)
                .foregroundStyle(SQColor.danger)
            Text("Tous les appareils actuels seront révoqués. L’historique non récupéré sera définitivement perdu.")
                .foregroundStyle(SQColor.danger)

            if !model.resetCompleted && model.resetChallenge == nil {
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
                    .foregroundStyle(SQColor.danger)
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
    }

    @ViewBuilder
    private var recoveryKeySection: some View {
        if let key = model.recoveryKey {
            Section {
                Text(key.base64EncodedString())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .accessibilityLabel("Clé de récupération de 256 bits affichée. Utilisez le bouton Copier pour la sauvegarder.")
                Button {
                    UIPasteboard.general.setItems(
                        [["public.utf8-plain-text": model.recoveryKeyText]],
                        options: [
                            .localOnly: true,
                            .expirationDate: Date().addingTimeInterval(60),
                        ]
                    )
                    model.confirmationMessage = "Clé copiée localement. Le presse-papiers l’effacera après 60 secondes."
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
        }
    }

    private var flowBackButton: some View {
        Button("Retour aux actions") {
            model.changeFlow(.menu)
        }
        .frame(minHeight: 48)
        .disabled(model.isBusy || !model.mayLeaveSecret)
    }

    private func resetAcknowledgement(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .tint(SQColor.danger)
            .frame(minHeight: 48)
            .disabled(model.isBusy)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var prefs: NotificationPreferences = NotificationPreferences(
        notifyPhotoCommentsEmail: nil, notifyPhotoCommentsPush: nil, notifyPhotoCommentsInApp: nil,
        notifyPhotoLikesEmail: nil, notifyPhotoLikesPush: nil, notifyPhotoLikesInApp: nil,
        notifyPhotoMentionsEmail: nil, notifyPhotoMentionsPush: nil, notifyPhotoMentionsInApp: nil,
        notifyPhotoRepliesEmail: nil, notifyPhotoRepliesPush: nil, notifyPhotoRepliesInApp: nil,
        notifyMessagesEmail: nil, notifyMessagesPush: nil, notifySocialPush: nil,
        notifyMessagesInApp: nil,
        notifyAnfrUpdatesPush: nil, notifyAnfrUpdatesEmail: nil,
        callsDoNotDisturb: nil
    )
    @Published var isBusy = false
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
        guard let expectedSession = LocalAccountScope.sessionSnapshot() else { return false }
        do {
            let receipt = try await userService.deleteAccount(using: proof, expectedSession: expectedSession)
            guard receipt.success else { throw APIError.transport("account-deletion-not-confirmed") }
            await authService.eraseDeletedAccountVault(ownerScopeId: expectedSession.ownerScopeId)
            deletedOwnerScopeId = expectedSession.ownerScopeId
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
    /// Statut système réel des notifications : si l'utilisateur a refusé le prompt,
    /// aucune push n'arrive quels que soient les toggles ci-dessous (UXP-02). On le
    /// signale et on propose les Réglages plutôt que de laisser des toggles aveugles.
    @State private var systemNotificationsDenied = false
    @State private var e2eeNotificationPrivacy: E2EEV2NotificationPrivacy = .full

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
                NavigationLink {
                    E2EEV2TrustedDevicesView(api: services.api)
                } label: { settingsLabel("Appareils E2EE v2", systemImage: "lock.shield") }
            } header: {
                Text("Sécurité")
                    .foregroundStyle(SQColor.label)
            }
            .listRowBackground(SQColor.surface)
            // `Section` porte des surcharges pour List ET pour Table : quand la
            // première expression du bloc est un NavigationLink à fermeture
            // traînante, Swift résout vers TableRowContent. Un Text concret en
            // tête ancre la résolution côté vues.
            Section {
                Text("État de votre connexion fixe, surveillée en continu depuis nos serveurs.")
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.labelSecondary)
                NavigationLink {
                    SentinelleView(service: services.sentinelle)
                } label: { settingsLabel("Sentinelle", systemImage: "wifi.router") }
            } header: {
                Text("Ma connexion")
                    .foregroundStyle(SQColor.label)
            }
            .listRowBackground(SQColor.surface)
            Section {
                Toggle(isOn: $fieldMode) {
                    settingsLabel("Mode terrain", systemImage: "sun.max.fill")
                }
                .tint(SQColor.brandRed)
                Text("Renforce le contraste, la graisse des textes et la taille des contrôles pour une lecture plus fiable en extérieur.")
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.labelSecondary)
                Toggle(isOn: $pureBlack) {
                    settingsLabel("Noir intense (OLED)", systemImage: "circle.lefthalf.filled")
                }
                .tint(SQColor.brandRed)
                Text("En thème sombre, les fonds passent au noir pur. Sur un écran OLED, un pixel noir est éteint : l'affichage consomme moins. Sans effet en thème clair.")
                    .font(.footnote)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Apparence")
                    .foregroundStyle(SQColor.label)
            }
            .listRowBackground(SQColor.surface)
            Section {
                Toggle(isOn: $carPlayCoverageAlerts) {
                    settingsLabel("Alerte zone mal couverte", systemImage: "car.fill")
                }
                .tint(SQColor.brandRed)
                Text("Sur l'écran de la voiture, te signale quand tu traverses une zone où le réseau est mauvais. Au maximum une alerte toutes les 10 minutes, jamais deux fois la même zone, et rien pendant une manœuvre annoncée.")
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.labelSecondary)
            } header: {
                Text("CarPlay")
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
                    .signInWithAppleButtonStyle(SQOledPalette.appleButtonStyle(colorScheme))
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
            Section {
                NavigationLink {
                    FavoriteAntennasView(favorites: services.favoriteAntennas)
                } label: {
                    HStack {
                        Label("Antennes suivies", systemImage: "star.fill")
                        Spacer()
                        Text("\(services.favoriteAntennas.favorites.count)")
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            } header: {
                Text("Antennes suivies")
            } footer: {
                Text("Les seules antennes pour lesquelles vous êtes prévenu dès le premier signalement, sans attendre que la communauté confirme.")
            }
            .foregroundStyle(SQColor.label)
            .listRowBackground(SQColor.surface)
            Section("Notifications") {
                if systemNotificationsDenied {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Label("Les notifications sont désactivées pour SignalQuest. Aucune alerte n’arrivera tant qu’elles ne sont pas réactivées dans les Réglages iOS.", systemImage: "bell.slash.fill")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Ouvrir les Réglages", destination: url)
                                .font(SQType.caption.weight(.semibold))
                                .foregroundStyle(SQColor.brandRed)
                        }
                    }
                }
                Toggle("Messages privés (push)", isOn: bind(\.notifyMessagesPush))
                Picker(selection: Binding(
                    get: { e2eeNotificationPrivacy },
                    set: { value in
                        if E2EEV2NotificationPrivacyStore.set(value) {
                            e2eeNotificationPrivacy = value
                            Haptics.selection()
                        } else {
                            model.errorMessage = String(localized: "Impossible de modifier les aperçus. Réessayez ou désactivez les notifications dans les Réglages iOS.")
                        }
                    }
                )) {
                    Text("Contenu complet").tag(E2EEV2NotificationPrivacy.full)
                    Text("Expéditeur seulement").tag(E2EEV2NotificationPrivacy.senderOnly)
                    Text("Tout masquer").tag(E2EEV2NotificationPrivacy.hidden)
                } label: {
                    settingsLabel("Aperçu des messages chiffrés", systemImage: "lock.rectangle")
                }
                .pickerStyle(.menu)
                .frame(minHeight: 48)
                E2EEV2NotificationPreviewNotice(showReminder: true) { e2eeNotificationPrivacy = $0 }
                // Le fil PUBLIC, séparé des messages privés : les deux vivaient sous un seul
                // interrupteur intitulé « Messages », si bien que couper ses messages coupait
                // aussi commentaires, réponses et mentions.
                Toggle("Commentaires et réponses", isOn: bind(\.notifySocialPush))
                Toggle("Messages (in-app)", isOn: bind(\.notifyMessagesInApp))
                Toggle("Mises à jour ANFR (push)", isOn: bind(\.notifyAnfrUpdatesPush))
                Toggle("Likes & commentaires (push)", isOn: bind(\.notifyPhotoLikesPush))
                Toggle("Réponses à mes signalements (e-mail)", isOn: bind(\.notifyAntennaReportsEmail))
                Toggle("Pannes signalées par la communauté", isOn: bind(\.notifyCommunityOutagesPush))
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
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(SQColor.brandRed)
                                .frame(width: 36, height: 36)
                                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).foregroundStyle(SQColor.label)
                                Text(option.subtitle)
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                            Spacer()
                            if MapBackdrop.resolve(mapBackdropRaw) == option {
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
                Text("La zone consultée est transmise au fournisseur du fond choisi : Apple Maps, OpenStreetMap ou OpenTopoMap.")
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
                        .foregroundStyle(SQColor.dangerInk)
                        .frame(maxWidth: .infinity)
                }
            }
            .listRowBackground(SQColor.dangerSoft)
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(SQColor.dangerInk) }
                    .listRowBackground(SQColor.dangerSoft)
            }
        }
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Réglages")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: PushOwnerScope.current) {
            await model.load()
            e2eeNotificationPrivacy = E2EEV2NotificationPrivacyStore.get()
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            systemNotificationsDenied = settings.authorizationStatus == .denied
        }
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
                guard model.deletedOwnerScopeId == LocalAccountScope.currentOwnerScopeId else { return }
                await services.push.unregister()
                guard model.deletedOwnerScopeId == LocalAccountScope.currentOwnerScopeId else { return }
                await session.logout()
            }
        }
    }

    /// Rangée de réglage (DA Crème) : pastille d'icône 36 pt `accentSoft`
    /// (icône brique) + libellé Figtree Medium 15,5. Aucune bordure.
    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SQColor.accentInk)
                .frame(width: 36, height: 36)
                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(.body.weight(.medium))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.label.\(title)")
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
                Section { Text(error).foregroundStyle(SQColor.dangerInk) }
                    .listRowBackground(SQColor.dangerSoft)
            }
            if success {
                Section { Label("Mot de passe modifié", systemImage: "checkmark.circle").foregroundStyle(SQColor.success) }
                    .listRowBackground(SQColor.successSoft)
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
                        Button {
                            Task { await loadPreview() }
                        } label: {
                            Text("Réessayer")
                                .font(SQType.button)
                                .foregroundStyle(SQColor.label)
                                .padding(.horizontal, SQSpace.xl)
                                .frame(minHeight: 44)
                                .background(SQColor.surface, in: Capsule(style: .continuous))
                                .sqShadowSoft()
                        }
                        .buttonStyle(SQPressButtonStyle())
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
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
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
            .signInWithAppleButtonStyle(SQOledPalette.appleButtonStyle(colorScheme))
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
            GradientButton("Envoyer le code", systemImage: "envelope.badge", style: .accent) {
                Task { await requestEmailCode() }
            }
            .disabled(!hasAcknowledged || isBusy)
            .opacity(hasAcknowledged && !isBusy ? 1 : 0.5)
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
