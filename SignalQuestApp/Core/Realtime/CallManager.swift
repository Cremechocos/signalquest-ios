import Foundation
import CallKit
import PushKit
import AVFAudio
import CryptoKit
import UserNotifications
import Intents
import os

enum CallTerminationAction: String, Codable, Equatable {
    case reject
    case leave
}

struct PendingCallTermination: Codable, Equatable {
    let ownerScopeId: String
    let callId: String
    let action: CallTerminationAction
    let createdAt: Date
}

/// Small account-scoped outbox for a hang-up performed while offline. Call IDs
/// are opaque and bounded; stale entries expire locally even if the server TTL
/// has already closed the room.
final class CallTerminationRetryStore {
    static let maximumAge: TimeInterval = 24 * 60 * 60
    static let maximumCount = 32

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "call-termination-outbox-v1") {
        self.defaults = defaults
        self.key = key
    }

    func enqueue(
        ownerScopeId: String,
        callId: String,
        action: CallTerminationAction,
        now: Date = Date()
    ) {
        guard validOwner(ownerScopeId), validCallId(callId) else { return }
        var records = validRecords(now: now)
        if let existing = records.first(where: {
            $0.ownerScopeId == ownerScopeId && $0.callId == callId
        }) {
            records.removeAll { $0.ownerScopeId == ownerScopeId && $0.callId == callId }
            records.append(.init(
                ownerScopeId: ownerScopeId,
                callId: callId,
                // Once a participant has joined, leave is the only safe replay.
                action: existing.action == .leave || action == .leave ? .leave : .reject,
                createdAt: min(existing.createdAt, now)
            ))
        } else {
            records.append(.init(
                ownerScopeId: ownerScopeId,
                callId: callId,
                action: action,
                createdAt: now
            ))
        }
        persist(Array(records.sorted { $0.createdAt < $1.createdAt }.suffix(Self.maximumCount)))
    }

    func pending(ownerScopeId: String, now: Date = Date()) -> [PendingCallTermination] {
        guard validOwner(ownerScopeId) else { return [] }
        let records = validRecords(now: now)
        persist(records)
        return records.filter { $0.ownerScopeId == ownerScopeId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func remove(ownerScopeId: String, callId: String, now: Date = Date()) {
        persist(validRecords(now: now).filter {
            !($0.ownerScopeId == ownerScopeId && $0.callId == callId)
        })
    }

    private func validRecords(now: Date) -> [PendingCallTermination] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([PendingCallTermination].self, from: data) else {
            return []
        }
        return records.filter {
            validOwner($0.ownerScopeId) && validCallId($0.callId) &&
                $0.createdAt <= now.addingTimeInterval(5 * 60) &&
                now.timeIntervalSince($0.createdAt) <= Self.maximumAge
        }
    }

    private func persist(_ records: [PendingCallTermination]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }

    private func validOwner(_ value: String) -> Bool {
        value.hasPrefix("user:") && value.count > "user:".count
    }

    private func validCallId(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
    }
}

struct CallLifecyclePolicy {
    static let ringingStatuses: Set<String> = ["pending", "ringing"]
    static let maximumParticipants = 8

    static func isRinging(_ status: String?, pending: Bool? = nil) -> Bool {
        // Un transfert vers un nouveau participant garde l'appel global ACTIVE,
        // tout en renvoyant `pending: true` pour ce destinataire.
        if pending == true { return true }
        guard let status else { return false }
        return ringingStatuses.contains(status.lowercased())
    }

    static func terminationAction(
        isOutgoing: Bool,
        isAnswered: Bool,
        serverStatus: String? = nil
    ) -> CallTerminationAction {
        // Dans un groupe, l'appel global devient ACTIVE dès qu'une personne
        // répond, tandis que les autres destinataires peuvent encore sonner.
        // `/reject` n'accepte que RINGING ; un destinataire transféré/encore en
        // sonnerie sur un appel ACTIVE doit donc passer par `/end` (alias leave).
        isOutgoing || isAnswered || serverStatus?.lowercased() == "active" ? .leave : .reject
    }

    static func canStartCall(participantCount: Int) -> Bool {
        (2...maximumParticipants).contains(participantCount)
    }

    /// Mode d'un appel lancé depuis une conversation. Dans une conversation
    /// chiffrée, l'appel n'est chiffré de bout en bout qu'une fois le contrat v2
    /// (époques, cryptor LiveKit) négocié. D'ici là, il part protégé pendant le
    /// transport seulement, jamais en silence : après confirmation, avec la
    /// mention « Appel non chiffré de bout en bout » à l'écran, comme les appels
    /// venus d'Android et du web (décision du 30/09, E2E-02).
    enum OutgoingCallMode: Equatable {
        case standard
        case endToEnd
        case confirmTransportOnly
        /// §10.0 : une conversation v2 n'appelle que chiffré. Tant que l'appel
        /// chiffré n'est pas prêt, il est indisponible, jamais en transport seul.
        case unavailable
    }

    static func outgoingCallMode(conversationE2EE: Bool, conversationV2: Bool, verifiedV2: Bool) -> OutgoingCallMode {
        guard conversationE2EE || conversationV2 else { return .standard }
        if verifiedV2 { return .endToEnd }
        return conversationV2 ? .unavailable : .confirmTransportOnly
    }

    /// Stable mapping so the same backend call cannot create several CallKit
    /// entries when PushKit delivery and foreground reconciliation race.
    static func callKitUUID(callId: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(callId.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // namespace-style UUID version
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Un appel chiffré garde l'époque de son descripteur : l'index de clé des
/// médias n'est pas pilotable sur tous les SDK. Quand la conversation passe à
/// une époque plus récente (membre ou appareil retiré), l'appel prend fin et
/// peut être relancé sous la nouvelle clé (spec §10.3).
enum E2EEV2CallEpochPolicy {
    static func endsCall(
        conversationId: String?,
        callEpochNumber: Int?,
        requiresE2EE: Bool,
        advance: E2EEV2EpochEvents.Advance
    ) -> Bool {
        guard requiresE2EE, let conversationId, conversationId == advance.conversationId,
              let callEpochNumber else { return false }
        return advance.epochNumber > callEpochNumber
    }
}

/// Discrétion d'un appel (spec du chiffrement §10.5, IOS-CALL-5).
enum CallDiscretionPolicy {
    /// Un appel d'une conversation chiffrée ne va pas dans l'historique
    /// d'appels d'iOS, que iCloud synchronise.
    static func isDiscreet(requiresE2EE: Bool?, conversation: CallConversationDirectory.Entry?) -> Bool {
        requiresE2EE == true || conversation?.isEncrypted == true
    }

    /// Nom affiché par CallKit. Pour un appel chiffré de bout en bout, il vient
    /// de l'appareil seul : la notification n'en porte plus, et le serveur ne
    /// doit pas pouvoir le choisir.
    static func displayName(
        payloadName: String?,
        requiresE2EE: Bool?,
        conversation: CallConversationDirectory.Entry?
    ) -> String {
        if requiresE2EE == true { return conversation?.title ?? fallbackName }
        let trimmed = payloadName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? conversation?.title ?? fallbackName : trimmed
    }

    static var fallbackName: String { String(localized: "Appel SignalQuest") }

    /// Décision du 06/10 (spec v0.4.36, §10.5) : les appels chiffrés vont eux
    /// aussi dans les Récents de l'app Téléphone, comme les autres. La discrétion
    /// ne porte plus que sur la notification, sans nom.
    static func includesCallsInRecents(discreet: Bool) -> Bool { true }

    static func configuration(_ base: CXProviderConfiguration, discreet: Bool) -> CXProviderConfiguration {
        base.includesCallsInRecents = includesCallsInRecents(discreet: discreet)
        return base
    }
}

/// Identifiant d'appel vu par CallKit, et donc par les Récents de Téléphone :
/// la conversation, jamais un nom. Le nom affiché passe par `localizedCallerName`.
/// Toucher l'entrée dans Récents rouvre la conversation et relance l'appel.
enum CallRecentsHandle {
    static let prefix = "sq-conversation:"

    static func value(conversationId: String?) -> String? {
        guard let conversationId, !conversationId.isEmpty else { return nil }
        return prefix + conversationId
    }

    static func conversationId(fromHandleValue value: String?) -> String? {
        guard let value, value.hasPrefix(prefix) else { return nil }
        let id = String(value.dropFirst(prefix.count))
        // Même forme que les identifiants opaques du serveur.
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    /// Appui dans Récents : `INStartCallIntent` (iOS 13+), ou ses formes audio/vidéo.
    static func callBack(from activity: NSUserActivity) -> (conversationId: String, video: Bool)? {
        let intent = activity.interaction?.intent
        let contact: INPerson?
        let video: Bool
        if let call = intent as? INStartCallIntent {
            contact = call.contacts?.first
            video = call.callCapability == .videoCall
        } else if let call = intent as? INStartVideoCallIntent {
            contact = call.contacts?.first
            video = true
        } else if let call = intent as? INStartAudioCallIntent {
            contact = call.contacts?.first
            video = false
        } else {
            return nil
        }
        guard let id = conversationId(fromHandleValue: contact?.personHandle?.value) else { return nil }
        return (id, video)
    }
}

enum IncomingCallE2EEExpectation: Equatable {
    case unresolved
    case legacy
    case required(E2EEV2SignedCallDescriptor)
    case invalid

    /// Le serveur peut rendre le chiffrement obligatoire, jamais le retirer :
    /// `/pending` ne fait pas redescendre un appel que sa notification
    /// annonçait chiffré (spec §10.0).
    static func merged(known: Bool?, server: Bool) -> Bool {
        known == true || server
    }

    /// §10.0 : une conversation que cet appareil sait v2 n'accepte que des
    /// appels chiffrés, même si la notification ou le serveur ne le disent pas.
    static func requiresEncryption(announced: Bool?, knownV2: Bool) -> Bool? {
        knownV2 ? true : announced
    }

    /// L'état « v2 » collant (§12) que garde l'appareil, lisible écran
    /// verrouillé après le premier déverrouillage. Illisible, il compte comme
    /// v2 : avant ce premier déverrouillage, aucun appel n'aboutit de toute façon.
    static func knownV2(
        conversationId: String?,
        ownerNamespace: String,
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore()
    ) -> Bool {
        guard let conversationId, !conversationId.isEmpty else { return false }
        return (try? stateStore.isV2(conversationId: conversationId, ownerNamespace: ownerNamespace)) ?? true
    }

    /// Une notification invalide est traitée comme chiffrée : ni son nom ni
    /// l'historique d'appels.
    var requiresE2EE: Bool? {
        switch self {
        case .unresolved: return nil
        case .legacy: return false
        case .required, .invalid: return true
        }
    }
}

enum IncomingCallE2EEContract {
    /// PushKit must be handled synchronously, so the non-secret descriptor is
    /// validated directly from the APNs payload. Older payloads stay
    /// `unresolved` and are authenticated through `/pending` before answer.
    static func parse(_ payload: [AnyHashable: Any]) -> IncomingCallE2EEExpectation {
        let marker = payload["e2eeRequired"] as? Bool
        guard let rawDescriptor = payload["e2eeV2"], !(rawDescriptor is NSNull) else {
            if marker == true { return .invalid }
            return marker == false ? .legacy : .unresolved
        }
        // VoIP : `e2eeV2` en objet (E.4), lu strictement ; sa vérification
        // (appareil, époque, nonce) suit le report à CallKit.
        guard marker != false,
              JSONSerialization.isValidJSONObject(rawDescriptor),
              let data = try? JSONSerialization.data(withJSONObject: rawDescriptor),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let descriptor = E2EEV2SignedCallDescriptor.parse(value) else {
            return .invalid
        }
        return .required(descriptor)
    }
}

/// Bridges SignalQuest calls to the system via CallKit, and receives incoming
/// calls via PushKit VoIP pushes. CallKit gives us the native incoming-call
/// screen (even when the app is backgrounded or the device is locked) and the
/// proper audio-session lifecycle; LiveKit carries the media.
///
/// Backend contract required for end-to-end incoming calls:
///  - `POST /api/user/voip-token` `{ voipToken, platform: "ios" }` to store the
///    VoIP token (separate APNs topic `<bundleid>.voip`).
///  - On call initiation, the server sends a VoIP push whose payload contains at
///    least `callId`/`conversationId`/`caller`/`mode` so we can report it.
/// The outgoing path and the CallKit/LiveKit wiring work without that; only the
/// background incoming ring needs the server VoIP push.
@MainActor
final class CallManager: NSObject, ObservableObject {
    struct ActiveCall: Identifiable, Equatable {
        let id: UUID
        var callId: String?
        let conversationId: String?
        let handle: String
        let hasVideo: Bool
        var isOutgoing: Bool
        var serverStatus: String? = nil
        /// Passe à true quand un appel ENTRANT a été décroché — distingue
        /// « jamais répondu » (reject) de « répondu puis raccroché » (end). CALL-BUG-02.
        var isAnswered: Bool = false
        var isEnding: Bool = false
        /// `nil` means a PushKit wake-up has not yet been reconciled with the
        /// authenticated `/pending` contract. Such a call cannot be answered.
        var requiresE2EE: Bool? = nil
        /// Descripteur signé d'un appel chiffré (D.11) : celui que cet appareil
        /// a signé, ou le premier reçu, vérifié avant de répondre.
        var e2eeDescriptor: E2EEV2SignedCallDescriptor? = nil
        /// Descripteur vérifié pendant sa fenêtre de sonnerie de 60 secondes
        /// (§10.1). Sans elle, la réponse revérifie avec cette fenêtre.
        var ringingVerified = false
    }

    enum CallError: LocalizedError {
        case missingCredentials
        case e2eeUnavailable
        /// Spec §2.6 (v0.4.13) : une clé de l'appel (époque sans aperçu complet,
        /// ou signature sans copie lisible) n'est lisible qu'après le déverrouillage.
        case deviceLocked
        case untrustedE2EESession
        case connectionFailed(String)
        case connectionEnded
        var errorDescription: String? {
            switch self {
            case .missingCredentials: return "Identifiants d'appel manquants."
            case .e2eeUnavailable: return "L’appel chiffré de bout en bout n’est pas disponible sur cet appareil."
            case .deviceLocked: return String(localized: "Déverrouille ton appareil pour rejoindre l’appel chiffré.")
            case .untrustedE2EESession: return "La vérification du chiffrement de l’appel a échoué."
            case .connectionFailed(let m): return String(localized: "Connexion à l'appel impossible : \(m)")
            case .connectionEnded: return String(localized: "L'appel s'est terminé pendant la connexion.")
            }
        }
    }

    /// Fin d'appel à expliquer : l'écran d'appel reste ouvert avec ce message
    /// au lieu de se fermer sans rien dire (SOC-13).
    struct EndNotice: Equatable {
        let title: String
        let message: String?
        let handle: String
        let conversationId: String?
        let hasVideo: Bool
        let requiresE2EE: Bool
    }

    @Published private(set) var activeCall: ActiveCall?
    @Published var showCallScreen = false
    @Published private(set) var endNotice: EndNotice?

    let liveKit = LiveKitClient()

    private let callsService: CallsServicing
    private let api: APIClient
    /// Appels chiffrés v2 (§10) ; nil : aucun appel chiffré ne part ni n'aboutit.
    private let callRuntime: E2EEV2CallRuntime?
    private let pushRegistrar: E2EEV2CallPushRegistrar?
    private let terminationRetryStore: CallTerminationRetryStore
    private let provider: CXProvider
    private let callController = CXCallController()
    private var voipRegistry: PKPushRegistry?
    private var incomingReconciliationTask: Task<Void, Never>?
    private var recentlyTerminatedCallIDs: [String: Date] = [:]
    private var epochObserver: NSObjectProtocol?
    private var pushTokenObserver: NSObjectProtocol?
    private let deviceID = InstallationIdentity().deviceID()
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "CallKit")

    init(
        callsService: CallsServicing,
        api: APIClient,
        callRuntime: E2EEV2CallRuntime? = nil,
        terminationRetryStore: CallTerminationRetryStore = CallTerminationRetryStore()
    ) {
        self.callsService = callsService
        self.api = api
        self.callRuntime = callRuntime
        pushRegistrar = callRuntime == nil ? nil : E2EEV2CallPushRegistrar(api: api)
        self.terminationRetryStore = terminationRetryStore
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // CALL-RTC-01 : quand le média se termine côté distant (l'autre raccroche,
        // room fermée, ou réseau tombé), LiveKit le signale → on clôt l'appel.
        liveKit.onRemoteDisconnect = { [weak self] in self?.handleRemoteDisconnect() }
        liveKit.onE2EETrustLost = { [weak self] reason in self?.handleE2EETrustLost(reason) }
        // Un nouveau jeton APNs fait repartir l'enregistrement des jetons v2.
        pushTokenObserver = NotificationCenter.default.addObserver(
            forName: E2EEV2CallPushTokens.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let registrar = self?.pushRegistrar else { return }
                Task { await registrar.register(voipToken: nil) }
            }
        }
        epochObserver = NotificationCenter.default.addObserver(
            forName: E2EEV2EpochEvents.didAdvance, object: nil, queue: .main
        ) { [weak self] note in
            // `Notification` n'est pas Sendable : on en extrait la valeur avant
            // de passer sur le MainActor.
            guard let advance = E2EEV2EpochEvents.advance(from: note) else { return }
            Task { @MainActor in self?.handleEpochAdvance(advance) }
        }
    }

    /// Registers for VoIP pushes. Safe to call multiple times.
    func registerForVoIPPushes() {
        guard voipRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }

    // MARK: Outgoing

    /// Un appel chiffré peut partir d'ici : verrou d'appels ouvert, conversation
    /// v2 et clé de son époque courante vérifiée (§10.0).
    func canStartEncryptedCall(conversationId: String) -> Bool {
        callRuntime?.canStart(conversationId: conversationId) ?? false
    }

    func startOutgoingCall(
        conversationId: String,
        mode: String,
        displayName: String,
        requiresE2EE: Bool = false,
        isEncryptedConversation: Bool = false
    ) {
        guard activeCall == nil else { return }
        // §10.0 : une conversation que cet appareil sait v2 n'appelle que
        // chiffré, quoi que dise le serveur ou l'écran qui relance l'appel.
        let requiresE2EE = requiresE2EE || (LocalAccountScope.currentUserId != nil && IncomingCallE2EEExpectation.knownV2(
            conversationId: conversationId, ownerNamespace: LocalAccountScope.storageNamespace
        ))
        updateDiscretion(isEncryptedConversation || CallDiscretionPolicy.isDiscreet(
            requiresE2EE: requiresE2EE,
            conversation: knownConversation(conversationId)
        ))
        endNotice = nil
        liveKit.prepareForCall()
        let uuid = UUID()
        let hasVideo = mode.lowercased() == "video"
        activeCall = ActiveCall(
            id: uuid,
            callId: nil,
            conversationId: conversationId,
            handle: displayName,
            hasVideo: hasVideo,
            isOutgoing: true,
            requiresE2EE: requiresE2EE
        )
        showCallScreen = true
        let action = CXStartCallAction(
            call: uuid,
            handle: CXHandle(type: .generic, value: CallRecentsHandle.value(conversationId: conversationId) ?? displayName)
        )
        action.isVideo = hasVideo
        callController.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.activeCall?.id == uuid else { return }
                self.logger.error("startCall request failed: \(error.localizedDescription, privacy: .public)")
                await self.tearDown(notice: self.failureNotice(
                    message: String(localized: "L’appel n’a pas pu démarrer. Réessaie dans un instant.")
                ))
            }
        }
    }

    /// User taps hang-up in the in-app call screen.
    func endActiveCall() {
        guard let call = activeCall else {
            endNotice = nil
            showCallScreen = false
            return
        }
        guard !call.isEnding else { return }
        activeCall?.isEnding = true
        let action = CXEndCallAction(call: call.id)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    guard let self else { return }
                    self.logger.error("endCall request failed: \(error.localizedDescription, privacy: .public)")
                    if let call = self.activeCall { await self.notifyBackendCallTerminated(call) }
                    await self.tearDown()
                }
            }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let call = activeCall else { return }
        let action = CXSetMutedCallAction(call: call.id, muted: muted)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    /// Réduit l'écran d'appel : l'appel continue, un bandeau permet d'y revenir.
    func minimizeCallScreen() {
        guard activeCall != nil else { return }
        showCallScreen = false
    }

    func restoreCallScreen() {
        guard let call = activeCall, call.isOutgoing || call.isAnswered else { return }
        showCallScreen = true
    }

    func dismissEndNotice() {
        endNotice = nil
        if activeCall == nil { showCallScreen = false }
    }

    /// « Rappeler » depuis l'écran de fin : même conversation, même mode.
    func redial() {
        guard activeCall == nil, let notice = endNotice, let conversationId = notice.conversationId else { return }
        startOutgoingCall(
            conversationId: conversationId,
            mode: notice.hasVideo ? "video" : "audio",
            displayName: notice.handle,
            requiresE2EE: notice.requiresE2EE
        )
    }

    #if DEBUG
    func presentQAEndNotice() {
        guard activeCall == nil else { return }
        endNotice = EndNotice(
            title: String(localized: "Pas de réponse"),
            message: nil,
            handle: "Camille",
            conversationId: "qa-conversation",
            hasVideo: false,
            requiresE2EE: false
        )
        showCallScreen = true
    }
    #endif

    /// Texte montré quand un appel échoue. Jamais le message brut du transport
    /// ni son nom : « Erreur : could not establish pc connection » (SOC-13).
    nonisolated static func failureMessage(for error: Error) -> String? {
        if error.isCancellation { return nil }
        if let callError = error as? CallError {
            switch callError {
            case .e2eeUnavailable, .untrustedE2EESession:
                return String(localized: "La vérification du chiffrement de l’appel a échoué. Aucun appel n’a été passé.")
            case .deviceLocked:
                return String(localized: "Appel chiffré manqué : ton appareil est resté verrouillé.")
            case .connectionEnded:
                return String(localized: "L’appel s’est terminé pendant la connexion.")
            case .missingCredentials, .connectionFailed:
                return String(localized: "Connexion à l’appel impossible. Vérifie ta connexion et réessaie.")
            }
        }
        return error.userFacingMessage
    }

    private func failureNotice(for error: Error) -> EndNotice? {
        guard let message = Self.failureMessage(for: error) else { return nil }
        return failureNotice(message: message)
    }

    private func failureNotice(message: String) -> EndNotice? {
        guard let call = activeCall else { return nil }
        return EndNotice(
            title: String(localized: "Appel impossible"),
            message: message,
            handle: call.handle,
            conversationId: call.conversationId,
            hasVideo: call.hasVideo,
            // Reçu ou passé : « Rappeler » ne retire jamais le chiffrement.
            requiresE2EE: call.requiresE2EE == true
        )
    }

    // MARK: Discrétion

    /// Conversation connue sur l'appareil, pour le nom et la discrétion d'un appel.
    private func knownConversation(_ conversationId: String?) -> CallConversationDirectory.Entry? {
        guard let conversationId, LocalAccountScope.currentUserId != nil else { return nil }
        return CallConversationDirectory.shared.entry(
            conversationId: conversationId,
            ownerScopeId: LocalAccountScope.currentOwnerScopeId
        )
    }

    /// Réglé avant de présenter un appel, gardé jusqu'au suivant. Pendant un
    /// appel, sa discrétion n'est jamais relâchée par un second appel refusé.
    private func updateDiscretion(_ discreet: Bool) {
        guard activeCall == nil || discreet else { return }
        let configuration = provider.configuration
        guard configuration.includesCallsInRecents != CallDiscretionPolicy.includesCallsInRecents(discreet: discreet) else { return }
        provider.configuration = CallDiscretionPolicy.configuration(configuration, discreet: discreet)
    }

    // MARK: Incoming

    /// Retire la notification de sonnerie d'un appel (`type: call_incoming`),
    /// tout de suite puis deux fois encore : elle peut arriver après la VoIP.
    nonisolated static func clearRingNotifications(callId: String) {
        let clear: @Sendable () -> Void = {
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { delivered in
                let ids = delivered
                    .filter { isRingNotification($0.request.content.userInfo, callId: callId) }
                    .map(\.request.identifier)
                if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            }
        }
        clear()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: clear)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: clear)
    }

    nonisolated static func isRingNotification(_ userInfo: [AnyHashable: Any], callId: String) -> Bool {
        (userInfo["type"] as? String) == "call_incoming" && (userInfo["callId"] as? String) == callId
    }

    private func reportInvalidIncomingPush(
        uuid: UUID,
        handle: String,
        hasVideo: Bool,
        completion: (() -> Void)?
    ) {
        updateDiscretion(true)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = handle
        update.hasVideo = hasVideo
        let completionBox = UnsafeMainActorBox(value: completion)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor in
                if let errorMessage {
                    self?.logger.error("invalid incoming payload report failed: \(errorMessage, privacy: .public)")
                } else {
                    self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                }
                completionBox.value?()
            }
        }
    }

    func reportIncomingCall(
        uuid: UUID,
        callId: String?,
        conversationId: String?,
        handle: String,
        hasVideo: Bool,
        serverStatus: String? = nil,
        requiresE2EE: Bool? = nil,
        e2eeDescriptor: E2EEV2SignedCallDescriptor? = nil,
        completion: (() -> Void)?
    ) {
        let conversation = knownConversation(conversationId)
        let announced = requiresE2EE
        let requiresE2EE = IncomingCallE2EEExpectation.requiresEncryption(
            announced: announced,
            knownV2: LocalAccountScope.currentUserId != nil && IncomingCallE2EEExpectation.knownV2(
                conversationId: conversationId, ownerNamespace: LocalAccountScope.storageNamespace
            )
        )
        // Un appel que la notification ne disait pas chiffré prend lui aussi son
        // nom sur l'appareil.
        let handle = requiresE2EE == true && announced != true
            ? CallDiscretionPolicy.displayName(payloadName: handle, requiresE2EE: true, conversation: conversation)
            : handle
        updateDiscretion(CallDiscretionPolicy.isDiscreet(
            requiresE2EE: requiresE2EE,
            conversation: conversation
        ))
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: CallRecentsHandle.value(conversationId: conversationId) ?? handle)
        update.localizedCallerName = handle
        update.hasVideo = hasVideo
        let completionBox = UnsafeMainActorBox(value: completion)

        // CallKit sonne : la notification « Appel entrant » du même appel, envoyée
        // en secours, ferait doublon.
        if let callId { Self.clearRingNotifications(callId: callId) }

        // Une push APNs peut arriver après un refus/raccrochage déjà traité.
        // Elle doit toujours être reportée à CallKit (contrat PushKit), puis
        // clôturée immédiatement sans recréer l'état applicatif ni une sonnerie.
        if let callId, wasRecentlyTerminated(callId) {
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    if let errorMessage {
                        self?.logger.error("stale incoming report failed: \(errorMessage, privacy: .public)")
                    } else {
                        self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .declinedElsewhere)
                    }
                    completionBox.value?()
                }
            }
            return
        }

        // PushKit peut relivrer le même appel alors que la réconciliation HTTP l'a
        // déjà présenté. On réutilise le même UUID CallKit, sans créer un second
        // appel système ni remplacer l'état actif.
        if let current = activeCall, let callId, current.callId == callId {
            provider.reportNewIncomingCall(with: current.id, update: update) { [weak self] error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    if let errorMessage {
                        self?.logger.error("duplicate incoming report failed: \(errorMessage, privacy: .public)")
                    }
                    completionBox.value?()
                }
            }
            return
        }

        // CALL-RTC-04 : un appel est déjà actif → on NE touche PAS activeCall ni la
        // session LiveKit en cours. On satisfait quand même l'exigence PushKit (tout
        // push VoIP doit être suivi d'un reportNewIncomingCall, sinon l'app est tuée)
        // puis on décline immédiatement le nouvel UUID, sans impacter l'appel courant.
        if activeCall != nil {
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor in
                    if let errorMessage {
                        self?.logger.error("2nd reportNewIncomingCall failed: \(errorMessage, privacy: .public)")
                    } else {
                        self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .declinedElsewhere)
                    }
                    // PushKit doit être libéré dès que le report CallKit est
                    // terminé. La requête HTTP de refus est best-effort et ne doit
                    // jamais retenir le watchdog système.
                    completionBox.value?()
                    if let self, let callId {
                        await self.notifyBackendCallTerminated(
                            callId: callId,
                            action: CallLifecyclePolicy.terminationAction(
                                isOutgoing: false,
                                isAnswered: false,
                                serverStatus: serverStatus
                            )
                        )
                    }
                }
            }
            return
        }

        // Un appel reçu remplace l'écran de fin d'un appel précédent.
        if endNotice != nil {
            endNotice = nil
            showCallScreen = false
        }
        activeCall = ActiveCall(
            id: uuid,
            callId: callId,
            conversationId: conversationId,
            handle: handle,
            hasVideo: hasVideo,
            isOutgoing: false,
            serverStatus: serverStatus?.lowercased(),
            requiresE2EE: requiresE2EE,
            e2eeDescriptor: e2eeDescriptor
        )
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            let errorMessage = error?.localizedDescription
            Task { @MainActor in
                if let errorMessage {
                    // Échec du report du SEUL nouvel appel : nettoyage local (aucun
                    // appel n'était actif avant), pas de teardown d'une autre room.
                    self?.logger.error("reportNewIncomingCall failed: \(errorMessage, privacy: .public)")
                    self?.activeCall = nil
                    self?.showCallScreen = false
                    completionBox.value?()
                    if let self, let callId {
                        await self.notifyBackendCallTerminated(
                            callId: callId,
                            action: CallLifecyclePolicy.terminationAction(
                                isOutgoing: false,
                                isAnswered: false,
                                serverStatus: serverStatus
                            )
                        )
                    }
                } else if let callId {
                    self?.startIncomingReconciliation(callId: callId)
                    completionBox.value?()
                    self?.verifyRinging(callId: callId)
                } else {
                    completionBox.value?()
                }
            }
        }
    }

    /// CALL-INCOMING-03 : filet anti-perte de push VoIP. À appeler au retour au premier
    /// plan (et après login) : demande au serveur les appels en attente et, si un appel
    /// « ringing »/« pending » n'est pas déjà actif, le présente via CallKit.
    func reconcilePendingIncomingCall() async {
        await retryPendingCallTerminations()
        let pending: [CallSession]
        do {
            pending = try await callsService.pending()
        } catch {
            logger.error("pending call reconciliation failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let call = pending.first(where: {
            CallLifecyclePolicy.isRinging($0.status, pending: $0.isPending)
        })

        if let active = activeCall {
            guard !active.isOutgoing, !active.isAnswered, !active.isEnding else { return }
            if let call {
                if call.id == active.callId {
                    // Un autre membre du groupe peut avoir répondu : l'appel global
                    // passe alors ACTIVE pendant que cet appareil sonne encore. On
                    // conserve ce statut pour choisir leave plutôt que reject.
                    activeCall?.serverStatus = call.status?.lowercased()
                    activeCall?.requiresE2EE = IncomingCallE2EEExpectation.merged(
                        known: active.requiresE2EE, server: call.e2eeRequired
                    )
                    // Le premier descripteur reçu reste : un autre est refusé à la réponse.
                    if active.e2eeDescriptor == nil, let descriptor = call.e2eeV2 {
                        activeCall?.e2eeDescriptor = descriptor
                        verifyRinging(callId: call.id)
                    }
                    return
                }
                // `/pending` ne renvoie qu'un appel (le plus récent). Si un second
                // appel arrive sans push pendant que CallKit sonne déjà, décliner
                // ce nouveau call plutôt que de supprimer arbitrairement l'appel
                // système courant. Le prochain poll retrouvera l'appel initial.
                await notifyBackendCallTerminated(
                    callId: call.id,
                    action: CallLifecyclePolicy.terminationAction(
                        isOutgoing: false,
                        isAnswered: false,
                        serverStatus: call.status
                    )
                )
                return
            }
            // L'appel n'est plus en attente côté serveur : annulé par l'appelant,
            // refusé/répondu sur un autre appareil ou expiré. Fermer CallKit évite
            // une sonnerie fantôme.
            reportCallEnded(active.id, reason: .remoteEnded)
            await tearDown()
            return
        }

        guard let call, !wasRecentlyTerminated(call.id) else { return }
        reportIncomingCall(
            uuid: CallLifecyclePolicy.callKitUUID(callId: call.id),
            callId: call.id,
            conversationId: call.conversationId,
            handle: CallDiscretionPolicy.displayName(
                payloadName: call.displayName ?? call.participants?.first,
                requiresE2EE: call.e2eeRequired,
                conversation: knownConversation(call.conversationId)
            ),
            hasVideo: call.mode == "video",
            serverStatus: call.status,
            requiresE2EE: call.e2eeRequired,
            e2eeDescriptor: call.e2eeV2,
            completion: nil
        )
    }

    // MARK: Internals

    /// Se connecte au média LiveKit ET vérifie le succès. CALL-BUG-01 : on lève si les
    /// identifiants manquent ou si LiveKit termine en `.failed`, pour que l'appelant
    /// échoue proprement l'action CallKit au lieu de marquer l'appel « connecté ».
    private func connectLiveKit(for session: CallSession, video: Bool) async throws {
        guard let url = session.liveKitUrl, let token = session.liveKitToken, let room = session.liveKitRoom else {
            logger.error("Call session missing LiveKit credentials")
            throw CallError.missingCredentials
        }
        let e2eeSession: E2EEV2LiveKitSession?
        if session.e2eeRequired {
            // Le descripteur de la réponse est celui vérifié ou signé ici, à l'octet.
            guard let descriptor = session.e2eeV2, descriptor == activeCall?.e2eeDescriptor,
                  descriptor.descriptor.conversationId == activeCall?.conversationId,
                  let callRuntime else {
                throw CallError.untrustedE2EESession
            }
            do {
                e2eeSession = try await callRuntime.liveKitSession(for: descriptor, liveKitURL: url)
            } catch E2EEV2CallRuntime.SessionFailure.deviceLocked {
                throw CallError.deviceLocked
            } catch E2EEV2CallRuntime.SessionFailure.runtimeClosed {
                throw CallError.e2eeUnavailable
            } catch {
                throw CallError.untrustedE2EESession
            }
        } else {
            guard activeCall?.requiresE2EE != true else {
                throw CallError.untrustedE2EESession
            }
            e2eeSession = nil
        }
        await liveKit.connect(
            url: url,
            token: token,
            room: room,
            video: video,
            managesAudioSession: false,
            e2eeSession: e2eeSession
        )
        if case .failed(let message) = liveKit.state {
            logger.error("LiveKit connect failed: \(message, privacy: .public)")
            throw CallError.connectionFailed(message)
        }
        guard liveKit.state == .connected else { throw CallError.connectionEnded }
    }

    /// Descripteur signé ici pour un appel sortant chiffré (§10.1).
    private func outgoingDescriptor(for call: ActiveCall) throws -> E2EEV2SignedCallDescriptor? {
        guard call.requiresE2EE == true else { return nil }
        guard let conversationId = call.conversationId, let callRuntime else { throw CallError.e2eeUnavailable }
        switch callRuntime.prepareOutgoing(conversationId: conversationId) {
        case .prepared(let descriptor): return descriptor
        case .runtimeClosed, .localEpochUnavailable: throw CallError.e2eeUnavailable
        case .deviceLocked: throw CallError.deviceLocked
        }
    }

    /// Initiation d'un appel chiffré : une époque remplacée entre-temps ou un
    /// identifiant déjà pris font signer un nouveau descripteur, une fois.
    private func initiate(_ call: ActiveCall, conversationId: String) async throws -> CallSession {
        let mode = call.hasVideo ? "video" : "audio"
        var descriptor = try outgoingDescriptor(for: call)
        activeCall?.e2eeDescriptor = descriptor
        do {
            return try await callsService.initiate(conversationId: conversationId, mode: mode, e2ee: descriptor)
        } catch CallsServiceError.refused(let code)
            where descriptor != nil && ["E2EE_EPOCH_STALE", "CALL_ID_TAKEN", "CALL_NONCE_TAKEN"].contains(code) {
            if code == "E2EE_EPOCH_STALE" { await callRuntime?.synchronize(conversationId: conversationId) }
            guard let current = activeCall, current.id == call.id, !current.isEnding else { throw CallError.connectionEnded }
            descriptor = try outgoingDescriptor(for: current)
            activeCall?.e2eeDescriptor = descriptor
            return try await callsService.initiate(conversationId: conversationId, mode: mode, e2ee: descriptor)
        }
    }

    /// Sonnerie d'un appel chiffré : son descripteur est vérifié (§10.1) dès
    /// qu'il est connu. Refusé, l'appel ne sonne plus et le serveur l'apprend.
    private func verifyRinging(callId: String) {
        guard let call = activeCall, call.callId == callId, !call.isOutgoing,
              let descriptor = call.e2eeDescriptor, let conversationId = call.conversationId,
              let callRuntime else { return }
        Task { [weak self] in
            let verification = await callRuntime.verify(descriptor, conversationId: conversationId, callId: callId, ringing: true)
            guard let self, let current = self.activeCall, current.callId == callId,
                  current.e2eeDescriptor == descriptor, !current.isEnding else { return }
            if case .verified = verification { self.activeCall?.ringingVerified = true }
            guard !current.isAnswered else { return }
            switch verification {
            case .verified:
                return
            case .unavailable:
                // Appareils ou conversation illisibles pour l'instant : la
                // réponse revérifie, et refuse si rien n'a changé.
                return
            case .refused(let failure):
                self.logger.error("encrypted call descriptor refused: \(String(describing: failure), privacy: .public)")
                self.activeCall?.isEnding = true
                self.reportCallEnded(current.id, reason: .failed)
                await self.notifyBackendCallTerminated(current)
                await self.tearDown()
            }
        }
    }

    private func reconcileE2EEForAnswer(_ call: ActiveCall) async throws -> ActiveCall {
        guard let callId = call.callId else { throw CallError.missingCredentials }
        let serverCall = try await callsService.pending().first(where: { $0.id == callId })
        guard let serverCall else { throw CallError.connectionEnded }
        // Relu après la réponse du serveur : un appel terminé entre-temps n'est
        // jamais ressuscité, et une fin en cours n'est jamais effacée.
        guard var reconciled = activeCall, reconciled.callId == callId, !reconciled.isEnding else {
            throw CallError.connectionEnded
        }
        reconciled.serverStatus = serverCall.status?.lowercased()
        reconciled.requiresE2EE = IncomingCallE2EEExpectation.merged(
            known: reconciled.requiresE2EE, server: serverCall.e2eeRequired
        )
        // Jamais un autre descripteur que celui déjà reçu pour cet appel.
        if let known = reconciled.e2eeDescriptor, let served = serverCall.e2eeV2, known != served {
            throw CallError.untrustedE2EESession
        }
        reconciled.e2eeDescriptor = reconciled.e2eeDescriptor ?? serverCall.e2eeV2
        activeCall = reconciled
        return reconciled
    }

    /// Avant de répondre à un appel chiffré, son descripteur est revérifié
    /// (§10.1) : appareil appelant, époque, nonce. Vrai pour un appel chiffré.
    private func verifiedForAnswer(_ call: ActiveCall, callId: String) async throws -> Bool {
        guard call.requiresE2EE == true else {
            guard call.requiresE2EE == false, call.e2eeDescriptor == nil else {
                throw CallError.untrustedE2EESession
            }
            return false
        }
        guard let conversationId = call.conversationId, let descriptor = call.e2eeDescriptor else {
            throw CallError.untrustedE2EESession
        }
        guard let callRuntime else { throw CallError.e2eeUnavailable }
        // La fenêtre de 12 heures ne vaut qu'après une sonnerie vérifiée dans
        // ses 60 secondes : jamais pour un descripteur qui ne l'a pas été.
        switch await callRuntime.verify(
            descriptor, conversationId: conversationId, callId: callId, ringing: !call.ringingVerified
        ) {
        case .verified:
            if activeCall?.callId == callId { activeCall?.ringingVerified = true }
            return true
        case .unavailable: throw CallError.e2eeUnavailable
        case .refused: throw CallError.untrustedE2EESession
        }
    }

    private func answerOnce(_ call: ActiveCall, callId: String) async throws -> CallSession {
        let encrypted = try await verifiedForAnswer(call, callId: callId)
        return try await callsService.answer(callId: callId, e2ee: encrypted)
    }

    /// Verrouillé : la clé de l'époque (aperçu qui n'est pas complet) ou la clé
    /// de signature (pas encore de copie lisible) attend le déverrouillage.
    nonisolated static func waitsForUnlock(_ error: Error) -> Bool {
        if case CallError.deviceLocked = error { return true }
        if case CallsServiceError.e2eeUnavailable(let reason) = error { return reason == "e2ee-device-locked" }
        return false
    }

    private func isStillAnswering(_ callId: String?) -> Bool {
        callId != nil && activeCall?.callId == callId && activeCall?.isEnding == false
    }

    /// On attend le déverrouillage tant que cet appel sonne encore ; l'écran de
    /// CallKit, seul visible téléphone verrouillé, et une notification le disent.
    private func waitForUnlockToAnswer(_ call: ActiveCall) async throws {
        let identifier = "e2ee-call-unlock-\(call.id.uuidString)"
        showUnlockHint(for: call, waiting: true)
        CallUnlockPrompt.show(identifier: identifier)
        defer {
            CallUnlockPrompt.dismiss(identifier: identifier)
            showUnlockHint(for: call, waiting: false)
        }
        let unlocked = await CallUnlockPrompt.waitForUnlock(stillWanted: { self.isStillAnswering(call.callId) })
        guard unlocked, isStillAnswering(call.callId) else { throw CallError.deviceLocked }
    }

    private func showUnlockHint(for call: ActiveCall, waiting: Bool) {
        guard activeCall?.id == call.id else { return }
        let update = CXCallUpdate()
        update.localizedCallerName = waiting
            ? String(localized: "\(call.handle) · Déverrouille pour rejoindre")
            : call.handle
        provider.reportCall(with: call.id, updated: update)
    }

    private func tearDown(notice: EndNotice? = nil) async {
        incomingReconciliationTask?.cancel()
        incomingReconciliationTask = nil
        if let callId = activeCall?.callId { markRecentlyTerminated(callId) }
        await liveKit.disconnect()
        activeCall = nil
        // Avec un message, l'écran reste ouvert sur la fin d'appel (SOC-13).
        endNotice = notice
        showCallScreen = notice != nil
    }

    /// CALL-RTC-02 : retire de CallKit un appel déjà rapporté quand la fin n'est
    /// PAS pilotée par un CXEndCallAction (échec de connexion média, fin distante).
    /// À NE PAS appeler depuis providerDidReset (provider déjà purgé) ni après un
    /// CXEndCallAction (action.fulfill() suffit).
    private func reportCallEnded(_ id: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: id, endedAt: Date(), reason: reason)
    }

    /// Notifie le backend de la fin de l'appel — best-effort, sémantique reject vs
    /// end alignée sur CALL-BUG-02 (entrant jamais décroché = reject ; sortant ou
    /// décroché = end). Réutilisé par CXEndCallAction et providerDidReset.
    private func notifyBackendCallTerminated(_ call: ActiveCall) async {
        guard let callId = call.callId else { return }
        await notifyBackendCallTerminated(
            callId: callId,
            action: CallLifecyclePolicy.terminationAction(
                isOutgoing: call.isOutgoing,
                isAnswered: call.isAnswered,
                serverStatus: call.serverStatus
            )
        )
    }

    private func notifyBackendCallTerminated(
        callId: String,
        action: CallTerminationAction
    ) async {
        markRecentlyTerminated(callId)
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        do {
            try await performBackendCallTermination(callId: callId, action: action)
            terminationRetryStore.remove(ownerScopeId: ownerScopeId, callId: callId)
        } catch {
            terminationRetryStore.enqueue(
                ownerScopeId: ownerScopeId,
                callId: callId,
                action: action
            )
            logger.error("backend call termination failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performBackendCallTermination(
        callId: String,
        action: CallTerminationAction
    ) async throws {
        switch action {
        case .reject:
            do {
                try await callsService.reject(callId: callId)
            } catch {
                // The global call can race from RINGING to ACTIVE. `/end` is an
                // idempotent participant leave in both states.
                try await callsService.end(callId: callId)
            }
        case .leave:
            try await callsService.end(callId: callId)
        }
    }

    func retryPendingCallTerminations() async {
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        for record in terminationRetryStore.pending(ownerScopeId: ownerScopeId) {
            do {
                try await performBackendCallTermination(
                    callId: record.callId,
                    action: record.action
                )
                terminationRetryStore.remove(ownerScopeId: ownerScopeId, callId: record.callId)
            } catch {
                logger.error("call termination replay failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    /// CALL-RTC-01/02 : le média s'est terminé côté distant (l'autre a raccroché,
    /// room fermée, réseau tombé). On clôt l'appel CallKit natif (reportCall) puis
    /// on nettoie. On NE rappelle PAS le backend : le distant a déjà clos la session.
    private func handleRemoteDisconnect() {
        guard let call = activeCall else { return }
        // Personne n'a décroché (refus, sonnerie écoulée) : on le dit au lieu
        // de fermer l'écran comme si l'appel avait eu lieu (SOC-13).
        let unanswered = call.isOutgoing && liveKit.remoteJoinedAt == nil
        let notice = unanswered ? EndNotice(
            title: String(localized: "Pas de réponse"),
            message: nil,
            handle: call.handle,
            conversationId: call.conversationId,
            hasVideo: call.hasVideo,
            requiresE2EE: call.requiresE2EE == true
        ) : nil
        reportCallEnded(call.id, reason: unanswered ? .unanswered : .remoteEnded)
        Task {
            await notifyBackendCallTerminated(call)
            await tearDown(notice: notice)
        }
    }

    /// La conversation a changé de clé pendant un appel chiffré : il prend fin,
    /// et « Rappeler » le relance sous la nouvelle époque (spec §10.3).
    private func handleEpochAdvance(_ advance: E2EEV2EpochEvents.Advance) {
        guard let call = activeCall, !call.isEnding,
              advance.ownerNamespace == LocalAccountScope.storageNamespace,
              E2EEV2CallEpochPolicy.endsCall(
                  conversationId: call.conversationId,
                  callEpochNumber: call.e2eeDescriptor?.descriptor.epochNumber,
                  requiresE2EE: call.requiresE2EE == true,
                  advance: advance
              ) else { return }
        activeCall?.isEnding = true
        reportCallEnded(call.id, reason: .failed)
        let notice = EndNotice(
            title: String(localized: "Appel terminé"),
            message: String(localized: "L’appel a pris fin : la conversation a changé de clé."),
            handle: call.handle,
            conversationId: call.conversationId,
            hasVideo: call.hasVideo,
            requiresE2EE: true
        )
        // Le média s'arrête avant tout aller-retour réseau.
        Task {
            await tearDown(notice: notice)
            await notifyBackendCallTerminated(call)
        }
    }

    private func handleE2EETrustLost(_ reason: E2EEV2CallTrustLoss) {
        guard let call = activeCall, !call.isEnding else { return }
        activeCall?.isEnding = true
        reportCallEnded(call.id, reason: .failed)
        let notice: EndNotice?
        switch reason {
        case .verification:
            notice = failureNotice(message: String(localized: "L’appel a été coupé : la vérification du chiffrement a échoué."))
        case .joinProof:
            // Spec §10.4 : un participant sans preuve de jonction valide.
            notice = EndNotice(
                title: String(localized: "Appel chiffré impossible"),
                message: String(localized: "Un participant n’a pas pu prouver l’appareil avec lequel il a rejoint l’appel."),
                handle: call.handle,
                conversationId: call.conversationId,
                hasVideo: call.hasVideo,
                requiresE2EE: call.isOutgoing && call.requiresE2EE == true
            )
        case .reconnected:
            notice = EndNotice(
                title: String(localized: "Appel interrompu"),
                message: String(localized: "La connexion a été rétablie, mais un appel chiffré ne reprend pas après une reconnexion complète. Rappelle pour continuer."),
                handle: call.handle,
                conversationId: call.conversationId,
                hasVideo: call.hasVideo,
                requiresE2EE: call.isOutgoing && call.requiresE2EE == true
            )
        }
        // Le média s'arrête avant tout aller-retour réseau.
        Task {
            await tearDown(notice: notice)
            await notifyBackendCallTerminated(call)
        }
    }

    private func startIncomingReconciliation(callId: String) {
        incomingReconciliationTask?.cancel()
        incomingReconciliationTask = Task { [weak self] in
            // Le backend expire les sonneries à 45 s. Une vérification toutes les
            // trois secondes suffit à retirer rapidement une réponse autre appareil
            // sans polling agressif.
            for _ in 0..<15 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self,
                      self.activeCall?.callId == callId,
                      self.activeCall?.isAnswered == false else { return }
                await self.reconcilePendingIncomingCall()
            }

            // Même si `/pending` reste bloqué sur `ringing` (ou si son expiration
            // serveur dérive), CallKit ne doit jamais sonner indéfiniment. La
            // fenêtre produit/backend est de 45 s : on clôt localement et on
            // rejoue un reject best-effort, idempotent pour l'utilisateur.
            guard let self,
                  let call = self.activeCall,
                  call.callId == callId,
                  !call.isAnswered,
                  !call.isEnding else { return }
            self.activeCall?.isEnding = true
            self.reportCallEnded(call.id, reason: .unanswered)
            await self.notifyBackendCallTerminated(call)
            await self.tearDown()
        }
    }

    private func markRecentlyTerminated(_ callId: String) {
        let now = Date()
        recentlyTerminatedCallIDs = recentlyTerminatedCallIDs.filter { now.timeIntervalSince($0.value) < 90 }
        recentlyTerminatedCallIDs[callId] = now
        // Sur le disque aussi : un appel chiffré terminé ne se rejoint plus (v0.4.6).
        E2EEV2CallNonceLedger.shared.markTerminated(callId: callId, nowMs: Int64(now.timeIntervalSince1970 * 1_000))
    }

    private func wasRecentlyTerminated(_ callId: String) -> Bool {
        guard let date = recentlyTerminatedCallIDs[callId] else { return false }
        if Date().timeIntervalSince(date) < 90 { return true }
        recentlyTerminatedCallIDs[callId] = nil
        return false
    }

    private var lastVoipToken: String?
    /// CALL-VOIP-07 : vrai uniquement quand le dernier POST du token VoIP a
    /// échoué. On ne retente alors qu'au prochain foreground OU au retour réseau,
    /// au lieu de re-POSTer inutilement un token déjà synchronisé.
    private var voipTokenNeedsSync = false

    fileprivate func registerVoIPToken(_ token: String) async {
        lastVoipToken = token
        do {
            let _: SuccessResponse = try await api.requestJSON(
                "/api/user/voip-token",
                body: [
                    "voipToken": token,
                    "platform": "ios",
                    "deviceId": deviceID,
                    "environment": api.config.environment.rawValue,
                ]
            )
            voipTokenNeedsSync = false
        } catch {
            // CALL-VOIP-04 : ne plus avaler l'échec silencieusement ; on marque le
            // token à resynchroniser et on le garde pour le ré-enregistrer au
            // prochain passage authentifié / foreground / retour réseau.
            voipTokenNeedsSync = true
            logger.error("VoIP token registration failed: \(error.localizedDescription, privacy: .public)")
        }
        // Appareil v2 : jetons liés à l'appareil, et session liée à lui (E.1).
        await pushRegistrar?.register(voipToken: token)
    }

    /// Ré-enregistre le dernier token VoIP UNIQUEMENT s'il reste à synchroniser
    /// (retour foreground / retour réseau). No-op si déjà à jour.
    func retryVoIPTokenRegistrationIfNeeded() async {
        guard voipTokenNeedsSync, let token = lastVoipToken else { return }
        await registerVoIPToken(token)
    }

    /// CALL-VOIP-04 : ré-associe le token VoIP à la SESSION authentifiée courante,
    /// SANS condition de needsSync. Indispensable car `registerForVoIPPushes` est
    /// gardé (registry déjà créé) → `didUpdate pushCredentials` n'est PAS re-livré
    /// à un 2e login dans le même process (install→1er login, ou changement de
    /// compte). No-op au tout premier login tant que le token n'a pas été livré
    /// (le `didUpdate` initial fera alors le POST).
    func registerVoIPTokenForSession() async {
        guard let token = lastVoipToken else {
            // Sans jeton VoIP encore livré, la session se lie quand même à
            // l'appareil v2 avec le jeton APNs (E.1, v0.4.19).
            await pushRegistrar?.register(voipToken: nil)
            return
        }
        await registerVoIPToken(token)
    }

    /// CALL-VOIP-05 : révoque le token VoIP côté serveur au logout (best-effort)
    /// pour qu'un autre compte sur cet appareil ne reçoive pas les pushes VoIP de
    /// l'ancien utilisateur. On GARDE `lastVoipToken` en mémoire (c'est le token de
    /// l'APPAREIL, pas du compte) : il sera ré-associé au prochain login via
    /// `registerVoIPTokenForSession`, sans attendre un nouveau `didUpdate`.
    func unregisterVoIPToken() async {
        guard let token = lastVoipToken else { return }
        do {
            let _: SuccessResponse = try await api.requestJSON(
                "/api/user/voip-token",
                method: .delete,
                body: [
                    "voipToken": token,
                    "platform": "ios",
                    "deviceId": deviceID,
                    "environment": api.config.environment.rawValue,
                ]
            )
        } catch {
            // Best-effort : la route DELETE peut ne pas encore exister côté backend.
            logger.error("VoIP token unregister failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated fileprivate static func string(_ info: [AnyHashable: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = info[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - CXProviderDelegate
/// Confines a non-Sendable system object (a CXAction or a PushKit completion
/// handler) so it can be ferried into a MainActor task. Safe because CallKit and
/// PushKit deliver on the main queue and we only ever touch the value on the
/// MainActor.
private struct UnsafeMainActorBox<T>: @unchecked Sendable {
    let value: T
}

// CallKit/PushKit deliver these callbacks on the main queue; we hop onto the
// MainActor — boxing the non-Sendable action/completion — to touch our state.
extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            // CALL-RTC-06 : le système a réinitialisé le provider (crash CallKit,
            // changement d'état système) → on signale la fin au serveur AVANT le
            // teardown pour ne pas laisser de session fantôme, puis on nettoie.
            if let call = self.activeCall { await self.notifyBackendCallTerminated(call) }
            await self.tearDown()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let box = UnsafeMainActorBox(value: action)
        Task { @MainActor in
            let action = box.value
            guard let call = self.activeCall, call.id == action.callUUID, let conversationId = call.conversationId else {
                action.fail(); return
            }
            // Le nom, pas l'identifiant de conversation, dans l'appel et dans Récents.
            let named = CXCallUpdate()
            named.remoteHandle = action.handle
            named.localizedCallerName = call.handle
            named.hasVideo = call.hasVideo
            self.provider.reportCall(with: action.callUUID, updated: named)
            do {
                let session = try await self.initiate(call, conversationId: conversationId)
                self.activeCall?.callId = session.id
                self.activeCall?.requiresE2EE = session.e2eeRequired
                self.activeCall?.e2eeDescriptor = session.e2eeV2
                self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
                try await self.connectLiveKit(for: session, video: call.hasVideo)
                self.provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
                action.fulfill()
            } catch {
                self.logger.error("initiate failed: \(error.localizedDescription, privacy: .public)")
                let notice = self.failureNotice(for: error)
                if let call = self.activeCall { await self.notifyBackendCallTerminated(call) }
                action.fail()
                await self.tearDown(notice: notice)
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let box = UnsafeMainActorBox(value: action)
        Task { @MainActor in
            let action = box.value
            guard let call = self.activeCall, let callId = call.callId else { action.fail(); return }
            var fulfilled = false
            do {
                var reconciled = try await self.reconcileE2EEForAnswer(call)
                let session: CallSession
                do {
                    session = try await self.answerOnce(reconciled, callId: callId)
                } catch where Self.waitsForUnlock(error) {
                    // Décroché : CallKit le montre, et l'appel attend le
                    // déverrouillage plutôt que d'échouer (§2.6, v0.4.13).
                    self.liveKit.prepareCallKitAudioSession()
                    action.fulfill()
                    fulfilled = true
                    try await self.waitForUnlockToAnswer(reconciled)
                    // Relu après l'attente : un appel terminé ou décroché ailleurs
                    // entre-temps n'est jamais rejoint.
                    reconciled = try await self.reconcileE2EEForAnswer(reconciled)
                    session = try await self.answerOnce(reconciled, callId: callId)
                }
                guard self.isStillAnswering(callId) else {
                    // Raccroché pendant la réponse : le serveur l'a peut-être déjà
                    // rejoint, on le quitte (sans effet s'il ne l'est pas).
                    await self.notifyBackendCallTerminated(callId: callId, action: .leave)
                    if !fulfilled { action.fail() }
                    return
                }
                // L'autorisation serveur a déjà fait passer le participant à
                // `joined`; tout échec média ultérieur doit donc utiliser leave/end,
                // jamais reject (qui n'accepte que RINGING).
                self.activeCall?.isAnswered = true
                try await self.connectLiveKit(for: session, video: call.hasVideo)
                self.showCallScreen = true
                if !fulfilled { action.fulfill() }
            } catch {
                // Raccroché ou terminé ailleurs pendant la réponse : la fin s'en
                // occupe, sans écran d'échec.
                guard self.isStillAnswering(callId) else {
                    if !fulfilled { action.fail() }
                    return
                }
                self.logger.error("answer failed: \(error.localizedDescription, privacy: .public)")
                // CALL-RTC-02 : l'appel a déjà été rapporté à CallKit (entrant) ;
                // action.fail() ne le retire pas → on le clôt explicitement pour ne
                // pas laisser une entrée d'appel fantôme côté système.
                if let id = self.activeCall?.id { self.reportCallEnded(id, reason: .failed) }
                let notice = self.failureNotice(for: error)
                if let call = self.activeCall { await self.notifyBackendCallTerminated(call) }
                if !fulfilled { action.fail() }
                await self.tearDown(notice: notice)
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let box = UnsafeMainActorBox(value: action)
        Task { @MainActor in
            let action = box.value
            // Avant toute attente : une réponse en cours ne reprend plus cet appel.
            self.activeCall?.isEnding = true
            let call = self.activeCall
            await self.liveKit.disconnect()
            // CALL-BUG-02 / CALL-RTC-06 : reject (entrant jamais décroché) vs end
            // (sortant ou décroché), factorisé dans notifyBackendCallTerminated.
            if let call { await self.notifyBackendCallTerminated(call) }
            self.activeCall = nil
            self.endNotice = nil
            self.showCallScreen = false
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let box = UnsafeMainActorBox(value: action)
        Task { @MainActor in
            self.liveKit.setMuted(box.value.isMuted)
            box.value.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in self.liveKit.audioSessionDidActivate(audioSession) }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in self.liveKit.audioSessionDidDeactivate(audioSession) }
    }
}

// MARK: - PKPushRegistryDelegate
extension CallManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await self.registerVoIPToken(token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in
            // CALL-VOIP-06 : iOS a invalidé le token VoIP — on l'oublie pour ne pas
            // retenter d'enregistrer un token mort ; le prochain didUpdate en
            // fournira un neuf.
            self.lastVoipToken = nil
            self.voipTokenNeedsSync = false
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // Extract everything off the non-Sendable payload before crossing actors.
        let dict = payload.dictionaryPayload
        let callId = CallManager.string(dict, "callId", "call_id", "id")
        let conversationId = CallManager.string(dict, "conversationId", "conversation_id")
        let payloadName = CallManager.string(dict, "caller", "callerName", "handle", "title")
        let hasVideo = CallManager.string(dict, "mode", "type")?.lowercased() == "video"
        let e2eeExpectation = IncomingCallE2EEContract.parse(dict)
        // `callId` est l'identité canonique. Elle prime sur un UUID de push pour
        // qu'une relivraison APNs (ou un producteur qui régénère son UUID) ne
        // crée jamais une seconde entrée CallKit pour le même appel.
        let uuid = callId.map(CallLifecyclePolicy.callKitUUID(callId:))
            ?? CallManager.string(dict, "uuid", "callUuid").flatMap(UUID.init(uuidString:))
            ?? UUID()
        // CallKit exige de rapporter l'appel entrant DANS LE MÊME run loop, avant que
        // `completion` ne s'exécute — sinon iOS termine l'app et finit par cesser de
        // livrer les pushes VoIP. Le registre est créé avec `queue: .main` (l.132) et
        // ce delegate est `nonisolated` : on est donc déjà sur le MainActor, on rapporte
        // SYNCHRONEMENT via `assumeIsolated` au lieu d'un `Task` différé (ROB-06).
        let completionBox = UnsafeMainActorBox(value: completion)
        MainActor.assumeIsolated {
            // Nom retrouvé sur l'appareil, lu de façon synchrone (§10.5).
            let handle = CallDiscretionPolicy.displayName(
                payloadName: payloadName,
                requiresE2EE: e2eeExpectation.requiresE2EE,
                conversation: self.knownConversation(conversationId)
            )
            guard let callId else {
                self.reportInvalidIncomingPush(uuid: uuid, handle: handle, hasVideo: hasVideo, completion: completionBox.value)
                return
            }
            if e2eeExpectation == .invalid {
                self.reportInvalidIncomingPush(
                    uuid: uuid,
                    handle: handle,
                    hasVideo: hasVideo,
                    completion: completionBox.value
                )
                return
            }
            let requirement: Bool?
            let descriptor: E2EEV2SignedCallDescriptor?
            switch e2eeExpectation {
            case .unresolved:
                requirement = nil
                descriptor = nil
            case .legacy:
                requirement = false
                descriptor = nil
            case .required(let value):
                requirement = true
                descriptor = value
            case .invalid:
                return
            }
            self.reportIncomingCall(
                uuid: uuid,
                callId: callId,
                conversationId: conversationId,
                handle: handle,
                hasVideo: hasVideo,
                requiresE2EE: requirement,
                e2eeDescriptor: descriptor,
                completion: completionBox.value
            )
        }
    }
}
