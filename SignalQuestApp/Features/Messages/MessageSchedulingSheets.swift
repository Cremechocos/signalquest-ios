import SwiftUI

/// Feuille de programmation d'un envoi : saisie du texte (pré-rempli avec le
/// brouillon) + date future. Fonctionne aussi en conversation chiffrée : le
/// texte est chiffré en payload v2 (AAD + nonce) — voir
/// MessagesService.createScheduledMessage.
struct ScheduleMessageSheet: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    let initialText: String
    let onScheduled: () -> Void

    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var sendAt = Date().addingTimeInterval(3600)
    @State private var isBusy = false
    @State private var errorMessage: String?

    init(
        conversation: MessageConversation,
        service: MessagesServicing,
        e2ee: E2EEServicing?,
        initialText: String,
        onScheduled: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.service = service
        self.e2ee = e2ee
        self.initialText = initialText
        self.onScheduled = onScheduled
        _text = State(initialValue: initialText)
    }

    private var isE2EE: Bool { conversation.e2eeEnabled == true }
    private var canSchedule: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sendAt > Date()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    if isE2EE {
                        Label("Message chiffré de bout en bout — programmé en toute sécurité.", systemImage: "lock.shield")
                            .font(SQType.caption.weight(.semibold))
                            .foregroundStyle(SQColor.brandGreen)
                            .padding(SQSpace.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SQColor.brandGreen.opacity(0.14), in: RoundedRectangle(cornerRadius: SQRadius.md))
                    }

                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Message").sqKicker()
                        TextField("Message à envoyer", text: $text, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(SQTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Envoyer le").sqKicker()
                        DatePicker("", selection: $sendAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                    }

                    GradientButton("Programmer l'envoi", systemImage: "clock", isBusy: isBusy) {
                        Task { await schedule() }
                    }
                    .disabled(!canSchedule || isBusy)
                    .opacity(canSchedule ? 1 : 0.5)
                }
                .padding()
            }
            .navigationTitle("Programmer l'envoi")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
            }
            .signalQuestBackground()
        }
    }

    private func schedule() async {
        guard canSchedule else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let senderId: String? = {
                if case .authenticated(let user) = session.state { return user.id }
                return nil
            }()
            _ = try await service.createScheduledMessage(
                sendAt: sendAt,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                in: conversation,
                replyToId: nil,
                senderId: senderId,
                e2ee: e2ee
            )
            Haptics.success()
            onScheduled()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}

/// Feuille d'ajout d'un rappel sur un message : motif optionnel + échéance.
struct AddReminderSheet: View {
    let conversation: MessageConversation
    let message: MessageItem
    let service: MessagesServicing
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var reason = ""
    @State private var remindAt = Date().addingTimeInterval(3600)
    @State private var isBusy = false
    @State private var errorMessage: String?

    private var canAdd: Bool { remindAt > Date() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Motif (optionnel)").sqKicker()
                        TextField("Pourquoi ce rappel ?", text: $reason, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(SQTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Me rappeler le").sqKicker()
                        DatePicker("", selection: $remindAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.danger)
                    }

                    GradientButton("Ajouter le rappel", systemImage: "bell", isBusy: isBusy) {
                        Task { await add() }
                    }
                    .disabled(!canAdd || isBusy)
                    .opacity(canAdd ? 1 : 0.5)
                }
                .padding()
            }
            .navigationTitle("Nouveau rappel")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
            }
            .signalQuestBackground()
        }
    }

    private func add() async {
        guard canAdd else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await service.createReminder(
                conversationId: conversation.id,
                messageId: message.id,
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reason.trimmingCharacters(in: .whitespacesAndNewlines),
                remindAt: remindAt
            )
            Haptics.success()
            onAdded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
