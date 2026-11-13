import Foundation
import os

/// SPEEDTEST-FAIL-1 : comptage anonyme des speedtests ratés (`POST /api/speedtest/failures`).
///
/// Le serveur ne voit que les tests réussis : un test qui n'aboutit pas ne laissait aucune
/// trace. Une ligne par test raté, avec ce que le contrat autorise et rien d'autre : code,
/// phase, moteur, techno, opérateur s'il est déjà connu, quart d'heure UTC. Ni position, ni
/// cellule, ni compte, ni appareil, ni heure exacte. Pas de consentement préalable : décision
/// d'Alexandre (28/10), dont la contrepartie est justement l'absence de donnée personnelle.
enum SpeedtestFailure {
    /// Les 12 codes du contrat. Tout autre code part en `UNKNOWN`.
    static let codes: Set<String> = [
        "PING_UNREACHABLE", "NO_INTERNET", "CELLULAR_NETWORK_UNAVAILABLE", "CONNECTION_UNSTABLE",
        "IP_MODE_UNAVAILABLE", "SECURE_ACCESS_UNAVAILABLE", "SESSION_UNAVAILABLE",
        "TEMPORARILY_UNAVAILABLE", "UPLOAD_UNVERIFIED", "CANCELLED", "TIMEOUT", "UNKNOWN",
    ]
    static let engines: Set<String> = ["cloudflare", "iperf3", "librespeed", "vps"]
    static let technologies: Set<String> = ["2G", "3G", "4G", "5G_NSA", "5G_SA", "WIFI", "ETHERNET", "UNKNOWN"]

    /// Étape atteinte. L'ordre compte : une étape ne recule jamais pendant un test.
    enum Phase: String, Codable, Comparable, Sendable {
        case setup, latency, download, upload

        private var rank: Int {
            switch self {
            case .setup: return 0
            case .latency: return 1
            case .download: return 2
            case .upload: return 3
            }
        }

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rank < rhs.rank }

        /// Le choix du serveur se fait sous `.ping` : il mesure déjà des latences.
        init?(_ phase: SpeedtestPhase) {
            switch phase {
            case .ping: self = .latency
            case .download: self = .download
            case .upload: self = .upload
            case .idle, .saving, .finished, .failed: return nil
            }
        }
    }

    /// Une ligne du lot. `engine` et `operatorKey` sont toujours présents, `null` compris :
    /// le schéma du serveur est strict et refuse une clé absente.
    struct Line: Codable, Equatable, Sendable {
        let code: String
        let phase: Phase
        let engine: String?
        let technology: String
        let operatorKey: String?
        let quarterStart: String

        enum CodingKeys: String, CodingKey { case code, phase, engine, technology, operatorKey, quarterStart }

        init(code: String, phase: Phase, engine: String?, technology: String, operatorKey: String?, quarterStart: String) {
            self.code = code
            self.phase = phase
            self.engine = engine
            self.technology = technology
            self.operatorKey = operatorKey
            self.quarterStart = quarterStart
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(code, forKey: .code)
            try c.encode(phase, forKey: .phase)
            try c.encode(engine, forKey: .engine)
            try c.encode(technology, forKey: .technology)
            try c.encode(operatorKey, forKey: .operatorKey)
            try c.encode(quarterStart, forKey: .quarterStart)
        }
    }

    struct Batch: Encodable, Equatable {
        let version = "1"
        let platform = "ios"
        let build: String
        let failures: [Line]

        enum CodingKeys: String, CodingKey { case version, platform, build, failures }
    }

    /// Pourquoi l'app a vu un test s'arrêter. Seul l'arrêt par le membre laisse une ligne.
    enum Stop: Sendable { case member }

    // MARK: Classement

    /// Code du contrat pour une erreur de test, ou nil quand aucune ligne ne doit partir
    /// (arrêt par l'app, test refusé parce qu'un autre tourne déjà).
    static func code(for error: Error, cancelled: Bool, stop: Stop?) -> String? {
        if error is SpeedtestBusyError { return nil }
        if cancelled || isCancellation(error) {
            return stop == .member ? "CANCELLED" : nil
        }
        if let failure = error as? CloudflareEngineFailure {
            return failure.underlying.flatMap { code(for: $0, cancelled: false, stop: nil) }
                ?? "TEMPORARILY_UNAVAILABLE"
        }
        if let classified = error as? SpeedtestFailureClassifiable { return classified.failureCode }
        if let iperf = error as? IPerf3Error {
            switch iperf {
            case .accessDenied, .serverError: return "TEMPORARILY_UNAVAILABLE"
            case .timeout, .emptyRead, .connectionClosed, .incomplete: return "CONNECTION_UNSTABLE"
            case .cancelled: return stop == .member ? "CANCELLED" : nil
            case .invalidJSON, .invalidPort, .unexpectedState: return "UNKNOWN"
            }
        }
        if let url = error as? URLError { return code(for: url.code) }
        if let api = error as? APIError {
            switch api {
            case .http(let status, _, _, _, _):
                switch status {
                case 429, 503: return "TEMPORARILY_UNAVAILABLE"
                case 401, 403: return "SECURE_ACCESS_UNAVAILABLE"
                default: return "UNKNOWN"
                }
            default: return "UNKNOWN"
            }
        }
        return "UNKNOWN"
    }

    static func code(for url: URLError.Code) -> String {
        switch url {
        case .notConnectedToInternet:
            return "NO_INTERNET"
        case .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return "CELLULAR_NETWORK_UNAVAILABLE"
        case .timedOut, .networkConnectionLost:
            return "CONNECTION_UNSTABLE"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return "SECURE_ACCESS_UNAVAILABLE"
        case .cannotFindHost, .dnsLookupFailed:
            // Aligné sur Android (Backend, 13/11) : un nom qui ne se résout pas = serveur injoignable.
            return "PING_UNREACHABLE"
        case .cannotConnectToHost:
            return "TEMPORARILY_UNAVAILABLE"
        default:
            return "UNKNOWN"
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return false
    }

    /// Techno du contrat. Sous VPN, le chemin vu est celui du tunnel : `UNKNOWN`.
    static func technology(_ status: NetworkPathStatus, viaVpn: Bool) -> String {
        if viaVpn { return "UNKNOWN" }
        switch status.connection {
        case .wifi: return "WIFI"
        case .wired: return "ETHERNET"
        case .other: return "UNKNOWN"
        case .cellular:
            switch status.cellularTechnology {
            case .twoG: return "2G"
            case .threeG: return "3G"
            case .fourG: return "4G"
            case .fiveGNSA: return "5G_NSA"
            case .fiveGSA: return "5G_SA"
            case nil: return "UNKNOWN"
            }
        }
    }

    /// Clé du registre, seulement en cellulaire hors VPN, et seulement si sa forme est valide.
    static func operatorKey(_ key: String?, status: NetworkPathStatus, viaVpn: Bool) -> String? {
        guard !viaVpn, status.connection == .cellular, let key, isOperatorKey(key) else { return nil }
        return key
    }

    static func isOperatorKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Z][A-Z0-9_]{1,31}$"#, options: .regularExpression) != nil
    }

    static func isBuild(_ build: String) -> Bool {
        build.range(of: #"^[0-9A-Za-z._-]{1,20}$"#, options: .regularExpression) != nil
    }

    // MARK: Heure

    /// Début du quart d'heure UTC, à la milliseconde, en « Z » : `2026-10-28T10:15:00.000Z`.
    static func quarterStart(_ date: Date) -> String {
        let seconds = floor(date.timeIntervalSince1970 / 900) * 900
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func date(ofQuarter value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    /// Une ligne que le serveur accepterait : valeurs dans les listes, quart d'heure ni trop
    /// vieux (7 jours moins une marge de 30 min) ni dans le futur au-delà de 15 min.
    static func isSendable(_ line: Line, now: Date) -> Bool {
        guard codes.contains(line.code), technologies.contains(line.technology),
              line.engine.map(engines.contains) ?? true,
              line.operatorKey.map(isOperatorKey) ?? true,
              let quarter = date(ofQuarter: line.quarterStart) else { return false }
        return quarter >= now.addingTimeInterval(-(7 * 24 * 3600 - 30 * 60))
            && quarter <= now.addingTimeInterval(15 * 60)
    }
}

/// Une erreur du moteur qui sait quel code du contrat elle représente.
protocol SpeedtestFailureClassifiable: Error {
    var failureCode: String { get }
}

/// Échec du moteur Cloudflare, avec sa cause quand elle est connue (hors ligne, TLS…).
protocol CloudflareEngineFailure: Error {
    var underlying: Error? { get }
}

/// Ce qu'un test a atteint avant d'échouer : la dernière étape et le dernier moteur lancé.
final class SpeedtestFailureProbe: @unchecked Sendable {
    @TaskLocal static var current: SpeedtestFailureProbe?

    private let state = OSAllocatedUnfairLock(initialState: (phase: SpeedtestFailure.Phase.setup, engine: String?.none))

    func reach(_ phase: SpeedtestPhase) {
        guard let mapped = SpeedtestFailure.Phase(phase) else { return }
        state.withLock { if mapped > $0.phase { $0.phase = mapped } }
    }

    func use(engine: String) {
        state.withLock { $0.engine = engine }
    }

    var snapshot: (phase: SpeedtestFailure.Phase, engine: String?) {
        state.withLock { ($0.phase, $0.engine) }
    }
}

/// File locale des lignes à envoyer, et leur envoi différé.
///
/// Différé pour une raison précise : l'heure d'arrivée de l'envoi, visible dans les journaux
/// de l'API, recollerait l'échec au test réussi qui le suit, donc à son auteur. D'où au moins
/// 15 minutes après le dernier échec, 60 secondes après le dernier `POST /api/speedtests`, et
/// jamais pendant un test.
actor SpeedtestFailureReporter {
    static let shared = SpeedtestFailureReporter()

    static let maxQueued = 200
    static let maxBatchLines = 50
    static let maxBodyBytes = 16 * 1024
    static let delayAfterFailure: TimeInterval = 15 * 60
    static let delayAfterSpeedtestPost: TimeInterval = 60
    static let retryDelay: TimeInterval = 30 * 60
    static let nextBatchDelay: TimeInterval = 2 * 60
    static let maxRetryAfter: TimeInterval = 24 * 3600

    struct State: Codable, Equatable {
        var lines: [SpeedtestFailure.Line] = []
        /// Lot déjà envoyé une fois sans réponse claire : il repart tel quel, avec la même clé.
        var inFlight: [SpeedtestFailure.Line] = []
        var inFlightKey: String?
        var lastFailureAt: Date?
        var notBefore: Date?
    }

    enum Outcome: Equatable {
        case sent
        case rejected
        case retry(after: TimeInterval?)
    }

    typealias Transport = @Sendable (_ body: Data, _ idempotencyKey: String) async -> (status: Int?, retryAfter: TimeInterval?)

    private let fileURL: URL?
    private let enabled: Bool
    private let transport: Transport
    private let now: @Sendable () -> Date
    private let build: String
    private var state: State
    private var flushTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "SpeedtestFailures")

    /// Heures hors de l'acteur : lues et écrites de façon synchrone par le moteur.
    private static let runtime = OSAllocatedUnfairLock(initialState: (
        lastSpeedtestPostAt: Date?.none, runningSince: Date?.none, memberStopAt: Date?.none
    ))

    init(
        fileURL: URL? = SpeedtestFailureReporter.defaultFileURL(),
        build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
        now: @escaping @Sendable () -> Date = Date.init,
        enabled: Bool = SpeedtestFailureReporter.isLiveEnvironment,
        transport: @escaping Transport = SpeedtestFailureReporter.liveTransport
    ) {
        self.fileURL = fileURL
        self.enabled = enabled
        self.build = build
        self.now = now
        self.transport = transport
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
    }

    // MARK: Signaux du moteur (synchrones)

    /// Le membre a touché « Arrêter » : le test en cours, s'il échoue, compte comme `CANCELLED`.
    nonisolated static func noteMemberStop(at date: Date = Date()) {
        runtime.withLock { $0.memberStopAt = date }
    }

    nonisolated static func noteRunStarted(at date: Date = Date()) {
        runtime.withLock {
            $0.runningSince = date
            $0.memberStopAt = nil
        }
    }

    /// Fin du test : dit si le membre l'a arrêté pendant qu'il tournait.
    nonisolated static func noteRunEnded() -> SpeedtestFailure.Stop? {
        runtime.withLock { value -> SpeedtestFailure.Stop? in
            let stopped = value.memberStopAt != nil
            value.runningSince = nil
            value.memberStopAt = nil
            return stopped ? .member : nil
        }
    }

    nonisolated static func noteSpeedtestPost(at date: Date = Date()) {
        runtime.withLock { $0.lastSpeedtestPostAt = date }
    }

    private static var runtimeSnapshot: (lastSpeedtestPostAt: Date?, runningSince: Date?) {
        runtime.withLock { ($0.lastSpeedtestPostAt, $0.runningSince) }
    }

    // MARK: File

    /// Ajoute la ligne d'un test raté. Aucun envoi immédiat : au plus tôt 15 minutes après.
    func record(_ line: SpeedtestFailure.Line) {
        state.lines.append(line)
        let overflow = state.lines.count + state.inFlight.count - Self.maxQueued
        if overflow > 0 { state.lines.removeFirst(min(overflow, state.lines.count)) }
        state.lastFailureAt = now()
        persist()
        schedule(after: Self.delayAfterFailure + 5)
    }

    var snapshot: State { state }

    /// Attente avant le prochain envoi possible ; 0 = maintenant.
    func delayBeforeSend(at date: Date) -> TimeInterval {
        var wait: TimeInterval = 0
        if let last = state.lastFailureAt { wait = max(wait, last.addingTimeInterval(Self.delayAfterFailure).timeIntervalSince(date)) }
        let runtime = Self.runtimeSnapshot
        if let post = runtime.lastSpeedtestPostAt {
            wait = max(wait, post.addingTimeInterval(Self.delayAfterSpeedtestPost).timeIntervalSince(date))
        }
        if runtime.runningSince != nil { wait = max(wait, 3 * 60) }
        if let notBefore = state.notBefore { wait = max(wait, notBefore.timeIntervalSince(date)) }
        return max(0, wait)
    }

    /// Au retour au premier plan : envoie si l'heure est venue, sinon programme l'envoi.
    func flushIfDue() async {
        guard !state.lines.isEmpty || !state.inFlight.isEmpty else { return }
        let wait = delayBeforeSend(at: now())
        if wait > 0 {
            schedule(after: wait + 1)
            return
        }
        _ = await sendOneBatch()
    }

    /// Un lot : au plus 50 lignes et 16 Kio, les plus anciennes d'abord.
    @discardableResult
    func sendOneBatch() async -> Outcome? {
        let date = now()
        guard enabled, SpeedtestFailure.isBuild(build) else { return nil }
        if state.inFlight.isEmpty {
            state.lines.removeAll { !SpeedtestFailure.isSendable($0, now: date) }
            guard !state.lines.isEmpty else { persist(); return nil }
            var batch = Array(state.lines.prefix(Self.maxBatchLines))
            while !batch.isEmpty, (try? body(batch).count).map({ $0 > Self.maxBodyBytes }) ?? true {
                batch.removeLast()
            }
            guard !batch.isEmpty else { return nil }
            state.lines.removeFirst(batch.count)
            state.inFlight = batch
            state.inFlightKey = UUID().uuidString
            persist()
        } else {
            state.inFlight.removeAll { !SpeedtestFailure.isSendable($0, now: date) }
            if state.inFlight.isEmpty {
                state.inFlightKey = nil
                persist()
                return await sendOneBatch()
            }
        }
        guard let key = state.inFlightKey, let payload = try? body(state.inFlight) else { return nil }
        let response = await transport(payload, key)
        let outcome = Self.outcome(status: response.status, retryAfter: response.retryAfter)
        switch outcome {
        case .sent, .rejected:
            logger.debug("SQ_SPEEDTEST_FAILURES lot \(self.state.inFlight.count) → \(response.status.map(String.init) ?? "-", privacy: .public)")
            state.inFlight = []
            state.inFlightKey = nil
            state.notBefore = nil
            persist()
            if !state.lines.isEmpty { schedule(after: Self.nextBatchDelay) }
        case .retry(let after):
            state.notBefore = now().addingTimeInterval(min(after ?? Self.retryDelay, Self.maxRetryAfter))
            persist()
        }
        return outcome
    }

    static func outcome(status: Int?, retryAfter: TimeInterval?) -> Outcome {
        guard let status else { return .retry(after: nil) }
        if (200..<300).contains(status) { return .sent }
        if [400, 413, 422].contains(status) { return .rejected }
        if status == 429, let retryAfter, retryAfter > 0 { return .retry(after: retryAfter) }
        return .retry(after: nil)
    }

    private func body(_ lines: [SpeedtestFailure.Line]) throws -> Data {
        // Clés triées : un nouvel essai renvoie exactement les mêmes octets sous la même clé d'idempotence.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(SpeedtestFailure.Batch(build: build, failures: lines))
    }

    private func schedule(after seconds: TimeInterval) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushIfDue()
        }
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Réseau

    /// Ni démonstration ni tests automatiques : leurs serveurs ne décrivent pas un vrai réseau.
    nonisolated static var isLiveEnvironment: Bool {
        !AppEnvironment.usesDemoData && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    nonisolated static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SignalQuest", isDirectory: true)
            .appendingPathComponent("SpeedtestFailures", isDirectory: true)
            .appendingPathComponent("queue-v1.json")
    }

    /// Session éphémère : ni cookie, ni cache, ni en-tête Authorization. La route ne lit aucun compte.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static let liveTransport: Transport = { body, key in
        var request = URLRequest(url: AppConfig.current.apiBaseURL.appendingPathComponent("api/speedtest/failures"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return (nil, nil) }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return (http.statusCode, retryAfter)
    }
}
