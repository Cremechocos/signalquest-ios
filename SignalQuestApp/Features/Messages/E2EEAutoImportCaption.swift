import SwiftUI

/// En tête des messages v1 importés (E2EE-AUTO §8).
struct E2EEAutoImportedHistoryHeader: View {
    var body: some View {
        Label(String(localized: "historique importé"), systemImage: "clock.arrow.circlepath")
            .font(SQType.micro)
            .foregroundStyle(SQColor.chipInk)
            .padding(.horizontal, SQSpace.sm2)
            .padding(.vertical, 4)
            .background(SQColor.chip, in: Capsule(style: .continuous))
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.sm)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("conversation.importedHistory")
    }
}

/// Sous la bulle d'un import : qui l'a importé, et ce qui n'est pas venu avec
/// lui. L'expéditeur d'origine n'est qu'une affirmation de l'importeur.
struct E2EEAutoImportCaption: View {
    let label: E2EEV2ThreadPresentation.ImportLabel
    let isMine: Bool

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            Text(verbatim: label.importedBy)
            if label.missingAttachments {
                Text(verbatim: String(localized: "pièce jointe non importée"))
            }
        }
        .font(SQType.micro)
        .foregroundStyle(SQColor.labelSecondary)
        .multilineTextAlignment(isMine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(.horizontal, SQSpace.sm)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.importCaption")
    }
}

/// Sous un ancien message resté hors du chiffrement (E2EE-AUTO §8).
struct E2EEAutoLegacyCaption: View {
    let text: String
    let isMine: Bool

    var body: some View {
        Text(verbatim: text)
            .font(SQType.micro)
            .foregroundStyle(SQColor.labelSecondary)
            .multilineTextAlignment(isMine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
            .padding(.horizontal, SQSpace.sm)
            .padding(.top, 2)
            .accessibilityIdentifier("conversation.legacyCaption")
    }
}
