import SwiftUI

@MainActor
final class NotificationsCenterViewModel: ObservableObject {
    @Published var items: [AppNotification] = []
    @Published var errorMessage: String?
    @Published private(set) var actionErrorMessage: String?
    @Published var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var pendingReadIDs: Set<String> = []

    enum FailedAction: Equatable {
        case markRead(String), markAll, deleteAll
    }
    @Published private(set) var failedAction: FailedAction?

    private let service: NotificationsServicing
    private var loadGeneration = UUID()
    private var actionGeneration = UUID()
    init(service: NotificationsServicing) { self.service = service }

    func load() async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            let loaded = try await service.list(cursor: nil)
            guard loadGeneration == generation else { return }
            items = loaded
        } catch {
            guard loadGeneration == generation, !error.isCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ id: String) async {
        guard !isMutating, !pendingReadIDs.contains(id),
              items.contains(where: { $0.id == id && $0.read != true }) else { return }
        let generation = actionGeneration
        pendingReadIDs.insert(id)
        actionErrorMessage = nil
        failedAction = nil
        defer { pendingReadIDs.remove(id) }
        do {
            try await service.markRead(id: id)
            guard actionGeneration == generation else { return }
            loadGeneration = UUID()
            isLoading = false
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index] = items[index].withRead(true)
            }
        } catch {
            guard actionGeneration == generation, !error.isCancellation else { return }
            actionErrorMessage = String(localized: "Action impossible")
            failedAction = .markRead(id)
        }
    }

    func markAll() async {
        guard !isMutating, pendingReadIDs.isEmpty else { return }
        isMutating = true
        actionErrorMessage = nil
        failedAction = nil
        defer { isMutating = false }
        do {
            try await service.markAllRead()
            actionGeneration = UUID()
            loadGeneration = UUID()
            isLoading = false
            items = items.map { $0.withRead(true) }
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            actionErrorMessage = String(localized: "Action impossible")
            failedAction = .markAll
        }
    }

    func deleteAll() async {
        guard !isMutating, pendingReadIDs.isEmpty else { return }
        isMutating = true
        actionErrorMessage = nil
        failedAction = nil
        defer { isMutating = false }
        do {
            try await service.deleteAll()
            actionGeneration = UUID()
            loadGeneration = UUID()
            isLoading = false
            items = []
            errorMessage = nil
        } catch {
            guard !error.isCancellation else { return }
            actionErrorMessage = String(localized: "Action impossible")
            failedAction = .deleteAll
        }
    }

    func retryFailedAction() async {
        switch failedAction {
        case .markRead(let id): await markRead(id)
        case .markAll: await markAll()
        case .deleteAll: await deleteAll()
        case nil: break
        }
    }
}

private extension AppNotification {
    func withRead(_ value: Bool) -> AppNotification {
        AppNotification(id: id, type: type, title: title, message: message,
            createdAt: createdAt, read: value, link: link, metadata: metadata)
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
            if let error = model.actionErrorMessage {
                Section {
                    HStack(spacing: SQSpace.md) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SQColor.dangerInk)
                        Spacer(minLength: 0)
                        Button("Réessayer") { Task { await model.retryFailedAction() } }
                            .disabled(model.isMutating || !model.pendingReadIDs.isEmpty)
                    }
                    .font(SQType.caption)
                    .listRowBackground(SQColor.dangerSoft)
                }
            }
            if let error = model.errorMessage, !model.items.isEmpty {
                Section {
                    HStack(spacing: SQSpace.md) {
                        Text(error).foregroundStyle(SQColor.dangerInk)
                        Spacer(minLength: 0)
                        Button("Réessayer") { Task { await model.load() } }
                    }
                    .font(SQType.caption)
                    .listRowBackground(SQColor.dangerSoft)
                }
            }
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
        .sqReadableWidth()
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
                .disabled(model.isMutating || !model.pendingReadIDs.isEmpty)
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
                        .foregroundStyle(SQColor.labelSecondary)
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
            siteId: metaString(meta, "siteId", "site_id"),
            reportId: metaString(meta, "reportId", "report_id"),
            // Panne communautaire : la metadata en base porte `outageId` (cf. le fan-out
            // serveur). C'est ce qui envoie sur la FEUILLE de panne plutôt que sur la fiche du
            // site — et le seul chemin qui atteigne une panne déjà rétablie, qu'aucune liste ne
            // rend plus.
            outageId: metaString(meta, "outageId", "outage_id")
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
        if k.contains("antenna_report") || k.contains("site_report") {
            return "exclamationmark.bubble.fill"
        }
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
