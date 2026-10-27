import SwiftUI

// MARK: - Alerte de fourche (E2EE-AUTO §3.5, §3.7)

/// Écart du journal gardé ici : signalement à l'équipe avec l'accord de
/// l'utilisateur, puis, s'il le veut, réinitialisation volontaire.
@MainActor
final class E2EEAutoLogAlertViewModel: ObservableObject {
    enum Report: Equatable {
        case idle, sending, sent, failed
    }

    struct Dependencies {
        var submit: @MainActor (BugReportSubmission) async throws -> String
        var reset: @MainActor () async throws -> Void
        var reportId: @MainActor () -> String?
        var setReported: @MainActor (String) -> Void
        var device: @MainActor () -> BugReportDevice
    }

    let alert: E2EEAutoLogStore.Alert
    let device: BugReportDevice
    @Published private(set) var report: Report
    @Published private(set) var isResetting = false
    @Published private(set) var resetFailed = false
    @Published private(set) var didReset = false
    private let dependencies: Dependencies

    init(alert: E2EEAutoLogStore.Alert, dependencies: Dependencies) {
        self.alert = alert
        self.dependencies = dependencies
        device = dependencies.device()
        report = dependencies.reportId() == nil ? .idle : .sent
    }

    enum Kind: Equatable {
        case fork
        case rollback
        /// Révision 13 : liste signée contraire aux règles du journal, traitée comme une fourche.
        case chainInvalid
    }

    var kind: Kind {
        switch alert.error {
        case E2EEAutoLog.ChainError.rollback.rawValue: return .rollback
        case E2EEAutoLog.ChainError.chainInvalid.rawValue: return .chainInvalid
        default: return .fork
        }
    }

    func sendReport() async {
        guard report != .sending, report != .sent else { return }
        report = .sending
        do {
            let id = try await dependencies.submit(E2EEAutoLogAlerts.submission(alert, device: device))
            dependencies.setReported(id)
            report = .sent
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Signalement envoyé"))
        } catch {
            report = .failed
        }
    }

    /// Seulement après le signalement : l'équipe est prévenue avant que l'écart soit oublié ici.
    func reset() async {
        guard report == .sent, !isResetting else { return }
        isResetting = true
        resetFailed = false
        defer { isResetting = false }
        do {
            try await dependencies.reset()
            didReset = true
        } catch {
            resetFailed = true
        }
    }
}

extension E2EEAutoLogAlertViewModel {
    static func live(alert: E2EEAutoLogStore.Alert, ownerScopeId: String, services: AppServices) -> E2EEAutoLogAlertViewModel {
        let alerts = E2EEAutoLogAlerts()
        return E2EEAutoLogAlertViewModel(alert: alert, dependencies: .init(
            submit: { try await services.bugReports.submit($0, submissionID: UUID()).id },
            reset: {
                try alerts.reset(ownerScopeId: ownerScopeId)
                await services.e2eeV2Messaging.invalidateDevices()
            },
            reportId: { alerts.reportId(for: alert, ownerScopeId: ownerScopeId) },
            setReported: { alerts.setReported($0, for: alert, ownerScopeId: ownerScopeId) },
            device: { .current(network: services.networkPath.status.displayName) }
        ))
    }
}

/// Présente l'alerte à l'ouverture, une fois par lancement : « Plus tard » la
/// laisse au bandeau de la Messagerie jusqu'au lancement suivant.
@MainActor
final class E2EEAutoLogAlertCoordinator: ObservableObject {
    @Published private(set) var model: E2EEAutoLogAlertViewModel?
    private var postponed: Set<String> = []
    private let alerts: E2EEAutoLogAlerts

    init(alerts: E2EEAutoLogAlerts = E2EEAutoLogAlerts()) {
        self.alerts = alerts
    }

    var isPresented: Bool { model != nil }

    func refresh(ownerScopeId: String, makeModel: (E2EEAutoLogStore.Alert) -> E2EEAutoLogAlertViewModel) {
        guard model == nil, !postponed.contains(ownerScopeId),
              let alert = alerts.current(ownerScopeId: ownerScopeId) else { return }
        model = makeModel(alert)
    }

    func close(ownerScopeId: String?) {
        if let ownerScopeId, model?.didReset != true { postponed.insert(ownerScopeId) }
        model = nil
    }

    /// Déconnexion : rien d'un compte ne reste à l'écran du suivant.
    func reset() {
        model = nil
        postponed = []
    }
}

struct E2EEAutoLogAlertView: View {
    @ObservedObject var model: E2EEAutoLogAlertViewModel
    let onClose: () -> Void
    @State private var confirmsReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Image(systemName: model.didReset ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(model.didReset ? SQColor.label : SQColor.dangerInk)
                    .accessibilityHidden(true)
                if model.didReset {
                    done
                } else {
                    explanation
                    reportCard
                    reportActions
                    if model.report == .sent { resetSection }
                    GradientButton(String(localized: "Plus tard"), style: .ghost) { onClose() }
                        .disabled(model.isResetting)
                        .accessibilityIdentifier("e2eeAuto.logAlert.later")
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
        .confirmationDialog(
            String(localized: "Refaire confiance au journal actuel ?"),
            isPresented: $confirmsReset, titleVisibility: .visible
        ) {
            Button(String(localized: "Refaire confiance"), role: .destructive) {
                Task { await model.reset() }
            }
            Button(String(localized: "Annuler"), role: .cancel) {}
        } message: {
            Text("Cet appareil oubliera le journal qu’il avait vérifié. Si un appareil a été glissé à ton insu, il recevra de nouveau tes messages.")
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            Text("Journal relu depuis le début")
                .font(SQType.display)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Text("Cet appareil vérifie de nouveau le journal que montre le serveur. L’envoi chiffré reprend dès que c’est fait. Vérifie ensuite tes appareils dans Réglages > Appareils.")
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "OK")) { onClose() }
                .accessibilityIdentifier("e2eeAuto.logAlert.done")
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Le journal de tes appareils ne correspond plus")
                .font(SQType.display)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                switch model.kind {
                case .fork:
                    Text("Le serveur montre une autre version de la liste des appareils que celle que cet appareil a déjà vérifiée.")
                case .rollback:
                    Text("Le serveur montre une version plus ancienne de la liste des appareils que celle que cet appareil a déjà vérifiée.")
                case .chainInvalid:
                    Text("Le serveur a signé une liste des appareils qui ne respecte pas les règles du journal.")
                }
            }
            .font(SQType.body)
            .foregroundStyle(SQColor.label)
            .fixedSize(horizontal: false, vertical: true)
            Text("Cela peut venir d’une erreur du serveur, ou d’une tentative de glisser un appareil dans tes conversations. Par précaution, cet appareil n’envoie plus de messages chiffrés. Ceux déjà reçus restent lisibles.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gapText: String {
        switch model.kind {
        case .fork: return String(localized: "Deux versions du journal")
        case .rollback: return String(localized: "Retour en arrière")
        case .chainInvalid: return String(localized: "Liste signée hors des règles")
        }
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Ce que contient le signalement")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            row(String(localized: "Écart"), gapText)
            row(String(localized: "Maillon"), String(model.alert.seq))
            row(String(localized: "App"), model.device.appVersion)
            row(String(localized: "Appareil"), "\(model.device.model), \(model.device.osVersion)")
            Text("Aucun message ni contact n’est envoyé.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.top, SQSpace.xs)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
                Text(verbatim: label).foregroundStyle(SQColor.labelSecondary)
                Spacer(minLength: SQSpace.sm)
                Text(verbatim: value).foregroundStyle(SQColor.label).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label).foregroundStyle(SQColor.labelSecondary)
                Text(verbatim: value).foregroundStyle(SQColor.label)
            }
        }
        .font(SQType.body)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var reportActions: some View {
        switch model.report {
        case .sent:
            Label("Signalement envoyé. Tu peux le suivre dans Profil > Mes signalements.", systemImage: "checkmark.circle.fill")
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("e2eeAuto.logAlert.sent")
        case .idle, .sending, .failed:
            if model.report == .failed {
                Label("Le signalement n’est pas parti. Vérifie ta connexion et réessaie.", systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GradientButton(String(localized: "Signaler à l’équipe"), isBusy: model.report == .sending) {
                Task { await model.sendReport() }
            }
            .disabled(model.report == .sending)
            .accessibilityIdentifier("e2eeAuto.logAlert.report")
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Si l’équipe te le conseille, ou si tu reconnais tous tes appareils, cet appareil peut refaire confiance au journal que montre le serveur maintenant.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.resetFailed {
                Label("La réinitialisation a échoué. Réessaie.", systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GradientButton(String(localized: "Refaire confiance au journal actuel"), isBusy: model.isResetting, style: .destructive, allowsMultiline: true) {
                confirmsReset = true
            }
            .disabled(model.isResetting)
            .accessibilityIdentifier("e2eeAuto.logAlert.reset")
        }
    }
}

/// En tête de la Messagerie tant que l'alerte dure, même après « Plus tard ».
struct E2EEAutoLogAlertBanner: View {
    @EnvironmentObject private var services: AppServices
    @State private var alert: E2EEAutoLogStore.Alert?
    @State private var ownerScopeId: String?
    @State private var model: E2EEAutoLogAlertViewModel?

    var body: some View {
        Group {
            if let alert, let ownerScopeId {
                Button {
                    model = .live(alert: alert, ownerScopeId: ownerScopeId, services: services)
                } label: {
                    E2EEAutoLogAlertBannerContent()
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Ouvre l’alerte"))
                .accessibilityIdentifier("e2eeAuto.logAlert.banner")
            }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: E2EEAutoLogAlerts.didChange).receive(on: RunLoop.main)) { _ in reload() }
        .sheet(item: Binding(get: { model.map(SheetItem.init) }, set: { if $0 == nil { model = nil } })) { item in
            E2EEAutoLogAlertView(model: item.model) {
                model = nil
                reload()
            }
        }
    }

    private struct SheetItem: Identifiable {
        let model: E2EEAutoLogAlertViewModel
        var id: ObjectIdentifier { ObjectIdentifier(model) }
    }

    private func reload() {
        guard SQFeatures.e2eeAutoLogEnabled, let session = LocalAccountScope.sessionSnapshot() else {
            alert = nil
            return
        }
        ownerScopeId = session.ownerScopeId
        alert = E2EEAutoLogAlerts().current(ownerScopeId: session.ownerScopeId)
    }
}

struct E2EEAutoLogAlertBannerContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Aux tailles d'accessibilité, les icônes coupaient le titre en plein mot.
        let showsIcons = !dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .top, spacing: SQSpace.md) {
            if showsIcons {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SQColor.dangerInk)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Envoi chiffré suspendu")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Text("Le journal de tes appareils ne correspond plus à celui vérifié ici.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showsIcons {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(SQSpace.md)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Banc visuel (simulateur Debug) : `--qa-auto-log-alert`, `--qa-auto-log-alert-rollback`
/// pour un retour en arrière, `--qa-auto-log-alert-invalid` pour une chaîne
/// invalide, `--qa-auto-log-alert-sent` après le signalement,
/// `--qa-auto-log-alert-banner` pour le bandeau de la Messagerie.
struct E2EEAutoLogAlertQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @StateObject private var model = Self.model()

    private static func model() -> E2EEAutoLogAlertViewModel {
        let arguments = ProcessInfo.processInfo.arguments
        return E2EEAutoLogAlertViewModel(
            alert: .init(
                error: arguments.contains("--qa-auto-log-alert-rollback") ? "ROLLBACK"
                    : arguments.contains("--qa-auto-log-alert-invalid") ? "CHAIN_INVALID" : "FORK",
                seq: 1_284
            ),
            dependencies: .init(
                submit: { _ in
                    try await Task.sleep(nanoseconds: 600_000_000)
                    return "bug_qa"
                },
                reset: { try await Task.sleep(nanoseconds: 600_000_000) },
                reportId: { arguments.contains("--qa-auto-log-alert-sent") ? "bug_qa" : nil },
                setReported: { _ in },
                device: {
                    BugReportDevice(model: "iPhone 17", osVersion: "iOS 27.0", appVersion: "1.0 (180)", build: "180",
                                    network: "Wi-Fi", screenSize: "402x874")
                }
            )
        )
    }
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--qa-auto-log-alert-banner") {
            E2EEAutoLogAlertBannerContent()
                .padding(.horizontal, SQSpace.xl)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, SQSpace.xl)
                .background(SQColor.bg.ignoresSafeArea())
        } else {
            E2EEAutoLogAlertView(model: model) {}
        }
        #else
        EmptyView()
        #endif
    }
}
