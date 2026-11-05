import SwiftUI

/// Liste des messages programmés de la conversation, avec suppression. Affiche le
/// contenu déchiffré quand c'est possible : les messages planifiés SONT chiffrés
/// (payload v2) quand la conversation est E2EE (voir MessagesService.createScheduledMessage).
/// Le repli « 🔒 » apparaît si la conversation n'est pas encore déverrouillée.
struct ScheduledMessagesView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// Nom de la conversation, sous le titre.
    var subtitle: String? = nil
    /// Conversation chiffrée automatiquement : programmés v3 (E2EE-AUTO §7.8 F).
    var usesV2 = false

    @EnvironmentObject private var services: AppServices
    @State private var items: [ScheduledMessage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var decrypted: [String: String] = [:]
    /// Programmés v3 dont le texte s'est ouvert ici : lui seul se modifie.
    @State private var decryptedTexts: Set<String> = []
    /// Envoi programmé dont l'annulation attend confirmation (irréversible).
    @State private var deletionTarget: ScheduledMessage?
    /// Envoi programmé dont l'heure ou le texte se modifie.
    @State private var editTarget: ScheduledMessage?

    private var isE2EE: Bool { conversation.e2eeEnabled == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSettingsHeader(title: "Messages programmés", subtitle: subtitle.map { LocalizedStringKey($0) }, backIdentifier: "scheduled.back")
                if isLoading && items.isEmpty {
                    SQSpinner().frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, items.isEmpty {
                    ErrorStateView(title: "Indisponible", message: errorMessage) {
                        Task { await load() }
                    }
                } else if items.isEmpty {
                    EmptyStateView(
                        title: "Aucun message programmé",
                        message: "Programme un envoi depuis le « + » du composer.",
                        systemImage: "clock.badge"
                    )
                } else {
                    // Une seule carte, une ligne par envoi programmé.
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            if item.id != items.first?.id { Divider().padding(.leading, 64) }
                            row(item)
                        }
                    }
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        // Échec d'une suppression sur une liste remplie : dit près de la liste.
        .actionErrorBar(items.isEmpty ? nil : errorMessage)
        .navigationTitle("Messages programmés")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .confirmationDialog(
            "Annuler cet envoi programmé ?",
            isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }),
            titleVisibility: .visible,
            presenting: deletionTarget
        ) { item in
            Button("Annuler l’envoi", role: .destructive) {
                deletionTarget = nil
                Task { await delete(item) }
            }
            Button("Garder", role: .cancel) { deletionTarget = nil }
        } message: { _ in
            Text("Le message ne sera pas envoyé.")
        }
        .sheet(item: $editTarget) { item in
            ScheduledMessageEditSheet(
                item: item,
                plainText: editableText(item),
                subtitle: subtitle
            ) { sendAt, content in
                try await update(item, sendAt: sendAt, content: content)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ item: ScheduledMessage) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: "clock.fill", size: 36, font: .system(size: 14, weight: .medium))
            VStack(alignment: .leading, spacing: SQSpace.xs2) {
                if let date = item.sendAt {
                    Text(date.sqFormatted(date: .medium))
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                }
                Text(content(for: item))
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(4)
                if let status = statusLabel(item) {
                    Text(status)
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.warning)
                }
            }
            // Regroupe date + contenu + statut en un seul élément VoiceOver (A11Y-1).
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                deletionTarget = item
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
            .accessibilityLabel(cancelAccessibilityLabel(for: item))
        }
        // Modifier l'heure (et le texte hors conversation chiffrée), sur la ligne entière.
        .contentShape(Rectangle())
        .onTapGesture {
            if canEdit(item) { editTarget = item }
        }
        .accessibilityAction(named: Text("Modifier")) {
            if canEdit(item) { editTarget = item }
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, SQSpace.xs)
        .padding(.vertical, SQSpace.sm2)
    }

    private func content(for item: ScheduledMessage) -> String {
        if item.isEncrypted { return decrypted[item.id] ?? String(localized: "🔒 Message chiffré") }
        let value = item.content ?? ""
        return value.isEmpty ? String(localized: "(vide)") : value
    }

    /// Seuls les envois encore en attente se modifient ; un programmé chiffré,
    /// seulement s'il s'ouvre ici (il est rechiffré à chaque modification).
    private func canEdit(_ item: ScheduledMessage) -> Bool {
        if let v3 = item.v3 {
            guard decrypted[item.id] != nil else { return false }
            switch v3.status {
            case .scheduled, .needsReencrypt: return true
            case .failed: return false
            }
        }
        return item.status == nil || item.status == "scheduled"
    }

    private func editableText(_ item: ScheduledMessage) -> String? {
        if item.v3 != nil { return decryptedTexts.contains(item.id) ? decrypted[item.id] : nil }
        return item.isEncrypted ? nil : (item.content ?? "")
    }

    /// « Annuler l'envoi du 18 oct. à 18:00 : Salut… » : N boutons identiques ne disent
    /// pas lequel (A01).
    private func cancelAccessibilityLabel(for item: ScheduledMessage) -> String {
        let when = item.sendAt.map { $0.sqFormatted(date: .medium) } ?? ""
        let text = String(content(for: item).prefix(40))
        return String(localized: "Annuler l’envoi du \(when) : \(text)")
    }

    private func statusLabel(_ item: ScheduledMessage) -> String? {
        if let v3 = item.v3 {
            switch v3.status {
            case .scheduled: return nil
            case .needsReencrypt: return String(localized: "En attente de rechiffrement")
            case .failed(let reason): return Self.failureLabel(reason)
            }
        }
        guard let status = item.status, status != "scheduled" else { return nil }
        return statusLabel(status)
    }

    /// `failureReason` d'un programmé chiffré ; une valeur inconnue a un texte générique.
    static func failureLabel(_ reason: String?) -> String {
        switch reason {
        case "MEMBER_LEFT": return String(localized: "Non envoyé : tu ne fais plus partie de la conversation.")
        case "DEVICE_REVOKED": return String(localized: "Non envoyé : l’appareil qui l’a programmé a été retiré.")
        case "REENCRYPT_EXPIRED": return String(localized: "Non envoyé : il n’a pas pu être rechiffré à temps.")
        default: return String(localized: "Échec d’envoi")
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "dispatching": return String(localized: "Envoi en cours…")
        case "failed_membership", "failed_validation", "failed_dispatch", "failed": return String(localized: "Échec d’envoi")
        case "canceled", "cancelled": return String(localized: "Annulé")
        case "sent": return String(localized: "Envoyé")
        default: return String(localized: "État inconnu")
        }
    }

    private func update(_ item: ScheduledMessage, sendAt: Date, content: String?) async throws {
        if let v3 = item.v3 {
            // Rechiffré sous l'époque courante, même message logique (point 3).
            let result = await services.e2eeV2Messaging.reschedule(
                v3, sendAt: sendAt, text: content, conversationId: conversation.id, isGroup: conversation.isGroup,
                participantIds: conversation.participants.map(\.userId)
            )
            if let message = result.map(EncryptedConversationSurfaces.scheduleFailureMessage)
                ?? String(localized: "Ce message programmé ne s’ouvre pas sur cet appareil.") {
                throw ScheduledMessageError(errorDescription: message)
            }
            await load()
            Haptics.success()
            return
        }
        let saved = try await service.updateScheduledMessage(
            conversationId: conversation.id,
            scheduledId: item.id,
            sendAt: sendAt,
            content: content
        )
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = saved }
        Haptics.success()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.scheduledMessages(conversationId: conversation.id)
            errorMessage = nil
            if usesV2, await ScheduledReencryption.run(items, conversation: conversation, runtime: services.e2eeV2Messaging) {
                items = try await service.scheduledMessages(conversationId: conversation.id)
            }
            await decryptAll()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    private func decryptAll() async {
        guard isE2EE else { return }
        if usesV2 {
            for item in items where decrypted[item.id] == nil {
                guard let v3 = item.v3,
                      let payload = await services.e2eeV2Messaging.openScheduled(v3, conversationId: conversation.id) else { continue }
                if case .text(let text) = payload.body {
                    decrypted[item.id] = text
                    decryptedTexts.insert(item.id)
                } else {
                    decrypted[item.id] = String(localized: "Message chiffré")
                }
            }
            return
        }
        guard let e2ee else { return }
        for item in items where item.isEncrypted && decrypted[item.id] == nil {
            // Reconstitue un MessageItem minimal pour réutiliser decryptText.
            let proxy = MessageItem(
                id: item.id,
                conversationId: item.conversationId,
                senderId: item.senderId,
                kind: item.kind,
                content: nil,
                e2eeVersion: item.e2eeVersion,
                e2eeIvB64: item.e2eeIvB64,
                e2eeCiphertextB64: item.e2eeCiphertextB64,
                e2eeAadB64: item.e2eeAadB64,
                metadata: item.metadata,
                createdAt: item.createdAt,
                editedAt: nil,
                deletedAt: nil,
                replyToId: item.replyToId,
                threadReplyCount: nil,
                sender: nil,
                attachments: [],
                reactions: []
            )
            decrypted[item.id] = try? await e2ee.decryptText(conversationId: conversation.id, message: proxy)
        }
    }

    private func delete(_ target: ScheduledMessage) async {
        errorMessage = nil
        do {
            try await service.deleteScheduledMessage(conversationId: conversation.id, scheduledId: target.id)
            items.removeAll { $0.id == target.id }
            Haptics.success()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}

private struct ScheduledMessageError: LocalizedError {
    let errorDescription: String?
}

/// Rechiffrement des programmés de son compte en `NEEDS_REENCRYPT`, à l'ouverture
/// de la conversation (E2EE-AUTO §7.8 F, point 3). Un programmé qui ne s'ouvre pas
/// ici reste en attente : un autre appareil du compte peut le sauver.
enum ScheduledReencryption {
    /// Vrai si au moins un programmé a été rechiffré.
    @discardableResult
    static func run(_ items: [ScheduledMessage], conversation: MessageConversation, runtime: E2EEV2MessagingRuntime) async -> Bool {
        var changed = false
        for item in items {
            guard let v3 = item.v3, v3.status == .needsReencrypt else { continue }
            if case .scheduled? = await runtime.reschedule(
                v3, sendAt: nil, conversationId: conversation.id, isGroup: conversation.isGroup,
                participantIds: conversation.participants.map(\.userId)
            ) { changed = true }
        }
        return changed
    }
}

/// Modification d'un envoi programmé : l'heure, et le texte quand la conversation n'est
/// pas chiffrée (le serveur refuse de changer le texte d'un envoi chiffré).
struct ScheduledMessageEditSheet: View {
    let item: ScheduledMessage
    /// `nil` : envoi chiffré, seule l'heure se change.
    let plainText: String?
    let subtitle: String?
    let onSave: (Date, String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var sendAt: Date
    @State private var isBusy = false
    @State private var errorMessage: String?

    init(item: ScheduledMessage, plainText: String?, subtitle: String?, onSave: @escaping (Date, String?) async throws -> Void) {
        self.item = item
        self.plainText = plainText
        self.subtitle = subtitle
        self.onSave = onSave
        _text = State(initialValue: plainText ?? "")
        _sendAt = State(initialValue: max(item.sendAt ?? Date(), Date().addingTimeInterval(120)))
    }

    private var canSave: Bool {
        sendAt > Date() && (plainText == nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(title: "Modifier l’envoi", subtitle: subtitle, closeIdentifier: "scheduled.edit.cancel") { dismiss() }
                if plainText != nil {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text("Message")
                            .sqKicker()
                            .padding(.leading, SQSpace.xs)
                        TextField("Message à envoyer", text: $text, axis: .vertical)
                            .lineLimit(2...5)
                            .sqHaloField()
                    }
                } else {
                    Label("Le texte d’un envoi chiffré ne se modifie pas : seule l’heure change.", systemImage: "lock.fill")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SendTimePicker(label: "Envoyer le", date: $sendAt)
                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                }
                GradientButton("Enregistrer", systemImage: "checkmark", isBusy: isBusy) {
                    Task { await save() }
                }
                .disabled(!canSave || isBusy)
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
    }

    private func save() async {
        guard canSave else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try await onSave(sendAt, plainText == nil || trimmed == plainText ? nil : trimmed)
            dismiss()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}
