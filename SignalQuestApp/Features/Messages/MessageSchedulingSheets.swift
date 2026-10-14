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
    /// « À Léa Martin » sous le titre.
    let subtitle: String?
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
        subtitle: String? = nil,
        onScheduled: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.service = service
        self.e2ee = e2ee
        self.initialText = initialText
        self.subtitle = subtitle
        self.onScheduled = onScheduled
        _text = State(initialValue: initialText)
    }

    private var isE2EE: Bool { conversation.e2eeEnabled == true }
    private var canSchedule: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sendAt > Date()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(title: "Programmer l'envoi", subtitle: subtitle, closeIdentifier: "schedule.cancel") { dismiss() }

                if isE2EE {
                    Label("Message chiffré de bout en bout — programmé en toute sécurité.", systemImage: "lock.shield")
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(SQColor.success)
                        .padding(SQSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SQColor.successSoft, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Message")
                        .sqKicker()
                        .padding(.leading, SQSpace.xs)
                    TextField("Message à envoyer", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .sqHaloField()
                }

                SendTimePicker(label: "Envoyer le", date: $sendAt)

                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                }

                GradientButton("Programmer l'envoi", systemImage: "clock", isBusy: isBusy) {
                    Task { await schedule() }
                }
                .disabled(!canSchedule || isBusy)
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
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
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}

/// Feuille d'ajout d'un rappel sur un message : motif optionnel + échéance.
struct AddReminderSheet: View {
    let conversation: MessageConversation
    let message: MessageItem
    let service: MessagesServicing
    /// « Dans Équipe terrain » sous le titre.
    var subtitle: String? = nil
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var reason = ""
    @State private var remindAt = Date().addingTimeInterval(3600)
    @State private var isBusy = false
    @State private var errorMessage: String?

    private var canAdd: Bool { remindAt > Date() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(title: "Nouveau rappel", subtitle: subtitle, closeIdentifier: "reminder.cancel") { dismiss() }

                // Le motif partirait en clair : pas de champ en conversation
                // chiffrée (E2E-05).
                if conversation.e2eeEnabled == true {
                    Label("En conversation chiffrée, un rappel n’a pas de motif : il serait stocké en clair sur nos serveurs.", systemImage: "lock.fill")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Motif (optionnel)")
                            .sqKicker()
                            .padding(.leading, SQSpace.xs)
                        TextField("Pourquoi ce rappel ?", text: $reason, axis: .vertical)
                            .lineLimit(1...3)
                            .sqHaloField()
                    }
                }

                SendTimePicker(label: "Me rappeler le", date: $remindAt)

                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                }

                GradientButton("Ajouter le rappel", systemImage: "bell", isBusy: isBusy) {
                    Task { await add() }
                }
                .disabled(!canAdd || isBusy)
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
    }

    private func add() async {
        guard canAdd else { return }
        isBusy = true
        defer { isBusy = false }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await service.createReminder(
                conversationId: conversation.id,
                messageId: message.id,
                reason: conversation.e2eeEnabled == true || trimmed.isEmpty ? nil : trimmed,
                remindAt: remindAt
            )
            Haptics.success()
            onAdded()
            dismiss()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}

/// Tête des feuilles Halo de la conversation : croix ronde, grand titre et,
/// dessous, la conversation visée.
struct MessageSheetHeader: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    let closeIdentifier: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            MapChipIconButton(systemImage: "xmark", label: "Annuler", identifier: closeIdentifier, action: onClose)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(title)
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }
}

/// Échéance d'un envoi ou d'un rappel : « Ce soir », « Demain » et « Lundi » en
/// un appui, « Autre… » ouvre le calendrier. Seules les dates à venir sont proposées.
struct SendTimePicker: View {
    let label: LocalizedStringKey
    @Binding var date: Date
    @State private var showsCalendar = false

    private struct Preset: Hashable {
        let title: String
        let date: Date
    }

    private var presets: [Preset] {
        let calendar = Calendar.current
        let now = Date()
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        var list: [Preset] = []
        if let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now), tonight > now.addingTimeInterval(60) {
            list.append(Preset(title: String(localized: "Ce soir \(time(tonight))"), date: tonight))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) {
            list.append(Preset(title: String(localized: "Demain \(time(morning))"), date: morning))
        }
        if let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime) {
            let day = monday.formatted(.dateTime.weekday(.wide)).localizedCapitalized
            list.append(Preset(title: "\(day) \(time(monday))", date: monday))
        }
        return list
    }

    var body: some View {
        let presets = presets
        let matchesPreset = presets.contains { $0.date == date }
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(label)
                .sqKicker()
                .padding(.leading, SQSpace.xs)
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SQSpace.sm) {
                    ForEach(presets, id: \.self) { preset in
                        SQChip(
                            label: preset.title,
                            isSelected: !showsCalendar && preset.date == date,
                            selectedFill: SQColor.label,
                            selectedInk: SQColor.onInk
                        ) {
                            date = preset.date
                            showsCalendar = false
                        }
                    }
                    SQChip(
                        label: "Autre…",
                        systemImage: "clock",
                        isSelected: showsCalendar || !matchesPreset,
                        selectedFill: SQColor.label,
                        selectedInk: SQColor.onInk
                    ) {
                        showsCalendar = true
                    }
                    .accessibilityIdentifier("sendTime.other")
                }
                .padding(.horizontal, SQSpace.lg)
            }
            // La rangée défile jusqu'aux bords de la feuille : « Autre… » n'est plus rogné.
            .padding(.horizontal, -SQSpace.lg)
            VStack(spacing: 0) {
                HStack(spacing: SQSpace.md) {
                    Text("Date et heure")
                        .font(SQType.body(.semibold))
                        .foregroundStyle(SQColor.label)
                    Spacer(minLength: SQSpace.sm)
                    Text(verbatim: date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .font(SQType.subhead(.bold))
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                }
                .padding(.horizontal, SQSpace.md)
                .frame(minHeight: 48)
                .accessibilityElement(children: .combine)
                if showsCalendar {
                    Divider().padding(.leading, SQSpace.md)
                    // Libellé masqué à l'écran mais lu par VoiceOver : le
                    // sélecteur n'avait pas de nom (SOC-31).
                    DatePicker(label, selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .tint(SQColor.brandRed)
                        .padding(.horizontal, SQSpace.sm)
                }
            }
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
    }
}

/// Champ Halo des feuilles de la conversation : blanc, coins `lg`.
extension View {
    func sqHaloField() -> some View {
        self
            .font(SQType.body)
            .foregroundStyle(SQColor.label)
            .padding(SQSpace.md)
            .frame(minHeight: 48)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }
}
