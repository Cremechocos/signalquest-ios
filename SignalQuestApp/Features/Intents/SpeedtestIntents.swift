import AppIntents
import Foundation

/// Raccourci Siri / Spotlight / Action « Lancer un Speedtest ». Ouvre l'app sur
/// l'onglet Tester, qui propose aussitôt le test avec confirmation (MES-34).
struct RunSpeedtestIntent: AppIntent {
    static let title: LocalizedStringResource = "Lancer un Speedtest"
    static let description = IntentDescription("Ouvre SignalQuest et propose de lancer un test de débit.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Directement sur le routeur : le drapeau lu au passage au premier plan
        // ne partait pas quand l'app était déjà ouverte (MES-34).
        AppServicesHolder.services.router.requestSpeedtestStart()
        return .result()
    }
}

/// Raccourci « Ouvrir la carte ».
struct OpenMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir la carte SignalQuest"
    static let description = IntentDescription("Ouvre la carte des antennes et mesures.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Directement sur le routeur, comme le Speedtest : le drapeau n'était lu
        // qu'au passage au premier plan, donc rien ne bougeait app ouverte (AF-ACC-01).
        AppServicesHolder.services.router.selectedTab = .map
        return .result()
    }
}

/// Raccourci « Ouvrir la messagerie ».
struct OpenMessagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir la messagerie SignalQuest"
    static let description = IntentDescription("Ouvre la messagerie chiffrée SignalQuest.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServicesHolder.services.router.route(toConversation: nil)
        return .result()
    }
}

/// Conversations proposées à Siri et Raccourcis : leur nom et leur identifiant,
/// jamais le moindre message. Lues dans l'annuaire local de l'appareil.
enum SQConversationIntentDirectory {
    struct Item: Equatable {
        let id: String
        let name: String
        let isEncrypted: Bool
    }

    /// Les plus récemment vues d'abord ; vide hors d'un compte connecté. Une
    /// conversation protégée n'y figure pas : ni son nom ni sa présence ne sortent de l'app.
    static func items() -> [Item] {
        let owner = LocalAccountScope.currentOwnerScopeId
        guard owner.hasPrefix("user:") else { return [] }
        let all = CallConversationDirectory.shared.allEntries(ownerScopeId: owner).map {
            Item(id: $0.id, name: $0.entry.title, isEncrypted: $0.entry.isEncrypted)
        }
        return excluding(ConversationSecretPolicyCache.protectedConversationIds(ownerScopeId: owner), from: all)
    }

    static func excluding(_ hidden: Set<String>, from items: [Item]) -> [Item] {
        items.filter { !hidden.contains($0.id) }
    }

    static func matching(_ items: [Item], name: String) -> [Item] {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.name.localizedStandardContains(needle) }
    }
}

/// Conversation à ouvrir (nom et identifiant seulement).
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = ConversationEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ item: SQConversationIntentDirectory.Item) {
        id = item.id
        name = item.name
    }
}

struct ConversationEntityQuery: EntityStringQuery {
    func entities(for identifiers: [ConversationEntity.ID]) async throws -> [ConversationEntity] {
        let items = SQConversationIntentDirectory.items()
        return identifiers.compactMap { id in items.first { $0.id == id }.map(ConversationEntity.init) }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        SQConversationIntentDirectory.matching(SQConversationIntentDirectory.items(), name: string).map(ConversationEntity.init)
    }

    /// Les conversations chiffrées s'ouvrent par leur nom, sans être proposées d'office.
    func suggestedEntities() async throws -> [ConversationEntity] {
        SQConversationIntentDirectory.items().filter { !$0.isEncrypted }.map(ConversationEntity.init)
    }
}

/// Cible d'un message envoyé par Siri ou Raccourcis. Une conversation chiffrée se choisit
/// par son nom sans être proposée d'office ; le texte y est chiffré sur l'appareil (v2).
/// Le nom du type reste celui des raccourcis déjà enregistrés.
struct PlainConversationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = PlainConversationEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ item: SQConversationIntentDirectory.Item) {
        id = item.id
        name = item.name
    }
}

struct PlainConversationEntityQuery: EntityStringQuery {
    func entities(for identifiers: [PlainConversationEntity.ID]) async throws -> [PlainConversationEntity] {
        let items = SQConversationIntentDirectory.items()
        return identifiers.compactMap { id in items.first { $0.id == id }.map(PlainConversationEntity.init) }
    }

    func entities(matching string: String) async throws -> [PlainConversationEntity] {
        SQConversationIntentDirectory.matching(SQConversationIntentDirectory.items(), name: string).map(PlainConversationEntity.init)
    }

    /// Les conversations chiffrées se choisissent par leur nom, sans être proposées d'office.
    func suggestedEntities() async throws -> [PlainConversationEntity] {
        SQConversationIntentDirectory.items().filter { !$0.isEncrypted }.map(PlainConversationEntity.init)
    }
}

/// « Ouvrir une conversation » : la conversation s'ouvre dans la messagerie, par
/// le même chemin qu'une notification.
struct OpenConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir une conversation"
    static let description = IntentDescription("Ouvre une conversation de la messagerie SignalQuest.")
    static let openAppWhenRun = true

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServicesHolder.services.router.route(toConversation: conversation.id)
        return .result()
    }
}

enum SendMessageIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyText
    case signedOut
    case encryptedConversation
    case protectedConversation
    case notSent(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyText:
            return "Le message est vide."
        case .signedOut:
            return "Connecte-toi à SignalQuest pour envoyer un message."
        case .encryptedConversation:
            return "Cette conversation chiffrée s’ouvre dans SignalQuest : ouvre-la pour y écrire."
        case .protectedConversation:
            return "Cette conversation est protégée : ouvre-la dans SignalQuest pour y écrire."
        case .notSent(let reason):
            // Déjà traduit par l'app (raison d'un envoi v2 refusé).
            return LocalizedStringResource(stringLiteral: reason)
        }
    }
}

/// « Envoyer un message » : un texte vers une conversation. Dans une conversation
/// chiffrée v2, il est chiffré sur l'appareil ; une conversation v1 est refusée,
/// sa clé ne s'ouvre que dans l'app.
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Envoyer un message"
    static let description = IntentDescription("Envoie un message texte dans une conversation, chiffré sur l’appareil si elle l’est.")
    static let openAppWhenRun = false

    /// Depuis iOS 17, l'envoi demande de déverrouiller l'appareil : pas de message écran verrouillé.
    @available(iOS 17.0, *)
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Conversation")
    var conversation: PlainConversationEntity

    @Parameter(title: "Message")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SendMessageIntentError.emptyText }
        guard LocalAccountScope.sessionSnapshot() != nil else { throw SendMessageIntentError.signedOut }
        let service = AppServicesHolder.services.messages
        // L'état réel de la conversation, pas celui de l'annuaire local.
        let target = try await service.conversation(id: conversation.id)
        let isV2 = EncryptedConversationSurfaces.isV2(target)
        guard target.e2eeEnabled != true || isV2 else { throw SendMessageIntentError.encryptedConversation }
        // Une conversation protégée ne s'écrit que dans l'app ; une éphémère garde sa durée.
        let policy = await ConversationSecretPolicyCache.resolved(conversationId: target.id, service: service)
        guard policy?.isProtectedFromOutsideApp != true else { throw SendMessageIntentError.protectedConversation }
        let ttlSeconds = policy?.backgroundSendTTLSeconds ?? 0
        if isV2 {
            // Gardé dans la file s'il ne part pas : il revient « Non envoyé » dans le fil.
            let result = await AppServicesHolder.services.sendV2TextOutsideThread(trimmed, to: target, ttlSeconds: ttlSeconds)
            if let failure = EncryptedConversationSurfaces.v2SendFailureMessage(result) {
                throw SendMessageIntentError.notSent(failure)
            }
        } else {
            let clientRequestId = UUID().uuidString
            do {
                _ = try await service.sendText(
                    trimmed, in: target, replyToId: nil, idempotencyKey: clientRequestId, ttlSeconds: ttlSeconds
                )
            } catch where error.isAutoEncryptionRequired {
                // Après la bascule, le serveur refuse le texte en clair : la conversation passe
                // en auto, puis le message part une fois en v2 (E2EE-AUTO §7.2, §8).
                guard let result = await AppServicesHolder.services.resendAfterAutoEncryption(
                    trimmed, conversationId: target.id, ttlSeconds: ttlSeconds, clientRequestId: clientRequestId
                ) else { throw SendMessageIntentError.notSent(E2EEError.autoEncryptionRequired.userFacingMessage) }
                if let failure = EncryptedConversationSurfaces.v2SendFailureMessage(result) {
                    throw SendMessageIntentError.notSent(failure)
                }
            }
        }
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Message envoyé à \(conversation.name).")))
    }
}

/// « Lance un drive test » (lot 5 CarPlay, choix d'Alexandre du 13/11), qui
/// remplace « Ouvrir le Drive Test ».
///
/// CarPlay branché : le trajet démarre sans écran et Siri répond à voix haute,
/// refus compris — en voiture, on ne renvoie personne vers son iPhone. Sans
/// CarPlay, rien ne change (F4) : l'app s'ouvre sur le Drive Test prêt à
/// démarrer, le préflight, la localisation et l'information de collecte
/// passant par l'écran.
struct RunDriveTestIntent: AppIntent {
    static let title: LocalizedStringResource = "Lancer un drive test"
    static let description = IntentDescription("En voiture, lance un drive test sans écran ; sinon, ouvre le Drive Test prêt à démarrer.")
    // L'app ne s'ouvre plus d'office : seulement hors voiture, à la demande.
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServicesHolder.services
        guard services.isCarPlayConnected else {
            try await openDriveTestScreen()
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Le Drive Test est prêt dans SignalQuest.")))
        }
        let answer = DriveTestVoice.start(services: services, isSignedIn: DriveTestVoice.isSignedIn)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }

    @MainActor
    private func openDriveTestScreen() async throws {
        if #available(iOS 26.0, *) {
            try await continueInForeground(nil, alwaysConfirm: false)
        } else if #available(iOS 16.4, *) {
            try await requestToContinueInForeground()
        }
        let router = AppServicesHolder.services.router
        router.selectedTab = .speed
        router.pendingDriveTest = true
    }
}

/// Ouverture de l'app à la demande, hors voiture (iOS 16.4 à 25 ; ensuite
/// `supportedModes`).
@available(iOS 16.4, *)
extension RunDriveTestIntent: ForegroundContinuableIntent {}

/// « Dernier résultat » (plan 3, vague 1) : Siri ou un raccourci donnent le
/// débit du dernier test sans ouvrir l'app. Lu dans l'instantané des widgets,
/// effacé à la déconnexion avec eux (MES-13).
struct LastSpeedtestResultIntent: AppIntent {
    static let title: LocalizedStringResource = "Dernier résultat SignalQuest"
    static let description = IntentDescription("Donne le débit de ton dernier speedtest.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = WidgetSharedStore.lastSpeedtest().map { Self.summary(of: $0, now: Date()) }
            ?? String(localized: "Aucun test pour l’instant. Lance un speedtest dans SignalQuest.")
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }

    /// Débit arrondi à l'entier (lu à voix haute) avec l'unité du design system.
    private static func rate(_ mbps: Double) -> String {
        "\(Int(mbps.rounded())) \(SQUnits.throughputUnit(mbps: mbps))"
    }

    static func summary(of snapshot: SpeedtestWidgetSnapshot, now: Date) -> String {
        var measures = [String(localized: "\(rate(snapshot.downloadMbps)) en réception")]
        if let upload = snapshot.uploadMbps {
            measures.append(String(localized: "\(rate(upload)) en envoi"))
        }
        if let ping = snapshot.pingMs {
            measures.append(String(localized: "latence \(Int(ping.rounded())) ms"))
        }
        let when = RelativeDateTimeFormatter().localizedString(for: snapshot.date, relativeTo: now)
        return String(localized: "Dernier test \(when) sur \(snapshot.network) : \(measures.joined(separator: ", ")).")
    }
}

struct SignalQuestShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunSpeedtestIntent(),
            phrases: [
                "Lance un speedtest avec \(.applicationName)",
                "Teste mon débit avec \(.applicationName)"
            ],
            shortTitle: "Speedtest",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: OpenMapIntent(),
            phrases: [
                "Ouvre la carte \(.applicationName)",
                "Montre les antennes avec \(.applicationName)"
            ],
            shortTitle: "Carte",
            systemImageName: "map"
        )
        AppShortcut(
            intent: OpenMessagesIntent(),
            phrases: [
                "Ouvre la messagerie \(.applicationName)",
                "Ouvre mes messages \(.applicationName)"
            ],
            shortTitle: "Messagerie",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: RunDriveTestIntent(),
            phrases: [
                "Lance un drive test avec \(.applicationName)",
                "Démarre un drive test \(.applicationName)",
                "Ouvre le drive test avec \(.applicationName)"
            ],
            shortTitle: "Drive Test",
            systemImageName: "car.fill"
        )
        // Les deux suivants répondent à voix haute sans ouvrir l'app : ils
        // servent en voiture (lot 5 CarPlay). Avec eux, 10 raccourcis, le
        // plafond d'Apple.
        AppShortcut(
            intent: StopDriveTestIntent(),
            phrases: [
                "Arrête le drive test \(.applicationName)",
                "Arrête le drive test avec \(.applicationName)"
            ],
            shortTitle: "Arrêter le drive test",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: NetworkHereIntent(),
            phrases: [
                "Comment est le réseau ici avec \(.applicationName)",
                "Le réseau ici \(.applicationName)"
            ],
            shortTitle: "Réseau ici",
            systemImageName: "cellularbars"
        )
        AppShortcut(
            intent: LastSpeedtestResultIntent(),
            phrases: [
                "Quel est mon dernier débit \(.applicationName)",
                "Mon dernier speedtest \(.applicationName)"
            ],
            shortTitle: "Dernier résultat",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: [
                "Ouvre une conversation avec \(.applicationName)",
                "Ouvre un message \(.applicationName)"
            ],
            shortTitle: "Conversation",
            systemImageName: "bubble.left"
        )
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: [
                "Envoie un message avec \(.applicationName)",
                "Écris un message \(.applicationName)"
            ],
            shortTitle: "Envoyer un message",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: OpenFollowedAntennaIntent(),
            phrases: [
                "Ouvre une antenne suivie avec \(.applicationName)",
                "Mes antennes suivies \(.applicationName)"
            ],
            shortTitle: "Antenne suivie",
            systemImageName: "star.fill"
        )
    }
}

/// Route en attente posée par un App Intent / Spotlight, consommée par l'app au
/// premier passage au premier plan (même process : `UserDefaults.standard`).
enum SQIntentRoute {
    private static let speedtestKey = "sq.intent.route.speedtest"
    private static let mapKey = "sq.intent.route.map"
    private static let messagesKey = "sq.intent.route.messages"
    private static let driveTestKey = "sq.intent.route.drivetest"

    static func requestSpeedtest() { UserDefaults.standard.set(true, forKey: speedtestKey) }
    static func requestMap() { UserDefaults.standard.set(true, forKey: mapKey) }
    static func requestMessages() { UserDefaults.standard.set(true, forKey: messagesKey) }
    static func requestDriveTest() { UserDefaults.standard.set(true, forKey: driveTestKey) }

    static func consumeSpeedtest() -> Bool { consume(speedtestKey) }
    static func consumeMap() -> Bool { consume(mapKey) }
    static func consumeMessages() -> Bool { consume(messagesKey) }
    static func consumeDriveTest() -> Bool { consume(driveTestKey) }

    private static func consume(_ key: String) -> Bool {
        guard UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.removeObject(forKey: key)
        return true
    }
}
