import SwiftUI

// MARK: - Alerte « Nouvel appareil » (E2EE-AUTO §4.2)

/// Présente, un à un, les appareils ajoutés à son propre compte. Tout ce qui
/// est montré vient du journal vérifié, relu juste avant : un appareil déjà
/// retiré, ou que le compte vérifié ne connaît pas, n'est jamais signalé.
@MainActor
final class E2EEAutoNewDeviceAlertCoordinator: ObservableObject {
    struct Presented: Equatable {
        let deviceId: String
        let ownerNamespace: String
    }

    @Published private(set) var presented: Presented?
    private(set) var model: E2EEAutoDevicesViewModel?
    private var checking = false
    /// « Plus tard » : plus présenté avant le prochain lancement.
    private var postponed: Set<String> = []
    private let store: E2EEAutoNewDeviceAlerts

    init(store: E2EEAutoNewDeviceAlerts = E2EEAutoNewDeviceAlerts()) {
        self.store = store
    }

    func refresh(ownerNamespace: String, makeModel: () -> E2EEAutoDevicesViewModel) async {
        guard presented == nil, !checking else { return }
        let pending = store.pending(ownerNamespace: ownerNamespace).filter { !postponed.contains($0) }
        guard !pending.isEmpty else { return }
        checking = true
        defer { checking = false }
        let model = makeModel()
        await model.load()
        // Journal refusé ou injoignable : la file attend la prochaine lecture.
        guard model.phase == .loaded else { return }
        let others = Set(model.rows.filter { !$0.isCurrent }.map(\.id))
        // Déjà retiré, ou inconnu du compte vérifié : plus rien à signaler.
        for id in pending where !others.contains(id) {
            store.resolve(id, ownerNamespace: ownerNamespace)
        }
        guard let id = pending.first(where: others.contains) else { return }
        self.model = model
        presented = Presented(deviceId: id, ownerNamespace: ownerNamespace)
    }

    /// `resolved` : « C'est moi » ou appareil retiré ; sinon l'alerte revient au prochain lancement.
    func close(resolved: Bool) {
        guard let presented else { return }
        if resolved {
            store.resolve(presented.deviceId, ownerNamespace: presented.ownerNamespace)
        } else {
            postponed.insert(presented.deviceId)
        }
        self.presented = nil
        model = nil
    }

    /// Déconnexion : rien d'un compte ne reste à l'écran du suivant.
    func reset() {
        presented = nil
        model = nil
        postponed = []
    }
}

struct E2EEAutoNewDeviceAlertView: View {
    let deviceId: String
    @ObservedObject var model: E2EEAutoDevicesViewModel
    let onClose: (_ resolved: Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Image(systemName: "lock.shield.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Text("Nouvel appareil sur ton compte")
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = model.confirmationMessage {
                    Text(message)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    GradientButton(String(localized: "OK")) { onClose(true) }
                        .accessibilityIdentifier("e2eeAuto.newDevice.done")
                } else if let row = model.rows.first(where: { $0.id == deviceId }) {
                    Text("Il vient d’être ajouté à ton compte et reçoit désormais tes messages chiffrés. Si c’est toi, il n’y a rien à faire.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    deviceCard(row)
                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.dangerInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions(row)
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
    }

    private func deviceCard(_ row: E2EEAutoDevicesViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(E2EEAutoDevicesView.deviceName(row))
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text(E2EEAutoDevicesView.addedText(row))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            if let activity = E2EEAutoDevicesView.activityText(row) {
                Text(activity)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if !row.shortFingerprint.isEmpty {
                Text("Empreinte")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.top, SQSpace.xs)
                Text(row.shortFingerprint.joined(separator: " "))
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .textSelection(.enabled)
                    .accessibilityLabel(String(localized: "Empreinte \(row.shortFingerprint.joined(separator: ", "))"))
                Text("Elle s’affiche aussi sur l’appareil, dans Réglages > Appareils, pour « Cet appareil ».")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func actions(_ row: E2EEAutoDevicesViewModel.Row) -> some View {
        GradientButton(String(localized: "C’est moi")) { onClose(true) }
            .disabled(model.isActing)
            .accessibilityIdentifier("e2eeAuto.newDevice.itsMe")
        if model.canRevokeOthers {
            GradientButton(String(localized: "Ce n’est pas moi"), isBusy: model.isActing, style: .destructive) {
                Task { await model.revoke(row, reason: .notMe) }
            }
            .disabled(model.isActing)
            .accessibilityIdentifier("e2eeAuto.newDevice.notMe")
            Text("« Ce n’est pas moi » le retire tout de suite et ferme toutes tes autres sessions.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Group {
                if let hours = model.hoursBeforeRevokingOthers {
                    Text("Cet appareil-ci a été ajouté il y a moins de 24 h. Si ce n’est pas toi, retire l’autre depuis un appareil plus ancien, ou reviens ici dans \(hours) h.")
                } else {
                    Text("Si ce n’est pas toi, retire-le depuis un autre de tes appareils, dans Réglages > Appareils.")
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Plus tard"), style: .ghost) { onClose(false) }
                .accessibilityIdentifier("e2eeAuto.newDevice.later")
        }
    }
}

/// Banc visuel (simulateur Debug) : `--qa-auto-new-device`, et avec
/// `--qa-auto-devices-recent` la garde des 24 h.
struct E2EEAutoNewDeviceAlertQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    @StateObject private var model = E2EEAutoDevicesQAScreen.model()
    @State private var loaded = false
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        Group {
            if loaded {
                E2EEAutoNewDeviceAlertView(deviceId: "web_device_qa_000000000003", model: model) { _ in }
            } else {
                Color.clear
            }
        }
        .task {
            await model.load()
            loaded = true
        }
        #else
        EmptyView()
        #endif
    }
}
