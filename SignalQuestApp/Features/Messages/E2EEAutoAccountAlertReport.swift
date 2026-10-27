import SwiftUI

/// Avis du fil chiffré : texte de l'avis et, s'il mène quelque part, son action.
struct E2EEV2NoticeLabel: View {
    let notice: E2EEV2ThreadPresentation.Notice
    let detail: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(notice.text)
                if let detail {
                    Text(detail)
                        .fontWeight(.semibold)
                        .foregroundStyle(SQColor.accentInk)
                }
            }
        } icon: {
            Image(systemName: "lock.trianglebadge.exclamationmark")
        }
        .font(SQType.caption)
        .foregroundStyle(SQColor.labelSecondary)
        .frame(maxWidth: .infinity, minHeight: detail == nil ? nil : 44, alignment: .leading)
        .padding(.vertical, SQSpace.xs)
        .contentShape(Rectangle())
    }
}

// MARK: - Maillon d'un contact sans entrée (E2EE-AUTO §3.5 point 5)

/// Signalement, depuis la ligne de sécurité d'une conversation, d'un journal
/// de contact qui ne correspond pas. L'alerte reste ; seul l'envoi à l'équipe
/// se fait d'ici, après avoir montré ce qui part.
@MainActor
final class E2EEAutoAccountAlertReportModel: ObservableObject {
    struct Dependencies {
        var alert: @MainActor () -> E2EEAutoLogStore.Alert?
        var submit: @MainActor (BugReportSubmission) async throws -> String
        var reportId: @MainActor (E2EEAutoLogStore.Alert) -> String?
        var setReported: @MainActor (String, E2EEAutoLogStore.Alert) -> Void
        var device: @MainActor () -> BugReportDevice
    }

    @Published private(set) var report: E2EEAutoLogAlertViewModel.Report = .idle
    private(set) var alert: E2EEAutoLogStore.Alert?
    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        reload()
    }

    func reload() {
        alert = dependencies.alert()
        guard report != .sending else { return }
        report = alert.flatMap(dependencies.reportId) == nil ? .idle : .sent
    }

    var detail: String {
        switch report {
        case .idle: return String(localized: "Signaler à l’équipe")
        case .sending: return String(localized: "Envoi du signalement…")
        case .sent: return String(localized: "Signalement envoyé")
        case .failed: return String(localized: "Le signalement n’est pas parti. Réessaie.")
        }
    }

    /// Ce qui part, dit avant l'envoi.
    var contents: String {
        String(localized: "Le signalement contient l’écart (entrée du journal absente), son maillon (\(String(alert?.seq ?? 0))), la version de l’app et le modèle de cet appareil. Aucun message ni contact n’est envoyé.")
    }

    func send() async {
        guard let alert, report != .sending, report != .sent else { return }
        report = .sending
        do {
            let id = try await dependencies.submit(E2EEAutoLogAlerts.accountSubmission(alert, device: dependencies.device()))
            dependencies.setReported(id, alert)
            report = .sent
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Signalement envoyé"))
        } catch {
            report = .failed
        }
    }
}

extension E2EEAutoAccountAlertReportModel {
    static func live(userId: String, services: AppServices) -> E2EEAutoAccountAlertReportModel {
        let alerts = E2EEAutoLogAlerts()
        let owner = { LocalAccountScope.sessionSnapshot()?.ownerScopeId }
        return E2EEAutoAccountAlertReportModel(dependencies: .init(
            alert: { owner().flatMap { alerts.accountAlert(userId: userId, ownerScopeId: $0) } },
            submit: { try await services.bugReports.submit($0, submissionID: UUID()).id },
            reportId: { alert in owner().flatMap { alerts.accountReportId(for: alert, userId: userId, ownerScopeId: $0) } },
            setReported: { id, alert in
                if let owner = owner() { alerts.setAccountReported(id, for: alert, userId: userId, ownerScopeId: owner) }
            },
            device: { .current(network: services.networkPath.status.displayName) }
        ))
    }
}

/// La ligne « le journal des appareils de X ne correspond pas » et son signalement.
struct E2EEAutoAccountAlertReportRow: View {
    @EnvironmentObject private var services: AppServices
    let notice: E2EEV2ThreadPresentation.Notice
    let userId: String
    @State private var model: E2EEAutoAccountAlertReportModel?

    var body: some View {
        Group {
            if let model {
                E2EEAutoAccountAlertReportButton(notice: notice, model: model)
            } else {
                E2EEV2NoticeLabel(notice: notice, detail: nil)
            }
        }
        .onAppear {
            if model == nil { model = .live(userId: userId, services: services) } else { model?.reload() }
        }
    }
}

struct E2EEAutoAccountAlertReportButton: View {
    let notice: E2EEV2ThreadPresentation.Notice
    @ObservedObject var model: E2EEAutoAccountAlertReportModel
    @State private var confirms = false

    var body: some View {
        if model.report == .sent || model.alert == nil {
            E2EEV2NoticeLabel(notice: notice, detail: model.alert == nil ? nil : model.detail)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("conversation.v2Notice.logMismatch")
        } else {
            Button {
                confirms = true
            } label: {
                E2EEV2NoticeLabel(notice: notice, detail: model.detail)
            }
            .buttonStyle(.plain)
            .disabled(model.report == .sending)
            .accessibilityIdentifier("conversation.v2Notice.logMismatch.report")
            .confirmationDialog(
                String(localized: "Signaler cet écart à l’équipe ?"),
                isPresented: $confirms, titleVisibility: .visible
            ) {
                Button(String(localized: "Envoyer le signalement")) {
                    Task { await model.send() }
                }
                Button(String(localized: "Annuler"), role: .cancel) {}
            } message: {
                Text(verbatim: model.contents)
            }
        }
    }
}

/// Banc visuel (simulateur Debug) : `--qa-auto-log-mismatch`, et
/// `--qa-auto-log-mismatch-sent` après le signalement.
struct E2EEAutoAccountAlertQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @StateObject private var model = Self.model()

    private static func model() -> E2EEAutoAccountAlertReportModel {
        E2EEAutoAccountAlertReportModel(dependencies: .init(
        alert: { .init(error: "ENTRY_MISSING", seq: 1_284) },
        submit: { _ in
            try await Task.sleep(nanoseconds: 600_000_000)
            return "bug_qa"
        },
        reportId: { _ in ProcessInfo.processInfo.arguments.contains("--qa-auto-log-mismatch-sent") ? "bug_qa" : nil },
        setReported: { _, _ in },
        device: {
            BugReportDevice(model: "iPhone 17", osVersion: "iOS 27.0", appVersion: "1.0 (180)", build: "180",
                            network: "Wi-Fi", screenSize: "402x874")
        }
        ))
    }
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                E2EEAutoAccountAlertReportButton(notice: .logMismatch(userId: "user_qa", name: "Camille"), model: model)
                E2EEV2NoticeLabel(notice: .logMismatch(userId: "user_qa", name: nil), detail: nil)
                E2EEV2NoticeLabel(notice: .devicesChanged(userId: "user_qa", name: "Camille"), detail: nil)
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.xl)
        }
        .background(SQColor.bg.ignoresSafeArea())
        #else
        EmptyView()
        #endif
    }
}
