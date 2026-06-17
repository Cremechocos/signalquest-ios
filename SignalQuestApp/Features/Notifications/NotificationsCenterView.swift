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
        defer { isLoading = false }
        do {
            items = try await service.list(cursor: nil)
        } catch {
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
    init(service: NotificationsServicing) {
        _model = StateObject(wrappedValue: NotificationsCenterViewModel(service: service))
    }

    var body: some View {
        List {
            Section {
                ForEach(model.items) { item in
                    notificationRow(item)
                        .listRowBackground(item.read != true ? SQColor.brandRed.opacity(0.08) : Color.clear)
                        .swipeActions {
                            Button("Lu") { Task { await model.markRead(item.id) } }.tint(SQColor.success)
                        }
                }
            } header: {
                Text("Activité").sqKicker()
            }
        }
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
        let style = iconStyle(for: item.type)
        let isUnread = item.read != true
        let titleText = item.title ?? item.type ?? "Notification"
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(style.color)
                .frame(width: 38, height: 38)
                .background(style.color.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: SQSpace.sm) {
                    Text(titleText)
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    if isUnread {
                        Circle().fill(SQColor.brandRed).frame(width: 8, height: 8)
                    }
                }
                if let message = item.message {
                    Text(message).font(.footnote).foregroundStyle(SQColor.labelSecondary)
                }
                if let date = item.createdAt {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(SQColor.labelTertiary)
                }
            }
        }
    }

    /// Icône + couleur de pastille par type de notification :
    /// like = rose, commentaire = bleu, follow = orange, système = gris.
    private func iconStyle(for kind: String?) -> (icon: String, color: Color) {
        let k = (kind ?? "").lowercased()
        if k.contains("like") || k.contains("reaction") || k.contains("favorite") {
            return ("heart.fill", SQColor.like)
        }
        if k.contains("comment") || k.contains("reply") || k.contains("mention") || k.contains("message") {
            return ("bubble.left.fill", SQColor.brandBlue)
        }
        if k.contains("follow") || k.contains("friend") {
            return ("person.fill.badge.plus", SQColor.brandRed)
        }
        return ("bell.fill", SQColor.labelSecondary)
    }
}
