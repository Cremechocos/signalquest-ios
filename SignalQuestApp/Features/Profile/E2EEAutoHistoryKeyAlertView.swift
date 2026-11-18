import SwiftUI

// MARK: - Alerte « Nouvelle clé d'historique » (E2EE-AUTO §5.1, révision 23)

/// Une HK suspecte écrite après celle que l'appareil détient (`E2EEAutoHistoryKeyAlert`) : un
/// bandeau ambre dans Messages (A1), qui ouvre la fenêtre (A2). « C'est moi » acquitte la HK
/// et mène à l'écran « Retrouver mes messages » (A3) ; « Ce n'est pas moi » retire le signataire
/// en `NOT_ME` (A4). Rien n'est bloqué : seule la sauvegarde de l'historique attend. Ce qui est
/// montré vient du journal vérifié, sauf le libellé (§4.2), affiché tel quel.
@MainActor
final class E2EEAutoHistoryKeyAlertCoordinator: ObservableObject {
    /// Issue d'un passage de la publication de HK : l'alerte se lève, tombe, ou reste.
    nonisolated static let changed = Notification.Name("SignalQuest.E2EEAuto.HistoryKeyAlertChanged")

    struct Alert: Equatable {
        let suspect: E2EEAutoHistoryKeyAlert.Suspect
        let ownerNamespace: String
    }

    @Published private(set) var alert: Alert?
    /// La fenêtre (A2, puis A4) est ouverte.
    @Published private(set) var isPresented = false
    /// « Ce n'est pas moi » touché : la fenêtre passe au retrait du signataire (A4).
    @Published private(set) var answeredNotMe = false
    private(set) var model: E2EEAutoDevicesViewModel?
    /// Le suspect de la fenêtre ouverte : il reste jusqu'à « OK », même si l'alerte tombe entre-temps
    /// (r23.2 : une dernière HK annulée fait tomber le bandeau, jamais la fenêtre « Appareil retiré »).
    private var presentedSuspect: E2EEAutoHistoryKeyAlert.Suspect?
    private var opening = false
    private let acknowledge: (_ hkPubB64: String, _ ownerNamespace: String) -> Void

    init(acknowledge: @escaping (_ hkPubB64: String, _ ownerNamespace: String) -> Void = { hkPubB64, ownerNamespace in
        E2EEAutoHistoryKeyAcknowledgements.acknowledge(
            hkPubB64, store: KeychainStore(service: "fr.signalquest.ios.e2ee"), ownerNamespace: ownerNamespace
        )
    }) {
        self.acknowledge = acknowledge
    }

    var showsBanner: Bool { alert != nil }

    /// `.unexpected` lève l'alerte ; une HK détenue, des HK toutes jugées ou une dernière HK
    /// annulée la font tomber (r23.2, choix d'Alexandre du 16/11 : sans attendre la rotation depuis
    /// la base ; le §5.3 reste fermé pendant l'attente). Un échec de lecture ne change rien.
    nonisolated static func post(_ outcome: E2EEAutoHistoryKeyPublication.Outcome, ownerNamespace: String) {
        var info: [String: String] = ["ownerNamespace": ownerNamespace]
        switch outcome {
        case .unexpected(let suspect):
            info["hkPubB64"] = suspect.hkPubB64
            info["signerDeviceId"] = suspect.signerDeviceId
        case .present, .missing, .unvouched, .cancelled:
            info["clear"] = "1"
        case .notActive, .tooRecent, .retryLater, .logRefused, .failed:
            return
        }
        NotificationCenter.default.post(name: changed, object: nil, userInfo: info)
    }

    func apply(_ userInfo: [AnyHashable: Any]?, ownerNamespace: String?) {
        guard let info = userInfo as? [String: String], let namespace = info["ownerNamespace"], namespace == ownerNamespace else { return }
        if let hkPubB64 = info["hkPubB64"], let signerDeviceId = info["signerDeviceId"] {
            let next = Alert(suspect: .init(hkPubB64: hkPubB64, signerDeviceId: signerDeviceId), ownerNamespace: namespace)
            guard next != alert else { return }
            // Une autre HK suspecte : la fenêtre repart de la question.
            if alert != nil, isPresented, !answeredNotMe { close() }
            alert = next
        } else if info["clear"] != nil {
            alert = nil
            // Un retrait affiché reste jusqu'à « OK ».
            if isPresented, !answeredNotMe { close() }
        }
    }

    /// Bandeau touché : le compte relu (plateforme, date d'ajout, statut du signataire), puis la fenêtre.
    func open(makeModel: () -> E2EEAutoDevicesViewModel) async {
        guard alert != nil, !isPresented, !opening else { return }
        opening = true
        defer { opening = false }
        let model = makeModel()
        await model.load()
        guard let alert else { return }
        self.model = model
        presentedSuspect = alert.suspect
        answeredNotMe = false
        isPresented = true
    }

    /// Le signataire, tel que le journal vérifié le montre ; nil s'il n'a pas pu être relu.
    var signerRow: E2EEAutoDevicesViewModel.Row? {
        guard let suspect = presentedSuspect ?? alert?.suspect, let model else { return nil }
        return model.row(id: suspect.signerDeviceId)
    }

    /// « C'est moi » : la HK suspecte est acquittée ici, l'alerte tombe ; la suite (A3) part
    /// du passage suivant. Rend l'alerte acquittée.
    @discardableResult
    func itsMe() -> Alert? {
        guard let alert else { return nil }
        acknowledge(alert.suspect.hkPubB64, alert.ownerNamespace)
        self.alert = nil
        close()
        return alert
    }

    /// « Ce n'est pas moi » : retrait direct du signataire en `NOT_ME` (A4), par le même
    /// parcours que l'alerte « Nouvel appareil » (code e-mail sous 24 h d'ancienneté).
    func notMe() async {
        answeredNotMe = true
        guard let model, let row = signerRow, row.status != .revoked, model.canRevokeOthers || model.revokesOthersByEmail else { return }
        await model.revoke(row, reason: .notMe)
    }

    /// « Plus tard » ou « OK » : le bandeau reste tant que l'alerte dure.
    func close() {
        isPresented = false
        answeredNotMe = false
        model = nil
        presentedSuspect = nil
    }

    /// Déconnexion : rien d'un compte ne reste à l'écran du suivant.
    func reset() {
        alert = nil
        close()
    }
}

/// A1 : bandeau ambre de la liste des conversations, sans suspension de l'envoi.
struct E2EEAutoHistoryKeyAlertBanner: View {
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "key.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(SQColor.warning)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Nouvelle clé d’historique sur ton compte")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Vérifie que c’est bien toi.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(SQSpace.md)
            .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Ouvre l’alerte"))
        .accessibilityIdentifier("e2eeAuto.historyKeyAlert.banner")
    }
}

/// A2 puis A4, en calque comme les autres alertes de sécurité.
struct E2EEAutoHistoryKeyAlertView: View {
    @ObservedObject var coordinator: E2EEAutoHistoryKeyAlertCoordinator
    @ObservedObject var model: E2EEAutoDevicesViewModel
    let onItsMe: () -> Void
    /// Retrait écrit : la rotation depuis la base peut partir tout de suite.
    var onRevoked: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Image(systemName: "key.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(SQColor.warning)
                    .accessibilityHidden(true)
                if let row = coordinator.signerRow, Self.removedAsNotMe(row) || model.confirmationMessage != nil {
                    removed
                } else if coordinator.answeredNotMe {
                    notMe
                } else {
                    question
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
        .sheet(item: $model.emailConfirmation) { _ in
            E2EEAutoEmailConfirmationSheet(model: model)
        }
        .onChange(of: model.confirmationMessage) { message in
            if message != nil { onRevoked() }
        }
    }

    private var title: some View {
        Text("Nouvelle clé d’historique sur ton compte")
            .font(SQType.display)
            .foregroundStyle(SQColor.label)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A2 : la question, avec ce que le journal dit du signataire.
    @ViewBuilder
    private var question: some View {
        title
        Text("Un autre appareil a créé une nouvelle clé pour ton historique chiffré. C’est normal si tu as perdu tes anciens messages et recommencé sur l’autre appareil.")
            .font(SQType.body)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if let row = coordinator.signerRow {
            Text(String(localized: "Créée par : \(Self.deviceName(row)), ajouté à ton compte le \(Self.date(row.addedAtMs))"))
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SQSpace.lg)
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
        Text("En attendant ta réponse, cet appareil ne sauvegarde plus tes nouveaux messages dans ton historique. Tes messages continuent de partir chiffrés.")
            .font(SQType.body)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        GradientButton("C’est moi") { onItsMe() }
            .accessibilityIdentifier("e2eeAuto.historyKeyAlert.itsMe")
        GradientButton("Ce n’est pas moi", style: .destructive) {
            Task { await coordinator.notMe() }
        }
        .accessibilityIdentifier("e2eeAuto.historyKeyAlert.notMe")
        if let row = coordinator.signerRow, row.status != .revoked {
            Group {
                if model.canRevokeOthers {
                    Text("« Ce n’est pas moi » le retire tout de suite et ferme toutes tes autres sessions.")
                } else if model.revokesOthersByEmail {
                    Text("Cet appareil-ci a été ajouté il y a moins de 24 h : un code envoyé par e-mail confirmera le retrait, et toutes tes autres sessions seront fermées.")
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        GradientButton("Plus tard", style: .ghost) { coordinator.close() }
            .accessibilityIdentifier("e2eeAuto.historyKeyAlert.later")
    }

    /// A4 avant ou pendant le retrait : en cours, refusé, impossible d'ici, ou déjà retiré (T4).
    @ViewBuilder
    private var notMe: some View {
        title
        if let row = coordinator.signerRow, row.status == .revoked {
            Text("Cet appareil a déjà été retiré de ton compte. Ton historique reste en pause pour ta sécurité.")
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            passwordAdvice
            GradientButton("OK") { coordinator.close() }
                .accessibilityIdentifier("e2eeAuto.historyKeyAlert.done")
        } else if let row = coordinator.signerRow, model.canRevokeOthers || model.revokesOthersByEmail {
            if model.isActing {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.isActing, model.emailConfirmation == nil {
                GradientButton("Réessayer", style: .destructive) {
                    Task { await model.revoke(row, reason: .notMe) }
                }
                .accessibilityIdentifier("e2eeAuto.historyKeyAlert.retry")
                GradientButton("Plus tard", style: .ghost) { coordinator.close() }
                    .accessibilityIdentifier("e2eeAuto.historyKeyAlert.later")
            }
        } else {
            Text("Si ce n’est pas toi, retire-le depuis un autre de tes appareils, dans Réglages > Appareils.")
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            passwordAdvice
            GradientButton("OK") { coordinator.close() }
                .accessibilityIdentifier("e2eeAuto.historyKeyAlert.done")
        }
    }

    /// A4 après le retrait (ici, ou vu au journal) : la fenêtre reste jusqu'à « OK » ; le bandeau, lui,
    /// tombe dès que la HK est annulée (r23.2).
    @ViewBuilder
    private var removed: some View {
        Text("Appareil retiré")
            .font(SQType.display)
            .foregroundStyle(SQColor.label)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
        passwordAdvice
        if SQFeatures.e2eeHistoryRotationFromBaseServed {
            Text("Ensuite, un de tes appareils remet ton historique en route.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        GradientButton("OK") { coordinator.close() }
            .accessibilityIdentifier("e2eeAuto.historyKeyAlert.done")
    }

    private var passwordAdvice: some View {
        Text("Change aussi ton mot de passe : la personne qui l’a ajouté le connaît peut-être.")
            .font(SQType.body)
            .foregroundStyle(SQColor.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func removedAsNotMe(_ row: E2EEAutoDevicesViewModel.Row) -> Bool {
        row.status == .revoked && (row.revokeReason == .notMe || row.revokeReason == .emailNotMe)
    }

    /// « Android · Pixel 8 » : la plateforme du journal, puis le libellé s'il y en a un.
    static func deviceName(_ row: E2EEAutoDevicesViewModel.Row) -> String {
        let platform = E2EEAutoDevicesView.platformName(row)
        guard let label = row.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty, label != platform else { return platform }
        return "\(platform) · \(label)"
    }

    static func date(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1_000).sqFormatted(date: .medium)
    }
}

/// Banc visuel (simulateur Debug) : `--qa-auto-history-key-alert`, avec
/// `--qa-auto-devices-recent` (garde des 24 h), `--qa-auto-history-key-alert-removed`
/// (signataire retiré en `NOT_ME`), `--qa-auto-history-key-alert-t4` (déjà retiré autrement) et
/// `--qa-auto-history-key-alert-banner` pour le bandeau seul.
struct E2EEAutoHistoryKeyAlertQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @StateObject private var coordinator = E2EEAutoHistoryKeyAlertCoordinator(acknowledge: { _, _ in })
    @State private var loaded = false
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        Group {
            if AppEnvironment.hasQAFlag("auto-history-key-alert-banner") {
                VStack {
                    E2EEAutoHistoryKeyAlertBanner {}
                    Spacer()
                }
                .padding(SQSpace.lg)
                .background(SQColor.bg.ignoresSafeArea())
            } else if loaded, let model = coordinator.model {
                E2EEAutoHistoryKeyAlertView(coordinator: coordinator, model: model, onItsMe: {})
            } else {
                Color.clear
            }
        }
        .task {
            let signer = AppEnvironment.hasQAFlag("auto-history-key-alert-removed") ? "web_device_qa_000000000004"
                : AppEnvironment.hasQAFlag("auto-history-key-alert-t4") ? "web_device_qa_000000000005" : "web_device_qa_000000000003"
            coordinator.apply(
                ["ownerNamespace": "qa", "hkPubB64": "qa-hk", "signerDeviceId": signer], ownerNamespace: "qa"
            )
            await coordinator.open { E2EEAutoDevicesQAScreen.model() }
            // T4 : « Ce n'est pas moi » sur un signataire déjà retiré autrement.
            if AppEnvironment.hasQAFlag("auto-history-key-alert-t4") { await coordinator.notMe() }
            loaded = true
        }
        #else
        EmptyView()
        #endif
    }
}
