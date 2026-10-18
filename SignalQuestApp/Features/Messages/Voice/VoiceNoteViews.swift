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
    let onStop: () -> Void

    var body: some View {
        // Corbeille ronde, capsule rouge avec le niveau et la durée, puis la
        // coche encre qui termine l'enregistrement.
        HStack(spacing: SQSpace.sm) {
            Button(action: onCancel) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SQColor.dangerInk)
                    .frame(width: 44, height: 44)
                    .sqSurface(SQColor.chip, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Annuler l'enregistrement")

            HStack(spacing: SQSpace.sm) {
                Circle()
                    .fill(SQColor.dangerInk)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                VoiceWaveform(
                    levels: VoiceNoteRecorder.waveform(from: recorder.levels),
                    tint: SQColor.dangerInk,
                    inactive: SQColor.dangerInk.opacity(0.7)
                )
                .frame(height: 24)
                Text(VoiceNotePlayer.formatted(recorder.duration))
                    .font(SQType.subhead(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.dangerInk)
            }
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 44)
            .background(SQColor.dangerSoft, in: Capsule(style: .continuous))

            Button(action: onStop) {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(SQColor.onInk)
                    .frame(width: 44, height: 44)
                    .background(SQColor.label, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Terminer l’enregistrement")
            .accessibilityIdentifier("voiceNote.stop")
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        // Un enregistrement en cours DOIT être annoncé : sans cela, un
        // utilisateur de VoiceOver ne saurait pas que le micro est ouvert.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enregistrement en cours")
        .accessibilityValue(VoiceNotePlayer.formatted(recorder.duration))
    }
}

/// Aperçu conservé après arrêt manuel ou limite de 120 secondes.
struct VoiceNoteDraftBar: View {
    let url: URL
    let duration: TimeInterval
    let levels: [Float]
    let onDelete: () -> Void
    let onSend: () -> Void

    @ObservedObject private var player = VoiceNotePlayer.shared

    var body: some View {
        VStack(spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Button { player.toggle(url: url) } label: {
                    Image(systemName: player.isPlaying(url) ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying(url) ? "Mettre en pause" : (player.isActive(url) ? "Reprendre la lecture" : "Toucher pour écouter"))
                .accessibilityIdentifier("voiceNote.preview")

                Text("Note vocale")
                    .font(SQType.subhead)
                    .foregroundStyle(SQColor.label)
                    .accessibilityIdentifier("voiceNote.ready")
                Spacer(minLength: 0)
                Text(VoiceNotePlayer.formatted(duration))
                    .font(SQType.caption)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
            }
            HStack(spacing: SQSpace.md) {
                VoiceWaveform(levels: VoiceNoteRecorder.waveform(from: levels))
                    .frame(height: 26)
                Button(action: onDelete) {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .foregroundStyle(SQColor.dangerInk)
                .accessibilityLabel("Supprimer")
                .accessibilityIdentifier("voiceNote.delete")
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(SQColor.brandRed)
                .accessibilityLabel("Envoyer la note vocale")
                .accessibilityIdentifier("voiceNote.send")
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .padding(.horizontal, SQSpace.md)
    }
}

/// Lecteur d'une note vocale reçue ou envoyée.
struct VoiceNoteBubble: View {
    let url: URL
    let levels: [Float]
    let duration: TimeInterval
    /// Bulle envoyée par l'utilisateur (fond brique).
    let mine: Bool
    /// Identifiant de la pièce jointe, pour enchaîner la note suivante du fil.
    var sequenceKey: String? = nil

    @ObservedObject private var player = VoiceNotePlayer.shared

    private var summary: String {
        player.isActive(url)
            ? String(localized: "\(VoiceNotePlayer.formatted(player.elapsed)) sur \(VoiceNotePlayer.formatted(player.duration))")
            : VoiceNotePlayer.formatted(duration)
    }

    var body: some View {
        let active = player.isActive(url)
        HStack(spacing: SQSpace.md) {
            Button {
                Haptics.selection()
                player.toggle(url: url, key: sequenceKey)
            } label: {
                Image(systemName: player.isPlaying(url) ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(mine ? SQColor.label : SQColor.onAccent)
                    .frame(width: 34, height: 34)
                    .background(mine ? SQColor.onInk : SQColor.brandRed, in: Circle())
                    // Zone tactile de 44 pt autour du rond de 34 pt, sans agrandir la bulle.
                    .padding(5)
                    .contentShape(Rectangle())
                    .padding(-5)
            }
            .buttonStyle(.plain)

            VoiceWaveform(
                levels: levels,
                progress: active ? player.progress : 0,
                tint: mine ? SQColor.onInk : SQColor.brandRed,
                inactive: mine ? SQColor.onInk.opacity(0.35) : SQColor.labelTertiary
            )
            .frame(height: 26)
            // Glisser le doigt sur la forme d'onde déplace la lecture ; le geste est
            // simultané pour ne pas bloquer le défilement vertical du fil.
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    guard active, geometry.size.width > 0,
                                          abs(value.translation.width) > abs(value.translation.height) else { return }
                                    player.seek(toFraction: value.location.x / geometry.size.width)
                                }
                        )
                }
            }

            Text(VoiceNotePlayer.formatted(active ? player.elapsed : duration))
                .font(SQType.micro)
                .monospacedDigit()
                .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)

            if active {
                Button {
                    Haptics.selection()
                    player.cycleRate()
                } label: {
                    Text(verbatim: VoiceNotePlayer.rateLabel(player.rate))
                        .font(SQType.micro.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(mine ? SQColor.onInk : SQColor.labelSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(mine ? SQColor.onInk.opacity(0.18) : SQColor.surfaceMuted, in: Capsule())
                        // Zone tactile de 44 pt autour de la pastille.
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .padding(.vertical, -12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voiceNote.rate")
            }
        }
        .frame(minWidth: 180)
        // Annoncé d'un bloc : « Note vocale, 0:07 sur 0:14 ». Balayer la forme d'onde
        // barre par barre n'aurait aucun sens ; haut/bas avance ou recule de 10 s.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note vocale")
        .accessibilityValue(summary)
        .accessibilityHint(player.isPlaying(url) ? "Toucher pour mettre en pause" : (active ? "Toucher pour reprendre" : "Toucher pour écouter"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            Haptics.selection()
            player.toggle(url: url, key: sequenceKey)
        }
        .accessibilityAdjustableAction { direction in
            guard active else { return }
            switch direction {
            case .increment: player.skip(by: 10)
            case .decrement: player.skip(by: -10)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Changer la vitesse de lecture")) {
            guard active else { return }
            player.cycleRate()
        }
    }
}
