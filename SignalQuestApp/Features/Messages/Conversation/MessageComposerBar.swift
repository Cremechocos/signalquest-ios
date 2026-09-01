import SwiftUI
import PhotosUI

/// Barre de saisie isolée (PERF-MSG-01) : possède son propre `@State text` afin que la
/// frappe n'invalide PAS le corps de `ConversationDetailView` (et donc la liste des
/// messages) à chaque caractère. Le parent POUSSE du texte (pré-remplissage édition,
/// vidage après envoi) via `seedText`/`seedToken` (appliqué au seul changement de
/// token) ; il REÇOIT le texte courant via les closures d'action.
struct MessageComposerBar: View {
    let canSend: Bool
    let isSending: Bool
    let isSharingLocation: Bool
    let isE2EE: Bool
    let seedText: String
    let seedToken: Int
    @Binding var ephemeralEnabled: Bool
    let onTyping: (String) -> Void
    let onSend: (String) -> Void
    let onPoll: () -> Void
    let onSchedule: (String) -> Void
    let onShareLocation: () -> Void
    let onLiveShare: () -> Void
    let onPickPhoto: (PhotosPickerItem, String) -> Void
    /// Note vocale enregistrée : fichier m4a et durée mesurée.
    let onVoiceNote: (URL, TimeInterval) -> Void

    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @StateObject private var recorder = VoiceNoteRecorder()

    var body: some View {
        // Pendant l'enregistrement, la barre est REMPLACÉE : garder le champ de
        // saisie inviterait à taper alors que le micro tourne, et laisserait
        // croire qu'on peut faire les deux.
        if recorder.isRecording {
            VoiceNoteRecordingBar(
                recorder: recorder,
                onCancel: { recorder.cancel() },
                onSend: {
                    let elapsed = recorder.duration
                    if let url = recorder.stop() { onVoiceNote(url, elapsed) }
                }
            )
            .transition(.opacity)
        } else {
            standardBar
        }
    }

    private var standardBar: some View {
        HStack(spacing: SQSpace.sm + 2) {
            Menu {
                Button { onSchedule(text) } label: {
                    Label("Programmer l'envoi", systemImage: "clock")
                }
                // Les contenus structurés et médias v1 exposeraient encore
                // leurs métadonnées : ils restent masqués jusqu'au runtime v2.
                if !isE2EE {
                    Button { onPoll() } label: {
                        Label("Créer un sondage", systemImage: "chart.bar")
                    }
                    Button { onShareLocation() } label: {
                        Label("Partager ma position", systemImage: "location.fill")
                    }
                    Button { onLiveShare() } label: {
                        Label("Partager en direct", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                Divider()
                Toggle(isOn: $ephemeralEnabled) {
                    Label("Messages éphémères (24 h)", systemImage: "timer")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(SQColor.surfaceMuted, in: Circle())
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .disabled(!canSend || isSending || isSharingLocation)
            .accessibilityLabel("Plus d'actions")

            if !isE2EE {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(SQColor.surfaceMuted, in: Circle())
                        .foregroundStyle(SQColor.label)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(!canSend || isSending)
                .accessibilityLabel("Joindre une photo")
            }

            TextField(canSend ? "Message…" : "Chiffrement à déverrouiller", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.lg + 2)
                .padding(.vertical, SQSpace.sm)
                .frame(minHeight: 44)
                .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .disabled(!canSend)

            // Micro OU envoi, selon qu'il y a du texte : c'est la convention de
            // toutes les messageries, et ça évite un bouton de plus dans une
            // barre déjà dense.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !isE2EE {
                Button {
                    Haptics.selection()
                    Task { await recorder.start() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(SQColor.surfaceMuted, in: Circle())
                        .foregroundStyle(SQColor.brandRed)
                }
                .disabled(!canSend)
                .accessibilityLabel("Enregistrer une note vocale")
            } else {
            Button {
                onSend(text)
            } label: {
                Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(SQColor.brandRed, in: Circle())
                    .foregroundStyle(SQColor.onAccent)
                    .sqShadowAccent()
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || !canSend)
            .accessibilityLabel(isSending ? "Envoi en cours" : "Envoyer le message")
            }
        }
        .padding(.horizontal, SQSpace.md + 2)
        .padding(.vertical, SQSpace.sm + 2)
        .onChangeCompat(of: text) { _, newValue in onTyping(newValue) }
        .onChangeCompat(of: seedToken) { _, _ in text = seedText }
        .onChangeCompat(of: pickerItem) { _, item in
            guard let item else { return }
            onPickPhoto(item, text)
            pickerItem = nil
        }
    }
}
