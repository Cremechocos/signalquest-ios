import SwiftUI

/// Création d'un sondage : question + 2..N options + choix multiple + échéance
/// optionnelle. Pour une conversation chiffrée, le contenu part chiffré (géré par
/// MessagesService.createPoll).
struct NewPollView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// Renvoie le message créé + le sondage (avec textes d'options déjà résolus,
    /// même en E2EE) pour un affichage immédiat et correct.
    let onCreated: (MessageItem, MessagePoll) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var multiSelect = false
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(24 * 3600)
    @State private var isBusy = false
    @State private var errorMessage: String?

    private let maxOptions = 6

    private var trimmedOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimmedOptions.count >= 2
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    section(title: "Question") {
                        TextField("Pose ta question", text: $question, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(SQTextFieldStyle())
                    }

                    section(title: "Options") {
                        VStack(spacing: SQSpace.sm) {
                            ForEach(options.indices, id: \.self) { index in
                                HStack(spacing: SQSpace.sm) {
                                    TextField("Option \(index + 1)", text: $options[index])
                                        .textFieldStyle(SQTextFieldStyle())
                                    if options.count > 2 {
                                        Button {
                                            options.remove(at: index)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(SQColor.labelTertiary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if options.count < maxOptions {
                                Button {
                                    options.append("")
                                } label: {
                                    Label("Ajouter une option", systemImage: "plus.circle")
                                        .font(SQType.caption.weight(.semibold))
                                        .foregroundStyle(SQColor.brandRed)
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    section(title: "Réglages") {
                        VStack(spacing: SQSpace.sm) {
                            Toggle("Choix multiples", isOn: $multiSelect)
                                .tint(SQColor.brandRed)
                            Toggle("Échéance", isOn: $hasDeadline)
                                .tint(SQColor.brandRed)
                            if hasDeadline {
                                DatePicker("Clôture le", selection: $deadline, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                    .font(SQType.caption)
                            }
                        }
                        .font(SQType.body)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                    }

                    GradientButton("Créer le sondage", systemImage: "chart.bar", isBusy: isBusy) {
                        Task { await create() }
                    }
                    .disabled(!canCreate || isBusy)
                    .opacity(canCreate ? 1 : 0.5)
                }
                .padding()
            }
            .navigationTitle("Nouveau sondage")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
            }
            .signalQuestBackground()
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title).sqKicker()
            content()
        }
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
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
