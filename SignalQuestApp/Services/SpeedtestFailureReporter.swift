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
    static let engines: Set<String> = ["cloudflare", "iperf3", "librespeed", "vps", "experience"]
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

    /// Une ligne du lot. `engine`, `operatorKey` et `experience` sont toujours présents, `null`
    /// compris : le schéma du serveur est strict et refuse une clé absente.
    struct Line: Codable, Equatable, Sendable {
        let code: String
        let phase: Phase
        let engine: String?
        let technology: String
        let operatorKey: String?
        let quarterStart: String
        /// SPEEDTEST-FAIL-2 : null pour un speedtest classique. Absent des lignes gardées par une
        /// build v1, donc lu comme null.
        let experience: Experience?

        enum CodingKeys: String, CodingKey { case code, phase, engine, technology, operatorKey, quarterStart, experience }

        init(code: String, phase: Phase, engine: String?, technology: String, operatorKey: String?, quarterStart: String,
             experience: Experience? = nil) {
            self.code = code
            self.phase = phase
            self.engine = engine
            self.technology = technology
            self.operatorKey = operatorKey
            self.quarterStart = quarterStart
            self.experience = experience
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(code, forKey: .code)
            try c.encode(phase, forKey: .phase)
            try c.encode(engine, forKey: .engine)
            try c.encode(technology, forKey: .technology)
            try c.encode(operatorKey, forKey: .operatorKey)
            try c.encode(quarterStart, forKey: .quarterStart)
            try c.encode(experience, forKey: .experience)
        }
    }

    /// SPEEDTEST-FAIL-2 : un test d'expérience fini en échec. Toutes les clés partent, `null` compris.
    struct Experience: Codable, Equatable, Sendable {
        static let tests: Set<String> = Set(ExperienceTestKind.allCases.map(\.rawValue))
        static let causes: Set<String> = [
            "server_busy", "route_changed", "http_error", "dns", "ip_mode", "connect", "tls", "timeout", "cut",
            "probe_loss", "no_network", "generic",
        ]

        let test: String
        let cause: String
        let httpStatus: Int?
        let megabytes: Double
        let durationS: Int
        /// Réglage Speedtest : iOS n'en a pas pour ces tests, toujours `auto`.
        let ipMode: String
        let addressFamily: String?
        /// RFC 7050 ; null quand la détection n'a pas abouti, jamais false par défaut.
        let nat64: Bool?
        /// Une app iOS ne lit pas le DNS chiffré du système : toujours null.
        let privateDns: String?
        let vpn: Bool

        enum CodingKeys: String, CodingKey {
            case test, cause, httpStatus, megabytes, durationS, ipMode, addressFamily, nat64, privateDns, vpn
        }

        init(test: String, cause: String, httpStatus: Int?, megabytes: Double, durationS: Int, ipMode: String = "auto",
             addressFamily: String?, nat64: Bool?, privateDns: String? = nil, vpn: Bool) {
            self.test = test
            self.cause = cause
            self.httpStatus = httpStatus
            self.megabytes = megabytes
            self.durationS = durationS
            self.ipMode = ipMode
            self.addressFamily = addressFamily
            self.nat64 = nat64
            self.privateDns = privateDns
            self.vpn = vpn
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(test, forKey: .test)
            try c.encode(cause, forKey: .cause)
            try c.encode(httpStatus, forKey: .httpStatus)
            try c.encode(megabytes, forKey: .megabytes)
            try c.encode(durationS, forKey: .durationS)
            try c.encode(ipMode, forKey: .ipMode)
            try c.encode(addressFamily, forKey: .addressFamily)
            try c.encode(nat64, forKey: .nat64)
            try c.encode(privateDns, forKey: .privateDns)
            try c.encode(vpn, forKey: .vpn)
        }

        var isValid: Bool {
            Self.tests.contains(test) && Self.causes.contains(cause)
                && httpStatus.map { (100...599).contains($0) } ?? true
                && (0...100_000).contains(megabytes) && (0...3_600).contains(durationS)
                && ["auto", "ipv4", "ipv6"].contains(ipMode)
                && addressFamily.map { ["ipv4", "ipv6"].contains($0) } ?? true
                && privateDns.map { ["off", "auto", "strict"].contains($0) } ?? true
        }
    }

    struct Batch: Encodable, Equatable {
        let version = "2"
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
        // v2 : `experience` présent pour un test d'expérience seulement, avec `UNKNOWN` et `setup` imposés.
        if line.engine == "experience" {
            guard let experience = line.experience, experience.isValid,
                  line.code == "UNKNOWN", line.phase == .setup else { return false }
        } else if line.experience != nil {
            return false
        }
        return quarter >= now.addingTimeInterval(-(7 * 24 * 3600 - 30 * 60))
            && quarter <= now.addingTimeInterval(15 * 60)
    }
}

// MARK: Tests d'expérience (SPEEDTEST-FAIL-2)

extension SpeedtestFailure {
    /// Nom de la cause dans le contrat.
    static func cause(_ cause: ExperienceFailureCause) -> String {
        switch cause {
        case .serverBusy: "server_busy"
        case .routeChanged: "route_changed"
        case .httpError: "http_error"
        case .dns: "dns"
        case .connect: "connect"
        case .tls: "tls"
        case .timeout: "timeout"
        case .cut: "cut"
        case .probeLoss: "probe_loss"
        case .noNetwork: "no_network"
        case .generic: "generic"
        }
    }

    /// Une ligne par test fini en échec (ni interrompu, ni non testé), comme Android.
    static func experienceLines(_ run: ExperienceRun, status: NetworkPathStatus, operatorKey: String?, viaVpn: Bool,
                                nat64: Bool?, now: Date) -> [Line] {
        let quarter = quarterStart(now)
        return ExperienceMethod.order.compactMap { test -> Line? in
            guard run.tests.state(of: test) == .failed else { return nil }
            let failure = run.failures[test] ?? .generic
            let usage = run.usage[test]
            var httpStatus: Int?
            if case .httpError(let status) = failure { httpStatus = status }
            let megabytes = (Double(usage?.bytes ?? 0) / 1e6 * 10).rounded() / 10
            let seconds = (Double(usage?.durationMs ?? 0) / 1_000).rounded()
            return Line(
                code: "UNKNOWN", phase: .setup, engine: "experience",
                technology: technology(status, viaVpn: viaVpn),
                operatorKey: self.operatorKey(operatorKey, status: status, viaVpn: viaVpn),
                quarterStart: quarter,
                experience: Experience(
                    test: test.rawValue, cause: cause(failure), httpStatus: httpStatus,
                    megabytes: min(max(megabytes, 0), 100_000), durationS: Int(min(max(seconds, 0), 3_600)),
                    addressFamily: run.addressFamilies[test], nat64: nat64, vpn: viaVpn
                )
            )
        }
    }

    /// RFC 7050 : le réseau annonce un préfixe NAT64 quand `ipv4only.arpa` se résout en IPv6.
    /// nil si la résolution échoue ou dépasse le délai : jamais false par défaut.
    static func detectNAT64(timeout: TimeInterval = 3) async -> Bool? {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Bool?, Never>?>(initialState: nil)
        return await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
            let finish: @Sendable (Bool?) -> Void = { value in pending.withLock { $0.take() }?.resume(returning: value) }
            DispatchQueue.global(qos: .utility).async { finish(nat64Lookup()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private static func nat64Lookup() -> Bool? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("ipv4only.arpa", nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var sawIPv4 = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            if node.pointee.ai_family == AF_INET6 { return true }
            if node.pointee.ai_family == AF_INET { sawIPv4 = true }
            cursor = node.pointee.ai_next
        }
        return sawIPv4 ? false : nil
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

    /// Les tests d'expérience ratés d'une suite (SPEEDTEST-FAIL-2), mis en file comme un speedtest
    /// raté. NAT64 n'est cherché que s'il y a au moins une ligne à envoyer.
    nonisolated static func recordExperience(_ run: ExperienceRun, status: NetworkPathStatus, operatorKey: String?) {
        guard isLiveEnvironment, ExperienceMethod.order.contains(where: { run.tests.state(of: $0) == .failed }) else { return }
        let viaVpn = VPNDetector.isActive()
        Task.detached(priority: .utility) {
            let nat64 = await SpeedtestFailure.detectNAT64()
            let lines = SpeedtestFailure.experienceLines(run, status: status, operatorKey: operatorKey, viaVpn: viaVpn,
                                                         nat64: nat64, now: Date())
            for line in lines { await shared.record(line) }
        }
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
