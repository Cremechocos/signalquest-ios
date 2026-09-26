import Foundation
import CoreLocation
import os

/// Émetteur de la présence et de la position live de l'utilisateur pour la carte
/// des amis. Publie périodiquement vers `POST /api/social/presence` (position) et
/// `POST /api/social/radio-snapshot` (techno/opérateur — iOS n'expose pas le RSRP).
///
/// La présence (en ligne/absent/DND/invisible) est indépendante de la position.
/// Le backend gate les coordonnées par `shareLiveLocationWithFriends` et purge au-delà
/// de 180 s ; le client n'envoie jamais de coordonnées quand le partage est coupé.
///
/// Les deux modes `LiveShareMode` pilotent uniquement les coordonnées. Le heartbeat
/// de présence continue au premier plan même si la carte est fermée.
///
/// Parité Android : intervalle ~15 s, saut si déplacement < 15 m (sauf silence
/// > 5 min). On s'appuie sur des relevés one-shot `LocationService.currentLocation()`
/// pour ne PAS entrer en conflit avec le suivi continu partagé du Drive Test.
@MainActor
final class LivePresenceService: ObservableObject {
    private let api: APIClient
    private let location: LocationService
    private let networkPath: NetworkPathMonitor
    private let preferences: LivePresencePreferences
    private let loadSettings: @Sendable (UUID) async -> LivePresenceSettingsResponse
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "LivePresence")

    /// Mode de partage courant (persisté localement).
    @Published private(set) var mode: LiveShareMode
    /// Vrai quand la boucle de publication tourne. Alimente l'indicateur « en direct ».
    @Published private(set) var isBroadcasting = false
    @Published private(set) var status: SocialPresenceStatus
    @Published private(set) var customStatus: String?
    /// Le statut du propriétaire doit être connu avant toute édition/publication.
    @Published private(set) var presenceLoaded = false

    /// Miroirs locaux des réglages serveur, rechargés via `refreshSharingSettings()`.
    private var shareLocation = false
    private var shareRadio = false
    private var settingsLoaded = false
    private var settingsOwner: UUID?
    private var settingsRevision = UUID()
    private var presenceRevision = UUID()
    private var refreshGeneration = UUID()
    private var loopGeneration = UUID()
    /// Carte des amis actuellement à l'écran (pilote `mapOpenOnly`).
    private var mapVisible = false

    private var loopTask: Task<Void, Never>?
    private var presenceUpdateTask: Task<Void, Never>?
    private var telemetryDelivery = LiveTelemetryDeliveryState()
    private var hasBroadcasted = false
    private var lastBroadcastSessionID: UUID?

    /// Cadence de publication (s), pilotée par le serveur : rapide quand un ami me
    /// regarde (« boost à la demande » façon Localiser), lente sinon — pour ne pas
    /// vider la batterie. Valeur de départ prudente avant la 1re réponse serveur.
    private var publishInterval: TimeInterval = 20
    /// Bornes utilisées quand le serveur ne renvoie pas d'intervalle (rétro-compat).
    private let idleInterval: TimeInterval = 20
    private let activeInterval: TimeInterval = 5
    /// Déplacement minimal pour republier une position (m) — réduit quand observé.
    private var minDistanceMeters: CLLocationDistance = 15
    /// Vrai quand au moins un ami regarde activement ma position (réponse serveur).
    @Published private(set) var isObserved = false
    /// Republie même immobile passé ce délai (garde la fraîcheur < TTL serveur 180 s).
    private let maxSilence: TimeInterval = 120

    init(
        api: APIClient,
        location: LocationService,
        networkPath: NetworkPathMonitor,
        privacy: PrivacyServicing,
        preferences: LivePresencePreferences = LivePresencePreferences(),
        settingsLoader: (@Sendable (UUID) async -> LivePresenceSettingsResponse)? = nil
    ) {
        self.api = api
        self.location = location
        self.networkPath = networkPath
        self.preferences = preferences
        mode = preferences.loadMode()
        status = preferences.loadStatus()
        customStatus = preferences.loadCustomStatus()
        self.loadSettings = settingsLoader ?? { owner in
            async let settings = try? privacy.get()
            async let presence: OwnPresenceEnvelope? = try? api.request(
                APIEndpoint(path: "/api/user/presence"), as: OwnPresenceEnvelope.self,
                expectedSessionID: owner
            )
            return await LivePresenceSettingsResponse(settings: settings, presence: presence?.presence)
        }
    }

    // MARK: - Pilotage

    /// Change le mode de partage et réévalue la diffusion.
    func setMode(_ newMode: LiveShareMode) {
        guard newMode != mode else { return }
        mode = newMode
        preferences.saveMode(newMode)
        reevaluate()
    }

    /// Recharge les toggles de partage depuis le backend puis réévalue. À appeler
    /// au lancement (pour amorcer le mode continu) et après une modification des
    /// réglages de confidentialité.
    func refreshSharingSettings() async {
        let owner = api.credentials.snapshot()
        guard owner.accessToken != nil else { stopForSignOut(); return }
        adoptOwner(owner.sessionID)
        let refresh = UUID()
        refreshGeneration = refresh
        let privacyVersion = settingsRevision
        let presenceVersion = presenceRevision
        let result = await loadSettings(owner.sessionID)
        guard !Task.isCancelled, api.credentials.isCurrent(owner),
              settingsOwner == owner.sessionID, refreshGeneration == refresh else { return }
        if settingsRevision == privacyVersion, let settings = result.settings {
            updateSharingFlags(shareLocation: settings.shareLiveLocationWithFriends,
                               shareRadio: settings.shareRadioDataWithFriends)
        }
        if presenceRevision == presenceVersion, let presence = result.presence,
           let serverStatus = presence.status {
            presenceRevision = UUID()
            status = serverStatus == .offline ? .online : serverStatus
            customStatus = presence.customStatus.map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            }?.nilIfBlank
            presenceLoaded = true
            preferences.saveStatus(status, customStatus)
        }
        reevaluate()
    }

    /// Applique un enregistrement confirmé pour la session qui l'a demandé.
    /// Un refresh plus ancien du même compte ne peut pas rétablir ses valeurs.
    func applySharingSettings(shareLocation: Bool, shareRadio: Bool, expectedSessionID: UUID) {
        let owner = api.credentials.snapshot()
        guard owner.accessToken != nil, owner.sessionID == expectedSessionID else { return }
        adoptOwner(owner.sessionID)
        settingsRevision = UUID()
        updateSharingFlags(shareLocation: shareLocation, shareRadio: shareRadio)
        reevaluate()
    }

    private func updateSharingFlags(shareLocation: Bool, shareRadio: Bool) {
        if self.shareLocation != shareLocation { telemetryDelivery.reset(.location) }
        if self.shareRadio != shareRadio { telemetryDelivery.reset(.radio) }
        settingsRevision = UUID()
        self.shareLocation = shareLocation
        self.shareRadio = shareRadio
        settingsLoaded = true
    }

    private func adoptOwner(_ owner: UUID) {
        guard settingsOwner != owner else { return }
        stopForSignOut()
        settingsOwner = owner
        mode = preferences.loadMode()
        status = preferences.loadStatus()
        customStatus = preferences.loadCustomStatus()
    }

    /// Met à jour le statut propre de l'utilisateur. L'envoi est débouncé pour ne
    /// pas publier chaque frappe du statut personnalisé.
    func setPresence(status newStatus: SocialPresenceStatus, customStatus newCustomStatus: String?) {
        let owner = api.credentials.snapshot()
        guard owner.accessToken != nil else { return }
        adoptOwner(owner.sessionID)
        // Une édition de texte ne confirme pas le statut serveur : après un GET
        // partiel, la valeur locale pourrait remplacer un statut invisible.
        guard presenceLoaded else { return }
        presenceRevision = UUID()
        status = newStatus == .offline ? .online : newStatus
        customStatus = String(
            (newCustomStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)
        ).nilIfBlank
        preferences.saveStatus(status, customStatus)
        presenceUpdateTask?.cancel()
        reevaluate()
        presenceUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.shouldBroadcast,
                  self.api.credentials.isCurrent(owner) else { return }
            await self.publishPresence(status: self.status, location: nil, expectedSessionID: owner.sessionID,
                                       expectedLoopGeneration: self.loopGeneration)
        }
    }

    func stopForSignOut() {
        refreshGeneration = UUID()
        settingsRevision = UUID()
        presenceRevision = UUID()
        settingsOwner = nil
        presenceLoaded = false
        settingsLoaded = false
        status = .online
        customStatus = nil
        shareLocation = false
        shareRadio = false
        presenceUpdateTask?.cancel()
        presenceUpdateTask = nil
        stopLoop()
    }

    /// La carte des amis est apparue (calque « Amis » potentiellement actif).
    func mapDidAppear() {
        mapVisible = true
        reevaluate()
    }

    /// La carte des amis a disparu.
    func mapDidDisappear() {
        mapVisible = false
        reevaluate()
    }

    // MARK: - Boucle

    /// L'app est au premier plan. En arrière-plan, la diffusion s'arrête —
    /// sauf si l'appelant décide explicitement de la maintenir (drive test ou
    /// appel en cours, cf. `AppServices.enterBackground()`).
    ///
    /// Sans ce drapeau, `mode == .foregroundLive` suffisait à diffuser
    /// indéfiniment : `mapDidDisappear()` n'est appelé que sur `.onDisappear`
    /// de la carte, qui ne se déclenche PAS au passage en arrière-plan. Un
    /// utilisateur en partage continu réveillait donc la radio toutes les
    /// 5 à 20 secondes, écran verrouillé, sans limite de durée.
    private var appIsActive = true

    deinit {
        // Filet : la boucle est normalement arrêtée par `stopLoop()`, mais une
        // Task non structurée survit à son propriétaire.
        loopTask?.cancel()
    }

    func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        reevaluate()
    }

    /// Le heartbeat décrit l'activité du compte, pas le consentement aux coordonnées.
    private var shouldBroadcast: Bool {
        settingsLoaded && presenceLoaded && appIsActive
            && settingsOwner == api.credentials.snapshot().sessionID
            && api.credentials.accessToken() != nil
    }

    private var shouldPublishLocation: Bool {
        shareLocation && (mode == .foregroundLive || mapVisible)
    }

    private func reevaluate() {
        if shouldBroadcast {
            startLoop()
        } else {
            stopLoop()
        }
    }

    private func startLoop() {
        guard loopTask == nil else { return }
        isBroadcasting = true
        let generation = UUID()
        loopGeneration = generation
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                // `guard let self` et non `self?` : si le service est désalloué
                // sans passer par `stopLoop()`, la boucle tournait à vide
                // indéfiniment, réveillant le processeur toutes les 15 s pour
                // ne rien faire.
                guard let self, self.loopGeneration == generation else { return }
                await self.publishTick(generation: generation)
                try? await Task.sleep(for: .seconds(self.publishInterval))
            }
        }
    }

    private func stopLoop() {
        loopGeneration = UUID()
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = nil
        isBroadcasting = false
        telemetryDelivery = LiveTelemetryDeliveryState()
        // Signale la sortie best-effort : l'ami passe « hors ligne » côté amis.
        // (La position expire de toute façon au TTL serveur ; désactiver le partage
        // la purge immédiatement via le PATCH privacy.)
        isObserved = false
        publishInterval = idleInterval
        minDistanceMeters = 15
        if hasBroadcasted {
            hasBroadcasted = false
            let owner = lastBroadcastSessionID
            lastBroadcastSessionID = nil
            if let owner {
                let stoppedGeneration = loopGeneration
                Task { [weak self] in
                    await self?.publishPresence(status: .offline, location: nil, expectedSessionID: owner,
                                                expectedLoopGeneration: stoppedGeneration)
                }
            }
        }
    }

    private func publishTick(generation: UUID) async {
        guard shouldBroadcast, loopGeneration == generation else { return }
        let needsFix = shouldPublishLocation || shareRadio
        let owner = api.credentials.snapshot()
        let fix = needsFix ? await location.currentLocation(timeoutSeconds: 4) : nil
        guard !Task.isCancelled, shouldBroadcast, loopGeneration == generation, api.credentials.isCurrent(owner) else { return }
        let privacyVersion = settingsRevision
        let presenceVersion = presenceRevision
        let locationDue = fix.map { telemetryDelivery.shouldSend($0, channel: .location, now: Date(),
            minDistance: minDistanceMeters, maxSilence: maxSilence) } ?? false
        let radioDue = fix.map { telemetryDelivery.shouldSend($0, channel: .radio, now: Date(),
            minDistance: minDistanceMeters, maxSilence: maxSilence) } ?? false
        let positionSubmitted = shouldPublishLocation && locationDue
        let acknowledged = await publishPresence(
            status: status, location: positionSubmitted ? fix : nil,
            expectedSessionID: owner.sessionID, expectedLoopGeneration: generation
        )
        guard !Task.isCancelled, shouldBroadcast, loopGeneration == generation, api.credentials.isCurrent(owner),
              settingsRevision == privacyVersion, presenceRevision == presenceVersion else { return }
        if let fix {
            if positionSubmitted {
                telemetryDelivery.acknowledge(fix, channel: .location,
                    accepted: acknowledged?.ok == true && acknowledged?.locationAccepted != false, now: Date())
            }
            if shareRadio, radioDue {
                let radioAccepted = await publishRadio(at: fix)
                guard !Task.isCancelled, shouldBroadcast, loopGeneration == generation,
                      settingsRevision == privacyVersion, presenceRevision == presenceVersion,
                      api.credentials.isCurrent(owner) else { return }
                telemetryDelivery.acknowledge(fix, channel: .radio, accepted: radioAccepted, now: Date())
            }
        }
    }

    // MARK: - Requêtes

    @discardableResult
    private func publishPresence(status: SocialPresenceStatus, location fix: CLLocation?, expectedSessionID: UUID? = nil,
                                 expectedLoopGeneration: UUID? = nil) async -> PresenceAck? {
        let owner = expectedSessionID ?? api.credentials.snapshot().sessionID
        let runtime = expectedLoopGeneration ?? loopGeneration
        let privacyVersion = settingsRevision
        let presenceVersion = presenceRevision
        guard api.credentials.snapshot().sessionID == owner,
              runtime == loopGeneration,
              status == .offline || shouldBroadcast else { return nil }
        let validFix = fix.flatMap { location.isUsable($0) ? $0 : nil }
        let payloadLocation: PresenceLocationPayload? = validFix.map { fix in
            PresenceLocationPayload(
                lat: fix.coordinate.latitude,
                lng: fix.coordinate.longitude,
                accuracy: fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil,
                heading: fix.course >= 0 ? fix.course : nil,
                speed: fix.speed >= 0 ? fix.speed : nil,
                observedAt: fix.timestamp
            )
        }
        let body = PresencePublishRequest(
            status: status.rawValue,
            customStatus: status == .offline ? nil : customStatus,
            location: payloadLocation
        )
        do {
            let ack = try await api.request(
                APIEndpoint(path: "/api/social/presence", method: .post,
                            headers: ["Content-Type": "application/json"], body: try JSONEncoder.signalQuest.encode(body),
                            validateBeforeSend: { [weak self] in
                                guard let self else { throw APIError.cancelled }
                                try await self.validateTransmission(owner: owner, runtime: runtime,
                                    privacyVersion: privacyVersion, presenceVersion: presenceVersion,
                                    offline: status == .offline, fix: validFix, radio: false)
                            }),
                as: PresenceAck.self, expectedSessionID: owner
            )
            guard !Task.isCancelled, api.credentials.snapshot().sessionID == owner,
                  loopGeneration == runtime, settingsRevision == privacyVersion,
                  presenceRevision == presenceVersion, ack.ok == true else { return nil }
            if status != .offline {
                hasBroadcasted = true
                lastBroadcastSessionID = owner
            }
            applyAck(ack)
            return ack
        } catch {
            logger.debug("presence non publiée: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Applique la cadence pilotée par le serveur (« boost à la demande » façon
    /// Localiser) : rapide quand un ami me regarde, lente sinon — sans vider la
    /// batterie. Rétro-compatible : sans champs serveur, on garde des cadences par
    /// défaut raisonnables.
    private func applyAck(_ ack: PresenceAck) {
        isObserved = ack.observed ?? false
        if let ms = ack.nextIntervalMs, ms > 0 {
            publishInterval = min(max(TimeInterval(ms) / 1000, 2), 120)
        } else {
            publishInterval = isObserved ? activeInterval : idleInterval
        }
        minDistanceMeters = isObserved ? 5 : 15
    }

    private func publishRadio(at fix: CLLocation) async -> Bool {
        guard !Task.isCancelled, shouldBroadcast, shareRadio, location.isUsable(fix) else { return false }
        let owner = api.credentials.snapshot().sessionID
        let runtime = loopGeneration
        let privacyVersion = settingsRevision
        let presenceVersion = presenceRevision
        networkPath.refreshNow()
        let capturedAt = Date()
        let status = networkPath.status
        // Rien d'utile à transmettre hors cellulaire (techno + opérateur vides).
        guard status.cellularTechnology != nil || status.operatorName != nil else { return false }
        let body = RadioSnapshotPublishRequest(
            technology: status.cellularTechnology?.displayName,
            operator: status.operatorName,
            lat: fix.coordinate.latitude,
            lng: fix.coordinate.longitude,
            observedAt: capturedAt,
            locationObservedAt: fix.timestamp
        )
        // 403 attendu si le partage radio est coupé côté serveur : silencieux.
        do {
            let data = try await api.requestData(
                APIEndpoint(path: "/api/social/radio-snapshot", method: .post,
                            headers: ["Content-Type": "application/json"], body: try JSONEncoder.signalQuest.encode(body),
                            validateBeforeSend: { [weak self] in
                                guard let self else { throw APIError.cancelled }
                                try await self.validateTransmission(owner: owner, runtime: runtime,
                                    privacyVersion: privacyVersion, presenceVersion: presenceVersion,
                                    offline: false, fix: fix, radio: true)
                            }),
                expectedSessionID: owner
            )
            guard !Task.isCancelled, api.credentials.snapshot().sessionID == owner else { return false }
            // Les anciens backends peuvent confirmer par 204. Le nouveau contrat
            // distingue un 200 reçu d'un échantillon effectivement accepté.
            if data.isEmpty { return true }
            let ack = try JSONDecoder.signalQuest.decode(RadioSnapshotAck.self, from: data)
            return ack.ok == true && ack.accepted != false
        } catch { return false }
    }
    private func validateTransmission(owner: UUID, runtime: UUID, privacyVersion: UUID,
                                      presenceVersion: UUID, offline: Bool, fix: CLLocation?, radio: Bool) throws {
        try Task.checkCancellation()
        guard api.credentials.snapshot().sessionID == owner, loopGeneration == runtime,
              settingsRevision == privacyVersion, presenceRevision == presenceVersion,
              offline || shouldBroadcast else { throw APIError.cancelled }
        if let fix {
            guard location.isUsable(fix), radio ? shareRadio : shouldPublishLocation else { throw APIError.cancelled }
        }
    }

}

struct LivePresenceSettingsResponse: Sendable {
    let settings: SocialPrivacy?
    let presence: OwnPresence?
}

private struct OwnPresenceEnvelope: Decodable, Sendable {
    let presence: OwnPresence?
}

struct OwnPresence: Decodable, Sendable {
    let status: SocialPresenceStatus?
    let customStatus: String?

    enum CodingKeys: String, CodingKey {
        case status = "presenceStatus"
        case customStatus
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}

/// Accès aux préférences locales séparé du moteur de diffusion : le banc de
/// concurrence n'écrit jamais dans les préférences du runner ou d'un compte.
@MainActor
struct LivePresencePreferences {
    var loadMode: () -> LiveShareMode = { LiveShareModeStore.load() }
    var loadStatus: () -> SocialPresenceStatus = { SocialPresencePreferenceStore.loadStatus() }
    var loadCustomStatus: () -> String? = { SocialPresencePreferenceStore.loadCustomStatus() }
    var saveMode: (LiveShareMode) -> Void = { LiveShareModeStore.save($0) }
    var saveStatus: (SocialPresenceStatus, String?) -> Void = {
        SocialPresencePreferenceStore.save(status: $0, customStatus: $1)
    }
}
