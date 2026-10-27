import Foundation

/// Constantes de la méthode `experience-v3`, communes à Android, iOS et au web
/// (document de méthode, révision 8). Une constante qui change une valeur mesurée
/// impose une nouvelle `methodology` ; un changement de barème, un nouveau `scoreScale`.
enum ExperienceMethod {
    static let methodology = "experience-v3"
    static let scoreScale = "video-score-v1"
    /// Serveur de mesure figé (méthode §8) : `__down`, `__up` et sondes TCP sur :443.
    static let host = "speed.cloudflare.com"
    /// Corps maximal accepté par `POST /api/experience-tests` (413 au-delà).
    static let maxBodyBytes = 64 * 1_024

    // Vidéo
    static let segmentMs: Int64 = 2_000
    static let ladderSegmentsPerRung = 5
    static let maxStallWaitMs: Int64 = 6_000
    static let startupTimeoutMs: Int64 = 10_000
    static let adaptivePlaybackMs: Int64 = 30_000
    static let adaptiveTargetBufferMs: Int64 = 10_000
    static let adaptiveClimbMinBufferMs: Int64 = 8_000
    static let adaptiveDropBelowBufferMs: Int64 = 4_000
    static let adaptiveSafety = 0.8
    static let adaptiveThroughputWindow = 3

    // Web
    static let webPageBytes: Int64 = 2_300_000
    static let webDocumentBytes: Int64 = 60_000
    static let webParallelRequests = 6
    static let webOpenings = 3
    static let webOpeningTimeoutMs: Int64 = 10_000
    /// Une résolution plus courte vient du cache du système : « en cache ».
    static let webDNSCachedBelowNanos: UInt64 = 1_000_000

    // Jeu et appels
    static let gameProbeSlots = 300
    static let gameProbeIntervalMs: Int64 = 100
    static let gameMaxInFlight = 2
    static let gameProbeTimeoutMs: Int64 = 1_000
    static let gameMinSuccessShare = 0.5
    static let gameMinValidProbes = 20
    static let gameSpikeMarginMs = 100
    static let tcpPort: UInt16 = 443
    static let loadIdleProbes = 20
    static let loadSeconds: Int64 = 5
    static let loadMaxBytes: Int64 = 40_000_000
    static let loadStreams = 4
    static let loadMinSamples = 5
    static let loadedProbeSlots = 100
    /// Un speedtest se reprend s'il a moins de 10 min (méthode §4).
    static let recentSpeedtestMaxAgeMs: Int64 = 10 * 60_000

    // Envoi
    static let uploadPhotoBytes: Int64 = 5_000_000
    static let uploadVideoBytes: Int64 = 30_000_000
    static let uploadTimeoutMs: Int64 = 60_000

    // Maximums annoncés (méthode §6) : l'avertissement en données mobiles, jamais un plafond.
    static let ladderMaxBytes: Int64 = 53_125_000
    static let adaptiveMaxBytes: Int64 = 75_000_000
    static let webMaxBytes: Int64 = webPageBytes * Int64(webOpenings)
    static let gameProbesReserveBytes: Int64 = 1_000_000
    static let gameMaxBytes: Int64 = gameProbesReserveBytes + loadMaxBytes
    static let uploadMaxBytes: Int64 = uploadPhotoBytes + uploadVideoBytes

    /// Ordre d'un lancement : la charge montante passe en dernier.
    static let order: [ExperienceTestKind] = [.videoLadder, .videoAdaptive, .webPage, .gameAndCalls, .upload]
}

/// Consommation maximale annoncée (méthode §6) et sélection par défaut (§0).
enum ExperienceBudget {
    static func maxBytes(_ test: ExperienceTestKind, recentLatencyReused: Bool = false) -> Int64 {
        switch test {
        case .videoLadder: ExperienceMethod.ladderMaxBytes
        case .videoAdaptive: ExperienceMethod.adaptiveMaxBytes
        case .webPage: ExperienceMethod.webMaxBytes
        case .gameAndCalls: recentLatencyReused ? ExperienceMethod.gameProbesReserveBytes : ExperienceMethod.gameMaxBytes
        case .upload: ExperienceMethod.uploadMaxBytes
        }
    }

    static func maxBytes(_ selection: Set<ExperienceTestKind>, recentLatencyReused: Bool = false) -> Int64 {
        selection.reduce(0) { $0 + maxBytes($1, recentLatencyReused: recentLatencyReused) }
    }

    /// Mégaoctets arrondis au-dessus : on annonce un maximum, jamais moins que la réalité.
    static func megabytesCeil(_ bytes: Int64) -> Int {
        Int((bytes + 999_999) / 1_000_000)
    }

    /// En données mobiles : échelle, web, jeu et appels ; en Wi-Fi, les cinq.
    static func defaultSelection(onMobileData: Bool) -> Set<ExperienceTestKind> {
        onMobileData ? [.videoLadder, .webPage, .gameAndCalls] : Set(ExperienceTestKind.allCases)
    }
}

// MARK: - Résultat (contrat `experience-tests-v1`)

enum ExperienceVideoQuality: String, CaseIterable, Comparable, Sendable {
    case p480 = "480p", p720 = "720p", p1080 = "1080p", p1440 = "1440p", p2160 = "2160p"

    var requiredBps: Int64 {
        switch self {
        case .p480: 1_500_000
        case .p720: 3_000_000
        case .p1080: 6_000_000
        case .p1440: 12_000_000
        case .p2160: 20_000_000
        }
    }

    /// Points du barème `video-score-v1`.
    var scorePoints: Int {
        switch self {
        case .p480: 8
        case .p720: 18
        case .p1080: 28
        case .p1440: 34
        case .p2160: 40
        }
    }

    /// Octets d'un segment de 2 s.
    var segmentBytes: Int64 { requiredBps * ExperienceMethod.segmentMs / 1_000 / 8 }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    var higher: Self? { Self.allCases.dropFirst(rank + 1).first }
}

enum ExperienceTestState: String, Sendable {
    case measured, notTested = "not_tested", interrupted, failed
}

/// Cause extérieure qui coupe la suite (`notTestedReason`). Aucun plafond : pas de `cap`.
enum ExperienceStopReason: String, Sendable {
    case background, networkChanged = "network_changed", offline, userStopped = "user_stopped"
}

struct ExperienceStall: Equatable, Sendable {
    let atPlaybackMs: Int64
    let waitMs: Int64
}

struct ExperienceVideoScore: Equatable, Sendable {
    let total: Int
    let quality: Int
    let smoothness: Int
    let startup: Int
}

struct ExperienceRung: Equatable, Sendable {
    enum State: String, Sendable { case measured, notTested = "not_tested", abandoned }

    let quality: ExperienceVideoQuality
    let state: State
    var startupMs: Int64?
    var stalls: [ExperienceStall] = []
    var bufferMinMs: Int64?
    var bufferAvgMs: Int64?
    var receivedBps: Int64?
    var bytes: Int64?
}

struct ExperienceLadderResult: Equatable, Sendable {
    let state: ExperienceTestState
    var reason: ExperienceStopReason?
    var rungs: [ExperienceRung] = []
}

struct ExperienceAdaptiveResult: Equatable, Sendable {
    let state: ExperienceTestState
    var reason: ExperienceStopReason?
    var playbackMs: Int64?
    var startupMs: Int64?
    var timeByQualityMs: [ExperienceVideoQuality: Int64] = [:]
    var switchesUp: Int?
    var switchesDown: Int?
    var stalls: [ExperienceStall]?
    var score: ExperienceVideoScore?
}

struct ExperienceWebOpening: Equatable, Sendable {
    let measured: Bool
    var protocolName: String?
    var freshConnection: Bool?
    var dnsMs: Int64?
    var dnsCached: Bool?
    var connectMs: Int64?
    var tlsMs: Int64?
    var firstByteMs: Int64?
    var contentMs: Int64?
    var totalMs: Int64?
}

struct ExperienceWebResult: Equatable, Sendable {
    let state: ExperienceTestState
    var reason: ExperienceStopReason?
    var pageBytes: Int64?
    var parallelRequests: Int?
    var openings: [ExperienceWebOpening] = []
}

struct ExperienceUnderLoad: Equatable, Sendable {
    enum Source: String, Sendable { case recentSpeedtest = "recent_speedtest", shortLoad = "short_load" }

    let idleMs: Int64
    let loadedDownMs: Int64?
    let loadedUpMs: Int64?
    let grade: String
    let deltaMs: Int64
    let source: Source
}

struct ExperienceGameResult: Equatable, Sendable {
    let state: ExperienceTestState
    var reason: ExperienceStopReason?
    /// Apps : poignée de main TCP.
    var probeMethod: String?
    var medianMs: Int64?
    /// Décimal en interne ; arrondi une seule fois, demi vers le haut, à l'écriture.
    var jitterMs: Double?
    var maxMs: Int64?
    var spikeCount: Int?
    var spikeShare: Double?
    var series: [Int] = []
    var underLoad: ExperienceUnderLoad?
}

struct ExperienceUploadItem: Equatable, Sendable {
    enum Kind: String, Sendable { case photo, video }

    let kind: Kind
    let bytes: Int64
    let totalMs: Int64
}

struct ExperienceUploadResult: Equatable, Sendable {
    let state: ExperienceTestState
    var reason: ExperienceStopReason?
    var items: [ExperienceUploadItem] = []
}

/// Les tests d'un lancement ; un test non sélectionné est absent.
struct ExperienceTestsResult: Equatable, Sendable {
    var videoLadder: ExperienceLadderResult?
    var videoAdaptive: ExperienceAdaptiveResult?
    var webPage: ExperienceWebResult?
    var gameAndCalls: ExperienceGameResult?
    var upload: ExperienceUploadResult?

    func state(of test: ExperienceTestKind) -> ExperienceTestState? {
        switch test {
        case .videoLadder: videoLadder?.state
        case .videoAdaptive: videoAdaptive?.state
        case .webPage: webPage?.state
        case .gameAndCalls: gameAndCalls?.state
        case .upload: upload?.state
        }
    }
}

extension ExperienceTestsResult {
    /// Relit les `tests` que sert `GET /api/experience-tests/{id}` (contrat v1 §5) : la
    /// forme exacte de l'envoi, pour l'auteur comme pour un autre lecteur. Un test dont
    /// l'état est inconnu est laissé de côté, une valeur mal formée reste absente.
    init(served: [String: JSONValue]) {
        self.init()
        typealias Reader = ExperienceServedReader
        if let test = Reader.object(served[ExperienceTestKind.videoLadder.rawValue]), let state = Reader.state(test) {
            videoLadder = ExperienceLadderResult(state: state, reason: Reader.reason(test), rungs: Reader.array(test["rungs"]).compactMap { item in
                guard let quality = Reader.string(item["quality"]).flatMap(ExperienceVideoQuality.init(rawValue:)),
                      let state = Reader.string(item["state"]).flatMap(ExperienceRung.State.init(rawValue:)) else { return nil }
                return ExperienceRung(
                    quality: quality, state: state, startupMs: Reader.int(item["startupMs"]), stalls: Reader.stalls(item["stalls"]) ?? [],
                    bufferMinMs: Reader.int(item["bufferMinMs"]), bufferAvgMs: Reader.int(item["bufferAvgMs"]),
                    receivedBps: Reader.int(item["receivedBps"]), bytes: Reader.int(item["bytes"])
                )
            })
        }
        if let test = Reader.object(served[ExperienceTestKind.videoAdaptive.rawValue]), let state = Reader.state(test) {
            var timeByQualityMs: [ExperienceVideoQuality: Int64] = [:]
            for (key, value) in Reader.object(test["timeByQualityMs"]) ?? [:] {
                if let quality = ExperienceVideoQuality(rawValue: key), let ms = Reader.int(value) { timeByQualityMs[quality] = ms }
            }
            let score = Reader.object(test["score"]).flatMap { score -> ExperienceVideoScore? in
                guard let total = Reader.int(score["total"]), let quality = Reader.int(score["quality"]),
                      let smoothness = Reader.int(score["smoothness"]), let startup = Reader.int(score["startup"]) else { return nil }
                return ExperienceVideoScore(total: Int(total), quality: Int(quality), smoothness: Int(smoothness), startup: Int(startup))
            }
            videoAdaptive = ExperienceAdaptiveResult(
                state: state, reason: Reader.reason(test), playbackMs: Reader.int(test["playbackMs"]),
                startupMs: Reader.int(test["startupMs"]), timeByQualityMs: timeByQualityMs,
                switchesUp: Reader.int(test["switchesUp"]).map(Int.init), switchesDown: Reader.int(test["switchesDown"]).map(Int.init),
                stalls: Reader.stalls(test["stalls"]), score: score
            )
        }
        if let test = Reader.object(served[ExperienceTestKind.webPage.rawValue]), let state = Reader.state(test) {
            webPage = ExperienceWebResult(
                state: state, reason: Reader.reason(test), pageBytes: Reader.int(test["pageBytes"]),
                parallelRequests: Reader.int(test["parallelRequests"]).map(Int.init),
                openings: Reader.array(test["openings"]).map { item in
                    ExperienceWebOpening(
                        measured: Reader.string(item["state"]) == "measured", protocolName: Reader.string(item["protocol"]),
                        freshConnection: Reader.bool(item["freshConnection"]), dnsMs: Reader.int(item["dnsMs"]),
                        dnsCached: Reader.bool(item["dnsCached"]), connectMs: Reader.int(item["connectMs"]),
                        tlsMs: Reader.int(item["tlsMs"]), firstByteMs: Reader.int(item["firstByteMs"]),
                        contentMs: Reader.int(item["contentMs"]), totalMs: Reader.int(item["totalMs"])
                    )
                }
            )
        }
        if let test = Reader.object(served[ExperienceTestKind.gameAndCalls.rawValue]), let state = Reader.state(test) {
            let underLoad = Reader.object(test["underLoad"]).flatMap { load -> ExperienceUnderLoad? in
                guard let idleMs = Reader.int(load["idleMs"]), let grade = Reader.string(load["grade"]),
                      let deltaMs = Reader.int(load["deltaMs"]),
                      let source = Reader.string(load["source"]).flatMap(ExperienceUnderLoad.Source.init(rawValue:)) else { return nil }
                return ExperienceUnderLoad(
                    idleMs: idleMs, loadedDownMs: Reader.int(load["loadedDownMs"]), loadedUpMs: Reader.int(load["loadedUpMs"]),
                    grade: grade, deltaMs: deltaMs, source: source
                )
            }
            gameAndCalls = ExperienceGameResult(
                state: state, reason: Reader.reason(test), probeMethod: Reader.string(test["probeMethod"]),
                medianMs: Reader.int(test["medianMs"]), jitterMs: Reader.number(test["jitterMs"]), maxMs: Reader.int(test["maxMs"]),
                spikeCount: Reader.int(test["spikeCount"]).map(Int.init), spikeShare: Reader.number(test["spikeShare"]),
                series: (Reader.values(test["series"]) ?? []).compactMap { Reader.int($0).map(Int.init) }, underLoad: underLoad
            )
        }
        if let test = Reader.object(served[ExperienceTestKind.upload.rawValue]), let state = Reader.state(test) {
            upload = ExperienceUploadResult(state: state, reason: Reader.reason(test), items: Reader.array(test["items"]).compactMap { item in
                guard let kind = Reader.string(item["kind"]).flatMap(ExperienceUploadItem.Kind.init(rawValue:)),
                      let bytes = Reader.int(item["bytes"]), let totalMs = Reader.int(item["totalMs"]) else { return nil }
                return ExperienceUploadItem(kind: kind, bytes: bytes, totalMs: totalMs)
            })
        }
    }
}

/// Lecture tolérante des valeurs servies : un entier JSON, une chaîne, un objet.
private enum ExperienceServedReader {
    static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let object)? = value { return object }
        return nil
    }

    static func values(_ value: JSONValue?) -> [JSONValue]? {
        if case .array(let array)? = value { return array }
        return nil
    }

    static func array(_ value: JSONValue?) -> [[String: JSONValue]] {
        (values(value) ?? []).compactMap { object($0) }
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let string)? = value { return string }
        return nil
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        if case .bool(let bool)? = value { return bool }
        return nil
    }

    static func number(_ value: JSONValue?) -> Double? {
        if case .number(let number)? = value, number.isFinite { return number }
        return nil
    }

    /// Un entier exact seulement : 41.5 n'est pas une durée en ms.
    static func int(_ value: JSONValue?) -> Int64? {
        guard let number = number(value), number == number.rounded(), abs(number) < 9_007_199_254_740_992 else { return nil }
        return Int64(number)
    }

    static func state(_ test: [String: JSONValue]) -> ExperienceTestState? {
        string(test["state"]).flatMap(ExperienceTestState.init(rawValue:))
    }

    static func reason(_ test: [String: JSONValue]) -> ExperienceStopReason? {
        string(test["notTestedReason"]).flatMap(ExperienceStopReason.init(rawValue:))
    }

    static func stalls(_ value: JSONValue?) -> [ExperienceStall]? {
        values(value).map { items in
            items.compactMap { object($0) }.compactMap { item in
                guard let at = int(item["atPlaybackMs"]), let wait = int(item["waitMs"]) else { return nil }
                return ExperienceStall(atPlaybackMs: at, waitMs: wait)
            }
        }
    }
}

/// Le corps de `POST /api/experience-tests` (contrat v1 §5 et §6). `isPublic` et
/// `isVisibleOnMap` ne sont jamais envoyés ; `observedPlmn` non plus (iOS ne l'a pas).
struct ExperienceSubmission: Equatable, Sendable {
    struct Network: Equatable, Sendable {
        /// `cellular`, `wifi` ou `unknown`.
        let connectionType: String
        var technology: String?
        var operatorKey: String?
        var marketCode: String?
    }

    struct Location: Equatable, Sendable {
        let city: String
        let marketCode: String
    }

    let clientSubmissionId: UUID
    let appVersion: String?
    let measuredAt: Date
    let durationMs: Int64
    let bytesUsed: Int64
    let network: Network
    /// `nil` dans une zone privée active, ou sans ville : aucune ville gardée.
    let location: Location?
    let tests: ExperienceTestsResult

    var jsonObject: [String: Any] {
        var network: [String: Any] = ["connectionType": self.network.connectionType]
        network["technology"] = self.network.technology
        network["operatorKey"] = self.network.operatorKey
        network["marketCode"] = self.network.marketCode
        var object: [String: Any] = [
            "methodology": ExperienceMethod.methodology,
            "scoreScale": ExperienceMethod.scoreScale,
            "clientSubmissionId": clientSubmissionId.uuidString.lowercased(),
            "platform": "ios",
            "measuredAt": Self.measuredAtText(measuredAt),
            "durationMs": durationMs,
            "bytesUsed": bytesUsed,
            "network": network,
            "location": location.map { ["city": $0.city, "marketCode": $0.marketCode] as Any } ?? NSNull(),
            "tests": Self.tests(tests)
        ]
        object["appVersion"] = appVersion.map { String($0.prefix(64)) }
        return object
    }

    func body() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }

    /// UTC avec « Z » et 3 décimales (le serveur refuse un décalage ou plus de 3 décimales).
    static func measuredAtText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Arrondi du contrat, comme `Math.round` : demi vers le haut.
    static func roundHalfUp(_ value: Double) -> Int64 { Int64((value + 0.5).rounded(.down)) }

    private static func base(_ state: ExperienceTestState, _ reason: ExperienceStopReason?) -> [String: Any] {
        var object: [String: Any] = ["state": state.rawValue]
        // `notTestedReason` seulement avec `not_tested` ou `interrupted`.
        if state == .notTested || state == .interrupted { object["notTestedReason"] = reason?.rawValue }
        return object
    }

    private static func stalls(_ stalls: [ExperienceStall]) -> [[String: Any]] {
        stalls.map { ["atPlaybackMs": $0.atPlaybackMs, "waitMs": $0.waitMs] }
    }

    static func tests(_ tests: ExperienceTestsResult) -> [String: Any] {
        var object: [String: Any] = [:]
        if let ladder = tests.videoLadder {
            var test = base(ladder.state, ladder.reason)
            if !ladder.rungs.isEmpty {
                test["rungs"] = ladder.rungs.map { rung -> [String: Any] in
                    var item: [String: Any] = [
                        "quality": rung.quality.rawValue, "requiredBps": rung.quality.requiredBps, "state": rung.state.rawValue
                    ]
                    item["startupMs"] = rung.startupMs
                    if rung.state != .notTested { item["stalls"] = stalls(rung.stalls) }
                    item["bufferMinMs"] = rung.bufferMinMs
                    item["bufferAvgMs"] = rung.bufferAvgMs
                    item["receivedBps"] = rung.receivedBps
                    item["bytes"] = rung.bytes
                    return item
                }
            }
            object[ExperienceTestKind.videoLadder.rawValue] = test
        }
        if let adaptive = tests.videoAdaptive {
            var test = base(adaptive.state, adaptive.reason)
            test["playbackMs"] = adaptive.playbackMs
            test["startupMs"] = adaptive.startupMs
            if !adaptive.timeByQualityMs.isEmpty {
                test["timeByQualityMs"] = Dictionary(uniqueKeysWithValues: adaptive.timeByQualityMs.map { ($0.key.rawValue, $0.value) })
            }
            test["switchesUp"] = adaptive.switchesUp
            test["switchesDown"] = adaptive.switchesDown
            test["stalls"] = adaptive.stalls.map(stalls)
            // `score` seulement pour une lecture allée au bout.
            if adaptive.state == .measured, let score = adaptive.score {
                test["score"] = ["total": score.total, "quality": score.quality, "smoothness": score.smoothness, "startup": score.startup]
            }
            object[ExperienceTestKind.videoAdaptive.rawValue] = test
        }
        if let web = tests.webPage {
            var test = base(web.state, web.reason)
            test["pageBytes"] = web.pageBytes
            test["parallelRequests"] = web.parallelRequests
            if !web.openings.isEmpty {
                test["openings"] = web.openings.map { opening -> [String: Any] in
                    var item: [String: Any] = ["state": opening.measured ? "measured" : "failed"]
                    item["protocol"] = opening.protocolName
                    item["freshConnection"] = opening.freshConnection
                    // Sans connexion neuve, le serveur refuse toute phase de connexion, `dnsCached` compris.
                    if opening.freshConnection == true {
                        item["dnsMs"] = opening.dnsMs
                        item["dnsCached"] = opening.dnsCached
                        item["connectMs"] = opening.connectMs
                        item["tlsMs"] = opening.tlsMs
                    }
                    item["firstByteMs"] = opening.firstByteMs
                    item["contentMs"] = opening.contentMs
                    item["totalMs"] = opening.totalMs
                    return item
                }
            }
            object[ExperienceTestKind.webPage.rawValue] = test
        }
        if let game = tests.gameAndCalls {
            var test = base(game.state, game.reason)
            test["probeMethod"] = game.probeMethod
            if !game.series.isEmpty {
                test["series"] = Array(game.series.prefix(ExperienceMethod.gameProbeSlots))
                test["probeCount"] = min(game.series.count, ExperienceMethod.gameProbeSlots)
            }
            test["medianMs"] = game.medianMs
            test["jitterMs"] = game.jitterMs.map(roundHalfUp)
            test["maxMs"] = game.maxMs
            test["spikeCount"] = game.spikeCount
            test["spikeShare"] = game.spikeShare
            if let load = game.underLoad {
                var underLoad: [String: Any] = [
                    "idleMs": load.idleMs, "grade": load.grade, "deltaMs": load.deltaMs, "source": load.source.rawValue
                ]
                underLoad["loadedDownMs"] = load.loadedDownMs
                underLoad["loadedUpMs"] = load.loadedUpMs
                test["underLoad"] = underLoad
            }
            object[ExperienceTestKind.gameAndCalls.rawValue] = test
        }
        if let upload = tests.upload {
            var test = base(upload.state, upload.reason)
            if !upload.items.isEmpty {
                test["items"] = upload.items.map { ["kind": $0.kind.rawValue, "bytes": $0.bytes, "totalMs": $0.totalMs] }
            }
            object[ExperienceTestKind.upload.rawValue] = test
        }
        return object
    }
}
