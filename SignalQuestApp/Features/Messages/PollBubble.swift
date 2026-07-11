import SwiftUI

/// Rendu d'un message de type sondage dans le fil. Question, options avec barres
/// de progression et compteurs, vote au tap, état « clôturé » et bouton de
/// clôture réservé à l'auteur. DA Crème & Terre cuite : pastille d'icône,
/// tuiles d'options SurfaceMuted rayon 14 sans bordure, jauge teinte accent.
struct PollBubble: View {
    let poll: MessagePoll
    let mine: Bool
    /// `true` si l'utilisateur courant peut clôturer (auteur du sondage).
    let canClose: Bool
    let onVote: (_ optionIds: [String]) -> Void
    let onClose: () -> Void

    private var totalVotes: Int { max(1, poll.totalVotes) }
    /// POLL-UX-01 : un sondage dont l'échéance est dépassée est traité comme clos.
    private var isExpired: Bool { poll.endsAt.map { $0 < Date() } ?? false }
    private var effectivelyClosed: Bool { poll.isClosed || isExpired }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(mine ? SQColor.onAccent : SQColor.brandRed)
                    .frame(width: 36, height: 36)
                    .background(mine ? SQColor.onAccent.opacity(0.18) : SQColor.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(poll.question.isEmpty ? "Sondage" : poll.question)
                        .font(SQType.heading)
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                    Text(metaLine)
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelTertiary)
                }
                Spacer(minLength: 0)
                if effectivelyClosed {
                    Text("Clos")
                        .font(SQType.micro)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 3)
                        .background((mine ? SQColor.onAccent.opacity(0.18) : SQColor.surfaceMuted), in: Capsule())
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            VStack(spacing: SQSpace.sm) {
                ForEach(poll.options) { option in
                    optionRow(option)
                }
            }

            if canClose && !effectivelyClosed {
                Button {
                    Haptics.light()
                    onClose()
                } label: {
                    Label("Clôturer le sondage", systemImage: "lock")
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.brandRed)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }

    private var metaLine: String {
        let mode = poll.multiSelect ? "Choix multiples" : "Choix unique"
        let count = "\(poll.totalVotes) vote\(poll.totalVotes > 1 ? "s" : "")"
        if effectivelyClosed { return "Clôturé · \(count)" }
        if let endsAt = poll.endsAt {
            let when = endsAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            return "\(mode) · clôture le \(when) · \(count)"
        }
        return "\(mode) · \(count)"
    }

    private func optionRow(_ option: PollOption) -> some View {
        let votedByMe = poll.votesByMe.contains(option.id)
        let ratio = Double(option.count) / Double(totalVotes)
        let fillColor = mine ? SQColor.onAccent.opacity(0.26) : SQColor.accentSoft
        return Button {
            guard !effectivelyClosed else { return }
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(votedByMe ? (mine ? SQColor.onAccent : SQColor.brandRed) : (mine ? SQColor.onAccent.opacity(0.7) : SQColor.labelTertiary))
                        .accessibilityHidden(true)
                    Text(option.text.isEmpty ? option.id : option.text)
                        .font(SQType.caption.weight(votedByMe ? .semibold : .regular))
                        .foregroundStyle(mine ? SQColor.onAccent : SQColor.label)
                        .lineLimit(2)
                    Spacer(minLength: SQSpace.sm)
                    Text("\(option.count)")
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(mine ? SQColor.onAccent.opacity(0.85) : SQColor.labelSecondary)
                }
                .padding(.horizontal, SQSpace.sm + 2)
                .padding(.vertical, SQSpace.sm)
            }
            .background((mine ? SQColor.onAccent.opacity(0.10) : SQColor.surfaceMuted), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(effectivelyClosed)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.text.isEmpty ? option.id : option.text)
        .accessibilityValue("\(option.count) vote\(option.count > 1 ? "s" : ""), \(Int((ratio * 100).rounded())) %\(votedByMe ? ", sélectionné" : "")")
        .accessibilityAddTraits(votedByMe ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(effectivelyClosed ? "" : "Toucher pour voter")
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
