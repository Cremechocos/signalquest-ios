import SwiftUI

/// One-time, inline disclosure. Reading and composing messages remain available.
struct E2EEV2NotificationPreviewNotice: View {
    var showReminder = false
    var onChoiceChanged: (E2EEV2NotificationPrivacy) -> Void = { _ in }
    @State private var ownerScopeId: String?
    @State private var selected = E2EEV2NotificationPrivacy.full
    @State private var needsNotice = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if needsNotice {
                E2EEV2NotificationPreviewNoticeContent(
                    selected: selected, errorMessage: errorMessage, onChoose: choose
                )
            } else if showReminder && selected == .full {
                Text("Le contenu complet est affiché par défaut. Il peut être visible par toute personne ayant accès à votre écran verrouillé.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: PushOwnerScope.current) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: E2EEV2NotificationContextEvents.refresh)) { _ in reload() }
    }

    private func reload() {
        ownerScopeId = PushOwnerScope.current
        selected = E2EEV2NotificationPrivacyStore.get(ownerScopeId: ownerScopeId)
        needsNotice = E2EEV2RuntimeReadGate.enabled && ownerScopeId != nil && selected != .hidden &&
            !E2EEV2NotificationPrivacyStore.isNoticeAcknowledged(ownerScopeId: ownerScopeId)
    }

    private func choose(_ privacy: E2EEV2NotificationPrivacy) {
        guard E2EEV2NotificationPrivacyStore.acknowledgeNotice(privacy: privacy, ownerScopeId: ownerScopeId) else {
            errorMessage = String(localized: "Impossible de modifier les aperçus. Réessayez ou désactivez les notifications dans les Réglages iOS.")
            return
        }
        errorMessage = nil
        reload()
        onChoiceChanged(privacy)
    }
}

struct E2EEV2NotificationPreviewNoticeContent: View {
    let selected: E2EEV2NotificationPrivacy
    var errorMessage: String?
    let onChoose: (E2EEV2NotificationPrivacy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label("Aperçus sur l’écran verrouillé", systemImage: "lock.rectangle")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            Text("Le contenu complet est proposé par défaut : toute personne devant l’écran peut le lire. Pour cet aperçu, un accès protégé aux messages reste disponible après le premier déverrouillage de cet appareil.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(choiceLabel, style: .primary, allowsMultiline: true) { onChoose(selected) }
                .accessibilityIdentifier("e2ee-preview-notice-accept")
            if selected != .hidden {
                GradientButton(String(localized: "Tout masquer"), style: .ghost, allowsMultiline: true) { onChoose(.hidden) }
                    .accessibilityIdentifier("e2ee-preview-notice-hide")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("e2ee-preview-notice")
    }

    private var choiceLabel: String {
        switch selected {
        case .full: String(localized: "Contenu complet")
        case .senderOnly: String(localized: "Expéditeur seulement")
        case .hidden: String(localized: "Tout masquer")
        }
    }
}
