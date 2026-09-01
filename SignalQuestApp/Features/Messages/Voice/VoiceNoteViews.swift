import SwiftUI

/// Forme d'onde d'une note vocale.
///
/// Dessinée en barres plutôt qu'en courbe : c'est le langage visuel attendu, et
/// une barre par tranche se lit à toutes les tailles sans lissage.
struct VoiceWaveform: View {
    let levels: [Float]
    /// Part déjà lue, 0…1. Les barres franchies passent en accent.
    var progress: Double = 0
    var tint: Color = SQColor.brandRed
    var inactive: Color = SQColor.labelTertiary

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, levels.count)
            let spacing: CGFloat = 2
            let width = max(1.5, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    // Hauteur minimale : une barre à zéro disparaîtrait, et la
                    // forme d'onde aurait des trous là où il y a du silence.
                    let height = max(3, CGFloat(level) * geometry.size.height)
                    RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                        .fill(Double(index) / Double(count) <= progress ? tint : inactive)
                        .frame(width: width, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        // Purement décoratif : le lecteur porte déjà le libellé et la durée.
        .accessibilityHidden(true)
    }
}

/// Barre d'enregistrement, affichée à la place du composer pendant la capture.
struct VoiceNoteRecordingBar: View {
    @ObservedObject var recorder: VoiceNoteRecorder
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: SQSpace.md) {
            Button(action: onCancel) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SQColor.dangerInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Annuler l'enregistrement")

            VoiceWaveform(levels: VoiceNoteRecorder.waveform(from: recorder.levels))
                .frame(height: 28)

            Text(VoiceNotePlayer.formatted(recorder.duration))
                .font(SQFont.body(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(SQColor.labelSecondary)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Envoyer la note vocale")
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .background(SQColor.surface, in: Capsule(style: .continuous))
        // Un enregistrement en cours DOIT être annoncé : sans cela, un
        // utilisateur de VoiceOver ne saurait pas que le micro est ouvert.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enregistrement en cours")
        .accessibilityValue(VoiceNotePlayer.formatted(recorder.duration))
    }
}

/// Lecteur d'une note vocale reçue ou envoyée.
struct VoiceNoteBubble: View {
    let url: URL
    let levels: [Float]
    let duration: TimeInterval
    /// Bulle envoyée par l'utilisateur (fond brique).
    let mine: Bool

    @ObservedObject private var player = VoiceNotePlayer.shared

    var body: some View {
        HStack(spacing: SQSpace.md) {
            Button {
                Haptics.selection()
                player.toggle(url: url)
            } label: {
                Image(systemName: player.isPlaying(url) ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(mine ? SQColor.brandRed : SQColor.onAccent)
                    .frame(width: 34, height: 34)
                    .background(mine ? SQColor.onAccent : SQColor.brandRed, in: Circle())
            }
            .buttonStyle(.plain)

            VoiceWaveform(
                levels: levels,
                progress: player.isPlaying(url) ? player.progress : 0,
                tint: mine ? SQColor.onAccent : SQColor.brandRed,
                inactive: mine ? SQColor.onAccent.opacity(0.35) : SQColor.labelTertiary
            )
            .frame(height: 26)

            Text(VoiceNotePlayer.formatted(player.isPlaying(url) ? player.duration : duration))
                .font(SQFont.body(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(mine ? SQColor.onAccent : SQColor.labelSecondary)
        }
        .frame(minWidth: 180)
        // Annoncé d'un bloc : « Note vocale, 0:14 ». Balayer la forme d'onde
        // barre par barre n'aurait aucun sens.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note vocale")
        .accessibilityValue(VoiceNotePlayer.formatted(player.isPlaying(url) ? player.duration : duration))
        .accessibilityHint(player.isPlaying(url) ? "Toucher pour mettre en pause" : "Toucher pour écouter")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            Haptics.selection()
            player.toggle(url: url)
        }
    }
}
