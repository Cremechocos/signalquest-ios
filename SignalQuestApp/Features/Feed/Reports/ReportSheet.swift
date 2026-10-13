import SwiftUI

struct ReportSheet: View {
    private let reasons: [ReportReason]
    private let notice: String?
    /// Sans champ libre : le signalement d'un message chiffré v2 ne porte que
    /// son motif en clair (§11, D.10).
    private let allowsComment: Bool
    private let submit: @MainActor (ReportReason, String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter
    @State private var reason: ReportReason
    @State private var note: String = ""
    @State private var isBusy = false
    @State private var error: String?

    init(target: ReportTarget, service: ReportsServicing) {
        self.init(reasons: ReportReason.allCases) { reason, comment in
            try await service.report(target, reason: reason, comment: comment)
        }
    }

    /// Signalement hors `/api/social/reports` (messages) : l'appelant fournit
    /// l'envoi, les motifs proposés et, au besoin, ce qu'il faut savoir avant.
    init(
        reasons: [ReportReason],
        notice: String? = nil,
        allowsComment: Bool = true,
        submit: @escaping @MainActor (ReportReason, String?) async throws -> Void
    ) {
        self.reasons = reasons
        self.notice = notice
        self.allowsComment = allowsComment
        self.submit = submit
        _reason = State(initialValue: reasons.first ?? .spam)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: "xmark", label: "Annuler", identifier: "report.cancel") { dismiss() }

                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text("Signaler")
                        .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choisis ce qui ne va pas.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                }

                if let notice {
                    Label(notice, systemImage: "lock")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("report.notice")
                }

                reasonsCard

                if allowsComment {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Précisions (optionnel)")
                            .sqKicker()
                            .padding(.leading, SQSpace.xs)
                        TextField("Décris ce qui te pose problème", text: $note, axis: .vertical)
                            .font(SQType.body)
                            .lineLimit(3...6)
                            .padding(SQSpace.md)
                            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                            .accessibilityIdentifier("report.comment")
                    }
                }

                if let error {
                    Text(error)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("report.error")
                }

                GradientButton(String(localized: "Envoyer le signalement"), isBusy: isBusy) {
                    Task { await send() }
                }
                .disabled(isBusy)
                .accessibilityIdentifier("report.send")
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
    }

    /// Motifs en boutons radio sur une carte : un seul choix, visible d'un coup d'œil.
    private var reasonsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(reasons.enumerated()), id: \.element.id) { index, value in
                if index > 0 { Divider().padding(.leading, SQSpace.md) }
                let isSelected = value == reason
                Button {
                    reason = value
                } label: {
                    HStack(spacing: SQSpace.md) {
                        Text(value.label)
                            .font(SQType.body(.semibold))
                            .foregroundStyle(SQColor.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("report.reason.\(value.rawValue)")
            }
        }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func send() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let comment = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try await submit(reason, allowsComment && !comment.isEmpty ? note : nil)
            Haptics.success()
            dismiss()
            // La feuille se ferme : sans ce message, rien ne dit que le signalement est parti.
            inAppNotifications.show(SQInAppNotificationItem(
                body: String(localized: "Signalement envoyé. Merci, nous allons l'examiner."),
                variant: .success
            ))
        } catch {
            self.error = error.userFacingMessage
            Haptics.error()
        }
    }
}
