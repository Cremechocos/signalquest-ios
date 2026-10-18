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

    /// La clôture est définitive : elle se confirme avant de partir.
    @State private var confirmsClose = false
    /// Horloge du rendu : avancée à l'échéance du sondage, sans quoi un sondage qui
    /// expire sous les yeux resterait votable jusqu'au prochain rendu (B11).
    @State private var now = Date()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var totalVotes: Int { max(1, poll.totalVotes) }
    /// POLL-UX-01 : un sondage dont l'échéance est dépassée est traité comme clos.
    private var isExpired: Bool { poll.endsAt.map { $0 < now } ?? false }
    private var effectivelyClosed: Bool { poll.isClosed || isExpired }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                    .frame(width: 36, height: 36)
                    .background(mine ? SQColor.onInk.opacity(0.18) : SQColor.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(poll.question.isEmpty ? String(localized: "Sondage") : poll.question)
                        .font(SQType.heading)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                    Text(metaLine)
                        .font(SQType.micro)
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                if effectivelyClosed {
                    Text("Clos")
                        .font(SQType.micro)
                        .padding(.horizontal, SQSpace.sm)
                        .padding(.vertical, 3)
                        .background((mine ? SQColor.onInk.opacity(0.18) : SQColor.surfaceMuted), in: Capsule())
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
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
                    confirmsClose = true
                } label: {
                    Label("Clôturer le sondage", systemImage: "lock")
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.brandRed)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .confirmationDialog("Clôturer ce sondage ?", isPresented: $confirmsClose, titleVisibility: .visible) {
                    Button("Clôturer", role: .destructive) { onClose() }
                    Button("Garder ouvert", role: .cancel) {}
                } message: {
                    Text("Plus aucun vote ne sera possible. Cette action est définitive.")
                }
            }
        }
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 280, alignment: .leading)
        .task(id: poll.endsAt) {
            now = Date()
            guard let endsAt = poll.endsAt, endsAt > now else { return }
            // Une seconde de marge : le réveil ne tombe jamais avant l'échéance.
            try? await Task.sleep(nanoseconds: UInt64(endsAt.timeIntervalSince(now) * 1_000_000_000) + 1_000_000_000)
            if !Task.isCancelled { now = Date() }
        }
    }

    private var metaLine: String {
        let mode = poll.multiSelect ? String(localized: "Choix multiples") : String(localized: "Choix unique")
        let count = String(localized: "\(poll.totalVotes) vote")
        if effectivelyClosed { return String(localized: "Clôturé · \(count)") }
        if let endsAt = poll.endsAt {
            let when = endsAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            return String(localized: "\(mode) · clôture le \(when) · \(count)")
        }
        return String(localized: "\(mode) · \(count)")
    }

    private func optionRow(_ option: PollOption) -> some View {
        let votedByMe = poll.votesByMe.contains(option.id)
        let ratio = Double(option.count) / Double(totalVotes)
        let fillColor = mine ? SQColor.onInk.opacity(0.26) : SQColor.accentSoft
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
                        .foregroundStyle(votedByMe ? (mine ? SQColor.onInk : SQColor.brandRed) : (mine ? SQColor.onInk.opacity(0.7) : SQColor.labelTertiary))
                        .accessibilityHidden(true)
                    Text(option.text.isEmpty ? option.id : option.text)
                        .font(SQType.caption.weight(votedByMe ? .semibold : .regular))
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Spacer(minLength: SQSpace.sm)
                    Text("\(option.count)")
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                }
                .padding(.horizontal, SQSpace.sm2)
                .padding(.vertical, SQSpace.sm)
                .frame(minHeight: 44)
            }
            .background((mine ? SQColor.onInk.opacity(0.10) : SQColor.surfaceMuted), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(effectivelyClosed)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.text.isEmpty ? option.id : option.text)
        .accessibilityValue(voteAccessibilityValue(for: option, ratio: ratio, votedByMe: votedByMe))
        .accessibilityAddTraits(votedByMe ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(effectivelyClosed ? "" : String(localized: "Toucher pour voter"))
    }

    private func voteAccessibilityValue(for option: PollOption, ratio: Double, votedByMe: Bool) -> String {
        var parts = [
            String(localized: "\(option.count) vote"),
            String(localized: "\(Int((ratio * 100).rounded())) %"),
        ]
        if votedByMe { parts.append(String(localized: "sélectionné")) }
        return parts.joined(separator: ", ")
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
