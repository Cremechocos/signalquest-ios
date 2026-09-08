import Foundation
import CoreLocation
import Combine

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var errorMessage: String?

    /// Âge maximal d'un fix réutilisé tel quel par `currentLocation()`. Au-delà,
    /// on redemande une position fraîche au lieu de renvoyer un cache périmé —
    /// sinon une app gardée en mémoire géotague les mesures (et les publie sur la
    /// carte communautaire) à une position quittée depuis longtemps (TEL-01/ROB-04).
    static let defaultMaxLocationAge: TimeInterval = 60

    private let manager: any LocationManagerDriving
    /// requestLocation ne peut pas coexister avec startUpdatingLocation sur le
    /// même CLLocationManager. Ce second gestionnaire garde les lectures
    /// ponctuelles indépendantes du suivi et de ses paramètres d'énergie.
    private let makeOneShotManager: @MainActor () -> any LocationManagerDriving
    private var oneShotManager: (any LocationManagerDriving)?
    private var oneShotDelegate: LocationOneShotDelegate?
    private var oneShotGeneration: UUID?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async throws -> Void
    private struct PendingLocation {
        let continuation: CheckedContinuation<CLLocation?, Never>
        let policy: LocationFixPolicy
        let startedAt: Date
        let startingFixSequence: UInt64
        let timer: Task<Void, Never>
        var acquisitionAttempts = 0
    }
    private var pending: [UUID: PendingLocation] = [:]
    private var fixSequence: UInt64 = 0
    private var trackingIsActive = false
    private var oneShotOutstanding = false
    private var authorizationRequested = false
    private var cachedFix: CLLocation?
    private var cacheGeneration = UUID()
    private var cacheExpiration: Task<Void, Never>?
    /// Suivi continu demandé (drive test) : permet de (re)démarrer le tracking dès
    /// que l'autorisation est accordée, même si l'utilisateur valide le prompt après.
    /// Suivi continu demandé (rafale / drive test). Exposé en lecture parce que
    /// c'est le signal qui autorise l'app à rester active écran verrouillé :
    /// tant qu'il est vrai, couper les boucles réseau d'arrière-plan priverait
    /// l'utilisateur de ce qu'il a explicitement lancé.
    @Published private(set) var wantsTracking = false
    /// Abonnés aux positions. Chaque consommateur possède son jeton : Drive Test,
    /// CarPlay et les alertes peuvent ainsi coexister sans s'écraser.
    private var locationObservers: [UUID: @MainActor (CLLocation) -> Void] = [:]

    /// Suivi réclamé explicitement par `startTracking()` (drive test, rafale),
    /// par opposition au suivi INDUIT par la présence d'abonnés.
    ///
    /// Les deux sources doivent être distinguées, sinon chacune coupe l'autre :
    /// un drive test qui se termine éteindrait le suivi dont CarPlay a encore
    /// besoin, et inversement.
    private var explicitTrackingRequested = false

    /// S'abonner suffit à obtenir des positions.
    ///
    /// Auparavant, poser un observateur n'enclenchait rien : seul `startTracking()`
    /// appelait `startUpdatingLocation()`. Un abonné qui ne démarrait pas lui-même
    /// le suivi n'était donc jamais appelé — c'est ce qui rendait les alertes de
    /// couverture CarPlay muettes hors guidage.
    @discardableResult
    func addLocationObserver(_ handler: @escaping @MainActor (CLLocation) -> Void) -> UUID {
        let token = UUID()
        locationObservers[token] = handler
        syncTracking()
        return token
    }

    func removeLocationObserver(_ token: UUID) {
        guard locationObservers.removeValue(forKey: token) != nil else { return }
        syncTracking()
    }

    /// Cap de l'appareil en degrés (0 = nord géographique), `nil` tant que
    /// personne ne l'a demandé ou si le magnétomètre est indisponible ou non
    /// calibré. Sert à orienter une visée : une flèche qui tourne avec le
    /// téléphone désigne l'antenne dans le monde réel, là où un relèvement en
    /// degrés demande de faire le calcul soi-même.
    ///
    /// On ne publie qu'un scalaire, pas le `CLHeading` : la classe n'est pas
    /// `Sendable` et ne peut pas traverser vers le main actor sous Swift 6.
    @Published private(set) var headingDegrees: Double?
    /// Nombre d'écrans qui ont demandé le cap. Le magnétomètre consomme : on ne
    /// l'arrête que lorsque le DERNIER écran le relâche, sinon deux fiches
    /// ouvertes en pile s'éteignent mutuellement.
    private var headingSubscribers = 0

    override convenience init() {
        self.init(manager: CLLocationManager(), makeOneShotManager: { CLLocationManager() })
    }

    init(
        manager: any LocationManagerDriving,
        makeOneShotManager: @escaping @MainActor () -> any LocationManagerDriving,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.manager = manager
        self.makeOneShotManager = makeOneShotManager
        self.now = now
        self.sleep = sleep
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Ne confond pas le dernier relevé reçu avec une position admissible.
    /// Les usages de consultation peuvent demander explicitement un âge plus
    /// long ; les publications gardent le plafond par défaut.
    func cachedLocation(maxAge: TimeInterval = LocationService.defaultMaxLocationAge,
                        maximumAccuracy: CLLocationAccuracy? = nil) -> CLLocation? {
        guard let cachedFix, isUsable(cachedFix, maxAge: maxAge, maximumAccuracy: maximumAccuracy) else { return nil }
        return cachedFix
    }

    func isUsable(_ fix: CLLocation, maxAge: TimeInterval = LocationService.defaultMaxLocationAge,
                  maximumAccuracy: CLLocationAccuracy? = nil) -> Bool {
        LocationFixPolicy.isAuthorized(manager.authorizationStatus)
            && LocationFixPolicy(maxAge: maxAge, maximumAccuracy: maximumAccuracy).accepts(fix, now: now())
    }

    deinit { cacheExpiration?.cancel() }

    func requestWhenInUse() {
        guard manager.authorizationStatus == .notDetermined, !authorizationRequested else { return }
        authorizationRequested = true
        manager.requestWhenInUseAuthorization()
    }

    /// Démarre un suivi de position CONTINU (mode rafale / drive test). Les updates
    /// alimentent `lastLocation`, que `currentLocation()` renvoie immédiatement à
    /// chaque test. `allowsBackgroundLocationUpdates` (avec le background mode
    /// `location` de l'Info.plist) maintient l'app active écran verrouillé. À
    /// n'appeler qu'au premier plan, autorisation « Pendant l'utilisation » accordée.
    func startTracking() {
        explicitTrackingRequested = true
        syncTracking()
    }

    /// Aligne l'état réel du `CLLocationManager` sur la demande courante.
    ///
    /// Point unique de bascule : le suivi démarre dès qu'au moins une source le
    /// réclame, et ne s'arrête qu'une fois la DERNIÈRE relâchée. Sans ce
    /// comptage, `startTracking()` laissait le GPS haute précision et
    /// `allowsBackgroundLocationUpdates` actifs indéfiniment — y compris après
    /// débranchement du véhicule.
    private func syncTracking() {
        let desired = explicitTrackingRequested || !locationObservers.isEmpty
        guard desired != wantsTracking else { return }
        wantsTracking = desired

        guard desired else {
            endTrackingNow()
            return
        }
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginTrackingNow()
        case .notDetermined:
            requestWhenInUse() // le tracking démarrera à l'octroi
        default:
            break // refusé : pas de tracking (le drive test tournera sans position)
        }
    }

    private func beginTrackingNow() {
        guard !trackingIsActive else { return }
        trackingIsActive = true
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // PERF-GPS-01 : ne livrer un fix que tous les 8 m (= le seuil applicatif de la
        // trace). Supprime les fixes redondants à l'arrêt / basse vitesse, qui
        // déclenchaient sinon à chaque fois recomputeNearest (O(antennes)) + écriture
        // App Group + tâches sur le main thread. Densité de trace inchangée (seuil 8 m).
        manager.distanceFilter = 8
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    /// Relâche la demande explicite de suivi continu.
    ///
    /// ⚠️ N'éteint pas forcément le GPS : si des observateurs sont encore posés
    /// (CarPlay branché, par exemple), le suivi continue pour eux. C'est
    /// délibéré — couper leurs positions parce qu'un autre écran a terminé
    /// serait une panne silencieuse.
    func stopTracking() {
        explicitTrackingRequested = false
        syncTracking()
    }

    /// Coupe réellement le suivi et restaure les réglages one-shot par défaut.
    private func endTrackingNow() {
        trackingIsActive = false
        manager.stopUpdatingLocation()
        if manager.allowsBackgroundLocationUpdates {
            manager.allowsBackgroundLocationUpdates = false
        }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
    }

    /// Démarre la diffusion du cap. Aucune autorisation supplémentaire n'est
    /// requise : le cap relève de la même permission de localisation. À appeler
    /// à l'apparition d'un écran qui vise, et à relâcher à sa disparition.
    func startHeadingUpdates() {
        headingSubscribers += 1
        guard headingSubscribers == 1, CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 2 // degrés : sous ce seuil, la flèche ne bouge pas à l'œil
        manager.startUpdatingHeading()
    }

    func stopHeadingUpdates() {
        headingSubscribers = max(0, headingSubscribers - 1)
        guard headingSubscribers == 0 else { return }
        manager.stopUpdatingHeading()
        headingDegrees = nil
    }

    func requestOneShotLocation() {
        Task { _ = await currentLocation() }
    }

    func currentLocation(
        timeoutSeconds: UInt64 = 8,
        maxAge: TimeInterval = LocationService.defaultMaxLocationAge,
        maximumAccuracy: CLLocationAccuracy? = nil
    ) async -> CLLocation? {
        let policy = LocationFixPolicy(maxAge: maxAge, maximumAccuracy: maximumAccuracy)
        guard policy.isValid, !Task.isCancelled else { return nil }
        refreshAuthorization()
        if LocationFixPolicy.isAuthorized(authorizationStatus), let cached = cachedLocation(maxAge: maxAge, maximumAccuracy: maximumAccuracy) {
            return cached
        }
        guard authorizationStatus == .notDetermined || LocationFixPolicy.isAuthorized(authorizationStatus), timeoutSeconds > 0 else { return nil }
        let id = UUID()
        let startedAt = now()
        let duration = min(timeoutSeconds, 60) * 1_000_000_000
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let delay = sleep
                let timer = Task { @MainActor [weak self] in
                    do { try await delay(duration) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.finishRequest(id, useAdmissibleCache: true)
                }
                pending[id] = PendingLocation(continuation: continuation, policy: policy, startedAt: startedAt, startingFixSequence: fixSequence, timer: timer)
                if authorizationStatus == .notDetermined {
                    requestWhenInUse()
                } else {
                    beginOneShotIfNeeded()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishRequest(id, useAdmissibleCache: false) }
        }
    }

    private func beginOneShotIfNeeded() {
        guard !oneShotOutstanding,
              pending.values.contains(where: { $0.acquisitionAttempts < 2 }),
              LocationFixPolicy.isAuthorized(manager.authorizationStatus) else { return }
        for id in Array(pending.keys) { pending[id]?.acquisitionAttempts += 1 }
        let generation = UUID()
        let driver = makeOneShotManager()
        let delegate = LocationOneShotDelegate(service: self, generation: generation)
        oneShotManager = driver
        oneShotDelegate = delegate
        oneShotGeneration = generation
        driver.delegate = delegate
        oneShotOutstanding = true
        let requested = pending.values.compactMap { $0.policy.maximumAccuracy }.min()
        driver.desiredAccuracy = requested ?? kCLLocationAccuracyHundredMeters
        driver.requestLocation()
    }

    private func finishRequest(_ id: UUID, useAdmissibleCache: Bool) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        let value: CLLocation?
        if useAdmissibleCache, LocationFixPolicy.isAuthorized(manager.authorizationStatus), let cachedFix,
           request.policy.maxAge != 0 || request.startingFixSequence != fixSequence,
           request.policy.accepts(cachedFix, now: now(), requestedAt: request.startedAt) {
            value = cachedFix
        } else { value = nil }
        request.continuation.resume(returning: value)
        if pending.isEmpty, authorizationStatus == .notDetermined { authorizationRequested = false }
        if pending.isEmpty { retireOneShot() }
    }

    private func retireOneShot() {
        oneShotGeneration = nil
        oneShotManager?.delegate = nil
        if oneShotOutstanding { oneShotManager?.stopUpdatingLocation() }
        oneShotOutstanding = false
        oneShotManager = nil
        oneShotDelegate = nil
    }

    // Le jeton appartient au delegate créé pour cette acquisition, et non au
    // manager réutilisé ni à la génération lue au traitement d'un ancien callback.
    func receiveLocations(_ locations: [CLLocation], generation: UUID) {
        guard generation == oneShotGeneration else { return }
        receiveLocations(locations, fromOneShot: true)
    }

    func receiveLocationFailure(_ error: Error, generation: UUID) {
        guard generation == oneShotGeneration else { return }
        receiveLocationFailure(error, fromOneShot: true)
    }

    /// Relit l'état natif au traitement, au lieu de réappliquer une ancienne
    /// valeur capturée dans un callback mis en attente.
    func refreshAuthorization() {
        let status = manager.authorizationStatus
        let changed = authorizationStatus != status
        authorizationStatus = status
        if status != .notDetermined { authorizationRequested = false }
        if LocationFixPolicy.isAuthorized(status) {
            if wantsTracking, !trackingIsActive { beginTrackingNow() }
            if changed { beginOneShotIfNeeded() }
        } else if status != .notDetermined {
            cachedFix = nil
            lastLocation = nil
            cacheGeneration = UUID()
            cacheExpiration?.cancel()
            endTrackingNow()
            manager.stopUpdatingHeading()
            headingDegrees = nil
            for id in Array(pending.keys) { finishRequest(id, useAdmissibleCache: false) }
        }
    }

    func receiveLocations(_ locations: [CLLocation], fromOneShot: Bool = false) {
        refreshAuthorization()
        guard LocationFixPolicy.isAuthorized(manager.authorizationStatus) else { return }
        if fromOneShot {
            oneShotOutstanding = false
            retireOneShot()
        }
        let clock = now()
        let admissible = locations.filter {
            LocationFixPolicy(maxAge: .greatestFiniteMagnitude, maximumAccuracy: nil).accepts($0, now: clock)
        }.sorted { $0.timestamp > $1.timestamp }
        guard let newest = admissible.first else {
            if fromOneShot { beginOneShotIfNeeded() }
            return
        }
        let previous = cachedFix
        if cachedFix.map({ newest.timestamp >= $0.timestamp }) ?? true {
            cachedFix = newest
            fixSequence &+= 1
            lastLocation = cachedLocation()
            scheduleCacheExpiration()
        }
        errorMessage = nil
        // Ne rediffuse ni un vieux relevé reçu en lot, ni deux fois le même
        // relevé livré par les gestionnaires ponctuel et continu.
        if isUsable(newest), previous.map({ newest.timestamp >= $0.timestamp }) ?? true,
           previous?.timestamp != newest.timestamp || previous?.coordinate.latitude != newest.coordinate.latitude || previous?.coordinate.longitude != newest.coordinate.longitude {
            for observer in Array(locationObservers.values) { observer(newest) }
        }
        for (id, request) in Array(pending) {
            guard let value = admissible.first(where: { request.policy.accepts($0, now: clock, requestedAt: request.startedAt) }) else { continue }
            pending.removeValue(forKey: id)?.timer.cancel()
            request.continuation.resume(returning: value)
        }
        if pending.isEmpty { retireOneShot() }
        else if fromOneShot { beginOneShotIfNeeded() }
    }

    private func scheduleCacheExpiration() {
        cacheExpiration?.cancel()
        let generation = UUID()
        cacheGeneration = generation
        guard let fix = lastLocation else { return }
        let remaining = max(0, Self.defaultMaxLocationAge - now().timeIntervalSince(fix.timestamp)) + 0.01
        let delay = sleep
        cacheExpiration = Task { @MainActor [weak self] in
            do { try await delay(UInt64(min(remaining, Self.defaultMaxLocationAge + LocationFixPolicy.futureTolerance + 0.1) * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled, let self, self.cacheGeneration == generation else { return }
            self.lastLocation = self.cachedLocation()
        }
    }

    func receiveLocationFailure(_ error: Error, fromOneShot: Bool = true) {
        errorMessage = error.localizedDescription
        if (error as? CLError)?.code == .denied {
            cachedFix = nil
            lastLocation = nil
            cacheGeneration = UUID()
            cacheExpiration?.cancel()
        }
        guard fromOneShot || (error as? CLError)?.code == .denied else { return }
        for id in Array(pending.keys) { finishRequest(id, useAdmissibleCache: false) }
        retireOneShot()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refreshAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let source = ObjectIdentifier(manager)
        Task { @MainActor in
            guard source == ObjectIdentifier(self.manager) else { return }
            self.receiveLocations(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Une précision négative signale un magnétomètre non calibré, et un
        // `trueHeading` négatif un cap géographique indisponible (pas de position) :
        // mieux vaut pas de flèche qu'une flèche qui pointe n'importe où. Le cap
        // magnétique reste utilisable à défaut — la déclinaison est de l'ordre du
        // degré en France, invisible sur un cadran de 90 pt.
        let degrees: Double?
        if newHeading.headingAccuracy < 0 {
            degrees = nil
        } else if newHeading.trueHeading >= 0 {
            degrees = newHeading.trueHeading
        } else {
            degrees = newHeading.magneticHeading >= 0 ? newHeading.magneticHeading : nil
        }
        Task { @MainActor in
            headingDegrees = degrees
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let source = ObjectIdentifier(manager)
        Task { @MainActor in
            guard source == ObjectIdentifier(self.manager) else { return }
            self.receiveLocationFailure(error, fromOneShot: false)
        }
    }
}
