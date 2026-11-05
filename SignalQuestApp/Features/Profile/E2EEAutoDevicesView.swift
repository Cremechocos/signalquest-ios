import CryptoKit
import SwiftUI
import UIKit

// MARK: - Appareils du compte (E2EE-AUTO)

/// Appareils du compte lus dans le journal vérifié (E2EE-AUTO §4.2, §4.4) : ce
/// que l'écran montre vient des entrées signées, jamais d'une liste du serveur.
/// Le libellé (« iPhone », « Pixel 8 ») n'est pas au journal : seule la
/// plateforme, la date d'ajout et l'empreinte courte le sont. Libellé et
/// dernière activité viennent d'une lecture à part, pour l'affichage seul.
@MainActor
final class E2EEAutoDevicesViewModel: ObservableObject {
    struct Dependencies {
        var ownDeviceId: () -> String?
        var readOwnAccount: () async -> E2EEAutoEnrollment.OwnAccount
        var revoke: (_ deviceId: String, _ reason: E2EEAutoLog.RevokeReason) async -> E2EEAutoDeviceRevocation.Outcome
        /// Libellés et activités (§4.2, révision 12) ; nil : inconnus, sans message.
        var readLabels: () async -> [String: E2EEAutoDeviceLabels.Display]? = { nil }
        /// Mode renforcé (§6) ; l'écran ne l'adopte qu'à la relecture du journal.
        var setMode: (_ mode: E2EEAutoLog.Mode) async -> E2EEAutoModeSetting.Outcome = { _ in .failed("e2ee-auto-mode-unavailable") }
        /// Passkey (§5.5) : ce que l'app propose, puis la feuille système et le dépôt.
        var passkeyOffer: () async -> E2EEAutoPasskeyContract.Offer = { .none }
        var protectWithPasskey: (_ offer: E2EEAutoPasskeyContract.Offer) async -> PasskeyResult = { _ in .failed }
        var dismissPasskeyOffer: () -> Void = {}
        var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    }

    enum Phase: Equatable {
        case loading
        case loaded
        /// Cet appareil n'est pas encore au journal : l'inscription le fera.
        case notEnrolled
        /// Journal refusé par le vérificateur (fourche, retour en arrière) : rien n'est montré.
        case refused
        /// Réseau, serveur : nouvel essai.
        case unavailable
    }

    enum PasskeyResult: Equatable {
        case done
        case cancelled
        /// Le gestionnaire de passkeys ne prend pas en charge `prf`.
        case unsupported
        /// Dix passkeys déjà enregistrées.
        case limit
        case failed
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let platform: E2EEAutoLog.Platform
        let isCurrent: Bool
        let status: E2EEAutoLog.DeviceStatus
        let addedAtMs: Int64
        let revokedAtMs: Int64?
        let revokeReason: E2EEAutoLog.RevokeReason?
        /// 4 groupes de 5 chiffres (§7), à comparer avec l'écran de l'autre appareil.
        let shortFingerprint: [String]
        /// Texte fourni à l'inscription, affiché tel quel : il ne prouve rien.
        var label: String?
        var lastSeenAtMs: Int64?
    }

    /// Retirés depuis moins de 30 jours : la trace d'une révocation reste visible un temps.
    static let revokedWindowMs: Int64 = 30 * 24 * 3_600_000

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var rows: [Row] = []
    @Published private(set) var revokedRows: [Row] = []
    @Published private(set) var isActing = false
    /// Garde des 24 h (§4.4) : heure à partir de laquelle cet appareil révoque les autres.
    @Published private(set) var othersRevocableAtMs: Int64?
    @Published var errorMessage: String?
    @Published var confirmationMessage: String?
    /// Mode du compte, lu au journal vérifié.
    @Published private(set) var mode: E2EEAutoLog.Mode = .normal
    @Published private(set) var passkeyOffer: E2EEAutoPasskeyContract.Offer = .none
    /// Auto-révocation écrite : la vue ferme la session.
    @Published private(set) var signedOut = false

    private let dependencies: Dependencies
    /// Dernière lecture réussie : une lecture en échec ne les efface pas.
    private var labels: [String: E2EEAutoDeviceLabels.Display] = [:]
    private var account: E2EEAutoLog.AccountState?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var current: Row? { rows.first(where: \.isCurrent) }

    /// Cet appareil est actif et inscrit depuis 24 h : il peut révoquer les autres.
    var canRevokeOthers: Bool {
        guard current?.status == .active else { return false }
        return othersRevocableAtMs.map { dependencies.nowMs() >= $0 } ?? true
    }

    /// Heures entières restantes avant la fin de la garde des 24 h, au moins 1.
    var hoursBeforeRevokingOthers: Int? {
        guard current?.status == .active, let at = othersRevocableAtMs else { return nil }
        let remaining = at - dependencies.nowMs()
        guard remaining > 0 else { return nil }
        return max(1, Int((remaining + 3_599_999) / 3_600_000))
    }

    var activeCount: Int { rows.filter { $0.status == .active }.count }

    /// Changer le mode : même garde que révoquer les autres (actif, inscrit depuis 24 h),
    /// et `STRICT` demande deux appareils actifs (§6).
    var canChangeMode: Bool {
        canRevokeOthers && (mode == .strict || activeCount >= 2)
    }

    func setMode(_ mode: E2EEAutoLog.Mode) async {
        guard !isActing, mode != self.mode, canChangeMode else { return }
        isActing = true
        errorMessage = nil
        defer { isActing = false }
        switch await dependencies.setMode(mode) {
        case .set:
            break
        case .tooRecent:
            errorMessage = String(localized: "Cet appareil a été ajouté il y a moins de 24 h : change le mode depuis un appareil plus ancien.")
        case .needsTwoDevices:
            errorMessage = String(localized: "Le mode renforcé demande au moins deux appareils actifs.")
        case .notActive:
            errorMessage = String(localized: "Cet appareil attend encore son activation : il ne peut pas changer le mode.")
        case .logRefused:
            errorMessage = String(localized: "Le journal des appareils n’a pas pu être vérifié. Le mode n’a pas changé.")
        case .retryLater, .failed:
            errorMessage = String(localized: "Impossible de changer le mode. Réessaie dans un instant.")
        }
        await load()
    }

    func protectWithPasskey() async {
        guard !isActing, passkeyOffer != .none else { return }
        isActing = true
        errorMessage = nil
        defer { isActing = false }
        switch await dependencies.protectWithPasskey(passkeyOffer) {
        case .done:
            confirmationMessage = String(localized: "Ta passkey protège maintenant ton historique.")
        case .cancelled:
            return
        case .unsupported:
            dependencies.dismissPasskeyOffer()
            errorMessage = String(localized: "Ton gestionnaire de passkeys ne permet pas de protéger l’historique.")
        case .limit:
            errorMessage = String(localized: "Ton compte a déjà dix passkeys pour l’historique.")
        case .failed:
            errorMessage = String(localized: "Impossible de protéger l’historique avec la passkey. Réessaie dans un instant.")
        }
        passkeyOffer = await dependencies.passkeyOffer()
    }

    func dismissPasskeyOffer() {
        dependencies.dismissPasskeyOffer()
        passkeyOffer = .none
    }

    func load() async {
        if rows.isEmpty { phase = .loading }
        switch await dependencies.readOwnAccount() {
        case .verified(let account):
            apply(account)
            if let read = await dependencies.readLabels() {
                labels = read
                if let kept = self.account { apply(kept) }
            }
            passkeyOffer = await dependencies.passkeyOffer()
        case .refused:
            rows = []
            revokedRows = []
            phase = .refused
        case .inconclusive:
            if rows.isEmpty { phase = .unavailable }
            else { errorMessage = String(localized: "Impossible d’actualiser la liste des appareils. Réessaie.") }
        }
    }

    func apply(_ account: E2EEAutoLog.AccountState) {
        self.account = account
        mode = account.mode
        let ownId = dependencies.ownDeviceId()
        let nowMs = dependencies.nowMs()
        let all = account.devices.values.map { device in
            Row(
                id: device.deviceId, platform: device.platform, isCurrent: device.deviceId == ownId, status: device.status,
                addedAtMs: device.addedAtMs, revokedAtMs: device.revokedAtMs, revokeReason: device.revokeReason,
                shortFingerprint: E2EEAutoSafetyCode.shortFingerprint(E2EEAutoSafetyCode.deviceFingerprint(
                    userId: account.userId, deviceId: device.deviceId, signingKeyB64: device.signingKeyB64
                )) ?? [],
                label: labels[device.deviceId]?.label, lastSeenAtMs: labels[device.deviceId]?.lastSeenAtMs
            )
        }
        // Cet appareil d'abord, puis du plus récent au plus ancien.
        rows = all.filter { $0.status != .revoked }
            .sorted { ($0.isCurrent ? 1 : 0, $0.addedAtMs, $0.id) > ($1.isCurrent ? 1 : 0, $1.addedAtMs, $1.id) }
        revokedRows = all.filter { row in
            row.status == .revoked && !row.isCurrent && (row.revokedAtMs.map { nowMs - $0 < Self.revokedWindowMs } ?? false)
        }
        .sorted { ($0.revokedAtMs ?? 0, $0.id) > ($1.revokedAtMs ?? 0, $1.id) }
        othersRevocableAtMs = ownId.flatMap { account.devices[$0] }.map { $0.addedAtMs + E2EEAutoLog.signerMinAgeMs }
        phase = rows.contains(where: \.isCurrent) ? .loaded : .notEnrolled
    }

    func revoke(_ row: Row, reason: E2EEAutoLog.RevokeReason) async {
        guard !isActing, row.isCurrent || canRevokeOthers else { return }
        isActing = true
        errorMessage = nil
        defer { isActing = false }
        let outcome = await dependencies.revoke(row.id, reason)
        switch outcome {
        case .revoked(ownDevice: true):
            signedOut = true
            return
        case .revoked:
            var message = reason == .notMe
                ? String(localized: "Appareil retiré. Tes autres sessions ont été fermées : change ton mot de passe si quelqu’un d’autre le connaît.")
                : String(localized: "Appareil retiré. Il ne reçoit plus tes messages.")
            // Un appareil Apple resté sur l'identifiant Apple garde la synchro du trousseau iCloud.
            if row.platform == .ios {
                message += "\n\n" + String(localized: "S’il est perdu ou volé, retire-le aussi de ton identifiant Apple : Réglages > ton nom, ou Localiser > Effacer.")
            }
            confirmationMessage = message
        case .tooRecent:
            errorMessage = String(localized: "Cet appareil a été ajouté il y a moins de 24 h : passe par un appareil plus ancien pour en retirer un autre.")
        case .notActive:
            errorMessage = String(localized: "Cet appareil attend encore son activation : il ne peut retirer aucun appareil.")
        case .notFound:
            errorMessage = String(localized: "Cet appareil n’existe plus sur ton compte.")
        case .thisDeviceRevoked, .reauthenticate:
            errorMessage = String(localized: "La session a changé. Reconnecte-toi avant de gérer les appareils.")
        case .updateRequired:
            errorMessage = String(localized: "Mets à jour SignalQuest pour gérer tes appareils.")
        case .logRefused:
            errorMessage = String(localized: "Le journal des appareils n’a pas pu être vérifié. Aucun appareil n’a été retiré.")
        case .retryLater, .failed:
            errorMessage = String(localized: "Impossible de retirer cet appareil. Réessaie dans un instant.")
        }
        await load()
    }
}

extension E2EEAutoDevicesViewModel {
    /// Modèle de la session courante ; sans session ni clé du journal, la liste reste indisponible.
    static func live(api: APIClient) -> E2EEAutoDevicesViewModel {
        guard let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api) else {
            return E2EEAutoDevicesViewModel(dependencies: .init(
                ownDeviceId: { nil }, readOwnAccount: { .inconclusive }, revoke: { _, _ in .reauthenticate }
            ))
        }
        let userId = String(session.ownerScopeId.dropFirst("user:".count))
        let namespace = session.ownerNamespace
        return E2EEAutoDevicesViewModel(dependencies: .init(
            ownDeviceId: { (try? E2EEV2DeviceIdentityStore().load(ownerNamespace: namespace))?.deviceId },
            readOwnAccount: { await E2EEAutoDeviceRevocation.ownAccount(reader: reader, userId: userId) },
            revoke: { deviceId, reason in
                guard let revocation = E2EEAutoDeviceRevocation.live(session: session, api: api) else { return .reauthenticate }
                return await revocation.revoke(deviceId: deviceId, reason: reason)
            },
            readLabels: E2EEAutoDeviceLabels.live(session: session, api: api),
            setMode: { mode in
                guard let setting = E2EEAutoModeSetting.live(session: session, api: api) else { return .failed("e2ee-auto-mode-unavailable") }
                return await setting.set(mode)
            },
            passkeyOffer: {
                guard let backup = E2EEAutoPasskeyBackup.live(session: session, api: api) else { return .none }
                return await backup.offer(
                    prfAvailable: E2EEAutoPasskeyAuthenticator.isAvailable,
                    creationDismissed: UserDefaults.standard.bool(forKey: passkeyDismissedKey(namespace))
                )
            },
            protectWithPasskey: { offer in
                guard let backup = E2EEAutoPasskeyBackup.live(session: session, api: api) else { return .failed }
                return await protect(offer: offer, backup: backup, userId: userId)
            },
            dismissPasskeyOffer: { UserDefaults.standard.set(true, forKey: passkeyDismissedKey(namespace)) }
        ))
    }

    /// « Plus tard » : la création n'est proposée qu'une fois sur cet appareil (§5.5).
    static func passkeyDismissedKey(_ namespace: String) -> String { "e2ee-auto-passkey-offer-dismissed-v1:\(namespace)" }

    /// Création : nouvelle passkey et nouveau `prfSalt`. Mise à jour : une passkey
    /// périmée listée, avec son propre `prfSalt`, puis la même enveloppe remplacée.
    private static func protect(offer: E2EEAutoPasskeyContract.Offer, backup: E2EEAutoPasskeyBackup, userId: String) async -> PasskeyResult {
        let authenticator = E2EEAutoPasskeyAuthenticator()
        let output: E2EEAutoPasskeyAuthenticator.Output
        let salt: Data
        do {
            switch offer {
            case .none:
                return .failed
            case .create:
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return .failed }
                salt = Data(bytes)
                output = try await authenticator.create(
                    userName: String(localized: "Historique chiffré SignalQuest"),
                    userHandle: E2EEAutoPasskeyAuthenticator.userHandle(userId: userId), salt: salt
                )
            case .update(let credentialIds):
                let listed = (await backup.list() ?? []).filter { credentialIds.contains($0.credentialId) }
                let candidates = listed.compactMap { item -> (Data, Data, String)? in
                    guard let raw = E2EEAutoPasskeyAuthenticator.rawCredentialId(item.credentialId),
                          let salt = Data(base64Encoded: item.wrap.prfSaltB64) else { return nil }
                    return (raw, salt, item.credentialId)
                }
                output = try await authenticator.assert(candidates.map { ($0.0, $0.1) })
                guard let chosen = candidates.first(where: { $0.2 == output.credentialId }) else { return .failed }
                salt = chosen.1
            }
        } catch E2EEAutoPasskeyAuthenticator.Failure.cancelled {
            return .cancelled
        } catch E2EEAutoPasskeyAuthenticator.Failure.prfUnsupported {
            return .unsupported
        } catch {
            return .failed
        }
        switch await backup.protect(credentialId: output.credentialId, prfSalt: salt, prfOutput: output.prfOutput) {
        case .protected: return .done
        case .limit: return .limit
        default: return .failed
        }
    }
}

struct E2EEAutoDevicesView: View {
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model: E2EEAutoDevicesViewModel
    @State private var rowToRevoke: E2EEAutoDevicesViewModel.Row?
    @State private var detailRow: E2EEAutoDevicesViewModel.Row?
    @State private var confirmsSignOut = false

    init(api: APIClient) {
        _model = StateObject(wrappedValue: E2EEAutoDevicesViewModel.live(api: api))
    }

    init(model: @autoclosure @escaping () -> E2EEAutoDevicesViewModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        List {
            switch model.phase {
            case .loading:
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Chargement des appareils…")
                        Spacer()
                    }
                    .frame(minHeight: 72)
                }
            case .notEnrolled:
                Section {
                    Label("Cet appareil s’inscrit au chiffrement de bout en bout. Reviens dans un instant.", systemImage: "iphone.gen3.badge.play")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                devicesSection
            case .refused:
                Section {
                    Label {
                        Text("Le journal des appareils n’a pas pu être vérifié. Par prudence, rien n’est affiché ni modifié.")
                            .font(SQType.body)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(SQColor.dangerInk)
                    }
                }
            case .unavailable:
                Section {
                    Label("Impossible de charger la liste des appareils.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(SQColor.labelSecondary)
                    Button("Réessayer") { Task { await model.load() } }
                        .frame(minHeight: 48)
                }
            case .loaded:
                devicesSection
                passkeySection
                strictModeSection
                if !model.revokedRows.isEmpty {
                    Section {
                        ForEach(model.revokedRows) { row in
                            deviceRow(row)
                        }
                    } header: {
                        Text("Retirés récemment")
                    }
                }
                if let current = model.current {
                    Section {
                        Button(role: .destructive) {
                            confirmsSignOut = true
                        } label: {
                            Label("Déconnecter cet appareil", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(minHeight: 48)
                        }
                        .disabled(model.isActing)
                        .accessibilityIdentifier("e2eeAuto.devices.signOut")
                    } footer: {
                        if current.status == .pending {
                            Text("Ferme la session sur cet appareil.")
                        } else {
                            Text("Retire cet appareil du compte et ferme sa session. Il faudra te reconnecter pour l’ajouter de nouveau.")
                        }
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(SQColor.dangerInk)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SQColor.bg.ignoresSafeArea())
        .tint(SQColor.brandRed)
        .navigationTitle("Appareils")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
        .onChangeCompat(of: model.signedOut) { _, signedOut in
            guard signedOut else { return }
            Task { await session.logout() }
        }
        .confirmationDialog(
            rowToRevoke.map { String(localized: "Retirer \(Self.deviceName($0)) ?") } ?? "",
            isPresented: Binding(get: { rowToRevoke != nil }, set: { if !$0 { rowToRevoke = nil } }),
            titleVisibility: .visible,
            presenting: rowToRevoke
        ) { row in
            Button("Retirer cet appareil", role: .destructive) {
                Task { await model.revoke(row, reason: .user) }
            }
            Button("Ce n’est pas moi", role: .destructive) {
                Task { await model.revoke(row, reason: .notMe) }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Il ne recevra plus tes messages. « Ce n’est pas moi » ferme aussi toutes tes autres sessions.")
        }
        .confirmationDialog(
            "Déconnecter cet appareil ?",
            isPresented: $confirmsSignOut,
            titleVisibility: .visible
        ) {
            Button("Déconnecter", role: .destructive) {
                guard let current = model.current else { return }
                // En attente, l'appareil ne révoque rien, pas même lui (§4.4) : seule la session se ferme.
                if current.status == .pending {
                    Task { await session.logout() }
                } else {
                    Task { await model.revoke(current, reason: .user) }
                }
            }
            Button("Annuler", role: .cancel) {}
        }
        .sheet(item: $detailRow) { row in
            detailSheet(row)
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

    /// Passkey (§5.5), proposée une fois, ou à mettre à jour après une rotation de HK.
    @ViewBuilder
    private var passkeySection: some View {
        switch model.passkeyOffer {
        case .none:
            EmptyView()
        case .create, .update:
            let updating = model.passkeyOffer != .create
            Section {
                Button {
                    Task { await model.protectWithPasskey() }
                } label: {
                    Group {
                        if updating {
                            Label("Mettre à jour la passkey", systemImage: "person.badge.key")
                        } else {
                            Label("Protéger l’historique avec une passkey", systemImage: "person.badge.key")
                        }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(model.isActing)
                .accessibilityIdentifier("e2eeAuto.devices.passkey")
                if !updating {
                    Button("Plus tard") { model.dismissPasskeyOffer() }
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(minHeight: 44)
                        .disabled(model.isActing)
                }
            } footer: {
                if updating {
                    Text("Ta clé d’historique a changé : mets à jour la passkey pour qu’elle ouvre aussi tes nouveaux messages.")
                } else {
                    Text("Avec une passkey, ton historique chiffré s’ouvre aussi sur Android ou dans un navigateur, sans passer par un autre appareil.")
                }
            }
        }
    }

    /// Mode renforcé (§6) : l'interrupteur montre le mode du journal vérifié, jamais l'intention.
    private var strictModeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.mode == .strict },
                set: { on in Task { await model.setMode(on ? .strict : .normal) } }
            )) {
                Label("Mode renforcé", systemImage: "lock.shield")
                    .frame(minHeight: 44)
            }
            .disabled(!model.canChangeMode || model.isActing)
            .accessibilityIdentifier("e2eeAuto.devices.strictMode")
        } footer: {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Un nouvel appareil ne lit ni n’envoie tes messages chiffrés tant qu’un de tes appareils ne l’a pas activé avec « C’est moi ». Le désactiver n’active aucun appareil en attente.")
                if let hours = model.hoursBeforeRevokingOthers {
                    Text("Disponible sur cet appareil dans \(hours) h.")
                } else if model.mode == .normal && model.activeCount < 2 {
                    Text("Il faut au moins deux appareils actifs pour l’activer.")
                }
            }
        }
    }

    @ViewBuilder
    private var devicesSection: some View {
        if !model.rows.isEmpty {
            Section {
                ForEach(model.rows) { row in
                    deviceRow(row)
                }
            } header: {
                Text("Appareils")
            } footer: {
                if let hours = model.hoursBeforeRevokingOthers {
                    Text("Cet appareil a été ajouté il y a moins de 24 h. Il pourra retirer tes autres appareils dans \(hours) h ; d’ici là, retire-les depuis un appareil plus ancien.")
                } else {
                    Text("Touche un appareil pour voir son empreinte et vérifier que c’est bien lui.")
                }
            }
        }
    }

    @ViewBuilder
    private func deviceRow(_ row: E2EEAutoDevicesViewModel.Row) -> some View {
        // Aux tailles d'accessibilité, la corbeille passe sous la ligne pour laisser au nom toute la largeur.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: SQSpace.md))
        layout {
            Button { detailRow = row } label: { rowSummary(row) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Affiche l’empreinte de l’appareil"))
            if !row.isCurrent, row.status != .revoked, model.canRevokeOthers {
                Button(role: .destructive) {
                    rowToRevoke = row
                } label: {
                    if dynamicTypeSize.isAccessibilitySize {
                        Label("Retirer cet appareil", systemImage: "trash")
                            .frame(minHeight: 44)
                    } else {
                        Image(systemName: "trash")
                            .frame(width: 44, height: 44)
                    }
                }
                .accessibilityLabel(String(localized: "Retirer \(Self.deviceName(row))"))
                .disabled(model.isActing)
            }
        }
        .padding(.vertical, 4)
    }

    private func rowSummary(_ row: E2EEAutoDevicesViewModel.Row) -> some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: platformIcon(row.platform))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(row.status == .revoked ? SQColor.labelSecondary : SQColor.brandRed)
                    .frame(width: 40, height: 40)
                    .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                // Aux grandes tailles de texte, la pastille passe sous le nom plutôt que de se couper.
                titleBlock(row)
                if let status = statusText(row) {
                    Text(status)
                        .font(SQFont.body(12, .bold, relativeTo: .caption))
                        .foregroundStyle(row.status == .revoked ? SQColor.labelSecondary : SQColor.warning)
                }
                Text(Self.addedText(row))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                if let activity = Self.activityText(row) {
                    Text(activity)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(minHeight: 40)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// L'empreinte courte (§7) : la seule donnée de la ligne qu'un serveur ne peut pas inventer.
    private func detailSheet(_ row: E2EEAutoDevicesViewModel.Row) -> some View {
        NavigationStack {
            List {
                Section {
                    rowSummaryHeader(row)
                }
                if !row.shortFingerprint.isEmpty {
                    Section {
                        Text(row.shortFingerprint.joined(separator: " "))
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(String(localized: "Empreinte \(row.shortFingerprint.joined(separator: ", "))"))
                    } header: {
                        Text("Empreinte")
                    } footer: {
                        if row.isCurrent {
                            Text("C’est l’empreinte de cet appareil. Tes autres appareils affichent la même pour lui dans Réglages > Appareils.")
                        } else {
                            Text("Elle vient de la clé de l’appareil, inscrite au journal signé. Ouvre Réglages > Appareils sur l’appareil en question : s’il affiche la même empreinte pour « Cet appareil », c’est bien lui.")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle(Self.deviceName(row))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { detailRow = nil }
                }
            }
        }
        .tint(SQColor.brandRed)
        // Aux tailles d'accessibilité, la demi-feuille cacherait l'empreinte.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private func rowSummaryHeader(_ row: E2EEAutoDevicesViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            titleBlock(row)
            if let status = statusText(row) {
                Text(status)
                    .font(SQFont.body(12, .bold, relativeTo: .caption))
                    .foregroundStyle(row.status == .revoked ? SQColor.labelSecondary : SQColor.warning)
            }
            Text(Self.addedText(row))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            if let activity = Self.activityText(row) {
                Text(activity)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func titleBlock(_ row: E2EEAutoDevicesViewModel.Row) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) { title(row, stacked: true) }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack { title(row) }
                VStack(alignment: .leading, spacing: 4) { title(row, stacked: true) }
            }
        }
    }

    @ViewBuilder
    private func title(_ row: E2EEAutoDevicesViewModel.Row, stacked: Bool = false) -> some View {
        Text(Self.deviceName(row))
            .font(SQType.heading)
        if row.isCurrent {
            // En ligne, la pastille ne se coupe pas ; sous le nom, elle rétrécit un peu plutôt que de se couper.
            Text("Cet appareil")
                .font(SQFont.body(12, .bold, relativeTo: .caption2))
                .lineLimit(1)
                .minimumScaleFactor(stacked ? 0.8 : 1)
                .fixedSize(horizontal: !stacked, vertical: true)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(SQColor.accentSoft, in: Capsule())
        }
    }

    private func platformIcon(_ platform: E2EEAutoLog.Platform) -> String {
        switch platform {
        case .android: return "apps.iphone"
        case .web: return "globe"
        case .ios: return "iphone"
        }
    }

    /// Le libellé servi s'il y en a un, sinon la plateforme du journal.
    static func deviceName(_ row: E2EEAutoDevicesViewModel.Row) -> String {
        row.label ?? platformName(row)
    }

    static func platformName(_ row: E2EEAutoDevicesViewModel.Row) -> String {
        switch row.platform {
        case .android: return "Android"
        case .web: return String(localized: "Navigateur web")
        case .ios where row.isCurrent: return E2EEAutoEnrollmentContract.label(isPad: UIDevice.current.userInterfaceIdiom == .pad)
        case .ios: return String(localized: "iPhone ou iPad")
        }
    }

    private func statusText(_ row: E2EEAutoDevicesViewModel.Row) -> String? {
        switch row.status {
        case .active: return nil
        case .pending: return String(localized: "En attente d’activation")
        case .revoked:
            switch row.revokeReason {
            case .notMe?, .emailNotMe?: return String(localized: "Retiré : « Ce n’est pas moi »")
            case .inactive?: return String(localized: "Retiré après 45 jours sans activité")
            case .admin?: return String(localized: "Retiré par l’équipe SignalQuest")
            default: return String(localized: "Retiré")
            }
        }
    }

    static func addedText(_ row: E2EEAutoDevicesViewModel.Row) -> String {
        let added = Self.date(row.addedAtMs)
        if let revokedAtMs = row.revokedAtMs {
            return String(localized: "Ajouté le \(added) · retiré le \(Self.date(revokedAtMs))")
        }
        return String(localized: "Ajouté le \(added)")
    }

    /// Dernière requête signée, arrondie à la minute par le serveur ; ni pour cet
    /// appareil, ni pour un appareil retiré.
    static func activityText(_ row: E2EEAutoDevicesViewModel.Row, now: Date = Date()) -> String? {
        guard !row.isCurrent, row.status != .revoked, let ms = row.lastSeenAtMs else { return nil }
        let seen = Date(timeIntervalSince1970: TimeInterval(ms) / 1_000)
        guard now.timeIntervalSince(seen) >= 60 else { return String(localized: "Actif à l’instant") }
        let formatter = RelativeDateTimeFormatter()
        // `.abbreviated` donne « -2 j » en français : `.short` donne « il y a 2 j ».
        formatter.unitsStyle = .short
        return String(localized: "Actif \(formatter.localizedString(for: seen, relativeTo: now))")
    }

    private static func date(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1_000).sqFormatted(date: .medium)
    }
}

/// Banc visuel (simulateur Debug) : un compte de démonstration, sans réseau.
/// `--qa-auto-devices`, `--qa-auto-devices-recent` (garde des 24 h),
/// `--qa-auto-devices-refused` (journal refusé), `--qa-auto-devices-unlabeled` (sans libellés),
/// `--qa-auto-devices-passkey` (création proposée), `--qa-auto-devices-passkey-update` (passkey périmée).
struct E2EEAutoDevicesQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    static func model() -> E2EEAutoDevicesViewModel {
        let userId = "user_alice_qa_01J7ABCD2345", ownId = "ios_device_qa_own_0000001"
        let hour: Int64 = 3_600_000
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        func device(
            _ id: String, _ platform: E2EEAutoLog.Platform, seed: UInt8, addedAgo: Int64,
            status: E2EEAutoLog.DeviceStatus = .active, revokedAgo: Int64? = nil, reason: E2EEAutoLog.RevokeReason? = nil
        ) -> E2EEAutoLog.DeviceState {
            let signing = (try? P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))?
                .publicKey.x963Representation.base64EncodedString() ?? ""
            return E2EEAutoLog.DeviceState(
                deviceId: id, platform: platform, identityKeyB64: signing, signingKeyB64: signing, keyVersion: 1, status: status,
                addedAtMs: now - addedAgo, activatedAtMs: status == .pending ? nil : now - addedAgo, addEntryHash: E2EEAutoLog.digest(id),
                identityKeys: [], revokeReason: reason, revokeSeq: reason == nil ? nil : 9, revokedAtMs: revokedAgo.map { now - $0 }
            )
        }
        var account = E2EEAutoLog.AccountState(userId: userId, accountSaltB64: Data(count: 16).base64EncodedString())
        let recent = AppEnvironment.hasQAFlag("auto-devices-recent")
        for state in [
            device(ownId, .ios, seed: 0x11, addedAgo: recent ? 5 * hour : 40 * 24 * hour),
            device("android_device_qa_00000002", .android, seed: 0x22, addedAgo: 12 * 24 * hour),
            device("web_device_qa_000000000003", .web, seed: 0x33, addedAgo: 3 * 24 * hour),
            device("web_device_qa_000000000004", .web, seed: 0x44, addedAgo: 9 * 24 * hour, status: .revoked, revokedAgo: 2 * 24 * hour, reason: .notMe),
        ] { account.devices[state.deviceId] = state }
        let refused = AppEnvironment.hasQAFlag("auto-devices-refused")
        // Libellés servis (révision 12) ; `--qa-auto-devices-unlabeled` : lecture en échec.
        let labels: [String: E2EEAutoDeviceLabels.Display] = [
            ownId: .init(label: "iPhone 17", lastSeenAtMs: now),
            "android_device_qa_00000002": .init(label: "Pixel 8", lastSeenAtMs: now - 2 * hour),
            "web_device_qa_000000000003": .init(label: "Safari sur macOS", lastSeenAtMs: now - 3 * 24 * hour),
            "web_device_qa_000000000004": .init(label: "Chrome sur Windows", lastSeenAtMs: now - 3 * 24 * hour),
        ]
        let unlabeled = AppEnvironment.hasQAFlag("auto-devices-unlabeled")
        return E2EEAutoDevicesViewModel(dependencies: .init(
            ownDeviceId: { ownId },
            readOwnAccount: { refused ? .refused : .verified(account) },
            revoke: { _, _ in .revoked(ownDevice: false) },
            readLabels: { unlabeled ? nil : labels },
            passkeyOffer: {
                if AppEnvironment.hasQAFlag("auto-devices-passkey-update") { return .update(credentialIds: ["AQID"]) }
                return AppEnvironment.hasQAFlag("auto-devices-passkey") ? .create : .none
            }
        ))
    }
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            E2EEAutoDevicesView(model: Self.model())
        }
        #else
        EmptyView()
        #endif
    }
}
