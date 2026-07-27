import SwiftUI

/// Sondage rendu dans une carte du fil.
///
/// Vue distincte de `PollBubble` (messagerie) : celle-ci vit sur une surface
/// claire et non dans une bulle brique, et son modèle diffère. Le langage visuel
/// reste le même — barre de proportion derrière le libellé, part en pourcentage
/// à droite — pour qu'un sondage se reconnaisse d'un écran à l'autre.
struct FeedPollView: View {
    let poll: FeedPoll
    let onVote: (FeedPoll.Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            if let question = poll.question, !question.isEmpty {
                Text(LocalizedStringKey(question))
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(poll.orderedOptions) { option in
                optionRow(option)
            }

            HStack(spacing: SQSpace.xs) {
                Text("\(poll.totalVotes) vote")
                if poll.hasExpired {
                    Text("·")
                    Text("Clos")
                } else if let expiresAt = poll.expiresAt {
                    Text("·")
                    Text("Clôture le \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(SQType.micro)
            .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(SQSpace.md)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func optionRow(_ option: FeedPoll.Option) -> some View {
        // Les résultats ne se révèlent qu'APRÈS avoir voté (ou à la clôture) :
        // afficher les scores avant biaiserait le vote suivant.
        let revealed = poll.hasVoted || poll.hasExpired
        let share = poll.share(of: option)

        Button {
            guard poll.isOpen else { return }
            Haptics.selection()
            onVote(option)
        } label: {
            ZStack(alignment: .leading) {
                GeometryReader { geometry in
                    if revealed {
                        RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                            .fill(option.votedByMe ? SQColor.accentSoft : SQColor.fill)
                            .frame(width: max(0, geometry.size.width * share))
                    }
                }
                HStack(spacing: SQSpace.sm) {
                    if option.votedByMe {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SQColor.accentInk)
                            .accessibilityHidden(true)
                    }
                    Text(LocalizedStringKey(option.label))
                        .font(SQFont.body(14, option.votedByMe ? .semibold : .regular))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: SQSpace.sm)
                    if revealed {
                        Text(share.formatted(.percent.precision(.fractionLength(0))))
                            .font(SQFont.body(13, .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm + 1)
            }
            .frame(minHeight: 40)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!poll.isOpen)
        // Un seul élément énoncé d'un bloc : « Fibre, 42 %, sélectionné ».
        // Balayer trois textes par option rendrait un sondage à quatre choix
        // interminable au lecteur d'écran.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizedStringKey(option.label))
        .accessibilityValue(
            revealed
                ? Text(share.formatted(.percent.precision(.fractionLength(0))))
                : Text("Toucher pour voter")
        )
        .accessibilityAddTraits(option.votedByMe ? [.isButton, .isSelected] : .isButton)
    }
}
