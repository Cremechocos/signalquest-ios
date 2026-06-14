import SwiftUI

/// Rendu d'un message de type sondage dans le fil. Question, options avec barres
/// de progression et compteurs, vote au tap, état « clôturé » et bouton de
/// clôture réservé à l'auteur. Éditorial : barres fines, bordures `.separator`.
struct PollBubble: View {
    let poll: MessagePoll
    let mine: Bool
    /// `true` si l'utilisateur courant peut clôturer (auteur du sondage).
    let canClose: Bool
    let onVote: (_ optionIds: [String]) -> Void
    let onClose: () -> Void

    private var totalVotes: Int { max(1, poll.totalVotes) }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Rectangle()
                    .fill(mine ? Color.white.opacity(0.7) : SQColor.brandRed)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SONDAGE")
                        .font(SQType.micro)
                        .foregroundStyle(mine ? .white.opacity(0.75) : SQColor.labelSecondary)
                    Text(poll.question.isEmpty ? "Sondage" : poll.question)
                        .font(SQType.heading)
                        .foregroundStyle(mine ? .white : SQColor.label)
                    Text(metaLine)
                        .font(SQType.micro)
                        .foregroundStyle(mine ? .white.opacity(0.7) : SQColor.labelTertiary)
                }
                Spacer(minLength: 0)
                if poll.isClosed {
                    Text("CLOS")
                        .font(SQType.micro)
                        .padding(.horizontal, SQSpace.xs + 2)
                        .padding(.vertical, 3)
                        .background((mine ? Color.white.opacity(0.18) : SQColor.fill), in: RoundedRectangle(cornerRadius: SQRadius.sm))
                        .foregroundStyle(mine ? .white : SQColor.labelSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: SQSpace.sm) {
                ForEach(poll.options) { option in
                    optionRow(option)
                }
            }

            if canClose && !poll.isClosed {
                Button {
                    Haptics.light()
                    onClose()
                } label: {
                    Label("Clôturer le sondage", systemImage: "lock")
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(mine ? .white : SQColor.brandRed)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }

    private var metaLine: String {
        let mode = poll.multiSelect ? "Choix multiples" : "Choix unique"
        let count = "\(poll.totalVotes) vote\(poll.totalVotes > 1 ? "s" : "")"
        return poll.isClosed ? "Clôturé · \(count)" : "\(mode) · \(count)"
    }

    private func optionRow(_ option: PollOption) -> some View {
        let votedByMe = poll.votesByMe.contains(option.id)
        let ratio = Double(option.count) / Double(totalVotes)
        let fillColor = mine ? Color.white.opacity(0.28) : SQColor.brandRed.opacity(0.16)
        let borderColor = votedByMe
            ? (mine ? Color.white : SQColor.brandRed)
            : (mine ? Color.white.opacity(0.35) : SQColor.separator)
        return Button {
            guard !poll.isClosed else { return }
            Haptics.selection()
            onVote(nextSelection(for: option.id))
        } label: {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(fillColor)
                        .frame(width: max(0, geo.size.width * ratio))
                }
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: votedByMe ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(votedByMe ? (mine ? .white : SQColor.brandRed) : (mine ? .white.opacity(0.7) : SQColor.labelTertiary))
                    Text(option.text.isEmpty ? option.id : option.text)
                        .font(SQType.caption.weight(votedByMe ? .semibold : .regular))
                        .foregroundStyle(mine ? .white : SQColor.label)
                        .lineLimit(2)
                    Spacer(minLength: SQSpace.sm)
                    Text("\(option.count)")
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(mine ? .white.opacity(0.85) : SQColor.labelSecondary)
                }
                .padding(.horizontal, SQSpace.sm + 2)
                .padding(.vertical, SQSpace.sm)
            }
            .background((mine ? Color.white.opacity(0.08) : SQColor.surfaceMuted), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(poll.isClosed)
    }

    /// Calcule la sélection à envoyer au backend après tap : en choix unique on
    /// remplace, en choix multiple on bascule l'option (sans descendre à zéro).
    private func nextSelection(for optionId: String) -> [String] {
        if poll.multiSelect {
            if poll.votesByMe.contains(optionId) {
                let next = poll.votesByMe.filter { $0 != optionId }
                return next.isEmpty ? poll.votesByMe : next
            }
            return poll.votesByMe + [optionId]
        }
        return [optionId]
    }
}
