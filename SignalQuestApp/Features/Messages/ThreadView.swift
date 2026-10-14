import SwiftUI

/// Fil de discussion (thread) d'un message. Affiche le message parent en tête,
/// les réponses, et un composer. Respecte l'E2EE : les réponses partent
/// chiffrées dans une conversation chiffrée (via `sendThreadReply`).
struct ThreadView: View {
    let parentMessage: MessageItem
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?

    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var parent: MessageItem?
    @State private var replies: [MessageItem] = []
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isSending = false
    /// Échec du chargement du fil (remplace le fil, avec « Réessayer »).
    @State private var errorMessage: String?
    /// Échec d'envoi d'une réponse : dit près du champ, le brouillon reste.
    @State private var sendError: String?
    @State private var decrypted: [String: String] = [:]

    private var isE2EE: Bool { conversation.e2eeEnabled == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SQSpace.sm) {
                Text("Fil de discussion")
                    .font(SQFont.display(22, .bold, relativeTo: .title2))
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "thread.close") { dismiss() }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.sm)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SQSpace.md) {
                    threadHeader
                    // Les réponses en retrait, le long d'un filet.
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        if isLoading && replies.isEmpty {
                            SQSpinner().frame(maxWidth: .infinity).padding(.vertical, SQSpace.xl)
                        } else if replies.isEmpty {
                            // L'erreur de chargement, plus bas, dit déjà pourquoi c'est vide.
                            if errorMessage == nil {
                                Text("Aucune réponse pour l'instant. Lance le fil.")
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, SQSpace.sm)
                            }
                        } else {
                            ForEach(replies) { reply in
                                replyRow(reply)
                            }
                        }
                    }
                    .padding(.leading, SQSpace.md)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(SQColor.separator).frame(width: 2)
                    }
                    .padding(.leading, SQSpace.sm)
                    if let errorMessage {
                        ErrorStateView(title: "Fil de discussion indisponible", message: errorMessage) {
                            Task { await load() }
                        }
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.sm)
            }
            composer
        }
        .sqSheet(background: SQColor.bg)
        .task { await load() }
    }

    // MARK: Sections

    /// Le message d'origine en carte : auteur, texte, heure et nombre de réponses.
    private var threadHeader: some View {
        let source = parent ?? parentMessage
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: SQSpace.sm) {
                SQAvatar(url: source.sender?.avatarUrl, name: source.sender?.displayName ?? "?", size: 28)
                    .accessibilityHidden(true)
                Text(source.sender?.displayName ?? String(localized: "Message"))
                    .font(SQType.caption.weight(.bold))
                    .foregroundStyle(SQColor.label)
            }
            let text = displayedContent(for: source)
            if !text.isEmpty {
                Text(text)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
            }
            HStack(spacing: SQSpace.xs) {
                if let date = source.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                if !replies.isEmpty {
                    if source.createdAt != nil { Text(verbatim: "·") }
                    Text("\(replies.count) réponse")
                }
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func replyRow(_ reply: MessageItem) -> some View {
        let mine = reply.senderId == currentUserId
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !mine, let name = reply.sender?.displayName {
                    Text(name)
                        .font(SQType.micro.weight(.semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Text(displayedContent(for: reply))
                    .font(SQType.body)
                    .foregroundStyle(mine ? SQColor.onInk : SQColor.label)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 15)
                    .background(mine ? SQColor.label : SQColor.surface, in: bubbleShape(mine: mine))
                    .sqShadowSoft()
                if let date = reply.createdAt {
                    Text(date.formatted(date: .omitted, time: .shortened))
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    /// Coins asymétriques DA (alignés sur ConversationDetailView) : le coin bas
    /// côté émetteur est plus petit, comme une « pointe » de bulle.
    private func bubbleShape(mine: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: SQRadius.xl,
            bottomLeadingRadius: mine ? SQRadius.xl : 6,
            bottomTrailingRadius: mine ? 6 : SQRadius.xl,
            topTrailingRadius: SQRadius.xl,
            style: .continuous
        )
    }

    /// Même compositeur que la conversation : champ blanc, envoi rond encre.
    private var composer: some View {
        let sendable = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
        return VStack(alignment: .leading, spacing: SQSpace.xs) {
            if let sendError {
                SQInlineError(message: sendError)
                    .padding(.horizontal, SQSpace.xs)
            }
            HStack(alignment: .bottom, spacing: SQSpace.sm) {
                TextField("Répondre dans le fil", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm)
                    .frame(minHeight: 44)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(SQColor.separator))
                Button {
                    Task { await sendReply() }
                } label: {
                    Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(sendable ? SQColor.onInk : SQColor.labelTertiary)
                        .frame(width: 44, height: 44)
                        .background(sendable ? SQColor.label : SQColor.chip, in: Circle())
                        .contentShape(Circle())
                }
                .disabled(!sendable)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(isSending ? "Envoi en cours" : "Envoyer la réponse")
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .background {
            SQColor.bg
                .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: Données

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.thread(parentMessageId: parentMessage.id, take: 80, cursor: nil)
            parent = page.parent ?? parentMessage
            replies = page.replies
            errorMessage = nil
            await decryptAll()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    private func sendReply() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            let sent = try await service.sendThreadReply(parentMessageId: parentMessage.id, text: text, in: conversation, e2ee: e2ee)
            if sent.isEncrypted { decrypted[sent.id] = text }
            replies.append(sent)
            draft = ""
            Haptics.success()
        } catch {
            sendError = error.userFacingMessage
            Haptics.error()
        }
    }

    private func decryptAll() async {
        guard isE2EE, let e2ee else { return }
        var targets = replies
        if let parent { targets.append(parent) }
        for message in targets where message.isEncrypted && decrypted[message.id] == nil {
            decrypted[message.id] = try? await e2ee.decryptText(conversationId: conversation.id, message: message)
        }
    }

    private func displayedContent(for message: MessageItem) -> String {
        if message.deletedAt != nil { return String(localized: "Message supprimé") }
        if message.isEncrypted { return decrypted[message.id] ?? String(localized: "🔒 Message chiffré") }
        return message.content ?? ""
    }

    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }
}
