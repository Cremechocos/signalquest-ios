import SwiftUI

@MainActor
final class NotificationsCenterViewModel: ObservableObject {
    @Published var items: [AppNotification] = []
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let service: NotificationsServicing
    init(service: NotificationsServicing) { self.service = service }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await service.list(cursor: nil)
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ id: String) async {
        try? await service.markRead(id: id)
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let clone = items[idx]
            items[idx] = AppNotification(
                id: clone.id, type: clone.type, title: clone.title, message: clone.message,
                createdAt: clone.createdAt, read: true, link: clone.link, metadata: clone.metadata
            )
        }
    }

    func markAll() async {
        try? await service.markAllRead()
        await load()
    }

    func deleteAll() async {
        try? await service.deleteAll()
        await load()
    }
}

struct NotificationsCenterView: View {
    @StateObject private var model: NotificationsCenterViewModel
    @EnvironmentObject private var router: AppRouter
    init(service: NotificationsServicing) {
        _model = StateObject(wrappedValue: NotificationsCenterViewModel(service: service))
    }

    var body: some View {
        List {
            if let error = model.errorMessage, model.items.isEmpty {
                Section {
                    ErrorStateView(title: "Notifications indisponibles", message: error) {
                        Task { await model.load() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else if !model.isLoading, model.items.isEmpty {
                Section {
                    EmptyStateView(
                        title: "Aucune notification",
                        message: "Tes notifications d'activité apparaîtront ici.",
                        systemImage: "bell"
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(model.items) { item in
                        Button {
                            Task { await model.markRead(item.id) }
                            route(item)
                        } label: {
                            notificationRow(item)
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: SQSpace.lg, bottom: 5, trailing: SQSpace.lg))
                        .swipeActions {
                            Button("Lu") { Task { await model.markRead(item.id) } }.tint(SQColor.success)
                        }
                    }
                } header: {
                    Text("Activité")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Tout marquer comme lu") { Task { await model.markAll() } }
                    Button("Tout supprimer", role: .destructive) { Task { await model.deleteAll() } }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(SQColor.label) }
                .accessibilityLabel("Options")
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private func notificationRow(_ item: AppNotification) -> some View {
        let isUnread = item.read != true
        let titleText = item.title ?? item.type ?? "Notification"
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: icon(for: item.type))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 38, height: 38)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: SQSpace.sm) {
                    Text(titleText)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    if isUnread {
                        Circle().fill(SQColor.brandRed).frame(width: 8, height: 8)
                            .accessibilityLabel("Non lue")
                    }
                }
                if let message = item.message {
                    Text(message)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let date = item.createdAt {
                    Text(date, format: .relative(presentation: .named))
                        .font(SQFont.body(11.5, relativeTo: .caption2))
                        .foregroundStyle(SQColor.labelTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        .contentShape(Rectangle())
    }

    /// Route vers le contenu lié (NOTIF-UX-01) via l'AppRouter partagé.
    private func route(_ item: AppNotification) {
        let meta = item.metadata
        router.handle(
            type: item.type,
            conversationId: metaString(meta, "conversationId", "conversation_id"),
            postId: metaString(meta, "postId", "post_id"),
            userId: metaString(meta, "userId", "user_id", "actorId", "actor_id"),
            siteId: metaString(meta, "siteId", "site_id")
        )
    }

    private func metaString(_ metadata: [String: JSONValue]?, _ keys: String...) -> String? {
        guard let metadata else { return nil }
        for key in keys {
            switch metadata[key] {
            case .string(let v) where !v.isEmpty: return v
            case .number(let n): return String(Int(n))
            default: continue
            }
        }
        return nil
    }

    /// Icône par type de notification (pastille unique `accentSoft` de la DA
    /// Crème : seule la forme distingue le type, la brique reste l'accent).
    private func icon(for kind: String?) -> String {
        let k = (kind ?? "").lowercased()
        if k.contains("like") || k.contains("reaction") || k.contains("favorite") {
            return "heart.fill"
        }
        if k.contains("comment") || k.contains("reply") || k.contains("mention") || k.contains("message") {
            return "bubble.left.fill"
        }
        if k.contains("follow") || k.contains("friend") {
            return "person.fill.badge.plus"
        }
        return "bell.fill"
    }
}
