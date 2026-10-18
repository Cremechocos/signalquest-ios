import SwiftUI
import ImageIO

@MainActor
final class MessagesViewModel: ObservableObject {
    @Published var conversations: [MessageConversation] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Échec d'une action sur une conversation (lu, épingle, sourdine, départ) :
    /// passager, il ne remplace pas la liste par « Messagerie indisponible ».
    @Published var actionError: String?
    /// Aperçus déchiffrés du dernier message, par id de conversation.
    @Published var decryptedPreviews: [String: String] = [:]
    /// Limite d'épinglage du compte (P2-46), quand le serveur la sert.
    @Published var pinLimit: Int?
    /// D'autres conversations existent côté serveur au-delà de celles chargées (B01).
    @Published private(set) var hasMoreConversations = false
    @Published private(set) var isLoadingMore = false
    /// Dossiers du compte et leurs conversations.
    @Published private(set) var folders: [ConversationFolder] = []
    /// Session focus en cours (échue ou inactive : `nil`).
    @Published private(set) var focus: MessageFocusSession?
    /// Nombre d'archivées, servi avec la liste par défaut. `nil` : le serveur ne
    /// sait pas archiver, et aucune action d'archivage ne se propose.
    @Published private(set) var shelvedSummary: ShelvedSummary?
    /// Archivées chargées à l'ouverture de l'écran « Archivées ».
    @Published private(set) var shelvedConversations: [MessageConversation] = []
    @Published private(set) var isLoadingShelved = false
    private var organizationSeededForDemo = false
    private var nextCursor: String?
    /// Pages déjà chargées : une relecture périodique les refait toutes, sinon elle
    /// ferait disparaître les plus anciennes que l'on vient de faire défiler.
    private var loadedPages = 1
    static let pageSize = 50
    static let maxPages = 40

    /// « Épingler » ne se propose plus une fois la limite atteinte.
    var canPinMore: Bool {
        guard let pinLimit else { return true }
        return conversations.filter { $0.pinnedAt != nil }.count < pinLimit
    }

    private let service: MessagesServicing

    init(service: MessagesServicing) {
        self.service = service
    }

    /// L'archivage n'existe côté serveur que s'il a servi `shelvedSummary`.
    var supportsShelving: Bool { shelvedSummary != nil }

    func load() async {
        if AppEnvironment.usesDemoData {
            conversations = Array.demo.inDisplayOrder().filter { demo in
                !shelvedConversations.contains { $0.id == demo.id }
            }
            if !organizationSeededForDemo {
                shelvedSummary = ShelvedSummary(count: Array.demoShelved.count, unreadCount: 1)
                shelvedConversations = Array.demoShelved
            }
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        if AppEnvironment.delaysLoadForQA {
            try? await Task.sleep(for: .seconds(4))
        }
        do {
            let first = try await service.conversationPage(cursor: nil, take: Self.pageSize)
            var all = first.conversations
            var seen = Set(all.map(\.id))
            var last = first
            var pages = 1
            // Relit les pages déjà défilées ; une page qui échoue garde ce qui précède.
            while pages < loadedPages, last.hasMore, let cursor = last.nextCursor {
                guard let page = try? await service.conversationPage(cursor: cursor, take: Self.pageSize) else { break }
                all += page.conversations.filter { seen.insert($0.id).inserted }
                last = page
                pages += 1
            }
            loadedPages = pages
            conversations = all.inDisplayOrder()
            pinLimit = first.pinLimit
            shelvedSummary = first.shelvedSummary
            hasMoreConversations = last.hasMore && last.nextCursor != nil
            nextCursor = last.nextCursor
            errorMessage = nil
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    // MARK: Dossiers, focus, archivées

    /// Dossiers et session focus : relus à l'ouverture, au retour et au tirer-pour-rafraîchir.
    /// Un échec garde l'état affiché (la liste reste utilisable sans eux).
    func loadOrganization() async {
        if AppEnvironment.usesDemoData {
            if !organizationSeededForDemo {
                organizationSeededForDemo = true
                folders = ConversationFolder.demo
            }
            return
        }
        if let list = try? await service.conversationFolders() { folders = list }
        do {
            let session = try await service.focusSession()
            focus = session?.isRunning() == true ? session : nil
        } catch {
            // Session inconnue : on garde l'état précédent.
        }
    }

    func folderIds(for conversationId: String) -> Set<String> {
        Set(folders.filter { $0.conversationIds.contains(conversationId) }.map(\.id))
    }

    /// Crée un dossier ; `nil` si le nom est vide ou si le serveur refuse.
    @discardableResult
    func createFolder(named name: String) async -> ConversationFolder? {
        let trimmed = Self.cleanFolderName(name)
        guard !trimmed.isEmpty else { return nil }
        do {
            let folder = try await service.createConversationFolder(name: trimmed)
            folders.append(folder)
            return folder
        } catch {
            if !error.isCancellation { actionError = String(localized: "Le dossier n’a pas pu être créé.") }
            return nil
        }
    }

    func renameFolder(_ folder: ConversationFolder, to name: String) async {
        let trimmed = Self.cleanFolderName(name)
        guard !trimmed.isEmpty, trimmed != folder.name else { return }
        let previous = folders
        update(folder: folder.id) { $0.name = trimmed }
        do {
            _ = try await service.renameConversationFolder(id: folder.id, name: trimmed)
        } catch {
            folders = previous
            if !error.isCancellation { actionError = String(localized: "Le dossier n’a pas pu être renommé.") }
        }
    }

    func deleteFolder(_ folder: ConversationFolder) async {
        let previous = folders
        folders.removeAll { $0.id == folder.id }
        do {
            try await service.deleteConversationFolder(id: folder.id)
        } catch {
            folders = previous
            if !error.isCancellation { actionError = String(localized: "Le dossier n’a pas pu être supprimé.") }
        }
    }

    /// Range ou retire une conversation d'un dossier (un dossier à la fois ; la
    /// conversation peut figurer dans plusieurs dossiers).
    func setConversation(_ conversationId: String, in folder: ConversationFolder, contained: Bool) async {
        let previous = folders
        var ids = folderIds(for: conversationId)
        if contained { ids.insert(folder.id) } else { ids.remove(folder.id) }
        update(folder: folder.id) { value in
            value.conversationIds.removeAll { $0 == conversationId }
            if contained { value.conversationIds.append(conversationId) }
        }
        do {
            try await service.setConversationFolders(Array(ids), conversationId: conversationId)
        } catch {
            folders = previous
            if !error.isCancellation { actionError = String(localized: "Le dossier n’a pas pu être modifié.") }
        }
    }

    private func update(folder id: String, _ transform: (inout ConversationFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        transform(&folders[index])
    }

    static func cleanFolderName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ConversationFolder.maxNameLength))
    }

    func startFocus(conversationIds: [String], endsAt: Date?) async {
        do {
            let session = try await service.startFocus(name: nil, conversationIds: conversationIds, endsAt: endsAt)
            focus = session?.isRunning() == true ? session : nil
        } catch {
            if !error.isCancellation { actionError = String(localized: "Le mode focus n’a pas pu être activé.") }
        }
    }

    func endFocus() async {
        let previous = focus
        focus = nil
        do {
            try await service.endFocus()
        } catch {
            focus = previous
            if !error.isCancellation { actionError = String(localized: "Le mode focus n’a pas pu être désactivé.") }
        }
    }

    /// Archive (ou désarchive) pour soi. La conversation quitte tout de suite la
    /// liste affichée ; elle revient si le serveur refuse. `true` si c'est fait.
    @discardableResult
    func setShelved(_ shelved: Bool, _ conversation: MessageConversation, isUnread: Bool) async -> Bool {
        guard supportsShelving else { return false }
        let previousSummary = shelvedSummary
        let previousList = conversations
        let previousShelved = shelvedConversations
        if shelved {
            conversations.removeAll { $0.id == conversation.id }
            if let summary = shelvedSummary {
                shelvedSummary = ShelvedSummary(count: summary.count + 1, unreadCount: summary.unreadCount + (isUnread ? 1 : 0))
            }
        } else {
            shelvedConversations.removeAll { $0.id == conversation.id }
            if let summary = shelvedSummary {
                shelvedSummary = ShelvedSummary(count: summary.count - 1, unreadCount: summary.unreadCount - (isUnread ? 1 : 0))
            }
        }
        do {
            try await service.setConversationShelved(shelved, conversationId: conversation.id)
            return true
        } catch {
            conversations = previousList
            shelvedConversations = previousShelved
            shelvedSummary = previousSummary
            if !error.isCancellation {
                actionError = shelved
                    ? String(localized: "La conversation n’a pas pu être archivée.")
                    : String(localized: "La conversation n’a pas pu être désarchivée.")
            }
            return false
        }
    }

    /// Les archivées, lues à l'ouverture de leur écran.
    func loadShelved() async {
        if AppEnvironment.usesDemoData { return }
        isLoadingShelved = true
        defer { isLoadingShelved = false }
        do {
            shelvedConversations = try await service.shelvedConversations().inDisplayOrder()
            errorMessage = nil
        } catch {
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }

    /// Une conversation hors des pages chargées (notification, lien) : elle est
    /// lue seule et ajoutée à la liste, pour pouvoir être ouverte (B01).
    func ensureLoaded(id: String) async {
        guard openableConversation(id: id) == nil,
              let conversation = try? await service.conversation(id: id) else { return }
        // Une conversation archivée s'ouvre sans reparaître dans la liste par défaut.
        if conversation.shelved {
            shelvedConversations = (shelvedConversations + [conversation]).inDisplayOrder()
        } else {
            conversations = (conversations + [conversation]).inDisplayOrder()
        }
    }

    /// Une conversation que l'on peut ouvrir : de la liste, ou des archivées chargées.
    func openableConversation(id: String) -> MessageConversation? {
        conversations.first { $0.id == id } ?? shelvedConversations.first { $0.id == id }
    }

    /// Page suivante de la liste, au défilement en bas (B01).
    func loadMore() async {
        guard hasMoreConversations, !isLoadingMore, loadedPages < Self.maxPages, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await service.conversationPage(cursor: cursor, take: Self.pageSize) else { return }
        let known = Set(conversations.map(\.id))
        conversations = (conversations + page.conversations.filter { !known.contains($0.id) }).inDisplayOrder()
        loadedPages += 1
        hasMoreConversations = page.hasMore && page.nextCursor != nil && loadedPages < Self.maxPages
        nextCursor = page.nextCursor
    }

    /// Déchiffre les aperçus des derniers messages des conversations E2EE une
    /// fois la clé déverrouillée. Best-effort : un échec laisse le cadenas.
    func decryptPreviews(e2ee: E2EEServicing?, v2: E2EEV2MessagingRuntime? = nil) async {
        // v2 : le dernier message vérifié et gardé ici, sans requête ni clé v1.
        if let v2 {
            for conversation in conversations where EncryptedConversationSurfaces.isV2(conversation) {
                if let text = v2.latestText(conversationId: conversation.id) { decryptedPreviews[conversation.id] = text }
            }
        }
        guard let e2ee, await e2ee.isUnlocked() else { return }
        for conversation in conversations where conversation.e2eeEnabled == true {
            guard let last = conversation.lastMessage, last.isEncrypted,
                  decryptedPreviews[conversation.id] == nil else { continue }
            if let plain = try? await e2ee.decryptText(conversationId: conversation.id, message: last) {
                decryptedPreviews[conversation.id] = plain
            }
        }
    }

    func refreshAfterCreate() async {
        await load()
    }

    /// Marque la conversation comme lue (balayage ou appui long). L'état change
    /// tout de suite et revient si le serveur refuse.
    func markRead(_ conversation: MessageConversation) async {
        guard let lastMessageId = conversation.lastMessage?.id else { return }
        let previous = conversation.lastReadAt
        update(conversation.id) { $0.with(lastReadAt: conversation.lastMessageAt ?? Date()) }
        do {
            try await service.markRead(conversationId: conversation.id, lastMessageId: lastMessageId)
        } catch {
            update(conversation.id) { $0.with(lastReadAt: previous) }
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }

    /// Remet en non lu (plan 3, vague 2) : le serveur ramène la lecture au tout
    /// début, la pastille et le badge reviennent.
    func markUnread(_ conversation: MessageConversation) async {
        let previous = conversation.lastReadAt
        update(conversation.id) { $0.with(lastReadAt: Date(timeIntervalSince1970: 0)) }
        do {
            try await service.markUnread(conversationId: conversation.id)
        } catch {
            update(conversation.id) { $0.with(lastReadAt: previous) }
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }

    /// Épingle ou désépingle (plan 3, vague 2) : les épinglées passent en tête.
    func setPinned(_ pinned: Bool, _ conversation: MessageConversation) async {
        let previous = conversation.pinnedAt
        update(conversation.id) { $0.with(pinnedAt: pinned ? Date() : nil) }
        do {
            _ = try await service.setConversationPinned(pinned, conversationId: conversation.id)
        } catch {
            update(conversation.id) { $0.with(pinnedAt: previous) }
            if case APIError.http(_, "CONVERSATION_PIN_LIMIT", _, _, _) = error {
                actionError = String(localized: "Tu as déjà épinglé le nombre maximal de conversations. Désépingles-en une pour en épingler une autre.")
            } else if !error.isCancellation {
                actionError = error.userFacingMessage
            }
        }
    }

    /// Sourdine pour soi (#354) : affichée tout de suite, puis l'état retenu par
    /// le serveur ; rétablie si le serveur refuse.
    func setMuted(_ muted: Bool, mentionsMuted: Bool?, _ conversation: MessageConversation) async {
        let previous = (conversation.muted, conversation.mentionsMuted)
        update(conversation.id) { $0.with(muted: muted, mentionsMuted: mentionsMuted ?? $0.mentionsMuted) }
        do {
            let saved = try await service.setConversationMuted(muted, mentionsMuted: mentionsMuted, conversationId: conversation.id)
            update(conversation.id) { $0.with(muted: saved.muted, mentionsMuted: saved.mentionsMuted) }
        } catch {
            update(conversation.id) { $0.with(muted: previous.0, mentionsMuted: previous.1) }
            if !error.isCancellation { actionError = String(localized: "La sourdine n’a pas pu être enregistrée.") }
        }
    }

    /// Change une conversation, puis remet la liste dans son ordre d'affichage.
    private func update(_ id: String, _ transform: (MessageConversation) -> MessageConversation) {
        if conversations.firstIndex(where: { $0.id == id }) == nil,
           let shelvedIndex = shelvedConversations.firstIndex(where: { $0.id == id }) {
            var updated = shelvedConversations
            updated[shelvedIndex] = transform(updated[shelvedIndex])
            shelvedConversations = updated.inDisplayOrder()
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var updated = conversations
        updated[index] = transform(updated[index])
        withAnimation(SQMotion.resolve(SQMotion.standard, UIAccessibility.isReduceMotionEnabled)) {
            conversations = updated.inDisplayOrder()
        }
    }

    /// Quitte la conversation (swipe) et la retire de la liste localement.
    func leave(_ conversation: MessageConversation, v2: E2EEV2MessagingRuntime? = nil, naming successor: String? = nil) async {
        do {
            // Conversation v2 : le départ passe par la chaîne signée (D.4).
            if let v2, v2.writesEnabled, EncryptedConversationSurfaces.isV2(conversation) {
                try await v2.leave(conversation, naming: successor)
            } else {
                try await service.leaveConversation(id: conversation.id)
            }
            conversations.removeAll { $0.id == conversation.id }
            shelvedConversations.removeAll { $0.id == conversation.id }
        } catch {
            if !error.isCancellation { actionError = error.userFacingMessage }
        }
    }
}

struct MessagesView: View {
    @StateObject private var model: MessagesViewModel
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var inAppNotifications: SQInAppNotificationCenter
    @EnvironmentObject private var networkPath: NetworkPathMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Dernière conversation ouverte à côté de la liste (iPad), rétablie au lancement suivant.
    @SceneStorage("sq.messages.selectedConversationId") private var persistedSelection = ""
    private let service: MessagesServicing
    private let e2ee: E2EEServicing?
    @State private var showNewConversation = false
    @State private var showE2EEUnlock = false
    @State private var routedConversationId: String?
    /// Quitter se confirme : le balayage suffisait à perdre la conversation (SOC-22).
    @State private var pendingLeave: MessageConversation?
    /// Dernier admin d'un groupe chiffré : successeur à nommer avant le départ (D.4).
    @State private var successorRequest: SuccessorRequest?

    struct SuccessorRequest: Identifiable {
        let conversation: MessageConversation
        let candidates: [String]
        var id: String { conversation.id }
    }
    /// Brouillons par conversation, lus sur l'appareil (plan 3, vague 1).
    @State private var drafts: [String: String] = [:]
    /// Porte E2EE v2 ouverte côté serveur, mais cet appareil n'y est pas encore entré.
    @State private var needsV2Activation = false
    @State private var showV2Activation = false
    /// Recherche et filtre de la liste, appliqués sur l'appareil.
    @State private var query = ""
    @State private var filter: InboxFilter = .all
    /// Recherche dans le texte des messages (hors conversations chiffrées, lisibles seulement ici).
    @State private var messageHits: [MessageSearchResult] = []
    @State private var messageSearchTask: Task<Void, Never>?
    @State private var routedFocusMessageId: String?
    @State private var searchFocusRequest = 0
    /// Dossier choisi dans les puces ; `nil` quand une puce de filtre l'est.
    @State private var folderFilterId: String?
    /// Écran « Archivées » : même liste, alimentée par les conversations archivées.
    @State private var showingShelved = false
    @State private var folderSheet: FolderSheetRequest?
    @State private var showFocusSheet = false

    enum InboxFilter: String, CaseIterable {
        case all, unread, groups
        /// Conversations du mode focus en cours ; sans puce quand aucun focus ne court.
        case focus

        var title: LocalizedStringKey {
            switch self {
            case .all: "Toutes"
            case .unread: "Non lues"
            case .groups: "Groupes"
            case .focus: "Focus"
            }
        }
    }

    /// Ouverture de la feuille des dossiers, avec la conversation à y ranger dès
    /// la création d'un dossier (menu « Ranger dans un dossier › Nouveau dossier »).
    struct FolderSheetRequest: Identifiable {
        let id = UUID()
        var fileConversationId: String?
    }

    /// Insets des rangées : gap vertical de 14 pt entre cartes (2 × 7),
    /// marge d'écran 20 pt.
    private var cardRowInsets: EdgeInsets {
        EdgeInsets(top: 7, leading: SQSpace.xl, bottom: 7, trailing: SQSpace.xl)
    }

    init(service: MessagesServicing, e2ee: E2EEServicing? = nil) {
        self.service = service
        self.e2ee = e2ee
        _model = StateObject(wrappedValue: MessagesViewModel(service: service))
    }

    /// Relecture périodique de la liste : app au premier plan, aucune conversation ouverte.
    private var listIsPolling: Bool { scenePhase == .active && (usesSplitLayout || routedConversationId == nil) }

    private func refreshV2Activation() {
        guard services.e2eeV2Messaging.writesEnabled, let current = LocalAccountScope.sessionSnapshot() else {
            needsV2Activation = false
            return
        }
        needsV2Activation = services.e2eeV2Messaging.lacksV2Readiness(current)
            && !E2EEV2ActivationPrompt.isSnoozed(current)
    }

    /// « Plus tard » : la carte revient au bout d'une semaine ; l'activation
    /// reste à portée dans Réglages › Appareils.
    private func snoozeV2Activation() {
        E2EEV2ActivationPrompt.snooze()
        needsV2Activation = false
    }

    /// Activation guidée : l'enregistrement de l'appareil et l'approbation
    /// demandent un geste (code e-mail du premier appareil, ou un appareil déjà
    /// approuvé), jamais faits en silence.
    private var v2ActivationCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label("Messages et appels chiffrés", systemImage: "lock.shield")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            Text("Active le chiffrement de bout en bout sur cet appareil pour écrire et appeler en privé.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Activer sur cet appareil"), style: .primary, allowsMultiline: true) {
                showV2Activation = true
            }
            .accessibilityIdentifier("e2ee-v2-activation-open")
            GradientButton(String(localized: "Plus tard"), style: .ghost, allowsMultiline: true) {
                snoozeV2Activation()
            }
            .accessibilityIdentifier("e2ee-v2-activation-later")
        }
        .padding(.vertical, SQSpace.md)
        .accessibilityElement(children: .contain)
    }

    /// iPad en largeur régulière : la liste à gauche, la conversation à droite.
    /// L'iPhone, même large en paysage, garde la pile.
    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        if usesSplitLayout {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                listColumn
                    .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 460)
            } detail: {
                splitDetail
            }
            .navigationSplitViewStyle(.balanced)
            // Poussée dans la pile du Feed : la barre de cette pile reste masquée,
            // le retour rond de la liste suffit.
            .toolbar(.hidden, for: .navigationBar)
            .sqKeepsSwipeBack()
            .task { restorePersistedSelection() }
            .onChangeCompat(of: routedConversationId) { _, id in persistSelection(id) }
        } else {
            listColumn
                .navigationDestinationItemCompat($routedConversationId) { id in
                    if let conversation = model.openableConversation(id: id) {
                        ConversationDetailView(
                            conversation: conversation, service: service, e2ee: e2ee,
                            focusMessageId: routedFocusMessageId
                        )
                    }
                }
        }
    }

    /// Colonne de droite : la conversation choisie, ou l'invitation à en choisir une.
    @ViewBuilder
    private var splitDetail: some View {
        if let id = routedConversationId, let conversation = model.openableConversation(id: id) {
            ConversationDetailView(
                conversation: conversation, service: service, e2ee: e2ee,
                focusMessageId: routedFocusMessageId
            )
            .id(id)
            .environment(\.sqMessagesCloseDetail, { routedConversationId = nil })
        } else {
            EmptyStateView(
                title: "Choisis une conversation",
                message: "Elle s’affiche ici, à côté de ta liste.",
                systemImage: "bubble.left.and.bubble.right"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .signalQuestBackground()
            .accessibilityIdentifier("messages.split.placeholder")
        }
    }

    /// La conversation ouverte est gardée entre deux lancements (iPad seulement).
    private func persistSelection(_ id: String?) {
        persistedSelection = id ?? ""
    }

    private func restorePersistedSelection() {
        guard routedConversationId == nil, !persistedSelection.isEmpty else { return }
        let id = persistedSelection
        Task {
            if model.conversations.isEmpty { await model.load() }
            guard routedConversationId == nil else { return }
            await model.ensureLoaded(id: id)
            if model.openableConversation(id: id) != nil, routedConversationId == nil { routedConversationId = id }
        }
    }

    private var listColumn: some View {
        List {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                if !networkPath.isOnline {
                    MessagesOfflineBanner()
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                }
                if needsV2Activation {
                    v2ActivationCard
                }
                if E2EEV2RuntimeReadGate.enabled {
                    E2EEV2NotificationPreviewNotice()
                }
                if let focus = model.focus, !showingShelved {
                    focusBanner(focus)
                }
                if !model.conversations.isEmpty || showingShelved {
                    // Aux tailles d'accessibilité, l'intitulé long ne tient pas sur une ligne.
                    SQSearchField(
                        text: $query,
                        placeholder: dynamicTypeSize.isAccessibilitySize ? "Rechercher" : "Rechercher une conversation",
                        focusRequest: searchFocusRequest
                    )
                        .accessibilityIdentifier("messages.search")
                    if !showingShelved { filterChips }
                }
                if !showingShelved, let summary = model.shelvedSummary, summary.count > 0 {
                    shelvedRow(summary)
                }
            }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: SQSpace.xl, bottom: SQSpace.sm, trailing: SQSpace.xl))

            if model.isLoading && model.conversations.isEmpty {
                ConversationListSkeleton()
                    .sqShimmer()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(cardRowInsets)
            }
            let visible = visibleConversations
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, conversation in
                Button {
                    routedConversationId = conversation.id
                } label: {
                    conversationRow(conversation, isFirst: index == 0)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(usesSplitLayout && routedConversationId == conversation.id ? .isSelected : [])
                // Une seule carte pour toute la liste : chaque rangée en porte un
                // morceau, arrondi en haut pour la première, en bas pour la dernière.
                // À côté de la conversation (iPad), la rangée ouverte est teintée.
                .listRowBackground(
                    MessagesCardSegment(top: index == 0, bottom: index == visible.count - 1)
                        .fill(usesSplitLayout && routedConversationId == conversation.id ? SQColor.accentSoft : SQColor.surface)
                        .overlay {
                            MessagesCardSegment(top: index == 0, bottom: index == visible.count - 1)
                                .strokeBorder(SQOledPalette.cardStroke, lineWidth: 1)
                        }
                        .padding(.horizontal, SQSpace.xl)
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: SQSpace.xl, bottom: 0, trailing: SQSpace.xl))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if isUnread(conversation) {
                        Button { setRead(true, conversation) } label: {
                            Label("Lu", systemImage: "checkmark.message")
                        }
                        .tint(SQColor.brandRed)
                    } else if conversation.canMarkUnread(currentUserId: currentUserId) {
                        Button { setRead(false, conversation) } label: {
                            Label("Non lu", systemImage: "message.badge")
                        }
                        .tint(SQColor.brandRed)
                    }
                    pinButton(conversation)
                        .tint(SQColor.info)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingLeave = conversation
                    } label: {
                        Label("Quitter", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    shelveButton(conversation)
                        .tint(SQColor.info)
                }
                // Mêmes actions à l'appui long, et au clic secondaire sur iPad.
                .contextMenu {
                    pinButton(conversation)
                    muteButtons(conversation)
                    shelveButton(conversation)
                    folderMenu(conversation)
                    if isUnread(conversation) {
                        Button { setRead(true, conversation) } label: {
                            Label("Marquer comme lu", systemImage: "checkmark.message")
                        }
                    } else if conversation.canMarkUnread(currentUserId: currentUserId) {
                        Button { setRead(false, conversation) } label: {
                            Label("Marquer comme non lu", systemImage: "message.badge")
                        }
                    }
                    Button(role: .destructive) {
                        pendingLeave = conversation
                    } label: {
                        Label("Quitter", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            if !messageHits.isEmpty {
                messageResultsSection
            }
            if model.hasMoreConversations && !showingShelved {
                // Page suivante au défilement ; la tâche repart à chaque page reçue,
                // de sorte qu'un filtre encore vide continue de chercher (B01).
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, SQSpace.md)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Chargement d’autres conversations")
                .accessibilityIdentifier("messages.loadingMore")
                .task(id: model.conversations.count) { await model.loadMore() }
            }
            if showingShelved && model.shelvedConversations.isEmpty && !model.isLoadingShelved {
                EmptyStateView(
                    title: "Aucune conversation archivée",
                    message: "Une conversation archivée revient dans ta liste au prochain message, sauf si elle est en sourdine.",
                    systemImage: "archivebox"
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("messages.shelved.empty")
            } else if !listSource.isEmpty && visible.isEmpty && (showingShelved || !model.hasMoreConversations) {
                Text("Aucune conversation ne correspond.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.xl)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("messages.noMatch")
            }
            if !showingShelved && !model.isLoading && model.conversations.isEmpty && model.errorMessage == nil {
                EmptyStateView(
                    title: "Aucune conversation",
                    message: "Démarre une discussion avec un membre de la communauté.",
                    systemImage: "bubble.left.and.bubble.right"
                )
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let error = model.errorMessage {
                // Pattern maison (titre + message + « Réessayer ») au lieu d'une ligne
                // rouge brute peu visible et sans action de relance (INT-09).
                ErrorStateView(title: "Messagerie indisponible", message: error) {
                    Task { await model.load() }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(cardRowInsets)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // §13 : un aperçu déchiffré ou un brouillon chiffré n'apparaît jamais
        // dans le sélecteur d'apps.
        .background {
            if EncryptedConversationSurfaces.listHidesSnapshot(
                model.conversations, decryptedPreviews: model.decryptedPreviews, drafts: drafts
            ) {
                AppSensitiveContentMarker()
            }
        }
        .sqReadableWidth()
        // Comme la conversation : balayage retour rétabli malgré la barre
        // masquée (SOC-30).
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .signalQuestBackground()
        .task {
            await reloadDrafts()
            if model.conversations.isEmpty { await model.load() }
            await model.loadOrganization()
            await maybePresentE2EEUnlock()
            openNewConversationIfRequested()
            await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
            await openRoutedConversationIfNeeded()
        }
        // Message v2 reçu app ouverte : la liste (non-lus, ordre) se met à jour.
        .onReceive(NotificationCenter.default.publisher(for: PushNotificationService.e2eeV2EnvelopeReceived)) { _ in
            Task {
                await model.load()
                await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
            }
        }
        // Message v1 reçu au premier plan : liste et badge se mettent à jour.
        .onReceive(NotificationCenter.default.publisher(for: PushNotificationService.inboxMessageReceived)) { _ in
            Task {
                await model.load()
                await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
                await services.applyLoadedInbox(model.conversations, isComplete: !model.hasMoreConversations)
            }
        }
        // Pas de flux au niveau de la boîte : la liste se relit toutes les ~15 s
        // tant qu'elle est à l'écran (la tâche s'annule quand elle disparaît), app
        // active et sans conversation ouverte par-dessus.
        .task(id: listIsPolling) {
            guard listIsPolling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { break }
                await model.load()
                await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
                await services.applyLoadedInbox(model.conversations, isComplete: !model.hasMoreConversations)
            }
        }
        // Au retour d'une conversation : la liste restait figée jusqu'au
        // tirer-pour-rafraîchir (SOC-23). Le premier affichage passe par `.task`.
        .onAppear {
            guard !model.conversations.isEmpty else { return }
            Task {
                await model.load()
                await model.loadOrganization()
                await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
                await services.applyLoadedInbox(model.conversations, isComplete: !model.hasMoreConversations)
            }
        }
        .refreshable {
            await model.load()
            await model.loadOrganization()
            if showingShelved { await model.loadShelved() }
            await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
        }
        .onReceive(NotificationCenter.default.publisher(for: MessageDraftStore.didChange)) { _ in
            Task { await reloadDrafts() }
        }
        .confirmationDialog(
            "Quitter cette conversation ?",
            isPresented: Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } }),
            titleVisibility: .visible,
            presenting: pendingLeave
        ) { conversation in
            Button("Quitter", role: .destructive) {
                pendingLeave = nil
                if conversation.isGroup,
                   case .mustName(let candidates) = services.e2eeV2Messaging.successorNeed(conversationId: conversation.id) {
                    let request = SuccessorRequest(conversation: conversation, candidates: candidates)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        successorRequest = request
                    }
                } else {
                    Task { await model.leave(conversation, v2: services.e2eeV2Messaging); await services.refreshInboxBadge(force: true) }
                }
            }
            Button("Annuler", role: .cancel) { pendingLeave = nil }
        } message: { _ in
            Text("Elle disparaîtra de ta liste et tu ne recevras plus ses messages.")
        }
        // Après la boîte de dialogue, jamais depuis elle : iOS 16 refuse une
        // feuille présentée pendant qu'elle se ferme.
        .sheet(item: $successorRequest) { request in
            SuccessorPickerSheet(
                candidates: request.candidates.compactMap { id in request.conversation.participants.first { $0.userId == id } }
            ) { successor in
                successorRequest = nil
                Task {
                    await model.leave(request.conversation, v2: services.e2eeV2Messaging, naming: successor)
                    await services.refreshInboxBadge(force: true)
                }
            }
        }
        .onChangeCompat(of: routedConversationId) { _, id in
            if id == nil { routedFocusMessageId = nil }
        }
        .onChangeCompat(of: query) { _, _ in scheduleMessageSearch() }
        // ⌘F : le curseur va dans la recherche de la liste.
        .background {
            Button("") { searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChangeCompat(of: router.openConversationId) { _, _ in
            Task { await openRoutedConversationIfNeeded() }
        }
        .onChangeCompat(of: model.actionError) { _, message in
            guard let message else { return }
            inAppNotifications.showError(message)
            model.actionError = nil
        }
        .onChangeCompat(of: router.openNewConversation) { _, requested in
            if requested { openNewConversationIfRequested() }
        }
        .task(id: PushOwnerScope.current) { refreshV2Activation() }
        // Les appels se décrochent souvent écran verrouillé, où iOS ne peut pas
        // demander l'accès au micro : la demande est faite ici, une fois.
        .task { await CallManager.requestMicrophoneAccessIfUndetermined() }
        .onAppear { refreshV2Activation() }
        .onReceive(NotificationCenter.default.publisher(for: E2EEV2ServerGate.didChange).receive(on: RunLoop.main)) { _ in
            refreshV2Activation()
        }
        // L'écran guidé, comme à l'ouverture de l'app, et non la liste technique
        // des appareils (qui reste dans Réglages › Appareils).
        .sheet(isPresented: $showV2Activation, onDismiss: refreshV2Activation) {
            E2EEV2ActivationScreen(
                api: services.api,
                onFinish: { showV2Activation = false },
                onLater: {
                    snoozeV2Activation()
                    showV2Activation = false
                }
            )
        }
        .sheet(isPresented: $showNewConversation) {
            NewConversationSheet(
                service: service,
                onCreated: { await model.refreshAfterCreate() },
                existingDirect: { peerId in
                    model.conversations.first { conversation in
                        !conversation.isGroup && (conversation.directPeerUserId == peerId
                            || conversation.participants.contains { $0.userId == peerId })
                    }?.id
                },
                onOpenExisting: { id in
                    Task {
                        if !model.conversations.contains(where: { $0.id == id }) { await model.load() }
                        await model.ensureLoaded(id: id)
                        routedConversationId = id
                    }
                },
                unlockUserId: currentUserId,
                unlockService: e2ee
            )
        }
        .sheet(item: $folderSheet) { request in
            ConversationFoldersSheet(model: model, fileConversationId: request.fileConversationId)
        }
        .sheet(isPresented: $showFocusSheet) {
            FocusSheet(model: model, currentUserId: currentUserId) {
                filter = .focus
                folderFilterId = nil
            }
        }
        .onChangeCompat(of: model.folders) { _, folders in
            if let id = folderFilterId, !folders.contains(where: { $0.id == id }) { folderFilterId = nil }
        }
        .onChangeCompat(of: model.focus == nil) { _, ended in
            if ended, filter == .focus { filter = .all }
        }
        .sheet(isPresented: $showE2EEUnlock, onDismiss: openNewConversationIfRequested) {
            if let e2ee = e2ee, case .authenticated(let user) = session.state {
                E2EEUnlockSheet(userId: user.id, service: e2ee) {
                    Task {
                        await model.load()
                        await model.decryptPreviews(e2ee: e2ee, v2: services.e2eeV2Messaging)
                    }
                }
            }
        }
    }

    /// Once the conversation list is loaded, if at least one is E2EE-enabled and
    /// the master key isn't unlocked yet, present the unlock sheet automatically.
    /// After a successful unlock all conversations share the same in-Keychain
    /// private JWK — the per-conversation prompt becomes unnecessary.
    private func maybePresentE2EEUnlock() async {
        guard let e2ee, !Self.unlockOffered else { return }
        // Le mot de passe v1 n'ouvre que les conversations v1 : un compte qui
        // n'a que des conversations v2 n'a rien à créer ni à déverrouiller.
        guard model.conversations.contains(where: {
            $0.e2eeEnabled == true && !EncryptedConversationSurfaces.isV2($0)
        }) else { return }
        let already = await e2ee.isUnlocked()
        if !already && !showE2EEUnlock {
            // Une fois par lancement : la feuille revenait à chaque retour sur
            // la liste (SOC-23). Le bandeau d'une conversation chiffrée reste là.
            Self.unlockOffered = true
            showE2EEUnlock = true
        }
    }

    @MainActor private static var unlockOffered = false

    /// Opens the conversation requested by a notification tap (via AppRouter),
    /// loading the list first if needed. Falls back to just landing on the
    /// Messages tab when the conversation isn't in the current list.
    private func openRoutedConversationIfNeeded() async {
        guard let id = router.openConversationId else { return }
        router.openConversationId = nil
        let focusId = router.openMessageId
        router.openMessageId = nil
        // Recharger si la liste est vide OU si le fil ciblé n'y est pas encore : le
        // cas fréquent d'une notification pour un NOUVEAU fil (premier message d'un
        // nouveau contact) échouait sinon en silence (UXP-10).
        if model.conversations.isEmpty || !model.conversations.contains(where: { $0.id == id }) {
            await model.load()
        }
        await model.ensureLoaded(id: id)
        if model.conversations.contains(where: { $0.id == id }) {
            routedFocusMessageId = focusId
            routedConversationId = id
        } else if router.pendingCall?.conversationId == id {
            // Conversation introuvable : le rappel demandé ne part jamais plus tard.
            router.pendingCall = nil
        }
    }

    /// ⌘N sur iPad : la messagerie s'ouvre sur une nouvelle conversation, une
    /// fois l'éventuel déverrouillage du chiffrement passé.
    private func openNewConversationIfRequested() {
        guard router.openNewConversation, !showE2EEUnlock else { return }
        router.openNewConversation = false
        showNewConversation = true
    }

    /// En-tête Halo : retour rond, « Nouvelle conversation » en rond encre, puis
    /// le grand titre et le nombre de conversations non lues.
    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.sm) {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "messages.back") {
                    if showingShelved { showingShelved = false } else { dismiss() }
                }
                Spacer(minLength: SQSpace.sm)
                if !showingShelved {
                    listMenu
                    Button {
                        Haptics.light()
                        showNewConversation = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SQColor.onInk)
                            .frame(width: 44, height: 44)
                            .background(SQColor.label, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .accessibilityLabel("Nouvelle conversation")
                    .accessibilityIdentifier("messages.new")
                }
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(showingShelved ? "Archivées" : "Messages")
                    .font(SQFont.display(30, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                let unread = model.conversations.filter(isUnread).count
                if showingShelved {
                    Text("Une conversation archivée revient dans ta liste au prochain message, sauf si elle est en sourdine.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("messages.shelved.note")
                } else if unread > 0 {
                    Text("\(unread) conversations non lues")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityIdentifier("messages.unreadCount")
                }
            }
        }
    }

    /// Menu de la liste : dossiers et mode focus.
    private var listMenu: some View {
        Menu {
            Button {
                folderSheet = FolderSheetRequest()
            } label: {
                Label("Gérer les dossiers", systemImage: "folder")
            }
            if model.focus != nil {
                Button { showFocusSheet = true } label: {
                    Label("Modifier le mode focus", systemImage: "scope")
                }
                Button(role: .destructive) {
                    Task { await endFocus() }
                } label: {
                    Label("Terminer le mode focus", systemImage: "xmark.circle")
                }
            } else {
                Button { showFocusSheet = true } label: {
                    Label("Mode focus", systemImage: "scope")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.chip, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Options de la liste")
        .accessibilityIdentifier("messages.menu")
    }

    /// Une puce de la rangée de filtres.
    private enum ListChip: Hashable {
        case filter(InboxFilter)
        case folder(String)
    }

    private var listChips: [ListChip] {
        var chips: [ListChip] = []
        if model.focus != nil { chips.append(.filter(.focus)) }
        chips += [.filter(.all), .filter(.unread), .filter(.groups)]
        chips += model.folders.map { ListChip.folder($0.id) }
        return chips
    }

    private func isSelected(_ chip: ListChip) -> Bool {
        switch chip {
        case .filter(let option): return folderFilterId == nil && filter == option
        case .folder(let id): return folderFilterId == id
        }
    }

    private func select(_ chip: ListChip) {
        Haptics.selection()
        switch chip {
        case .filter(let option):
            folderFilterId = nil
            filter = option
        case .folder(let id):
            filter = .all
            folderFilterId = id
        }
    }

    /// Filtres de la liste en pastilles : la pastille active est pleine encre.
    /// Les dossiers suivent les filtres, dans le même style.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(listChips, id: \.self) { chip in
                    let selected = isSelected(chip)
                    Button {
                        select(chip)
                    } label: {
                        HStack(spacing: SQSpace.xs) {
                            chipTitle(chip)
                            let count = chipCount(chip)
                            if count > 0 { Text(verbatim: "\(count)").monospacedDigit() }
                        }
                        .font(SQType.subhead(.semibold))
                        .sqSingleLine()
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, SQSpace.md2)
                        .frame(minHeight: 34)
                        .foregroundStyle(selected ? SQColor.onInk : SQColor.chipInk)
                        .background(selected ? SQColor.label : SQColor.chip, in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SQPressButtonStyle(scale: 0.97))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier(chipIdentifier(chip))
                }
            }
            .padding(.horizontal, SQSpace.xl)
        }
        .padding(.horizontal, -SQSpace.xl)
    }

    @ViewBuilder
    private func chipTitle(_ chip: ListChip) -> some View {
        switch chip {
        case .filter(let option): Text(option.title)
        case .folder(let id): Text(verbatim: model.folders.first { $0.id == id }?.name ?? "")
        }
    }

    private func chipCount(_ chip: ListChip) -> Int {
        guard case .filter(.unread) = chip else { return 0 }
        return model.conversations.filter(isUnread).count
    }

    private func chipIdentifier(_ chip: ListChip) -> String {
        switch chip {
        case .filter(let option): return "messages.filter.\(option.rawValue)"
        case .folder(let id): return "messages.folder.\(id)"
        }
    }

    /// Mode focus en cours : rappel discret au-dessus des filtres, avec de quoi le terminer.
    private func focusBanner(_ focus: MessageFocusSession) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "scope")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SQColor.accentInk)
                .accessibilityHidden(true)
            Group {
                if let endsAt = focus.endsAt {
                    Text("Mode focus · jusqu’à \(endsAt.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Mode focus")
                }
            }
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.accentInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await endFocus() }
            } label: {
                Text("Terminer")
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("messages.focus.end")
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, SQSpace.sm)
        .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messages.focus.banner")
    }

    /// Ligne « Archivées » en tête de liste : le nombre, et celui des non lues.
    private func shelvedRow(_ summary: ShelvedSummary) -> some View {
        Button {
            Haptics.selection()
            showingShelved = true
            filter = .all
            folderFilterId = nil
            query = ""
            Task { await model.loadShelved() }
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: "archivebox")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.chipInk)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text("Archivées")
                    .font(SQType.body(.semibold))
                    .foregroundStyle(SQColor.label)
                Spacer(minLength: SQSpace.sm)
                if summary.unreadCount > 0 {
                    Text(verbatim: "\(summary.unreadCount)")
                        .font(SQType.micro(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(SQColor.brandRed, in: Capsule())
                        .accessibilityHidden(true)
                }
                Text(verbatim: "\(summary.count)")
                    .font(SQType.subhead)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 48)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle(scale: 0.99))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shelvedRowLabel(summary))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("messages.shelved.row")
    }

    private func shelvedRowLabel(_ summary: ShelvedSummary) -> String {
        if summary.unreadCount > 0 {
            return String(localized: "Archivées : \(summary.count), non lues : \(summary.unreadCount)")
        }
        return String(localized: "Archivées : \(summary.count)")
    }

    private func endFocus() async {
        await model.endFocus()
        if filter == .focus { filter = .all }
    }

    /// Recherche dans le texte des messages, après une courte pause de frappe. Le mot cherché part
    /// au serveur pour les conversations ordinaires ; les conversations chiffrées n'y sont pas
    /// incluses (leur texte ne se lit que sur l'appareil, et la liste n'en garde que l'aperçu).
    private func scheduleMessageSearch() {
        messageSearchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 3, !AppEnvironment.usesDemoData else {
            messageHits = []
            return
        }
        messageSearchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let found = (try? await service.searchMessages(query: needle, filters: .empty, take: 20)) ?? []
            guard !Task.isCancelled else { return }
            messageHits = found.filter {
                !$0.message.isEncrypted && $0.message.deletedAt == nil && $0.conversation?.id.isEmpty == false
            }
        }
    }

    private var messageResultsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Dans les messages")
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(messageHits) { hit in
                    if hit.id != messageHits.first?.id { Divider().padding(.leading, SQSpace.md) }
                    messageHitRow(hit)
                }
            }
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            Text("Les conversations chiffrées ne sont pas incluses : leurs messages ne se lisent que sur ton téléphone.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(cardRowInsets)
        .accessibilityIdentifier("messages.searchResults")
    }

    private func messageHitRow(_ hit: MessageSearchResult) -> some View {
        let message = hit.message
        let title = hit.conversation?.title.flatMap { $0.isEmpty ? nil : $0 }
            ?? message.sender?.displayName ?? String(localized: "Conversation")
        return Button {
            guard let conversationId = hit.conversation?.id else { return }
            Task {
                await model.ensureLoaded(id: conversationId)
                guard model.conversations.contains(where: { $0.id == conversationId }) else { return }
                routedFocusMessageId = message.id
                routedConversationId = conversationId
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(SQType.caption.weight(.bold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    Spacer(minLength: SQSpace.sm)
                    if let date = message.createdAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Text(message.content ?? "")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    /// La liste affichée : les conversations, ou les archivées sur leur écran.
    private var listSource: [MessageConversation] {
        showingShelved ? model.shelvedConversations : model.conversations
    }

    /// Conversations après le filtre et la recherche (titre, puis aperçu).
    private var visibleConversations: [MessageConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusIds = Set(model.focus?.conversationIds ?? [])
        let folderIds = folderFilterId.flatMap { id in model.folders.first { $0.id == id }?.conversationIds }.map(Set.init)
        return listSource.filter { conversation in
            if let folderIds { guard folderIds.contains(conversation.id) else { return false } }
            switch filter {
            case .all: break
            case .unread: guard isUnread(conversation) else { return false }
            case .groups: guard conversation.isGroup else { return false }
            case .focus: guard focusIds.contains(conversation.id) else { return false }
            }
            guard !needle.isEmpty else { return true }
            return conversation.displayTitle(excluding: currentUserId).localizedStandardContains(needle)
                || lastMessagePreview(conversation).localizedStandardContains(needle)
        }
    }

    /// Aperçu du dernier message : déchiffré quand la clé E2EE est disponible,
    /// cadenas sinon ; mention explicite pour les pièces jointes.
    /// Les replis passent par `String(localized:)` : rendus en `Text(String)`,
    /// ils restaient en français dans l'app anglaise.
    private func lastMessagePreview(_ conversation: MessageConversation) -> String {
        // Message v2 : le serveur n'en sert qu'un aperçu vide (lot A7).
        if conversation.e2eeV2?.lastMessage != nil { return String(localized: "Message chiffré") }
        guard let last = conversation.lastMessage else {
            return String(localized: "Aucun message")
        }
        if last.deletedAt != nil { return String(localized: "Message supprimé") }
        let attachmentHint = last.attachments.isEmpty ? "" : "📎 "
        if last.isEncrypted {
            if let plain = model.decryptedPreviews[conversation.id], !plain.isEmpty {
                return attachmentHint + plain
            }
            return attachmentHint.isEmpty ? String(localized: "Message chiffré") : String(localized: "📎 Pièce jointe")
        }
        if let content = last.content, !content.isEmpty {
            return attachmentHint + content
        }
        return last.attachments.isEmpty ? String(localized: "Aucun message") : String(localized: "📎 Pièce jointe")
    }

    private func reloadDrafts() async {
        drafts = await MessageDraftStore.shared.all(ownerScopeId: LocalAccountScope.currentOwnerScopeId)
    }

    /// « Brouillon · … » à la place du dernier message, comme dans les
    /// messageries courantes : on retrouve ce qu'on avait commencé.
    private func draftPreview(_ draft: String) -> some View {
        (Text("Brouillon").foregroundColor(SQColor.accentInk)
            + Text(verbatim: " · " + draft.replacingOccurrences(of: "\n", with: " ")))
            .font(SQType.subhead(.regular))
            .foregroundStyle(SQColor.labelSecondary)
            .sqSingleLine()
            .accessibilityIdentifier("messages.row.draft")
    }

    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }

    private func rowDate(_ date: Date, unread: Bool) -> some View {
        // `accentInk` : la brique n'est garantie que pour le grand texte.
        Text(verbatim: ConversationListDate.label(for: date))
            .font(SQType.micro(unread ? .bold : .medium))
            .monospacedDigit()
            .foregroundStyle(unread ? SQColor.accentInk : SQColor.labelSecondary)
            .fixedSize()
            .accessibilityIdentifier("messages.row.date")
    }

    /// Rangée de la carte des conversations : avatar 44 et présence, nom avec
    /// cadenas, sourdine et épingle, heure (carmin si non lu), aperçu et pastille.
    private func conversationRow(_ conversation: MessageConversation, isFirst: Bool) -> some View {
        let unread = isUnread(conversation)
        let title = conversation.displayTitle(excluding: currentUserId)
        let unreadCount = conversation.e2eeV2?.unreadCount ?? 0
        return HStack(spacing: SQSpace.md) {
            ConversationAvatar(conversation: conversation, currentUserId: currentUserId, size: 44)
                .accessibilityHidden(true)
                .overlay(alignment: .bottomTrailing) {
                    if isOnline(conversation) {
                        Circle()
                            .fill(SQColor.brandGreen)
                            .frame(width: 13, height: 13)
                            .overlay { Circle().stroke(SQColor.surface, lineWidth: 2.5) }
                            .offset(x: 2, y: 2)
                            .accessibilityLabel("En ligne")
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title.isEmpty ? String(localized: "Conversation") : title)
                        .font(unread ? SQType.body(.bold) : SQType.rowTitle)
                        .foregroundStyle(SQColor.label)
                        // Aux tailles d'accessibilité, le nom passe à la ligne autant
                        // qu'il faut : un mot plus large que la ligne n'est pas coupé.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .layoutPriority(1)
                        .accessibilityIdentifier("messages.row.title")
                    // Badges de l'interlocuteur, comme dans le fil.
                    SQUserBadges(badges: conversation.otherParticipantBadges(excluding: currentUserId), size: 12)
                    if conversation.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .accessibilityLabel("En sourdine")
                            .accessibilityIdentifier("messages.row.muted")
                    }
                    if conversation.pinnedAt != nil {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .accessibilityLabel("Épinglée")
                            .accessibilityIdentifier("messages.row.pinned")
                    }
                    Spacer(minLength: SQSpace.xs)
                    if !dynamicTypeSize.isAccessibilitySize, let date = conversation.listDate {
                        rowDate(date, unread: unread)
                    }
                }
                HStack(spacing: SQSpace.sm) {
                    if let draft = drafts[conversation.id] {
                        draftPreview(draft)
                    } else {
                        Text(lastMessagePreview(conversation))
                            .font(unread ? SQType.subhead : SQType.subhead(.regular))
                            .foregroundStyle(unread ? SQColor.label : SQColor.labelSecondary)
                            .sqSingleLine()
                            .accessibilityIdentifier("messages.row.preview")
                    }
                    Spacer(minLength: 0)
                    if unread {
                        // Le nombre quand le serveur le sert (v2), sinon un point.
                        Group {
                            if unreadCount > 0 {
                                Text(verbatim: "\(unreadCount)")
                                    .font(SQType.micro(.heavy))
                                    .monospacedDigit()
                                    .foregroundStyle(SQColor.onAccent)
                                    .padding(.horizontal, 6)
                                    .frame(minWidth: 20, minHeight: 20)
                                    .background(SQColor.brandRed, in: Capsule())
                            } else {
                                Circle()
                                    .fill(SQColor.brandRed)
                                    .frame(width: 10, height: 10)
                            }
                        }
                        .accessibilityLabel("Non lu")
                    }
                }
                // Aux tailles d'accessibilité, l'heure laisse toute la largeur au nom.
                if dynamicTypeSize.isAccessibilitySize, let date = conversation.listDate {
                    rowDate(date, unread: unread)
                }
            }
        }
        .padding(.vertical, SQSpace.md)
        .padding(.horizontal, SQSpace.lg)
        .frame(minHeight: 68)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(SQColor.separator)
                    .frame(height: 1)
                    .padding(.leading, SQSpace.lg + 44 + SQSpace.md)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func pinButton(_ conversation: MessageConversation) -> some View {
        let pinned = conversation.pinnedAt != nil
        // Limite d'épinglage atteinte (P2-46) : seul « Désépingler » reste. Une
        // conversation archivée ne s'épingle pas : archiver retire l'épingle.
        if !showingShelved && (pinned || model.canPinMore) {
            Button {
                Haptics.light()
                Task { await model.setPinned(!pinned, conversation) }
            } label: {
                Label(pinned ? "Désépingler" : "Épingler", systemImage: pinned ? "pin.slash" : "pin")
            }
        }
    }

    @ViewBuilder
    private func muteButtons(_ conversation: MessageConversation) -> some View {
        Button {
            Haptics.light()
            Task { await model.setMuted(!conversation.muted, mentionsMuted: nil, conversation) }
        } label: {
            Label(conversation.muted ? "Réactiver les notifications" : "Mettre en sourdine",
                  systemImage: conversation.muted ? "bell" : "bell.slash")
        }
        // En v2, le serveur ne voit pas les mentions : la sourdine coupe tout.
        if conversation.muted, !EncryptedConversationSurfaces.isV2(conversation) {
            Toggle(isOn: Binding(
                get: { conversation.mentionsMuted },
                set: { value in Task { await model.setMuted(true, mentionsMuted: value, conversation) } }
            )) {
                Label("Couper aussi les mentions", systemImage: "at")
            }
        }
    }

    /// « Archiver » / « Désarchiver » : seulement quand le serveur sait archiver.
    @ViewBuilder
    private func shelveButton(_ conversation: MessageConversation) -> some View {
        if model.supportsShelving {
            if showingShelved {
                Button {
                    unshelve(conversation)
                } label: {
                    Label("Désarchiver", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    shelve(conversation)
                } label: {
                    Label("Archiver", systemImage: "archivebox")
                }
            }
        }
    }

    /// Archive, puis propose d'annuler : la conversation revient d'un toucher.
    private func shelve(_ conversation: MessageConversation) {
        let unread = isUnread(conversation)
        Haptics.light()
        Task {
            guard await model.setShelved(true, conversation, isUnread: unread) else { return }
            await services.refreshInboxBadge(force: true)
            inAppNotifications.showUndo(
                body: String(localized: "Conversation archivée"),
                actionLabel: String(localized: "Annuler")
            ) {
                Task {
                    await model.setShelved(false, conversation, isUnread: unread)
                    await model.load()
                    await services.refreshInboxBadge(force: true)
                }
            }
        }
    }

    private func unshelve(_ conversation: MessageConversation) {
        let unread = isUnread(conversation)
        Haptics.light()
        Task {
            guard await model.setShelved(false, conversation, isUnread: unread) else { return }
            await model.load()
            await services.refreshInboxBadge(force: true)
        }
    }

    /// « Ranger dans un dossier » : une coche par dossier, et la création d'un nouveau.
    @ViewBuilder
    private func folderMenu(_ conversation: MessageConversation) -> some View {
        Menu {
            ForEach(model.folders) { folder in
                Toggle(isOn: Binding(
                    get: { folder.conversationIds.contains(conversation.id) },
                    set: { contained in Task { await model.setConversation(conversation.id, in: folder, contained: contained) } }
                )) {
                    Text(verbatim: folder.name)
                }
            }
            Button {
                folderSheet = FolderSheetRequest(fileConversationId: conversation.id)
            } label: {
                Label("Nouveau dossier…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Ranger dans un dossier", systemImage: "folder")
        }
    }

    private func setRead(_ read: Bool, _ conversation: MessageConversation) {
        Task {
            if read { await model.markRead(conversation) } else { await model.markUnread(conversation) }
            await services.refreshInboxBadge(force: true)
        }
    }

    /// Pastille de présence : au moins un autre participant est en ligne.
    private func isOnline(_ conversation: MessageConversation) -> Bool {
        conversation.participants.contains { $0.presence?.isOnline == true }
    }

    /// Conversation non lue (MSG-UX-02) : dernier message reçu d'un autre, postérieur
    /// au marqueur de lecture courant.
    private func isUnread(_ conversation: MessageConversation) -> Bool {
        conversation.isUnread(currentUserId: currentUserId)
    }
}

// MARK: - Dossiers

/// Gestion des dossiers : création, renommage, suppression. Ouverte aussi depuis
/// « Ranger dans un dossier › Nouveau dossier… », où le dossier créé reçoit la conversation.
private struct ConversationFoldersSheet: View {
    @ObservedObject var model: MessagesViewModel
    var fileConversationId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var isCreating = false
    @State private var renaming: ConversationFolder?
    @State private var renameText = ""
    @State private var pendingDelete: ConversationFolder?

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous) }
    private var canCreate: Bool { !MessagesViewModel.cleanFolderName(newName).isEmpty && !isCreating }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(
                    title: "Dossiers",
                    subtitle: String(localized: "Range tes conversations et retrouve-les d’une puce."),
                    closeIdentifier: "folders.close"
                ) { dismiss() }

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Nouveau dossier")
                        .sqKicker()
                        .padding(.leading, SQSpace.xs)
                        .accessibilityAddTraits(.isHeader)
                    TextField("Nom du dossier", text: $newName)
                        .submitLabel(.done)
                        .onSubmit { Task { await create() } }
                        .sqHaloField()
                        .accessibilityIdentifier("folders.name")
                    GradientButton(String(localized: "Créer le dossier"), systemImage: "folder.badge.plus", isBusy: isCreating) {
                        Task { await create() }
                    }
                    .disabled(!canCreate)
                    .accessibilityIdentifier("folders.create")
                }

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Tes dossiers")
                        .sqKicker()
                        .padding(.leading, SQSpace.xs)
                        .accessibilityAddTraits(.isHeader)
                    if model.folders.isEmpty {
                        Text("Aucun dossier pour l’instant.")
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.labelSecondary)
                            .padding(.horizontal, SQSpace.xs)
                            .accessibilityIdentifier("folders.empty")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.folders.enumerated()), id: \.element.id) { index, folder in
                                if index > 0 { Divider().padding(.leading, SQSpace.md + 28 + SQSpace.md) }
                                folderRow(folder)
                            }
                        }
                        .sqSurface(SQColor.surface, in: cardShape)
                    }
                }
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
        .onChangeCompat(of: newName) { _, value in
            if value.count > ConversationFolder.maxNameLength { newName = String(value.prefix(ConversationFolder.maxNameLength)) }
        }
        .alert("Renommer le dossier", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nom du dossier", text: $renameText)
            Button("Renommer") {
                if let folder = renaming { Task { await model.renameFolder(folder, to: renameText) } }
                renaming = nil
            }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Supprimer ce dossier ?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { folder in
            Button("Supprimer", role: .destructive) {
                pendingDelete = nil
                Task { await model.deleteFolder(folder) }
            }
            Button("Annuler", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Les conversations ne sont pas supprimées : elles quittent seulement le dossier.")
        }
    }

    private func folderRow(_ folder: ConversationFolder) -> some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: "folder")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SQColor.chipInk)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: folder.name)
                    .font(SQType.body(.semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                Text("Conversations : \(folder.conversationIds.count)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button {
                    renameText = folder.name
                    renaming = folder
                } label: {
                    Label("Renommer", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDelete = folder
                } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options du dossier \(folder.name)")
        }
        .padding(.leading, SQSpace.md)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folders.row")
    }

    private func create() async {
        guard canCreate else { return }
        isCreating = true
        defer { isCreating = false }
        guard let folder = await model.createFolder(named: newName) else { return }
        newName = ""
        Haptics.success()
        if let fileConversationId {
            await model.setConversation(fileConversationId, in: folder, contained: true)
            dismiss()
        }
    }
}

// MARK: - Mode focus

/// Durées proposées au lancement du mode focus.
enum FocusDuration: String, CaseIterable, Identifiable {
    case oneHour, fourHours, untilTomorrow, untilStopped

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .oneHour: "1 h"
        case .fourHours: "4 h"
        case .untilTomorrow: "Jusqu’à demain matin"
        case .untilStopped: "Jusqu’à l’arrêt"
        }
    }

    /// Heure de fin ; `nil` : le mode dure jusqu'à ce qu'on le termine.
    func endsAt(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .oneHour: return now.addingTimeInterval(3_600)
        case .fourHours: return now.addingTimeInterval(4 * 3_600)
        case .untilTomorrow:
            return calendar.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0), matchingPolicy: .nextTime)
        case .untilStopped: return nil
        }
    }
}

/// Mode focus : on choisit les conversations à garder en avant et pour combien de
/// temps. La liste n'affiche alors que celles-là, les autres restent dans « Toutes ».
private struct FocusSheet: View {
    @ObservedObject var model: MessagesViewModel
    let currentUserId: String?
    let onStarted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var duration: FocusDuration = .fourHours
    @State private var isBusy = false

    init(model: MessagesViewModel, currentUserId: String?, onStarted: @escaping () -> Void) {
        self.model = model
        self.currentUserId = currentUserId
        self.onStarted = onStarted
        let current = model.focus?.conversationIds ?? model.conversations.filter { $0.pinnedAt != nil }.map(\.id)
        _selected = State(initialValue: Set(current))
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(
                    title: "Mode focus",
                    subtitle: String(localized: "Garde en avant les conversations qui comptent."),
                    closeIdentifier: "focus.close"
                ) { dismiss() }

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Conversations")
                        .sqKicker()
                        .padding(.leading, SQSpace.xs)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(model.conversations.enumerated()), id: \.element.id) { index, conversation in
                            if index > 0 { Divider().padding(.leading, SQSpace.md + 36 + SQSpace.md) }
                            conversationRow(conversation)
                        }
                    }
                    .sqSurface(SQColor.surface, in: cardShape)
                }

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Durée")
                        .sqKicker()
                        .padding(.leading, SQSpace.xs)
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SQSpace.sm) {
                            ForEach(FocusDuration.allCases) { option in
                                durationChip(option)
                            }
                        }
                    }
                }

                Text("Tant que le mode est actif, la liste n’affiche que ces conversations. Les autres restent à un toucher, dans « Toutes ».")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                GradientButton(String(localized: "Activer le mode focus"), systemImage: "scope", isBusy: isBusy) {
                    Task { await start() }
                }
                .disabled(selected.isEmpty || isBusy)
                .accessibilityIdentifier("focus.start")
            }
            .padding(SQSpace.lg)
        }
        .sqSheet(background: SQColor.bg)
    }

    private func durationChip(_ option: FocusDuration) -> some View {
        let isSelected = duration == option
        return Button {
            Haptics.selection()
            duration = option
        } label: {
            Text(option.title)
                .font(SQType.subhead(.semibold))
                .sqSingleLine()
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, SQSpace.md2)
                .frame(minHeight: 34)
                .foregroundStyle(isSelected ? SQColor.onInk : SQColor.chipInk)
                .background(isSelected ? SQColor.label : SQColor.chip, in: Capsule(style: .continuous))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle(scale: 0.97))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func conversationRow(_ conversation: MessageConversation) -> some View {
        let isSelected = selected.contains(conversation.id)
        let title = conversation.displayTitle(excluding: currentUserId)
        return Button {
            Haptics.selection()
            if isSelected { selected.remove(conversation.id) } else { selected.insert(conversation.id) }
        } label: {
            HStack(spacing: SQSpace.md) {
                ConversationAvatar(conversation: conversation, currentUserId: currentUserId, size: 36)
                    .accessibilityHidden(true)
                Text(verbatim: title.isEmpty ? String(localized: "Conversation") : title)
                    .font(SQType.body(.semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func start() async {
        isBusy = true
        defer { isBusy = false }
        // Dans l'ordre de la liste, pour un envoi stable.
        let ids = model.conversations.map(\.id).filter { selected.contains($0) }
        await model.startFocus(conversationIds: ids, endsAt: duration.endsAt(from: Date()))
        guard model.focus != nil else { return }
        Haptics.success()
        onStarted()
        dismiss()
    }
}

private struct NewConversationSheet: View {
    let service: MessagesServicing
    let onCreated: () async -> Void
    /// Un tête-à-tête avec cette personne existe déjà : on l'ouvre au lieu
    /// d'en créer un second (v1 comme v2).
    var existingDirect: (String) -> String? = { _ in nil }
    var onOpenExisting: (String) -> Void = { _ in }
    /// Repli quand l'activation v2 est impossible : le mot de passe v1 existant.
    var unlockUserId: String? = nil
    var unlockService: E2EEServicing? = nil

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    /// Parcours d'activation v2 (celui de Messages et de Réglages › Appareils),
    /// ouvert quand une conversation chiffrée est demandée sans identité v2 prête.
    @State private var showV2Activation = false
    @State private var createAfterActivation = false
    @State private var showUnlock = false
    @State private var createAfterUnlock = false
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var title = ""
    @State private var e2ee = true
    @State private var results: [MessageSearchUser] = []
    @State private var selected: [MessageSearchUser] = []
    @State private var isBusy = false
    @State private var errorMessage: String?
    /// Recherche en vol, et dernière requête dont la réponse est arrivée (pour
    /// ne dire « aucun résultat » que pour ce qui est tapé).
    @State private var isSearching = false
    @State private var searchedQuery = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showsNoResult: Bool {
        !isSearching && errorMessage == nil && !trimmedQuery.isEmpty && searchedQuery == trimmedQuery && results.isEmpty
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapChipIconButton(systemImage: "xmark", label: "Annuler", identifier: "newConversation.cancel") { dismiss() }

                Text("Nouveau message")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)

                // La recherche d'abord : c'est par elle qu'on commence.
                SQSearchField(text: $query, placeholder: "Nom, handle ou email", onSubmit: { Task { await search() } })
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("newConversation.search")

                if !selected.isEmpty {
                    selectedChips
                }

                section("Groupe") {
                    VStack(spacing: 0) {
                        TextField("Nom du groupe optionnel", text: $title)
                            .font(SQType.body)
                            .padding(.horizontal, SQSpace.md)
                            .frame(minHeight: 48)
                        Divider().padding(.leading, SQSpace.md)
                        Toggle(isOn: $e2ee) {
                            HStack(spacing: SQSpace.xs) {
                                Text("Conversation chiffrée")
                                    .font(SQType.body(.semibold))
                                    .foregroundStyle(SQColor.label)
                                SQInfoButton(term: .endToEndEncryption)
                            }
                        }
                        .tint(SQColor.brandRed)
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 52)
                    }
                    .sqSurface(SQColor.surface, in: cardShape)
                    // La limite se dit AVANT de créer : on la découvrait au premier
                    // envoi de photo refusé (SOC-07).
                    if e2ee {
                        Text("Une conversation chiffrée n’accepte que du texte : ni photo, ni fichier, ni vocal, ni sondage, ni réaction.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, SQSpace.xs)
                    }
                }

                if isSearching || showsNoResult || !results.isEmpty {
                    section("Résultats") {
                        VStack(spacing: 0) {
                            if isSearching || showsNoResult {
                                UserSearchStatusRow(isSearching: isSearching)
                                    .padding(.horizontal, SQSpace.md)
                                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            }
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, user in
                                if index > 0 || isSearching || showsNoResult { Divider().padding(.leading, SQSpace.md + 36 + SQSpace.md) }
                                resultRow(user)
                            }
                        }
                        .sqSurface(SQColor.surface, in: cardShape)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("newConversation.error")
                }

                GradientButton(startLabel, isBusy: isBusy) {
                    Task { await create() }
                }
                .disabled(selected.isEmpty || isBusy)
                .accessibilityIdentifier("newConversation.create")
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
        .sheet(isPresented: $showV2Activation, onDismiss: {
            guard createAfterActivation else { return }
            createAfterActivation = false
            Task { await create(afterActivation: true) }
        }) {
            E2EEV2ActivationScreen(
                api: services.api,
                onFinish: {
                    createAfterActivation = true
                    showV2Activation = false
                },
                onLater: {
                    errorMessage = String(localized: "Active le chiffrement sur cet appareil pour créer une conversation chiffrée.")
                    showV2Activation = false
                }
            )
        }
        .sheet(isPresented: $showUnlock, onDismiss: {
            guard createAfterUnlock else { return }
            createAfterUnlock = false
            Task { await create(afterActivation: true) }
        }) {
            if let unlockUserId, let unlockService {
                E2EEUnlockSheet(userId: unlockUserId, service: unlockService) {
                    createAfterUnlock = true
                }
            }
        }
        .onChangeCompat(of: query) { _, _ in
            // Debounce annulable : annule la requête précédente avant d'en relancer
            // une et abandonne si annulée pendant l'attente — évite les rafales
            // réseau et les réponses périmées qui écrasent les récentes.
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await search()
            }
        }
    }

    /// « Démarrer », puis le nombre de personnes choisies.
    private var startLabel: String {
        if isBusy { return String(localized: "Création…") }
        if selected.isEmpty { return String(localized: "Démarrer") }
        return String(localized: "Démarrer · \(selected.count) personnes")
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title)
                .sqKicker()
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, SQSpace.xs)
            content()
        }
    }

    /// Personnes choisies en pastilles, chacune avec sa croix pour la retirer.
    private var selectedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(selected) { user in
                    Button {
                        Haptics.selection()
                        selected.removeAll { $0.id == user.id }
                    } label: {
                        HStack(spacing: SQSpace.xs) {
                            Text(verbatim: user.displayName)
                                .sqSingleLine()
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .accessibilityHidden(true)
                        }
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 32)
                        .background(SQColor.accentSoft, in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retirer \(user.displayName)")
                }
            }
        }
    }

    /// Résultat de recherche : un toucher coche ou décoche la personne.
    private func resultRow(_ user: MessageSearchUser) -> some View {
        let isSelected = selected.contains { $0.id == user.id }
        return Button {
            Haptics.selection()
            if isSelected {
                selected.removeAll { $0.id == user.id }
            } else {
                selected.append(user)
            }
        } label: {
            HStack(spacing: SQSpace.md) {
                SQAvatar(url: user.avatarUrl, name: user.displayName, size: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: user.displayName)
                        .font(SQType.body(.semibold))
                        .foregroundStyle(SQColor.label)
                    if let subtitle = user.publicSubtitle {
                        Text(verbatim: subtitle)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            searchedQuery = ""
            isSearching = false
            return
        }
        isSearching = true
        do {
            let found = try await service.searchUsers(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            searchedQuery = trimmed
            // Une erreur de recherche (ou de création) précédente ne survit pas à une recherche réussie.
            errorMessage = nil
        } catch {
            guard !error.isCancellation, !Task.isCancelled else { return }
            errorMessage = error.userFacingMessage
        }
        isSearching = false
    }

    /// `afterActivation` : relance après l'activation v2 ou le déverrouillage ;
    /// si l'identité v2 n'est toujours pas prête, on le dit au lieu de reboucler.
    private func create(afterActivation: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let isGroup = selected.count > 1
            if !isGroup, let peer = selected.first, let existing = existingDirect(peer.id) {
                dismiss()
                onOpenExisting(existing)
                return
            }
            // Chiffrée et verrous ouverts : naît en v2 si tous les membres le
            // lisent ; sinon en v1, tant que le serveur l'accepte (v0.4.17).
            // Appareil pas encore entré en v2 : on déroule d'abord l'activation
            // guidée (le serveur refuse la v1 à un compte sans mot de passe de
            // chiffrement), puis la création repart en v2. Une porte serveur
            // refermée, elle, crée en v1.
            if e2ee, services.e2eeV2Messaging.writesEnabled,
               let session = LocalAccountScope.sessionSnapshot(),
               services.e2eeV2Messaging.lacksV2Readiness(session) {
                if afterActivation {
                    errorMessage = String(localized: "Le chiffrement n’est pas encore prêt sur cet appareil. Réessaie.")
                } else {
                    showV2Activation = true
                }
                return
            }
            if e2ee, services.e2eeV2Messaging.writesEnabled,
               let session = LocalAccountScope.sessionSnapshot(),
               !services.e2eeV2Messaging.lacksV2Readiness(session) {
                switch await services.e2eeV2Messaging.create(
                    participantIds: selected.map(\.id), isGroup: isGroup,
                    title: isGroup && !normalizedTitle.isEmpty ? normalizedTitle : nil, excludesWeb: false
                ) {
                case .created:
                    Haptics.success()
                    await onCreated()
                    dismiss()
                    return
                case .failure(let failure) where failure.message == "e2ee-v2-capability-missing"
                    || failure.kind == .activationBlocked:
                    break
                // Créé entre-temps ailleurs (autre appareil, autre plateforme) : on l'ouvre.
                case .failure(let failure) where failure.code == "E2EE_DIRECT_CONVERSATION_EXISTS":
                    if case .string(let existing)? = failure.details?["conversationId"] {
                        await onCreated()
                        dismiss()
                        onOpenExisting(existing)
                        return
                    }
                    throw E2EEV2MessagingError(String(localized: "La conversation chiffrée n’a pas pu être créée."))
                case .failure(let failure):
                    throw E2EEV2MessagingError(failure.kind == .retryable
                        ? String(localized: "Connexion instable. Réessaie.")
                        : String(localized: "La conversation chiffrée n’a pas pu être créée."))
                }
            }
            _ = try await service.createConversation(
                participantIds: selected.map(\.id),
                title: normalizedTitle.isEmpty ? nil : normalizedTitle,
                e2ee: e2ee
            )
            Haptics.success()
            await onCreated()
            dismiss()
        } catch {
            // Création v1 refusée faute de mot de passe de chiffrement : la feuille
            // de création de clé, puis la création repart (au lieu de l'erreur brute).
            if e2ee, !afterActivation, unlockUserId != nil, unlockService != nil,
               case APIError.http(let status, _, let message, _, _) = error,
               status == 400, message.localizedCaseInsensitiveContains("mot de passe de chiffrement") {
                showUnlock = true
                return
            }
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}

extension Array where Element == MessageConversation {
    static var demo: [MessageConversation] {
        [
            MessageConversation(
                id: "demo-conv-1",
                title: "SignalQuest iOS",
                isGroup: false,
                e2eeEnabled: false,
                groupPhotoUrl: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastMessageAt: Date(),
                lastReadAt: nil,
                pinnedAt: nil,
                participants: [
                    ConversationParticipant(
                        userId: "demo-user",
                        role: "member",
                        joinedAt: Date(),
                        lastReadAt: nil,
                        user: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                        presence: SocialPresence(status: "online", customStatus: nil, lastSeenAt: Date(), isOnline: true)
                    )
                ],
                lastMessage: MessageItem.demo.first
            ),
            MessageConversation(
                id: "demo-conv-2",
                title: "Conversation chiffrée",
                isGroup: false,
                e2eeEnabled: true,
                groupPhotoUrl: nil,
                createdAt: Date(),
                updatedAt: Date(),
                // Une heure plus tôt : la liste se trie par date affichée.
                lastMessageAt: Date().addingTimeInterval(-3_600),
                lastReadAt: nil,
                pinnedAt: nil,
                // Deux personnes, comme une vraie conversation chiffrée : sans
                // elles, « Appeler » s'arrête sur « Aucun autre participant ».
                participants: [
                    ConversationParticipant(
                        userId: "mock-user",
                        role: "member",
                        joinedAt: Date(),
                        lastReadAt: nil,
                        user: MessageUser(id: "mock-user", name: "SignalQuest iOS", email: "ios@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    ),
                    ConversationParticipant(
                        userId: "demo-user-2",
                        role: "member",
                        joinedAt: Date(),
                        lastReadAt: nil,
                        user: MessageUser(id: "demo-user-2", name: "Léa", email: "lea@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    )
                ],
                lastMessage: nil
            ),
            // Groupe non chiffré : les mentions n'existent que là.
            MessageConversation(
                id: "demo-conv-3",
                title: "Équipe terrain",
                isGroup: true,
                e2eeEnabled: false,
                groupPhotoUrl: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastMessageAt: Date().addingTimeInterval(-7_200),
                lastReadAt: Date(),
                pinnedAt: nil,
                participants: [
                    ConversationParticipant(
                        userId: "mock-user", role: "owner", joinedAt: Date(), lastReadAt: nil,
                        user: MessageUser(id: "mock-user", name: "SignalQuest iOS", email: "ios@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    ),
                    ConversationParticipant(
                        userId: "demo-user", role: "member", joinedAt: Date(), lastReadAt: nil,
                        user: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    ),
                    ConversationParticipant(
                        userId: "demo-user-2", role: "member", joinedAt: Date(), lastReadAt: nil,
                        user: MessageUser(id: "demo-user-2", name: "Léa", email: "lea@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    )
                ],
                lastMessage: MessageItem(
                    id: "demo-group-message-1", conversationId: "demo-conv-3", senderId: "demo-user-2", kind: "TEXT",
                    content: "On se retrouve au pylône nord samedi ? https://signalquest.fr/carte", e2eeVersion: nil, e2eeIvB64: nil,
                    e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil,
                    createdAt: Date().addingTimeInterval(-7_200), editedAt: nil, deletedAt: nil, replyToId: nil,
                    threadReplyCount: 0,
                    sender: MessageUser(id: "demo-user-2", name: "Léa", email: "lea@signalquest.fr", avatarUrl: nil),
                    attachments: [], reactions: []
                )
            )
        ]
    }
}

extension Array where Element == MessageConversation {
    /// Conversations archivées du mode démo.
    static var demoShelved: [MessageConversation] {
        [
            MessageConversation(
                id: "demo-conv-shelved-1",
                title: "Collectif ANFR",
                isGroup: true,
                e2eeEnabled: false,
                groupPhotoUrl: nil,
                createdAt: Date(),
                updatedAt: Date(),
                lastMessageAt: Date().addingTimeInterval(-259_200),
                lastReadAt: nil,
                pinnedAt: nil,
                participants: [
                    ConversationParticipant(
                        userId: "mock-user", role: "member", joinedAt: Date(), lastReadAt: nil,
                        user: MessageUser(id: "mock-user", name: "SignalQuest iOS", email: "ios@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    ),
                    ConversationParticipant(
                        userId: "demo-user", role: "member", joinedAt: Date(), lastReadAt: nil,
                        user: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                        presence: nil
                    )
                ],
                lastMessage: MessageItem(
                    id: "demo-shelved-message-1", conversationId: "demo-conv-shelved-1", senderId: "demo-user", kind: "TEXT",
                    content: "Le relevé de jeudi est dans le dossier partagé.", e2eeVersion: nil, e2eeIvB64: nil,
                    e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil,
                    createdAt: Date().addingTimeInterval(-259_200), editedAt: nil, deletedAt: nil, replyToId: nil,
                    threadReplyCount: 0,
                    sender: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                    attachments: [], reactions: []
                )
            )
        ].map { conversation in
            var archived = conversation
            archived.shelved = true
            archived.shelvedAt = Date()
            return archived
        }
    }
}

extension ConversationFolder {
    /// Dossiers du mode démo.
    static var demo: [ConversationFolder] {
        [
            ConversationFolder(id: "demo-folder-1", name: "Terrain", conversationIds: ["demo-conv-3"]),
            ConversationFolder(id: "demo-folder-2", name: "Amis", conversationIds: ["demo-conv-1", "demo-conv-2"])
        ]
    }
}

extension CallThreadEvent {
    /// Appels du mode démo : un appel passé, un manqué, un refusé, pour la conversation donnée.
    static func demo(conversationId: String) -> [CallThreadEvent] {
        let peerId = conversationId == "demo-conv-3" ? "demo-user-2" : "demo-user"
        return [
            CallThreadEvent(callId: "demo-call-\(conversationId)-1", mode: .audio, outcome: .completed,
                            startedAt: Date().addingTimeInterval(-5_400), durationSec: 252, callerId: "mock-user"),
            CallThreadEvent(callId: "demo-call-\(conversationId)-2", mode: .video, outcome: .missed,
                            startedAt: Date().addingTimeInterval(-1_800), durationSec: nil, callerId: peerId),
            CallThreadEvent(callId: "demo-call-\(conversationId)-3", mode: .audio, outcome: .declined,
                            startedAt: Date().addingTimeInterval(-600), durationSec: nil, callerId: "mock-user")
        ]
    }
}

extension MessageItem {
    static var demo: [MessageItem] {
        [
            MessageItem(
                id: "demo-message-1",
                conversationId: "demo-conv-1",
                senderId: "demo-user",
                kind: "TEXT",
                content: "Tu peux partager un post, une photo ou un speedtest vers cette conversation.",
                e2eeVersion: nil,
                e2eeIvB64: nil,
                e2eeCiphertextB64: nil,
                e2eeAadB64: nil,
                metadata: nil,
                createdAt: Date(),
                editedAt: nil,
                deletedAt: nil,
                replyToId: nil,
                threadReplyCount: 0,
                sender: MessageUser(id: "demo-user", name: "Camille", email: "camille@signalquest.fr", avatarUrl: nil),
                attachments: [],
                reactions: []
            ),
            // Sites partagés au format commun (P2-47) : l'un reçu, l'autre envoyé.
            demoSiteMessage(
                id: "demo-site-1", senderId: "demo-user", name: "Camille", minutesAgo: 6,
                text: ["Antenne Orange (eNB 812345)", "Opérateur: Orange", "Technologies: 4G, 5G", "eNB: 812345", "PCI: 211",
                       "Support: 1234567", "ANFR: 0691234567", "Marché: FR", "Adresse: 45, rue de Gerland, 69007 Lyon",
                       "Position: 45.72869, 4.83312",
                       "Lien: https://signalquest.fr/carte?lat=45.72869&lng=4.83312&siteId=1234567&market=FR&operator=ORANGE&open=antenna"]
            ),
            demoSiteMessage(
                id: "demo-site-2", senderId: "mock-user", name: "SignalQuest iOS", minutesAgo: 2,
                text: ["Antenne Bouygues Telecom (ANFR 0381234567)", "Opérateur: Bouygues Telecom", "Technologies: 4G", "Support: 7654321",
                       "ANFR: 0381234567", "Marché: FR", "Adresse: Rue du Port, 38000 Grenoble"]
            )
        ]
    }

    private static func demoSiteMessage(id: String, senderId: String, name: String, minutesAgo: Double, text: [String]) -> MessageItem {
        MessageItem(
            id: id, conversationId: "demo-conv-1", senderId: senderId, kind: "TEXT",
            content: text.joined(separator: "\n"), e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil, e2eeAadB64: nil,
            metadata: nil, createdAt: Date().addingTimeInterval(-minutesAgo * 60), editedAt: nil, deletedAt: nil, replyToId: nil,
            threadReplyCount: 0,
            sender: MessageUser(id: senderId, name: name, email: "demo@signalquest.fr", avatarUrl: nil),
            attachments: [], reactions: []
        )
    }
}

/// Date d'une conversation dans la liste, comme les messageries : l'heure
/// aujourd'hui, « Hier », le jour de la semaine, puis la date. « il y a 2 m. »
/// se lisait minutes ou mois (UI-12).
enum ConversationListDate {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(locale))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Hier")
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            return date.formatted(.dateTime.weekday(.wide).locale(locale))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }
}

extension View {
    /// Échec d'une action sur une liste déjà remplie (retrait, suppression) :
    /// bandeau collé en bas, annoncé à VoiceOver. Sans lui, l'erreur n'apparaissait
    /// que sur une liste vide et la rangée revenait sans explication.
    func actionErrorBar(_ message: String?) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if let message {
                SQInlineError(message: message)
                    .padding(SQSpace.md)
                    .background(SQColor.dangerSoft)
                    .background(SQColor.surface)
            }
        }
    }
}

/// Ligne d'état d'une recherche d'utilisateurs : chargement, puis « aucun
/// résultat » (une recherche réussie mais vide ne doit pas ressembler à un
/// champ resté inactif).
struct UserSearchStatusRow: View {
    let isSearching: Bool

    var body: some View {
        if isSearching {
            HStack(spacing: SQSpace.sm) {
                SQSpinner().tint(SQColor.brandRed)
                Text("Recherche en cours")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Aucun résultat")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .task { UIAccessibility.post(notification: .announcement, argument: String(localized: "Aucun résultat")) }
        }
    }
}

/// Morceau de la carte unique des conversations : coins arrondis en haut pour
/// la première rangée, en bas pour la dernière, droits entre les deux.
struct MessagesCardSegment: InsettableShape {
    var top: Bool
    var bottom: Bool
    var radius: CGFloat = SQRadius.xl
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let r = min(max(radius - insetAmount, 0), rect.height / 2)
        let topRadius = top ? r : 0
        let bottomRadius = bottom ? r : 0
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        if topRadius > 0 {
            path.addArc(center: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius), radius: topRadius,
                        startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        if topRadius > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius), radius: topRadius,
                        startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        if bottomRadius > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY - bottomRadius), radius: bottomRadius,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        if bottomRadius > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY - bottomRadius), radius: bottomRadius,
                        startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> MessagesCardSegment {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// Avatar d'une conversation : la photo du groupe ou de l'interlocuteur ; un
/// groupe sans photo montre deux de ses membres superposés. Partagé par la
/// liste et la barre du haut de la conversation.
struct ConversationAvatar: View {
    let conversation: MessageConversation
    let currentUserId: String?
    var size: CGFloat = 44

    var body: some View {
        let others = conversation.participants.filter { $0.userId != currentUserId }
        if conversation.isGroup, conversation.groupPhotoUrl == nil, others.count >= 2 {
            let small = (size * 0.68).rounded()
            ZStack(alignment: .topLeading) {
                SQAvatar(url: others[0].user.avatarUrl, name: others[0].user.displayName, size: small)
                SQAvatar(url: others[1].user.avatarUrl, name: others[1].user.displayName, size: small)
                    .padding(2)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: small * 0.36, style: .continuous))
                    .offset(x: size - small - 2, y: size - small - 2)
            }
            .frame(width: size, height: size, alignment: .topLeading)
        } else {
            let title = conversation.displayTitle(excluding: currentUserId)
            // À deux : la photo de l'interlocuteur ; en groupe : seulement celle du groupe.
            let personal = conversation.isGroup ? nil : (others.first ?? conversation.participants.first)?.user.avatarUrl
            SQAvatar(
                url: conversation.groupPhotoUrl ?? personal,
                name: title.isEmpty ? "Conversation" : title,
                size: size
            )
        }
    }
}

/// « Partage reçu » : ce que l'extension « Partager vers SignalQuest » a déposé.
///
/// Rien ne part d'ici. Choisir une conversation l'ouvre avec le compositeur
/// prérempli (texte par le brouillon, pièces jointes mises en attente) ; choisir
/// le fil ouvre le composer de publication. L'envoi reste celui de ces écrans,
/// chiffrement compris.
///
/// En mode `isOutgoing` (P2-47), la feuille sert de sélecteur de conversation à un
/// texte écrit par l'app elle-même (un site à envoyer) : pas de fil, « Annuler » à
/// la place d'« Ignorer », même remise par le brouillon.
struct ReceivedShareSheet: View {
    let entry: ShareInbox.Entry
    /// Brouillon écrit, pièces jointes lues : la conversation peut s'ouvrir.
    let onDelivered: (MessageConversation, [ShareHandoffAttachment]) -> Void
    let onFeed: (ComposerSharedContent) -> Void
    let onIgnore: () -> Void
    var isOutgoing = false

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [MessageConversation] = []
    @State private var routes: [String: EncryptedConversationSurfaces.ForwardRoute] = [:]
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var busyId: String?
    @State private var actionError: String?
    @State private var thumbnails: [UIImage] = []
    @State private var query = ""

    private var manifest: ShareInbox.Manifest { entry.manifest }
    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }

    /// Les conversations qui peuvent recevoir ce partage, et combien en sont écartées.
    private var targets: [MessageConversation] {
        conversations.filter { accepts($0) }
    }

    private var hiddenEncryptedCount: Int {
        conversations.filter { $0.e2eeEnabled == true && !accepts($0) }.count
    }

    private func accepts(_ conversation: MessageConversation) -> Bool {
        ShareDestinationPolicy.conversationAccepts(
            manifest, toEncrypted: conversation.e2eeEnabled == true,
            route: routes[conversation.id] ?? .plain
        )
    }

    private var visibleTargets: [MessageConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return targets }
        return targets.filter {
            $0.displayTitle(excluding: currentUserId).localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(
                    title: isOutgoing ? "Envoyer dans une conversation" : "Partage reçu",
                    subtitle: isOutgoing
                        ? String(localized: "Choisis la conversation. Tu relis le message avant de l’envoyer.")
                        : String(localized: "Choisis où le déposer. Rien ne part sans ton accord."),
                    closeIdentifier: "share.close"
                ) { dismiss() }
                previewCard
                conversationsSection
                if !isOutgoing { feedSection }
                Button(role: .destructive) { onIgnore() } label: {
                    Text(isOutgoing ? LocalizedStringKey("Annuler") : LocalizedStringKey("Ignorer"))
                        .font(SQType.body.weight(.semibold))
                        .foregroundStyle(isOutgoing ? SQColor.accentInk : SQColor.dangerInk)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busyId != nil)
                .accessibilityIdentifier("share.ignore")
            }
            .padding(SQSpace.lg)
        }
        .sqSheet(background: SQColor.bg)
        .presentationDetents([.large])
        .task { await load() }
        .task { thumbnails = await Self.thumbnails(for: entry) }
    }

    // MARK: Aperçu

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if isOutgoing, let text = manifest.text, let site = SiteShareCard.parse(text) {
                // Ce qui va partir, tel que le destinataire le verra.
                SiteShareCardBubble(card: site, mine: false, onOpenSite: { _, _ in }, interactive: false)
            } else if let text = manifest.text {
                Text(verbatim: text)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let raw = manifest.url, let url = URL(string: raw) {
                let host = Self.displayHost(of: url)
                Label {
                    Text(verbatim: host).font(SQType.body.weight(.medium)).foregroundStyle(SQColor.label)
                } icon: {
                    Image(systemName: "link").foregroundStyle(SQColor.accentInk)
                }
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Lien web : \(host)"))
            }
            if manifest.imageCount > 0 {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: SQSpace.sm) {
                            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 76, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                            }
                        }
                    }
                    .accessibilityHidden(true)
                    Text("\(manifest.imageCount) image")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let file = manifest.attachment {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: file.fileName)
                            .font(SQType.body.weight(.medium))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                } icon: {
                    Image(systemName: file.kind == .video ? "film" : "doc").foregroundStyle(SQColor.accentInk)
                }
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityIdentifier("share.preview")
    }

    // MARK: Conversations

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Dans une conversation")
                .sqKicker()
                .padding(.leading, SQSpace.xs)
                .accessibilityAddTraits(.isHeader)
            if let loadError {
                ErrorStateView(title: "Conversations indisponibles", message: loadError) {
                    Task { await load() }
                }
            } else if !hasLoaded {
                SQSpinner()
                    .tint(SQColor.brandRed)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.xl)
            } else if targets.isEmpty {
                EmptyStateView(
                    title: String(localized: "Aucune conversation"),
                    message: String(localized: "Aucune conversation ne peut recevoir ce partage."),
                    systemImage: "bubble.left.and.bubble.right"
                )
            } else {
                if targets.count > 6 {
                    TextField("Rechercher une conversation", text: $query)
                        .submitLabel(.search)
                        .sqHaloField()
                        .accessibilityIdentifier("share.search")
                }
                VStack(spacing: 0) {
                    ForEach(visibleTargets) { target in
                        if target.id != visibleTargets.first?.id { Divider().padding(.leading, 64) }
                        row(for: target)
                    }
                }
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                if hiddenEncryptedCount > 0 {
                    Text("Les conversations chiffrées ne reçoivent que du texte.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.horizontal, SQSpace.xs)
                        .accessibilityIdentifier("share.encryptedNote")
                }
            }
            if let actionError {
                Text(verbatim: actionError)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .accessibilityIdentifier("share.error")
            }
        }
    }

    private func row(for target: MessageConversation) -> some View {
        Button {
            Task { await choose(target) }
        } label: {
            HStack(spacing: SQSpace.md) {
                ConversationAvatar(conversation: target, currentUserId: currentUserId, size: 40)
                    .accessibilityHidden(true)
                Text(verbatim: target.displayTitle(excluding: currentUserId))
                    .font(SQType.rowTitle)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if busyId == target.id { SQSpinner().tint(SQColor.brandRed) }
            }
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busyId != nil)
    }

    // MARK: Fil

    private var feedSection: some View {
        let blocker = ShareDestinationPolicy.feedBlocker(for: manifest)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Dans le fil")
                .sqKicker()
                .padding(.leading, SQSpace.xs)
                .accessibilityAddTraits(.isHeader)
            Button {
                Task { await postToFeed() }
            } label: {
                HStack(spacing: SQSpace.md) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(blocker == nil ? SQColor.accentInk : SQColor.labelSecondary)
                        .frame(width: 40, height: 40)
                        .background(SQColor.chip, in: Circle())
                        .accessibilityHidden(true)
                    Text("Publier dans le fil")
                        .font(SQType.rowTitle)
                        .foregroundStyle(blocker == nil ? SQColor.label : SQColor.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, SQSpace.md)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(blocker != nil || busyId != nil)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .accessibilityIdentifier("share.feed")
            if let blocker {
                Text(verbatim: Self.explanation(for: blocker))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.horizontal, SQSpace.xs)
                    .accessibilityIdentifier("share.feedBlocker")
            }
        }
    }

    // MARK: Actions

    private func load() async {
        loadError = nil
        do {
            // Mode démo : les conversations de la liste, comme l'écran Messages.
            let loaded = AppEnvironment.usesDemoData
                ? [MessageConversation].demo.inDisplayOrder()
                : try await services.messages.conversations()
            let v2Enabled = services.e2eeV2Messaging.readsEnabled && services.e2eeV2Messaging.writesEnabled
            conversations = loaded
            routes = Dictionary(loaded.map { conversation -> (String, EncryptedConversationSurfaces.ForwardRoute) in
                let encrypted = conversation.e2eeEnabled == true
                return (conversation.id, EncryptedConversationSurfaces.forwardRoute(
                    toEncrypted: encrypted,
                    targetIsV2: encrypted && EncryptedConversationSurfaces.isV2(conversation),
                    v2Enabled: v2Enabled
                ))
            }, uniquingKeysWith: { first, _ in first })
            hasLoaded = true
        } catch {
            loadError = error.userFacingMessage
        }
    }

    private func choose(_ target: MessageConversation) async {
        guard busyId == nil else { return }
        busyId = target.id
        actionError = nil
        do {
            let attachments = try await Self.attachments(of: entry)
            let composed = manifest.composedText
            if !composed.isEmpty {
                let scope = LocalAccountScope.currentOwnerScopeId
                let existing = await MessageDraftStore.shared.text(conversationId: target.id, ownerScopeId: scope)
                try await MessageDraftStore.shared.save(
                    Self.mergedDraft(existing: existing, shared: composed),
                    conversationId: target.id, ownerScopeId: scope
                )
            }
            onDelivered(target, attachments)
        } catch {
            actionError = String(localized: "Impossible de lire ce partage. Réessaie.")
            busyId = nil
            Haptics.error()
        }
    }

    private func postToFeed() async {
        guard busyId == nil, ShareDestinationPolicy.feedBlocker(for: manifest) == nil else { return }
        busyId = "feed"
        actionError = nil
        do {
            let image = try await Self.attachments(of: entry).first { $0.kind == .image }
            onFeed(ComposerSharedContent(text: manifest.composedText, imageData: image?.data))
        } catch {
            actionError = String(localized: "Impossible de lire ce partage. Réessaie.")
            busyId = nil
            Haptics.error()
        }
    }

    // MARK: Logique pure et lectures

    /// Le texte partagé après le brouillon déjà là, sans l'écraser.
    nonisolated static func mergedDraft(existing: String?, shared: String) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return shared }
        if existing.contains(shared) { return existing }
        return existing + "\n" + shared
    }

    static func explanation(for blocker: ShareDestinationPolicy.FeedBlocker) -> String {
        switch blocker {
        case .videoOrFile: return String(localized: "Une publication ne porte ni vidéo ni fichier.")
        case .severalImages: return String(localized: "Une publication ne porte qu’une seule photo.")
        }
    }

    static func displayHost(of url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func attachments(of entry: ShareInbox.Entry) async throws -> [ShareHandoffAttachment] {
        try await Task.detached(priority: .userInitiated) {
            try entry.manifest.items.map {
                ShareHandoffAttachment(data: try entry.data(for: $0), fileName: $0.fileName, uti: $0.uti, kind: $0.kind)
            }
        }.value
    }

    /// Vignettes décodées depuis les fichiers, à la taille voulue.
    private static func thumbnails(for entry: ShareInbox.Entry) async -> [UIImage] {
        await Task.detached(priority: .userInitiated) {
            entry.manifest.items.filter { $0.kind == .image }.compactMap { item -> UIImage? in
                guard let source = CGImageSourceCreateWithURL(entry.fileURL(for: item) as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 240,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
            }
        }.value
    }
}

// MARK: Envoi d'un site dans une conversation (P2-47)

/// Texte de site à envoyer, prêt pour le sélecteur de conversation.
struct SiteShareDraft: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

private struct SiteSharePickerModifier: ViewModifier {
    @Binding var draft: SiteShareDraft?
    /// Appelé une fois la conversation choisie : la fiche d'où part le site se ferme.
    let onDelivered: () -> Void
    @EnvironmentObject private var router: AppRouter

    func body(content: Content) -> some View {
        content.sheet(item: $draft) { draft in
            ReceivedShareSheet(
                // Un dépôt sans fichier : seul le texte compte, le dossier n'est jamais lu.
                entry: ShareInbox.Entry(
                    manifest: ShareInbox.Manifest(id: draft.id.uuidString, createdAt: Date(), text: draft.text, url: nil, items: []),
                    directory: FileManager.default.temporaryDirectory
                ),
                onDelivered: { conversation, _ in
                    // Le texte est déjà dans le brouillon de la conversation : elle s'ouvre,
                    // l'utilisateur relit et envoie lui-même.
                    self.draft = nil
                    router.pendingShare = ShareHandoff(conversationId: conversation.id, attachments: [])
                    router.route(toConversation: conversation.id)
                    onDelivered()
                },
                onFeed: { _ in },
                onIgnore: { self.draft = nil },
                isOutgoing: true
            )
        }
    }
}

extension View {
    /// Présente le sélecteur de conversation d'un site à envoyer (P2-47). Le texte
    /// arrive prérempli dans le compositeur de la conversation choisie, chiffrée
    /// comprise : c'est du texte.
    func siteSharePicker(_ draft: Binding<SiteShareDraft?>, onDelivered: @escaping () -> Void) -> some View {
        modifier(SiteSharePickerModifier(draft: draft, onDelivered: onDelivered))
    }
}
