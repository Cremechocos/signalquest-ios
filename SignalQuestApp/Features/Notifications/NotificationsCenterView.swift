import SwiftUI

@MainActor
final class NotificationsCenterViewModel: ObservableObject {
    @Published var items: [AppNotification] = []
    @Published var errorMessage: String?
    @Published private(set) var paginationErrorMessage: String?
    @Published private(set) var actionErrorMessage: String?
    @Published var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var nextCursor: String?
    @Published private(set) var unreadCount = 0
    @Published private(set) var isMutating = false
    @Published private(set) var pendingReadIDs: Set<String> = []

    enum FailedAction: Equatable {
        case markRead(String), markAll, deleteAll
    }
    @Published private(set) var failedAction: FailedAction?

    private let service: NotificationsServicing
    private let badge: AppServices?
    private let accountSession: LocalAccountSession?
    private var loadGeneration = UUID()
    private var actionGeneration = UUID()
    private var isCurrentAccount: Bool {
        accountSession == nil || LocalAccountScope.sessionSnapshot() == accountSession
    }

    init(service: NotificationsServicing, badge: AppServices? = nil) {
        self.service = service
        self.badge = badge
        accountSession = LocalAccountScope.sessionSnapshot()
    }

    func load() async {
        guard isCurrentAccount else { return }
        let badgeTicket = badge?.notificationBadgeRefreshTicket()
        let generation = UUID()
        loadGeneration = generation
        if AppEnvironment.usesDemoData {
            // Tours de captures : une activité plausible, sans réseau.
            if items.isEmpty { items = AppNotification.demo() }
            unreadCount = items.filter { $0.read != true }.count
            errorMessage = nil
            return
        }
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        paginationErrorMessage = nil
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            let page = try await service.list(cursor: nil)
            guard loadGeneration == generation, isCurrentAccount else { return }
            items = page.notifications
            nextCursor = page.nextCursor
            unreadCount = page.unreadCount ?? page.notifications.filter { $0.read != true }.count
            if let badgeTicket { badge?.publishNotificationBadge(unreadCount: unreadCount, for: badgeTicket) }
        } catch {
            guard loadGeneration == generation, isCurrentAccount, !error.isCancellation else { return }
            errorMessage = error.userFacingMessage
        }
    }

    func loadMore() async {
        guard isCurrentAccount, let cursor = nextCursor, !isLoading, !isLoadingMore, !isMutating else { return }
        let badgeTicket = badge?.notificationBadgeRefreshTicket()
        let generation = loadGeneration
        isLoadingMore = true
        paginationErrorMessage = nil
        defer { if loadGeneration == generation { isLoadingMore = false } }
        do {
            let page = try await service.list(cursor: cursor)
            guard loadGeneration == generation, nextCursor == cursor, isCurrentAccount else { return }
            var seen = Set(items.map(\.id))
            items.append(contentsOf: page.notifications.filter { seen.insert($0.id).inserted })
            nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
            if let count = page.unreadCount {
                unreadCount = count
                if let badgeTicket { badge?.publishNotificationBadge(unreadCount: count, for: badgeTicket) }
            }
        } catch {
            guard loadGeneration == generation, isCurrentAccount, !error.isCancellation else { return }
            paginationErrorMessage = String(localized: "Chargement impossible")
        }
    }

    func markRead(_ id: String) async {
        guard isCurrentAccount, !isMutating, !pendingReadIDs.contains(id),
              items.contains(where: { $0.id == id && $0.read != true }) else { return }
        let generation = actionGeneration
        pendingReadIDs.insert(id)
        actionErrorMessage = nil
        failedAction = nil
        defer { pendingReadIDs.remove(id) }
        do {
            if !AppEnvironment.usesDemoData { try await service.markRead(id: id) }
            guard actionGeneration == generation, isCurrentAccount else { return }
            loadGeneration = UUID()
            isLoading = false
            isLoadingMore = false
            if let index = items.firstIndex(where: { $0.id == id }) {
                if items[index].read != true { unreadCount = max(0, unreadCount - 1) }
                items[index] = items[index].withRead(true)
            }
            if let accountSession { badge?.applyNotificationBadgeMutation(unreadCount: unreadCount, for: accountSession) }
        } catch {
            guard actionGeneration == generation, isCurrentAccount, !error.isCancellation else { return }
            actionErrorMessage = String(localized: "Action impossible")
            failedAction = .markRead(id)
        }
    }

    func markAll() async {
        guard isCurrentAccount, !isMutating, pendingReadIDs.isEmpty else { return }
        isMutating = true
        actionErrorMessage = nil
        failedAction = nil
        defer { isMutating = false }
        do {
            if !AppEnvironment.usesDemoData { try await service.markAllRead() }
            guard isCurrentAccount else { return }
            actionGeneration = UUID()
            loadGeneration = UUID()
            isLoading = false
            isLoadingMore = false
            items = items.map { $0.withRead(true) }
            unreadCount = 0
            if let accountSession { badge?.applyNotificationBadgeMutation(unreadCount: 0, for: accountSession) }
            errorMessage = nil
        } catch {
            guard isCurrentAccount, !error.isCancellation else { return }
            actionErrorMessage = String(localized: "Action impossible")
            failedAction = .markAll
        }
    }

    func deleteAll() async {
        guard isCurrentAccount, !isMutating, pendingReadIDs.isEmpty else { return }
        isMutating = true
        actionErrorMessage = nil
        failedAction = nil
        defer { isMutating = false }
        do {
            if !AppEnvironment.usesDemoData { try await service.deleteAll() }
            guard isCurrentAccount else { return }
            actionGeneration = UUID()
            loadGeneration = UUID()
            isLoading = false
            isLoadingMore = false
            items = []
            nextCursor = nil
            unreadCount = 0
            if let accountSession { badge?.applyNotificationBadgeMutation(unreadCount: 0, for: accountSession) }
            errorMessage = nil
        } catch {
            guard isCurrentAccount, !error.isCancellation else { return }
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

    /// Activité de démonstration : trois non-lues du jour, puis la semaine et plus ancien.
    static func demo(now: Date = .now) -> [AppNotification] {
        func item(_ id: String, _ type: String, _ message: String?, ago: TimeInterval, read: Bool) -> AppNotification {
            AppNotification(id: "demo-\(id)", type: type, title: nil, message: message,
                            createdAt: now.addingTimeInterval(-ago), read: read, link: nil, metadata: nil)
        }
        return [
            item("1", "message_new", "Marc : « On compare nos débits ? »", ago: 12 * 60, read: false),
            item("2", "community_outage", "Bouygues · Gare de la Part-Dieu", ago: 40 * 60, read: false),
            item("3", "social_reaction", "Camille a aimé ta mesure de 312 Mbit/s", ago: 2 * 3_600, read: false),
            item("4", "friend_accepted", "Léa fait maintenant partie de tes amis", ago: 2 * 86_400, read: true),
            item("5", "social_repost", nil, ago: 3 * 86_400, read: true),
            item("6", "social_comment", "Julien : « Même chose à Villeurbanne »", ago: 12 * 86_400, read: true),
        ]
    }
}

struct NotificationsCenterView: View {
    @StateObject private var model: NotificationsCenterViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.openURL) private var openURL
    /// « Tout supprimer » est définitif : il se confirme (SOC-22).
    @State private var confirmDeleteAll = false
    init(service: NotificationsServicing, badge: AppServices? = nil) {
        _model = StateObject(wrappedValue: NotificationsCenterViewModel(service: service, badge: badge))
    }

    init(model: NotificationsCenterViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.sm, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
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
            if model.isLoading && model.items.isEmpty {
                Section { SQSpinner().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            } else if let error = model.errorMessage, model.items.isEmpty {
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
                ForEach(NotificationPeriod.groups(model.items)) { group in
                    Section {
                        ForEach(group.items) { item in
                            Button {
                                Task { await model.markRead(item.id) }
                                route(item)
                            } label: {
                                notificationRow(item, period: group.period)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(SQColor.surface)
                            .listRowSeparatorTint(SQColor.separator)
                            .swipeActions {
                                Button("Lu") { Task { await model.markRead(item.id) } }.tint(SQColor.success)
                            }
                        }
                    } header: {
                        Text(group.period.title).sqKicker().textCase(nil)
                    }
                }
                Section {
                    if model.isLoadingMore {
                        SQSpinner().frame(maxWidth: .infinity)
                    } else if model.nextCursor != nil {
                        Button(model.paginationErrorMessage == nil ? "Charger la suite" : "Réessayer") {
                            Task { await model.loadMore() }
                        }
                        .font(SQType.callout(.semibold))
                        .foregroundStyle(SQColor.label)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("notifications.loadMore")
                    }
                    if let error = model.paginationErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.dangerInk)
                    }
                } footer: {
                    Text("Glisse une notification vers la gauche pour la marquer comme lue.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .modifier(NotificationListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .background(SQColor.bg.ignoresSafeArea())
        // Le titre vit en tête de liste ; la barre garde le retour et le menu.
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Tout marquer comme lu") { Task { await model.markAll() } }
                    Button("Tout supprimer", role: .destructive) { confirmDeleteAll = true }
                } label: { Image(systemName: "ellipsis").foregroundStyle(SQColor.label) }
                .accessibilityLabel("Options")
                .disabled(model.isMutating || !model.pendingReadIDs.isEmpty)
            }
        }
        .confirmationDialog("Supprimer toutes les notifications ?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Tout supprimer", role: .destructive) { Task { await model.deleteAll() } }
        } message: {
            Text("Cette action est définitive.")
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    /// Grand titre et nombre de non-lues, comme les autres écrans Halo.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Notifications")
                .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                .foregroundStyle(SQColor.label)
                .sqHeader()
            if model.unreadCount > 0 {
                Text("\(model.unreadCount) non lues")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
            } else if !model.items.isEmpty {
                Text("Tout est lu")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func notificationRow(_ item: AppNotification, period: NotificationPeriod) -> some View {
        let isUnread = item.read != true
        let titleText = item.title ?? Self.title(for: item.type)
        let isOutage = Self.isOutage(item.type)
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: icon(for: item.type), size: 38,
                           tint: isOutage ? SQColor.dangerInk : SQColor.ink2,
                           fill: isOutage ? SQColor.dangerSoft : SQColor.chip,
                           font: .system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(SQType.callout(isUnread ? .heavy : .semibold))
                    .foregroundStyle(SQColor.label)
                if let message = item.message, !message.isEmpty {
                    Text(message)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                }
                if let date = item.createdAt {
                    Group {
                        switch period {
                        case .today: Text(date, format: .relative(presentation: .named))
                        case .thisWeek: Text(date, format: .dateTime.weekday(.wide))
                        case .older: Text(date, format: .dateTime.day().month(.wide))
                        }
                    }
                    .font(SQFont.body(12, relativeTo: .caption2))
                    .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isUnread {
                Circle().fill(SQColor.brandRed).frame(width: 9, height: 9)
                    .padding(.top, 6)
                    .accessibilityLabel("Non lue")
            }
        }
        .padding(.vertical, SQSpace.xs)
        .contentShape(Rectangle())
    }

    /// Route vers le contenu lié (NOTIF-UX-01) via l'AppRouter partagé.
    private func route(_ item: AppNotification) {
        if let url = Self.adminWebURL(type: item.type, link: item.link, base: AppConfig.current.appBaseURL) {
            openURL(url)
            return
        }
        let meta = item.metadata
        router.handle(
            type: item.type,
            conversationId: metaString(meta, "conversationId", "conversation_id"),
            postId: metaString(meta, "postId", "post_id"),
            userId: metaString(meta, "userId", "user_id", "actorId", "actor_id"),
            siteId: metaString(meta, "siteId", "site_id", "codeSiteOp"),
            reportId: metaString(meta, "reportId", "report_id"),
            targetId: metaString(meta, "targetId", "target_id"),
            // Panne communautaire : la metadata en base porte `outageId` (cf. le fan-out
            // serveur). C'est ce qui envoie sur la FEUILLE de panne plutôt que sur la fiche du
            // site — et le seul chemin qui atteigne une panne déjà rétablie, qu'aucune liste ne
            // rend plus.
            outageId: metaString(meta, "outageId", "outage_id"),
            bugId: metaString(meta, "bugId", "bug_id"),
            anfrFocus: item.type?.lowercased() == "anfr_update" ? anfrFocus(meta) : nil
        )
    }

    /// Relevé et zone d'une mise à jour ANFR : la metadata en base écrit la zone
    /// `zoneLatitude` / `zoneLongitude` / `zoneRadius`, en nombres (`metaString` les
    /// tronquerait en entiers).
    private func anfrFocus(_ metadata: [String: JSONValue]?) -> ANFRFocus? {
        func text(_ keys: String...) -> String? {
            for key in keys {
                switch metadata?[key] {
                case .string(let value)? where !value.isEmpty: return value
                case .number(let value)?: return String(value)
                default: continue
                }
            }
            return nil
        }
        return ANFRFocus.parse(
            date: text("date"), latitude: text("zoneLatitude", "zoneLat"),
            longitude: text("zoneLongitude", "zoneLon"), radiusMeters: text("zoneRadius", "zoneRadiusMeters")
        )
    }

    /// Modération sans écran iOS (message ou photo signalés, contestation, nom d'antenne
    /// proposé) : la page d'administration du site. Seul un chemin `/admin` est suivi.
    static func adminWebURL(type: String?, link: String?, base: URL) -> URL? {
        let adminTypes: Set<String> = ["message_report", "photo_reported", "photo_appeal", "antenna_name_proposal_admin"]
        guard adminTypes.contains(type?.lowercased() ?? ""), let link, link.hasPrefix("/admin"),
              let url = URL(string: link, relativeTo: base)?.absoluteURL,
              url.host == base.host else { return nil }
        return url
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

    /// Titre lisible quand le serveur n'en envoie pas : la liste affichait le
    /// type technique (« social_follow », SOC-44).
    static func title(for kind: String?) -> String {
        switch kind?.lowercased() {
        case "message_new": return String(localized: "Nouveau message")
        case "message_reaction", "social_reaction": return String(localized: "Nouvelle réaction")
        case "message_mention", "social_mention": return String(localized: "On t’a mentionné")
        case "social_comment": return String(localized: "Nouveau commentaire")
        case "social_repost": return String(localized: "Ta publication a été repartagée")
        case "social_follow": return String(localized: "Quelqu’un te suit")
        case "friend_request": return String(localized: "Demande d’ami")
        case "friend_accepted": return String(localized: "Demande d’ami acceptée")
        case "community_outage": return String(localized: "Panne signalée")
        default: return String(localized: "Notification")
        }
    }

    /// Une panne se signale en rouge ; les autres types partagent la pastille
    /// neutre et se distinguent par la forme.
    static func isOutage(_ kind: String?) -> Bool {
        (kind ?? "").lowercased().contains("outage")
    }

    private func icon(for kind: String?) -> String {
        let k = (kind ?? "").lowercased()
        if Self.isOutage(k) { return "exclamationmark.triangle.fill" }
        if k.contains("repost") { return "arrow.2.squarepath" }
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

/// Période d'une notification : la liste se lit comme un fil daté
/// (« Aujourd’hui », « Cette semaine », « Plus ancien »), dans l'ordre du serveur.
enum NotificationPeriod: Int, CaseIterable, Identifiable {
    case today, thisWeek, older

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: return String(localized: "Aujourd’hui")
        case .thisWeek: return String(localized: "Cette semaine")
        case .older: return String(localized: "Plus ancien")
        }
    }

    static func of(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> NotificationPeriod {
        guard let date else { return .older }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let startOfToday = calendar.startOfDay(for: now)
        guard let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) else { return .older }
        return date >= weekAgo ? .thisWeek : .older
    }

    struct Bucket: Identifiable {
        let period: NotificationPeriod
        let items: [AppNotification]
        var id: Int { period.rawValue }
    }

    static func groups(_ items: [AppNotification], now: Date = .now, calendar: Calendar = .current) -> [Bucket] {
        let byPeriod = Dictionary(grouping: items) { of($0.createdAt, now: now, calendar: calendar) }
        return allCases.compactMap { period in
            byPeriod[period].map { Bucket(period: period, items: $0) }
        }
    }
}

/// Marges d'une liste groupée sous un en-tête maison (iOS 17+ ; iOS 16 garde
/// celles du système).
private struct NotificationListMargins: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .contentMargins(.top, SQSpace.xs, for: .scrollContent)
                .listSectionSpacing(SQSpace.lg)
        } else {
            content
        }
    }
}
