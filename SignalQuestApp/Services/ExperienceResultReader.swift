import Foundation

/// Un test d'expérience relu : le corps gardé sur le téléphone, ou le JSON que sert
/// `GET /api/experience-tests/{id}` (celui d'Android ou du web compris).
struct ExperienceStoredResult: Equatable, Sendable {
    struct Network: Equatable, Sendable {
        let connectionType: String
        var technology: String?
        var operatorKey: String?
        var marketCode: String?
    }

    var clientSubmissionId: String?
    let measuredAt: Date
    let platform: String
    let durationMs: Int64?
    let bytesUsed: Int64?
    let network: Network
    /// Ville de l'auteur ; jamais servie à un autre lecteur.
    var city: String?
    let tests: ExperienceTestsResult
}

/// Lecture tolérante du contrat `experience-tests-v1` (§5) : un champ inconnu est ignoré,
/// une valeur mal formée est absente, jamais remplacée par 0.
enum ExperienceResultReader {
    static func read(_ data: Data) -> ExperienceStoredResult? {
        (try? JSONSerialization.jsonObject(with: data)).flatMap { $0 as? [String: Any] }.flatMap(read)
    }

    static func read(_ object: [String: Any]) -> ExperienceStoredResult? {
        guard let measuredAt = date(object["measuredAt"]),
              let network = object["network"] as? [String: Any],
              let connectionType = string(network["connectionType"]) else { return nil }
        let location = object["location"] as? [String: Any]
        return ExperienceStoredResult(
            clientSubmissionId: string(object["clientSubmissionId"]),
            measuredAt: measuredAt,
            platform: string(object["platform"]) ?? "android",
            durationMs: int(object["durationMs"]),
            bytesUsed: int(object["bytesUsed"]),
            network: .init(connectionType: connectionType, technology: string(network["technology"]),
                           operatorKey: string(network["operatorKey"]), marketCode: string(network["marketCode"])),
            city: string(location?["city"]),
            tests: tests(object["tests"] as? [String: Any] ?? [:])
        )
    }

    static func tests(_ object: [String: Any]) -> ExperienceTestsResult {
        var tests = ExperienceTestsResult()
        if let test = object[ExperienceTestKind.videoLadder.rawValue] as? [String: Any], let state = state(test) {
            tests.videoLadder = ExperienceLadderResult(state: state, reason: reason(test), rungs: objects(test["rungs"]).compactMap(rung))
        }
        if let test = object[ExperienceTestKind.videoAdaptive.rawValue] as? [String: Any], let state = state(test) {
            let score = (test["score"] as? [String: Any]).flatMap { score -> ExperienceVideoScore? in
                guard let total = int(score["total"]), let quality = int(score["quality"]),
                      let smoothness = int(score["smoothness"]), let startup = int(score["startup"]) else { return nil }
                return ExperienceVideoScore(total: Int(total), quality: Int(quality), smoothness: Int(smoothness), startup: Int(startup))
            }
            var timeByQuality: [ExperienceVideoQuality: Int64] = [:]
            for (key, value) in test["timeByQualityMs"] as? [String: Any] ?? [:] {
                if let quality = ExperienceVideoQuality(rawValue: key), let ms = int(value) { timeByQuality[quality] = ms }
            }
            tests.videoAdaptive = ExperienceAdaptiveResult(
                state: state, reason: reason(test), playbackMs: int(test["playbackMs"]), startupMs: int(test["startupMs"]),
                timeByQualityMs: timeByQuality, switchesUp: int(test["switchesUp"]).map(Int.init),
                switchesDown: int(test["switchesDown"]).map(Int.init),
                stalls: test["stalls"] == nil ? nil : stalls(test["stalls"]),
                score: state == .measured ? score : nil
            )
        }
        if let test = object[ExperienceTestKind.webPage.rawValue] as? [String: Any], let state = state(test) {
            tests.webPage = ExperienceWebResult(
                state: state, reason: reason(test), pageBytes: int(test["pageBytes"]),
                parallelRequests: int(test["parallelRequests"]).map(Int.init),
                openings: objects(test["openings"]).map { item in
                    ExperienceWebOpening(
                        measured: string(item["state"]) == "measured", protocolName: string(item["protocol"]),
                        freshConnection: item["freshConnection"] as? Bool, dnsMs: int(item["dnsMs"]),
                        dnsCached: item["dnsCached"] as? Bool, connectMs: int(item["connectMs"]), tlsMs: int(item["tlsMs"]),
                        firstByteMs: int(item["firstByteMs"]), contentMs: int(item["contentMs"]), totalMs: int(item["totalMs"])
                    )
                }
            )
        }
        if let test = object[ExperienceTestKind.gameAndCalls.rawValue] as? [String: Any], let state = state(test) {
            let underLoad = (test["underLoad"] as? [String: Any]).flatMap { load -> ExperienceUnderLoad? in
                guard let idle = int(load["idleMs"]), let grade = string(load["grade"]), let delta = int(load["deltaMs"]),
                      let source = string(load["source"]).flatMap(ExperienceUnderLoad.Source.init(rawValue:)) else { return nil }
                return ExperienceUnderLoad(idleMs: idle, loadedDownMs: int(load["loadedDownMs"]), loadedUpMs: int(load["loadedUpMs"]),
                                           grade: grade, deltaMs: delta, source: source)
            }
            tests.gameAndCalls = ExperienceGameResult(
                state: state, reason: reason(test), probeMethod: string(test["probeMethod"]), medianMs: int(test["medianMs"]),
                jitterMs: number(test["jitterMs"]), maxMs: int(test["maxMs"]), spikeCount: int(test["spikeCount"]).map(Int.init),
                spikeShare: number(test["spikeShare"]),
                series: (test["series"] as? [Any] ?? []).compactMap { int($0).map(Int.init) }, underLoad: underLoad
            )
        }
        if let test = object[ExperienceTestKind.upload.rawValue] as? [String: Any], let state = state(test) {
            tests.upload = ExperienceUploadResult(state: state, reason: reason(test), items: objects(test["items"]).compactMap { item in
                guard let kind = string(item["kind"]).flatMap(ExperienceUploadItem.Kind.init(rawValue:)),
                      let bytes = int(item["bytes"]), let totalMs = int(item["totalMs"]) else { return nil }
                return ExperienceUploadItem(kind: kind, bytes: bytes, totalMs: totalMs)
            })
        }
        return tests
    }

    private static func rung(_ item: [String: Any]) -> ExperienceRung? {
        guard let quality = string(item["quality"]).flatMap(ExperienceVideoQuality.init(rawValue:)),
              let state = string(item["state"]).flatMap(ExperienceRung.State.init(rawValue:)) else { return nil }
        return ExperienceRung(
            quality: quality, state: state, startupMs: int(item["startupMs"]), stalls: stalls(item["stalls"]),
            bufferMinMs: int(item["bufferMinMs"]), bufferAvgMs: int(item["bufferAvgMs"]),
            receivedBps: int(item["receivedBps"]), bytes: int(item["bytes"])
        )
    }

    private static func stalls(_ value: Any?) -> [ExperienceStall] {
        objects(value).compactMap { stall in
            guard let at = int(stall["atPlaybackMs"]), let wait = int(stall["waitMs"]) else { return nil }
            return ExperienceStall(atPlaybackMs: at, waitMs: wait)
        }
    }

    private static func state(_ test: [String: Any]) -> ExperienceTestState? {
        string(test["state"]).flatMap(ExperienceTestState.init(rawValue:))
    }

    private static func reason(_ test: [String: Any]) -> ExperienceStopReason? {
        string(test["notTestedReason"]).flatMap(ExperienceStopReason.init(rawValue:))
    }

    private static func objects(_ value: Any?) -> [[String: Any]] { (value as? [Any] ?? []).compactMap { $0 as? [String: Any] } }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Entier JSON seulement : un booléen ou un nombre décimal ne vaut pas un entier.
    private static func int(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9e15 else { return nil }
        return Int64(double)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// Dates du contrat : UTC « Z », 0 à 3 décimales.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
