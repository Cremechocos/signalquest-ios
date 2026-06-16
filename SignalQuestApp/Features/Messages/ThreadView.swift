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
    @State private var errorMessage: String?
    @State private var decrypted: [String: String] = [:]

    private var isE2EE: Bool { conversation.e2eeEnabled == true }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SQSpace.md) {
                        threadHeader
                        Divider().overlay(SQColor.separator)
                        if isLoading && replies.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, SQSpace.xl)
                        } else if replies.isEmpty {
                            Text("Aucune réponse pour l'instant. Lance le fil.")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SQSpace.lg)
                        } else {
                            ForEach(replies) { reply in
                                replyRow(reply)
                            }
                        }
                        if let errorMessage {
                            ErrorStateView(title: "Fil indisponible", message: errorMessage)
                        }
                    }
                    .padding()
                }
                composer
            }
            .navigationTitle("Fil de discussion")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
            }
            .signalQuestBackground()
            .task { await load() }
        }
    }

    // MARK: Sections

    private var threadHeader: some View {
        let source = parent ?? parentMessage
        return VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
            HStack(spacing: SQSpace.sm) {
                SQAvatar(url: source.sender?.avatarUrl, name: source.sender?.displayName ?? "?", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.sender?.displayName ?? "Message")
                        .font(SQType.caption.weight(.semibold))
                        .foregroundStyle(SQColor.label)
                    if let date = source.createdAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelTertiary)
                    }
                }
            }
            let text = displayedContent(for: source)
            if !text.isEmpty {
                Text(text)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
            }
            Text("\(replies.count) réponse\(replies.count > 1 ? "s" : "")")
                .sqKicker()
                .padding(.top, SQSpace.xs)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1)
        }
    }

    private func replyRow(_ reply: MessageItem) -> some View {
        let mine = reply.senderId == currentUserId
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !mine, let name = reply.sender?.displayName {
                    Text(name)
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Text(displayedContent(for: reply))
                    .font(SQType.body)
                    .foregroundStyle(mine ? .white : SQColor.label)
                    .padding(SQSpace.sm + 2)
                    .background(
                        mine ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                        in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                    )
                    .overlay {
                        if !mine {
                            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                                .stroke(SQColor.separator, lineWidth: 1)
                        }
                    }
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack(spacing: SQSpace.sm + 2) {
            TextField("Répondre dans le fil", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(SQTextFieldStyle())
            Button {
                Task { await sendReply() }
            } label: {
                Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                    .frame(width: 44, height: 44)
                    .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .foregroundStyle(.white)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding()
        .background(SQColor.surface)
        .overlay(alignment: .top) { Divider().overlay(SQColor.separator) }
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
            errorMessage = error.localizedDescription
        }
    }

    private func sendReply() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let sent = try await service.sendThreadReply(parentMessageId: parentMessage.id, text: text, in: conversation, e2ee: e2ee)
            if sent.isEncrypted { decrypted[sent.id] = text }
            replies.append(sent)
            draft = ""
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
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
        if message.deletedAt != nil { return "Message supprimé" }
        if message.isEncrypted { return decrypted[message.id] ?? "🔒 Message chiffré" }
        return message.content ?? ""
    }

    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }
}
