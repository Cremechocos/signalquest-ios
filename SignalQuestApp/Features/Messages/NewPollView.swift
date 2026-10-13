import SwiftUI

/// Création d'un sondage : question + 2..N options + choix multiple + échéance
/// optionnelle. Pour une conversation chiffrée, le contenu part chiffré (géré par
/// MessagesService.createPoll).
struct NewPollView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// « Dans Équipe terrain » sous le titre.
    var subtitle: String? = nil
    /// Renvoie le message créé + le sondage (avec textes d'options déjà résolus,
    /// même en E2EE) pour un affichage immédiat et correct.
    let onCreated: (MessageItem, MessagePoll) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Option de sondage avec identité stable : indexer un `ForEach` éditable par
    /// position (`indices`) décale le texte/focus lors d'une suppression au milieu.
    private struct PollOption: Identifiable {
        let id = UUID()
        var text: String = ""
    }

    @State private var question = ""
    @State private var options: [PollOption] = [PollOption(), PollOption()]
    @State private var multiSelect = false
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(24 * 3600)
    @State private var isBusy = false
    @State private var errorMessage: String?

    private let maxOptions = 6

    private var trimmedOptions: [String] {
        options.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func optionPlaceholder(for option: PollOption) -> String {
        let position = (options.firstIndex { $0.id == option.id } ?? 0) + 1
        return "Option \(position)"
    }

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimmedOptions.count >= 2
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(title: "Nouveau sondage", subtitle: subtitle, closeIdentifier: "poll.cancel") { dismiss() }

                TextField("Pose ta question", text: $question, axis: .vertical)
                    .lineLimit(1...3)
                    .sqHaloField()
                    .accessibilityIdentifier("poll.question")

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Options")
                        .sqKicker()
                        .padding(.leading, SQSpace.xs)
                    optionsCard
                }

                settingsCard

                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                }

                GradientButton("Créer le sondage", systemImage: "chart.bar", isBusy: isBusy) {
                    Task { await create() }
                }
                .disabled(!canCreate || isBusy)
                .opacity(canCreate ? 1 : 0.5)
                .accessibilityIdentifier("poll.create")
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
    }

    /// Une option par rangée sur une carte, croix ronde pour la retirer ;
    /// « Ajouter une option » est la dernière rangée de la même carte.
    private var optionsCard: some View {
        VStack(spacing: 0) {
            ForEach($options) { $option in
                if option.id != options.first?.id { Divider().padding(.leading, SQSpace.md) }
                HStack(spacing: SQSpace.sm) {
                    TextField(optionPlaceholder(for: option), text: $option.text)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .frame(maxWidth: .infinity, minHeight: 48)
                    if options.count > 2 {
                        Button {
                            options.removeAll { $0.id == option.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(SQColor.chipInk)
                                .frame(width: 28, height: 28)
                                .background(SQColor.chip, in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Supprimer l'option \(optionPlaceholder(for: option))")
                    }
                }
                .padding(.leading, SQSpace.md)
                .padding(.trailing, SQSpace.xs)
            }
            if options.count < maxOptions {
                Divider().padding(.leading, SQSpace.md)
                Button {
                    options.append(PollOption())
                } label: {
                    Label("Ajouter une option", systemImage: "plus")
                        .font(SQType.body(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, SQSpace.md)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("poll.addOption")
            }
        }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            Toggle("Choix multiples", isOn: $multiSelect)
                .frame(minHeight: 48)
                .padding(.horizontal, SQSpace.md)
            Divider().padding(.leading, SQSpace.md)
            Toggle("Échéance", isOn: $hasDeadline)
                .frame(minHeight: 48)
                .padding(.horizontal, SQSpace.md)
            if hasDeadline {
                Divider().padding(.leading, SQSpace.md)
                DatePicker("Clôture le", selection: $deadline, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .frame(minHeight: 48)
                    .padding(.horizontal, SQSpace.md)
            }
        }
        .font(SQType.body(.semibold))
        .foregroundStyle(SQColor.label)
        .tint(SQColor.brandRed)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func create() async {
        guard canCreate else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await service.createPoll(
                conversationId: conversation.id,
                question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                options: trimmedOptions,
                multiSelect: multiSelect,
                endsAt: hasDeadline ? deadline : nil,
                in: conversation,
                e2ee: e2ee
            )
            Haptics.success()
            if let message = response.message {
                onCreated(message, response.poll)
            }
            dismiss()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}
