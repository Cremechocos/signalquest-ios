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
    private let privacy: PrivacyServicing
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "LivePresence")

    /// Mode de partage courant (persisté localement).
    @Published private(set) var mode: LiveShareMode = LiveShareModeStore.load()
    /// Vrai quand la boucle de publication tourne. Alimente l'indicateur « en direct ».
    @Published private(set) var isBroadcasting = false
    @Published private(set) var status = SocialPresencePreferenceStore.loadStatus()
    @Published private(set) var customStatus = SocialPresencePreferenceStore.loadCustomStatus()

    /// Miroirs locaux des réglages serveur, rechargés via `refreshSharingSettings()`.
    private var shareLocation = false
    private var shareRadio = false
    private var settingsLoaded = false
    /// Carte des amis actuellement à l'écran (pilote `mapOpenOnly`).
    private var mapVisible = false

    private var loopTask: Task<Void, Never>?
    private var presenceUpdateTask: Task<Void, Never>?
    private var lastSentLocation: CLLocation?
    private var lastSentAt: Date?
    private var hasBroadcasted = false

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
        privacy: PrivacyServicing
    ) {
        self.api = api
        self.location = location
        self.networkPath = networkPath
        self.privacy = privacy
    }

    // MARK: - Pilotage

    /// Change le mode de partage et réévalue la diffusion.
    func setMode(_ newMode: LiveShareMode) {
        guard newMode != mode else { return }
        mode = newMode
        LiveShareModeStore.save(newMode)
        reevaluate()
    }

    /// Recharge les toggles de partage depuis le backend puis réévalue. À appeler
    /// au lancement (pour amorcer le mode continu) et après une modification des
    /// réglages de confidentialité.
    func refreshSharingSettings() async {
        async let fetchedSettings = try? privacy.get()
        async let fetchedPresence: OwnPresenceEnvelope? = try? api.request(
            APIEndpoint(path: "/api/user/presence"),
            as: OwnPresenceEnvelope.self
        )
        let (settings, presenceEnvelope) = await (fetchedSettings, fetchedPresence)
        if let settings {
            shareLocation = settings.shareLiveLocationWithFriends
            shareRadio = settings.shareRadioDataWithFriends
            settingsLoaded = true
        }
        if let presence = presenceEnvelope?.presence {
            if let serverStatus = presence.status, serverStatus != .offline {
                status = serverStatus
            }
            customStatus = presence.customStatus.map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            }?.nilIfBlank
            SocialPresencePreferenceStore.save(status: status, customStatus: customStatus)
        }
        reevaluate()
    }

    /// Applique localement des réglages déjà connus (évite un aller-retour réseau
    /// quand l'écran Confidentialité vient de les sauvegarder).
    func applySharingSettings(shareLocation: Bool, shareRadio: Bool) {
        self.shareLocation = shareLocation
        self.shareRadio = shareRadio
        settingsLoaded = true
        reevaluate()
    }

    /// Met à jour le statut propre de l'utilisateur. L'envoi est débouncé pour ne
    /// pas publier chaque frappe du statut personnalisé.
    func setPresence(status newStatus: SocialPresenceStatus, customStatus newCustomStatus: String?) {
        status = newStatus == .offline ? .online : newStatus
        customStatus = String(
            (newCustomStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)
        ).nilIfBlank
        SocialPresencePreferenceStore.save(status: status, customStatus: customStatus)
        presenceUpdateTask?.cancel()
        presenceUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.shouldBroadcast else { return }
            await self.publishPresence(status: self.status, location: nil)
        }
    }

    func stopForSignOut() {
        settingsLoaded = false
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
        settingsLoaded && appIsActive
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
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                // `guard let self` et non `self?` : si le service est désalloué
                // sans passer par `stopLoop()`, la boucle tournait à vide
                // indéfiniment, réveillant le processeur toutes les 15 s pour
                // ne rien faire.
                guard let self else { return }
                await self.publishTick()
                try? await Task.sleep(for: .seconds(self.publishInterval))
            }
        }
    }

    private func stopLoop() {
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = nil
        isBroadcasting = false
        lastSentLocation = nil
        lastSentAt = nil
        // Signale la sortie best-effort : l'ami passe « hors ligne » côté amis.
        // (La position expire de toute façon au TTL serveur ; désactiver le partage
        // la purge immédiatement via le PATCH privacy.)
        if hasBroadcasted {
            hasBroadcasted = false
            Task { [weak self] in await self?.publishPresence(status: .offline, location: nil) }
        }
    }

    private func publishTick() async {
        guard shouldBroadcast else { return }
        let needsFix = shouldPublishLocation || shareRadio
        let fix = needsFix ? await location.currentLocation(timeoutSeconds: 4) : nil
        var shouldSendTelemetry = false
        if let fix {
            if let last = lastSentLocation, let at = lastSentAt {
                shouldSendTelemetry = fix.distance(from: last) >= minDistanceMeters
                    || Date().timeIntervalSince(at) >= maxSilence
            } else {
                shouldSendTelemetry = true
            }
        }

        await publishPresence(
            status: status,
            location: shouldPublishLocation && shouldSendTelemetry ? fix : nil
        )
        hasBroadcasted = true
        if let fix, shouldSendTelemetry {
            lastSentLocation = fix
            lastSentAt = Date()
            if shareRadio { await publishRadio(at: fix) }
        }
    }

    // MARK: - Requêtes

    private func publishPresence(status: SocialPresenceStatus, location fix: CLLocation?) async {
        let payloadLocation: PresenceLocationPayload? = fix.map { fix in
            PresenceLocationPayload(
                lat: fix.coordinate.latitude,
                lng: fix.coordinate.longitude,
                accuracy: fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil,
                heading: fix.course >= 0 ? fix.course : nil,
                speed: fix.speed >= 0 ? fix.speed : nil
            )
        }
        let body = PresencePublishRequest(
            status: status.rawValue,
            customStatus: status == .offline ? nil : customStatus,
            location: payloadLocation
        )
        do {
            let ack: PresenceAck = try await api.requestJSON("/api/social/presence", body: body)
            applyAck(ack)
        } catch {
            logger.debug("presence non publiée: \(error.localizedDescription, privacy: .public)")
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

    private func publishRadio(at fix: CLLocation) async {
        let status = networkPath.status
        // Rien d'utile à transmettre hors cellulaire (techno + opérateur vides).
        guard status.cellularTechnology != nil || status.operatorName != nil else { return }
        let body = RadioSnapshotPublishRequest(
            technology: status.cellularTechnology?.displayName,
            operator: status.operatorName,
            lat: fix.coordinate.latitude,
            lng: fix.coordinate.longitude
        )
        // 403 attendu si le partage radio est coupé côté serveur : silencieux.
        try? await api.requestJSON("/api/social/radio-snapshot", body: body)
    }
}

private struct OwnPresenceEnvelope: Decodable {
    let presence: OwnPresence?
}

private struct OwnPresence: Decodable {
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
