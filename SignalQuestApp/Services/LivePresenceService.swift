import Foundation
import CoreLocation
import os

/// Émetteur de la présence et de la position live de l'utilisateur pour la carte
/// des amis. Publie périodiquement vers `POST /api/social/presence` (position) et
/// `POST /api/social/radio-snapshot` (techno/opérateur — iOS n'expose pas le RSRP).
///
/// Le backend gate la position par `shareLiveLocationWithFriends` et purge au-delà
/// de 180 s ; on double ce garde-fou côté client (on n'envoie pas de coordonnées
/// quand le partage est coupé) pour l'économie réseau et la vie privée.
///
/// Deux modes (réglage local, cf. `LiveShareMode`) :
///  · `mapOpenOnly` : publie seulement pendant que la carte des amis est ouverte ;
///  · `foregroundLive` : publie tant que le partage est actif et l'app au premier
///    plan, même carte fermée.
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

    /// Miroirs locaux des réglages serveur, rechargés via `refreshSharingSettings()`.
    private var shareLocation = false
    private var shareRadio = false
    /// Carte des amis actuellement à l'écran (pilote `mapOpenOnly`).
    private var mapVisible = false

    private var loopTask: Task<Void, Never>?
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
        if let settings = try? await privacy.get() {
            shareLocation = settings.shareLiveLocationWithFriends
            shareRadio = settings.shareRadioDataWithFriends
        }
        reevaluate()
    }

    /// Applique localement des réglages déjà connus (évite un aller-retour réseau
    /// quand l'écran Confidentialité vient de les sauvegarder).
    func applySharingSettings(shareLocation: Bool, shareRadio: Bool) {
        self.shareLocation = shareLocation
        self.shareRadio = shareRadio
        reevaluate()
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

    /// Vrai quand on doit diffuser : partage actif ET (mode continu OU carte visible).
    private var shouldBroadcast: Bool {
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
                await self?.publishTick()
                let interval = self?.publishInterval ?? 15
                try? await Task.sleep(for: .seconds(interval))
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
        guard shareLocation else { return }
        let fix = await location.currentLocation(timeoutSeconds: 4)
        guard let fix else {
            // Sans position exploitable, on maintient au moins la présence en ligne.
            await publishPresence(status: .online, location: nil)
            hasBroadcasted = true
            return
        }
        if let last = lastSentLocation, let at = lastSentAt {
            let moved = fix.distance(from: last)
            let elapsed = Date().timeIntervalSince(at)
            if moved < minDistanceMeters && elapsed < maxSilence { return }
        }
        await publishPresence(status: .online, location: fix)
        lastSentLocation = fix
        lastSentAt = Date()
        hasBroadcasted = true
        if shareRadio { await publishRadio(at: fix) }
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
            customStatus: nil,
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
