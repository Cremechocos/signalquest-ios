import SwiftUI

/// Ce qui change le réglage : au branchement (lot 8), la messagerie v2, qui
/// signe le changement, l'ajoute à la chaîne d'appartenance et crée aussitôt
/// l'époque suivante (§3.3).
protocol E2EEV2BrowserExclusionChanging: Sendable {
    func setExcludesBrowsers(_ on: Bool) async -> E2EEV2MembershipWriteResultV2
}

/// Réglage « exclure les navigateurs » d'une conversation chiffrée v2 (§2.7) :
/// un admin le règle dans un groupe, l'un des deux membres en tête-à-tête
/// (D.4). Chaque membre le voit en message système vérifié.
@MainActor
final class E2EEV2BrowserExclusionModel: ObservableObject {
    @Published private(set) var excludesBrowsers: Bool
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    let canChange: Bool
    private let isGroup: Bool
    private let changer: any E2EEV2BrowserExclusionChanging

    init(excludesBrowsers: Bool, isGroup: Bool, isAdmin: Bool, changer: any E2EEV2BrowserExclusionChanging) {
        self.excludesBrowsers = excludesBrowsers
        self.isGroup = isGroup
        canChange = !isGroup || isAdmin
        self.changer = changer
    }

    func set(_ on: Bool) async {
        guard canChange, !isSaving, on != excludesBrowsers else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        switch await changer.setExcludesBrowsers(on) {
        case .applied:
            excludesBrowsers = on
            UIAccessibility.post(
                notification: .announcement,
                argument: on ? String(localized: "Navigateurs exclus") : String(localized: "Navigateurs de nouveau autorisés")
            )
        case .notAllowed:
            error = isGroup
                ? String(localized: "Seul un admin du groupe peut changer ce réglage.")
                : String(localized: "Ce réglage ne peut plus être changé depuis ton compte.")
        case .needsSync:
            error = String(localized: "La conversation vient de changer. Réessaie.")
        case .failure:
            error = String(localized: "Impossible d’enregistrer ce réglage. Vérifie ta connexion et réessaie.")
        }
    }
}

struct E2EEV2BrowserExclusionRow: View {
    @ObservedObject var model: E2EEV2BrowserExclusionModel

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Toggle(isOn: Binding(get: { model.excludesBrowsers }, set: { on in Task { await model.set(on) } })) {
                HStack(spacing: SQSpace.sm) {
                    Text("Exclure les navigateurs")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                    if model.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .tint(SQColor.brandRed)
            .disabled(!model.canChange || model.isSaving)
            .frame(minHeight: 44)
            .accessibilityIdentifier("browsers.toggle")

            Text("Les navigateurs web ne pourront plus lire les nouveaux messages de cette conversation ni rejoindre ses appels. Ce qu’ils ont déjà reçu y reste lisible. Tous les membres sont prévenus.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("browsers.explanation")

            if !model.canChange {
                Text("Seul un admin du groupe peut changer ce réglage.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("browsers.adminOnly")
            }
            if let error = model.error {
                Text(error)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("browsers.error")
            }
        }
    }
}

/// Démonstration du réglage (`--qa-e2ee-browsers`, admin dont le changement
/// passe ; `--qa-e2ee-browsers-member`, membre d'un groupe ;
/// `--qa-e2ee-browsers-refused`, changement refusé par les règles).
struct E2EEV2BrowserExclusionQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    private struct Changer: E2EEV2BrowserExclusionChanging {
        let result: E2EEV2MembershipWriteResultV2
        func setExcludesBrowsers(_ on: Bool) async -> E2EEV2MembershipWriteResultV2 { result }
    }

    @StateObject private var model: E2EEV2BrowserExclusionModel = {
        let arguments = ProcessInfo.processInfo.arguments
        return E2EEV2BrowserExclusionModel(
            excludesBrowsers: false,
            isGroup: true,
            isAdmin: !arguments.contains("--qa-e2ee-browsers-member"),
            changer: Changer(result: arguments.contains("--qa-e2ee-browsers-refused") ? .notAllowed : .applied(changeNumber: 7))
        )
    }()
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        NavigationStack {
            List {
                Section {
                    E2EEV2BrowserExclusionRow(model: model)
                }
                .listRowBackground(SQColor.surface)
            }
            .scrollContentBackground(.hidden)
            .background(SQColor.bg)
            .navigationTitle("Navigateurs v2 QA")
        }
        #else
        EmptyView()
        #endif
    }
}
