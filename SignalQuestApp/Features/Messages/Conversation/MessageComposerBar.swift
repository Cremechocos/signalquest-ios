import SwiftUI
import PhotosUI
import UIKit

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
    /// Faux dans une conversation v2 (§13) : « Programmer l'envoi » disparaît.
    var canSchedule = true
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
    /// Membres à proposer après « @ » (plan 3, vague 2) ; `nil` hors des
    /// groupes non chiffrés.
    var mentionSuggestions: ((String) async -> [MentionCandidate])? = nil

    @State private var text = ""
    @State private var mentionCandidates: [MentionCandidate] = []
    @State private var mentionTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool
    @State private var pickerItem: PhotosPickerItem?
    @StateObject private var recorder = VoiceNoteRecorder()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        bar
            // Quitter la conversation abandonne l'enregistrement en cours : la
            // session audio restait active (autres apps atténuées) et le fichier
            // temporaire orphelin (AF-MSG-10).
            .onDisappear { if recorder.isRecording { recorder.cancel() } }
            // Arrière-plan : le micro s'arrête, la note reste en brouillon.
            .onChangeCompat(of: scenePhase) { _, phase in
                if phase == .background, recorder.isRecording { recorder.stop() }
            }
    }

    @ViewBuilder
    private var bar: some View {
        // Pendant l'enregistrement, la barre est REMPLACÉE : garder le champ de
        // saisie inviterait à taper alors que le micro tourne, et laisserait
        // croire qu'on peut faire les deux.
        if recorder.isRecording {
            VoiceNoteRecordingBar(
                recorder: recorder,
                onCancel: { recorder.cancel() },
                onStop: { _ = recorder.stop() }
            )
            .transition(.opacity)
        } else if case let .finished(url, duration) = recorder.state {
            VoiceNoteDraftBar(
                url: url,
                duration: duration,
                levels: recorder.levels,
                onDelete: { recorder.cancel() },
                onSend: {
                    guard let draft = recorder.takeFinished() else { return }
                    onVoiceNote(draft.url, draft.duration)
                }
            )
        } else if recorder.state == .permissionDenied {
            voiceNoteFailure(String(localized: "Autorise le micro dans les Réglages pour enregistrer."), showSettings: true)
        } else if case let .failed(message) = recorder.state {
            voiceNoteFailure(message, showSettings: false)
        } else {
            standardBar
        }
    }

    private func voiceNoteFailure(_ message: String, showSettings: Bool) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(message)
                .font(SQType.caption)
                .foregroundStyle(SQColor.dangerInk)
                .accessibilityIdentifier("voiceNote.error")
            VStack(alignment: .leading, spacing: 0) {
                Button("Réessayer") { Task { await recorder.start() } }
                    .frame(minHeight: 44)
                if showSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Ouvrir les Réglages") { openURL(url) }
                        .frame(minHeight: 44)
                }
                Button("Annuler") { recorder.cancel() }
                    .frame(minHeight: 44)
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.brandRed)
        }
        .padding(SQSpace.md)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .padding(.horizontal, SQSpace.md)
    }

    private var standardBar: some View {
        VStack(spacing: 0) {
            if !mentionCandidates.isEmpty { mentionStrip }
            inputRow
        }
    }

    /// « + » rond, champ blanc avec le trombone dedans, puis micro rond ou
    /// envoi encre dès qu'il y a du texte.
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: SQSpace.sm) {
            Menu {
                if canSchedule {
                    Button { onSchedule(text) } label: {
                        Label("Programmer l'envoi", systemImage: "clock")
                    }
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
                    .font(.system(size: 17, weight: .semibold))
                    // Grisé tant que le chiffrement est verrouillé : la couleur
                    // imposée masquait l'état désactivé du menu.
                    .foregroundStyle(canSend && !isSending && !isSharingLocation ? SQColor.label : SQColor.labelTertiary)
                    .frame(width: 44, height: 44)
                    .sqSurface(SQColor.chip, in: Circle())
                    .contentShape(Circle())
            }
            .disabled(!canSend || isSending || isSharingLocation)
            .accessibilityLabel("Plus d'actions")

            HStack(alignment: .bottom, spacing: 0) {
                TextField(canSend ? "Message…" : "Chiffrement à déverrouiller", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .focused($fieldFocused)
                    .padding(.leading, SQSpace.cardPadding)
                    .padding(.trailing, isE2EE ? SQSpace.cardPadding : SQSpace.xs)
                    .padding(.vertical, SQSpace.sm)
                    .frame(minHeight: 44)
                    .disabled(!canSend)
                    .accessibilityIdentifier("composer.field")

                // Le trombone vit dans le champ ; la photo part avec le texte
                // déjà tapé en légende.
                if !isE2EE {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(SQColor.labelSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!canSend || isSending)
                    .accessibilityLabel("Joindre une photo")
                }
            }
            // Toute la capsule ouvre le clavier, pas seulement la ligne de
            // texte qu'elle entoure : le fond reçoit les touchers autour.
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(SQColor.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(SQColor.separator, lineWidth: 1)
                    }
                    .onTapGesture { if canSend { fieldFocused = true } }
            }

            // Micro OU envoi, selon qu'il y a du texte : c'est la convention de
            // toutes les messageries, et ça évite un bouton de plus dans une
            // barre déjà dense.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !isE2EE {
                Button {
                    Haptics.selection()
                    Task { await recorder.start() }
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SQColor.label)
                        .frame(width: 44, height: 44)
                        .sqSurface(SQColor.chip, in: Circle())
                        .contentShape(Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Enregistrer une note vocale")
            } else {
            let sendable = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && canSend
            Button {
                onSend(text)
            } label: {
                Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(sendable ? SQColor.onInk : SQColor.labelTertiary)
                    .frame(width: 44, height: 44)
                    .background(sendable ? SQColor.label : SQColor.chip, in: Circle())
                    .contentShape(Circle())
            }
            .disabled(!sendable)
            // ⌘↩ au clavier de l'iPad ; Retour seul garde le saut de ligne.
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(isSending ? "Envoi en cours" : "Envoyer le message")
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .onChangeCompat(of: text) { _, newValue in
            onTyping(newValue)
            refreshMentions()
        }
        .onChangeCompat(of: seedToken) { _, _ in text = seedText }
        .onChangeCompat(of: pickerItem) { _, item in
            guard let item else { return }
            onPickPhoto(item, text)
            pickerItem = nil
        }
    }

    /// Suggestions au-dessus du champ, une pastille par membre.
    private var mentionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(mentionCandidates) { candidate in
                    Button { applyMention(candidate) } label: {
                        HStack(spacing: SQSpace.xs2) {
                            SQAvatar(url: candidate.avatarUrl, name: candidate.displayName, size: 26)
                                .accessibilityHidden(true)
                            Text(verbatim: candidate.displayName)
                                .font(SQType.subhead(.semibold))
                                .foregroundStyle(SQColor.label)
                            Text(verbatim: "@\(candidate.handle)")
                                .font(SQType.micro(.regular))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 44)
                        .sqSurface(SQColor.chip, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Mentionner \(candidate.displayName), @\(candidate.handle)"))
                    .accessibilityIdentifier("composer.mention.\(candidate.handle)")
                }
            }
            .padding(.horizontal, SQSpace.md2)
            .padding(.top, SQSpace.sm)
        }
    }

    /// Relance les suggestions sur le « @… » en fin de texte, après 250 ms :
    /// taper « @cam » ne part pas en quatre requêtes.
    private func refreshMentions() {
        mentionTask?.cancel()
        guard let mentionSuggestions,
              let token = MentionAutocomplete.activeToken(in: text, cursor: text.endIndex),
              token.kind == .mention,
              token.query.count >= MentionAutocomplete.minimumQueryLength else {
            mentionCandidates = []
            return
        }
        mentionTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await mentionSuggestions(token.query)
            guard !Task.isCancelled else { return }
            mentionCandidates = found
        }
    }

    private func applyMention(_ candidate: MentionCandidate) {
        guard let token = MentionAutocomplete.activeToken(in: text, cursor: text.endIndex) else { return }
        Haptics.selection()
        mentionTask?.cancel()
        text = MentionAutocomplete.apply(candidate.handle, to: text, token: token).text
        mentionCandidates = []
    }
}
