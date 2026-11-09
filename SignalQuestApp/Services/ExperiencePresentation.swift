import Foundation

/// Présentation commune des tests d'expérience (`presentation-v1`, contrat
/// experience-tests v3 §4, servi le 02/11 par #811) : pour chaque usage, la clé et les
/// arguments de sa phrase, de sa valeur clé et de son détail, puis leur rendu en
/// français et en anglais. Les trois apps rendent ces phrases depuis `tests`, jamais
/// depuis `highlights`. Remplace `experience-share-phrases-v1` : l'image de partage
/// reprend `share`, 60 caractères au plus.
///
/// Les textes vivent dans cette table plutôt que dans le catalogue, comme les phrases
/// de partage d'avant : le vecteur se rejoue à l'octet dans les deux langues quel que
/// soit le simulateur, espaces insécables et pluriels compris. Le vouvoiement rend le
/// français, aucun texte n'étant au tutoiement.
enum ExperiencePresentation {
    enum Use: String, CaseIterable, Sendable {
        case video, webPage, gameAndCalls, upload

        var tests: [ExperienceTestKind] {
            switch self {
            case .video: [.videoLadder, .videoAdaptive]
            case .webPage: [.webPage]
            case .gameAndCalls: [.gameAndCalls]
            case .upload: [.upload]
            }
        }
    }

    /// Une phrase du catalogue et ses arguments (nombres entiers ou qualité).
    struct Text: Equatable, Sendable {
        let key: String
        var args: [String: Arg] = [:]

        enum Arg: Equatable, Sendable {
            case int(Int)
            case string(String)
        }

        func rendered(_ language: ExperienceShareLanguage) -> String {
            ExperiencePresentation.render(self, language)
        }
    }

    struct UsePresentation: Equatable, Sendable {
        /// `measured`, `failed`, `interrupted` ou `not_tested`.
        let state: String
        /// Note sur 100 (`experience-score-v1`, jeu plafonné par son verdict), nil si non notée.
        let score: Int?
        /// Une ligne par usage, deux pour la vidéo (échelle puis lecteur adaptatif).
        let lines: [Text]
        let keyValue: Text?
        /// Lignes du détail (« Pointes au-delà de … », « Avec un téléchargement en cours … »).
        let detail: [Text]
        /// La phrase de l'image de partage : la première ligne.
        var share: Text { lines[0] }
    }

    /// Durée de lecture prévue du lecteur adaptatif, le `{m}` de « Interrompu à {n} s sur {m} ».
    static let adaptivePlannedS = 30
    static let shareMaxChars = 60
    /// Pire cas mesuré de la légende chiffrée d'un speedtest (`rules.captionMaxChars`).
    static let captionMaxChars = 127

    /// La présentation des quatre usages d'un test, telle que les trois apps la rendent.
    static func uses(tests: [String: Any], methodology: String) -> [Use: UsePresentation] {
        let scores = ExperienceScores(tests: tests)
        let byUse: [Use: Int?] = [.video: scores.video, .webPage: scores.webPage,
                                  .gameAndCalls: scores.gameAndCalls, .upload: scores.upload]
        var result: [Use: UsePresentation] = [:]
        for use in Use.allCases {
            let state = state(use, tests: tests)
            let derived: Derived? = switch use {
            case .video: videoLines(tests)
            case _ where state != "measured": nil
            case .webPage: webLines(tests)
            case .gameAndCalls: gameLines(tests, methodology: methodology)
            case .upload: uploadLines(tests)
            }
            let lines = derived.map(\.lines).flatMap { $0.isEmpty ? nil : $0 } ?? [stateText(use, state: state, tests: tests)]
            result[use] = UsePresentation(state: state, score: byUse[use] ?? nil, lines: lines,
                                          keyValue: derived?.keyValue, detail: derived?.detail ?? [])
        }
        return result
    }

    /// `measured` si au moins un test de l'usage l'est ; sinon en échec, puis interrompu, sinon non lancé.
    static func state(_ use: Use, tests: [String: Any]) -> String {
        let states = use.tests.map { object(tests[$0.rawValue])?["state"] as? String }
        return ["measured", "failed", "interrupted"].first { states.contains($0) } ?? "not_tested"
    }

    // MARK: À-coups

    /// Seuil d'un à-coup en ms entières : `experience-v3` médiane + 100, `experience-v4`
    /// médiane + min(100, max(30, médiane)). Une mesure compte si elle est STRICTEMENT
    /// supérieure. Le graphique trace ce même seuil, jamais une constante.
    static func spikeThresholdMs(medianMs: Int, methodology: String) -> Int {
        methodology == "experience-v4" ? medianMs + min(100, max(30, medianMs)) : medianMs + 100
    }

    // MARK: Verdict « Appels et jeu »

    enum GameVerdict: String, CaseIterable, Sendable {
        case all, casual, video, audio, none

        /// La note du jeu ne dit jamais plus que le verdict (décision du 28/10).
        var scoreCap: Int {
            switch self {
            case .all: 100
            case .casual: 85
            case .video: 70
            case .audio: 50
            case .none: 25
            }
        }
    }

    private static let gameSteps: [(verdict: GameVerdict, medianMs: Int, jitterMs: Int?, maxMs: Int, noSpike: Bool)] = [
        (.all, 40, 10, 80, true),
        (.casual, 80, 20, 150, false),
        (.video, 150, 30, 300, false),
        (.audio, 300, nil, 600, false),
    ]

    /// Premier palier dont toutes les conditions tiennent, bornes inclusives. Un critère non
    /// mesuré ne valide pas le palier qui l'exige. `none` seulement si une valeur mesurée
    /// dépasse le dernier palier ; avec des données manquantes, pas de verdict.
    static func gameVerdict(medianMs: Int?, jitterMs: Int?, maxMs: Int?, spikeCount: Int?) -> GameVerdict? {
        guard let medianMs else { return nil }
        for step in gameSteps {
            guard medianMs <= step.medianMs, let maxMs, maxMs <= step.maxMs else { continue }
            if let limit = step.jitterMs { guard let jitterMs, jitterMs <= limit else { continue } }
            if step.noSpike, spikeCount != 0 { continue }
            return step.verdict
        }
        let last = gameSteps[gameSteps.count - 1]
        return medianMs > last.medianMs || (maxMs.map { $0 > last.maxMs } ?? false) ? GameVerdict.none : nil
    }

    static func gameVerdict(_ game: [String: Any]) -> GameVerdict? {
        gameVerdict(medianMs: int(game["medianMs"]), jitterMs: int(game["jitterMs"]),
                    maxMs: int(game["maxMs"]), spikeCount: int(game["spikeCount"]))
    }

    // MARK: Dérivation

    private struct Derived {
        var lines: [Text]
        var keyValue: Text?
        var detail: [Text] = []
    }

    private static func plural(_ key: String, _ count: Int) -> String { "\(key)_\(count == 1 ? "one" : "other")" }

    private static let stopReasonKeys = [
        "background": "experience.state.interrupted_background",
        "network_changed": "experience.state.interrupted_network_changed",
        "offline": "experience.state.interrupted_offline",
        "user_stopped": "experience.state.interrupted_user_stopped",
    ]

    private static func stateText(_ use: Use, state: String, tests: [String: Any]) -> Text {
        if state == "failed" || state == "measured" { return Text(key: "experience.state.failed") }
        if state == "not_tested" { return Text(key: "experience.state.not_measured") }
        let interrupted = use.tests.lazy.compactMap { object(tests[$0.rawValue]) }.first { $0["state"] as? String == "interrupted" }
        let reason = interrupted?["notTestedReason"] as? String ?? ""
        return Text(key: stopReasonKeys[reason] ?? "experience.state.interrupted")
    }

    private static func qualityRank(_ quality: String) -> Int? {
        ExperienceVideoQuality(rawValue: quality).flatMap { ExperienceVideoQuality.allCases.firstIndex(of: $0) }
    }

    private static func videoLines(_ tests: [String: Any]) -> Derived {
        var derived = Derived(lines: [])
        if let ladder = object(tests["videoLadder"]), let state = ladder["state"] as? String, state == "measured" || state == "interrupted" {
            let held = objects(ladder["rungs"])
                .filter { $0["state"] as? String == "measured" && objects($0["stalls"]).isEmpty }
                .compactMap { rung -> (rung: [String: Any], quality: String, rank: Int)? in
                    guard let quality = rung["quality"] as? String, let rank = qualityRank(quality) else { return nil }
                    return (rung, quality, rank)
                }
                .max { $0.rank < $1.rank }
            if let held {
                derived.lines.append(Text(key: state == "measured" ? "experience.video.ladder_up_to" : "experience.video.ladder_at_least",
                                          args: ["q": .string(held.quality)]))
                if state == "measured", let startup = int(held.rung["startupMs"]) {
                    derived.keyValue = Text(key: "experience.video.starts_in", args: ["t": .int(startup)])
                }
            } else if state == "measured" {
                derived.lines.append(Text(key: "experience.video.ladder_stalls_from_lowest"))
            }
        }
        if let adaptive = object(tests["videoAdaptive"]) {
            switch adaptive["state"] as? String {
            case "measured":
                // La qualité la plus longtemps jouée, la plus haute en cas d'égalité ; jamais une moyenne.
                let mostly = (adaptive["timeByQualityMs"] as? [String: Any] ?? [:])
                    .compactMap { quality, value -> (quality: String, ms: Int, rank: Int)? in
                        guard let rank = qualityRank(quality), let ms = int(value), ms > 0 else { return nil }
                        return (quality, ms, rank)
                    }
                    .max { ($0.ms, $0.rank) < ($1.ms, $1.rank) }
                let stalls = objects(adaptive["stalls"]).count
                if let mostly {
                    derived.lines.append(stalls == 0
                        ? Text(key: "experience.video.adaptive_clean", args: ["q": .string(mostly.quality)])
                        : Text(key: plural("experience.video.adaptive_stalls", stalls), args: ["q": .string(mostly.quality), "n": .int(stalls)]))
                }
            case "interrupted":
                if let played = int(adaptive["playbackMs"]) {
                    derived.lines.append(Text(key: "experience.video.adaptive_interrupted",
                                              args: ["n": .int(played / 1_000), "m": .int(adaptivePlannedS)]))
                }
            default:
                break
            }
        }
        return derived
    }

    private static func webLines(_ tests: [String: Any]) -> Derived? {
        let openings = objects(object(tests["webPage"])?["openings"])
        let times = openings.filter { $0["state"] as? String == "measured" }.compactMap { int($0["totalMs"]) }
        guard let median = ExperienceHighlights.median(times), let low = times.min(), let high = times.max() else { return nil }
        let failed = openings.filter { $0["state"] as? String == "failed" }.count
        var keyValue: Text?
        if failed > 0 {
            keyValue = Text(key: plural("experience.web.failed", failed), args: ["n": .int(failed), "m": .int(openings.count)])
        } else if 10 * (high - low) >= 3 * median {
            // (max − min) ≥ 0,3 × médiane, en entiers.
            keyValue = Text(key: "experience.web.uneven")
        }
        return Derived(lines: [Text(key: "experience.web.opens_in", args: ["t": .int(median)])], keyValue: keyValue)
    }

    private static func gameLines(_ tests: [String: Any], methodology: String) -> Derived? {
        guard let game = object(tests["gameAndCalls"]), let median = int(game["medianMs"]) else { return nil }
        let verdict = gameVerdict(game)
        let max = int(game["maxMs"])
        let keyValue = max.map { Text(key: "experience.game.key", args: ["median": .int(median), "max": .int($0)]) }
            ?? Text(key: "experience.game.key_median", args: ["median": .int(median)])
        var detail = [Text(key: "experience.detail.peaks_above", args: ["ms": .int(spikeThresholdMs(medianMs: median, methodology: methodology))])]
        if let delta = int(object(game["underLoad"])?["deltaMs"]) {
            detail.append(Text(key: "experience.detail.under_load", args: ["delta": .int(delta)]))
        }
        // Sans verdict (gigue ou à-coups non envoyés), la phrase est la valeur clé, en début de phrase.
        let line = max.map { Text(key: "experience.game.line", args: ["median": .int(median), "max": .int($0)]) }
            ?? Text(key: "experience.game.line_median", args: ["median": .int(median)])
        return Derived(lines: [verdict.map { Text(key: "experience.game.\($0.rawValue)") } ?? line],
                       keyValue: verdict == nil ? nil : keyValue, detail: detail)
    }

    /// Débit en kb/s entiers, demi vers le haut : Σ octets × 8 ÷ Σ ms.
    private static func rateKbps(_ items: [[String: Any]]) -> Int {
        let bytes = items.reduce(0) { $0 + (int($1["bytes"]) ?? 0) }
        let ms = items.reduce(0) { $0 + (int($1["totalMs"]) ?? 0) }
        return (2 * bytes * 8 + ms) / (2 * ms)
    }

    private static func uploadLines(_ tests: [String: Any]) -> Derived? {
        let items = objects(object(tests["upload"])?["items"]).filter { (int($0["totalMs"]) ?? 0) > 0 }
        func median(_ kind: String) -> Int? {
            ExperienceHighlights.median(items.filter { $0["kind"] as? String == kind }.compactMap { int($0["totalMs"]) })
        }
        let line: Text
        switch (median("photo"), median("video")) {
        case let (photo?, video?): line = Text(key: "experience.upload.both", args: ["photo": .int(photo), "video": .int(video)])
        case let (nil, video?): line = Text(key: "experience.upload.video", args: ["video": .int(video)])
        case let (photo?, nil): line = Text(key: "experience.upload.photo", args: ["photo": .int(photo)])
        case (nil, nil): return nil
        }
        func withBytes(_ kind: String) -> [[String: Any]] {
            items.filter { $0["kind"] as? String == kind && (int($0["bytes"]) ?? 0) > 0 }
        }
        let rated = withBytes("video").isEmpty ? withBytes("photo") : withBytes("video")
        return Derived(lines: [line], keyValue: rated.isEmpty ? nil : Text(key: "experience.upload.rate", args: ["r": .int(rateKbps(rated))]))
    }

    // MARK: Rendu

    enum ArgType: String, Sendable {
        case quality, duration, ms, integer, rate, text
    }

    struct Entry: Sendable {
        let args: [String: ArgType]
        let fr: String
        let en: String
        var local = false
        /// Deux débits dont l'unité commune ne s'écrit qu'une fois, après le second.
        var ratePair: [String]? = nil
    }

    /// Catalogue : la référence est contracts/experience-tests/presentation-v1.json (le test vérifie l'égalité).
    static let texts: [String: Entry] = [
        "experience.video.ladder_up_to": Entry(args: ["q": .quality], fr: "Jusqu’à {q} sans coupure", en: "Up to {q} without stalling"),
        "experience.video.ladder_at_least": Entry(args: ["q": .quality], fr: "Au moins {q} sans coupure", en: "At least {q} without stalling"),
        "experience.video.ladder_stalls_from_lowest": Entry(args: [:], fr: "Coupures dès 480p", en: "Stalls from 480p"),
        "experience.video.starts_in": Entry(args: ["t": .duration], fr: "démarre en {t}", en: "starts in {t}"),
        "experience.video.adaptive_clean": Entry(args: ["q": .quality], fr: "{q} la plupart du temps, sans coupure", en: "Mostly {q}, no stalls"),
        "experience.video.adaptive_stalls_one": Entry(args: ["q": .quality, "n": .integer], fr: "{q} la plupart du temps, {n} coupure", en: "Mostly {q}, {n} stall"),
        "experience.video.adaptive_stalls_other": Entry(args: ["q": .quality, "n": .integer], fr: "{q} la plupart du temps, {n} coupures", en: "Mostly {q}, {n} stalls"),
        "experience.video.adaptive_interrupted": Entry(args: ["n": .integer, "m": .integer], fr: "Interrompu à {n}\u{00A0}s sur {m}", en: "Stopped at {n}\u{00A0}s of {m}"),
        "experience.web.opens_in": Entry(args: ["t": .duration], fr: "Une page s’ouvre en {t}", en: "A page opens in {t}"),
        "experience.web.failed_one": Entry(args: ["n": .integer, "m": .integer], fr: "{n} échec sur {m}", en: "{n} failed of {m}"),
        "experience.web.failed_other": Entry(args: ["n": .integer, "m": .integer], fr: "{n} échecs sur {m}", en: "{n} failed of {m}"),
        "experience.web.uneven": Entry(args: [:], fr: "temps irrégulier", en: "uneven times"),
        "experience.game.all": Entry(args: [:], fr: "Convient à tous les usages, jeu compétitif compris", en: "Fine for everything, competitive gaming included"),
        "experience.game.casual": Entry(args: [:], fr: "Convient aux appels vidéo et au jeu occasionnel", en: "Fine for video calls and casual gaming"),
        "experience.game.video": Entry(args: [:], fr: "Convient aux appels vidéo, pas au jeu", en: "Fine for video calls, not gaming"),
        "experience.game.audio": Entry(args: [:], fr: "Convient aux appels audio seulement", en: "Fine for audio calls only"),
        "experience.game.none": Entry(args: [:], fr: "Latence trop élevée pour le jeu et les appels", en: "Latency too high for gaming and calls"),
        "experience.game.key": Entry(args: ["median": .ms, "max": .ms], fr: "réactivité {median} · pointes à {max}", en: "responsiveness {median} · peaks at {max}"),
        "experience.game.key_median": Entry(args: ["median": .ms], fr: "réactivité {median}", en: "responsiveness {median}"),
        "experience.game.line": Entry(args: ["median": .ms, "max": .ms], fr: "Réactivité {median} · pointes à {max}", en: "Responsiveness {median} · peaks at {max}"),
        "experience.game.line_median": Entry(args: ["median": .ms], fr: "Réactivité {median}", en: "Responsiveness {median}"),
        "experience.upload.both": Entry(args: ["photo": .duration, "video": .duration], fr: "Photo en {photo} · vidéo de 30\u{00A0}s en {video}", en: "Photo in {photo} · 30\u{00A0}s video in {video}"),
        "experience.upload.photo": Entry(args: ["photo": .duration], fr: "Photo en {photo}", en: "Photo in {photo}"),
        "experience.upload.video": Entry(args: ["video": .duration], fr: "Vidéo de 30\u{00A0}s en {video}", en: "30\u{00A0}s video in {video}"),
        "experience.upload.rate": Entry(args: ["r": .rate], fr: "{r} en envoi", en: "{r} upload"),
        "experience.state.not_measured": Entry(args: [:], fr: "Non mesuré", en: "Not measured"),
        "experience.state.interrupted": Entry(args: [:], fr: "Interrompu", en: "Interrupted"),
        "experience.state.interrupted_background": Entry(args: [:], fr: "Interrompu\u{00A0}: app passée en arrière-plan", en: "Interrupted: app went to background"),
        "experience.state.interrupted_network_changed": Entry(args: [:], fr: "Interrompu\u{00A0}: réseau changé", en: "Interrupted: network changed"),
        "experience.state.interrupted_offline": Entry(args: [:], fr: "Interrompu\u{00A0}: connexion perdue", en: "Interrupted: connection lost"),
        "experience.state.interrupted_user_stopped": Entry(args: [:], fr: "Interrompu\u{00A0}: test arrêté", en: "Interrupted: test stopped"),
        "experience.state.failed": Entry(args: [:], fr: "Échec de la mesure", en: "Measurement failed"),
        "experience.detail.peaks_above": Entry(args: ["ms": .ms], fr: "Pointes au-delà de {ms}", en: "Peaks above {ms}"),
        "experience.detail.under_load": Entry(args: ["delta": .ms], fr: "Avec un téléchargement en cours\u{00A0}: +{delta}", en: "While downloading: +{delta}"),
        "experience.detail.responsiveness": Entry(args: [:], fr: "Réactivité", en: "Responsiveness"),
        "experience.detail.variation": Entry(args: [:], fr: "Variation", en: "Variation"),
        "experience.detail.typical_time": Entry(args: [:], fr: "Temps typique", en: "Typical time"),
        "experience.detail.slowest": Entry(args: [:], fr: "Plus lente", en: "Slowest"),
        "experience.detail.failures": Entry(args: [:], fr: "Échecs", en: "Failures"),
        "experience.detail.startup": Entry(args: [:], fr: "Démarrage", en: "Start-up"),
        "experience.detail.stalls": Entry(args: [:], fr: "Coupures", en: "Stalls"),
        "experience.detail.upload_speed": Entry(args: [:], fr: "Débit d’envoi", en: "Upload speed"),
        "experience.detail.how_calculated": Entry(args: [:], fr: "Comment c’est calculé", en: "How it's calculated"),
        "experience.share.caption": Entry(args: [:], fr: "Vidéo, web, jeu\u{00A0}: ma connexion testée avec SignalQuest", en: "Video, web, gaming: my connection tested with SignalQuest"),
        "speedtest.share.caption": Entry(args: [:], fr: "Débit et latence, mesurés avec #SignalQuest", en: "Speed and latency, measured with #SignalQuest"),
        "speedtest.share.caption_measured": Entry(args: ["down": .rate, "up": .rate, "ping": .ms], fr: "↓ {down} · ↑ {up} · {ping} de latence, mesuré avec #SignalQuest", en: "↓ {down} · ↑ {up} · {ping} latency, measured with #SignalQuest", ratePair: ["down", "up"]),
        "speedtest.share.caption_measured_operator": Entry(args: ["down": .rate, "up": .rate, "ping": .ms, "operator": .text], fr: "↓ {down} · ↑ {up} · {ping} de latence chez {operator}, mesuré avec #SignalQuest", en: "↓ {down} · ↑ {up} · {ping} latency on {operator}, measured with #SignalQuest", ratePair: ["down", "up"]),
        // Textes LOCAUX, affichés juste après le test : la cause d'un échec ne quitte pas le téléphone.
        "experience.local.failed_server_busy": Entry(args: [:], fr: "Échec\u{00A0}: serveur de mesure occupé", en: "Failed: measurement server busy", local: true),
        "experience.local.failed_server_redirected": Entry(args: [:], fr: "Échec\u{00A0}: serveur de mesure redirigé", en: "Failed: measurement server redirected", local: true),
    ]

    static func render(_ text: Text, _ language: ExperienceShareLanguage) -> String {
        guard let entry = texts[text.key] else {
            assertionFailure("clé inconnue : \(text.key)")
            return ""
        }
        var output = language == .fr ? entry.fr : entry.en
        var rendered = entry.args.reduce(into: [String: String]()) { result, arg in
            if let value = text.args[arg.key] { result[arg.key] = format(arg.value, value, language) }
        }
        // `ratePair` : unité commune écrite une seule fois, après le second débit.
        if let pair = entry.ratePair, pair.count == 2,
           let first = rendered[pair[0]], let second = rendered[pair[1]],
           let unit = first.range(of: "\u{00A0}", options: .backwards).map({ first[$0.lowerBound...] }),
           second.hasSuffix(unit) {
            rendered[pair[0]] = String(first[..<unit.startIndex])
        }
        for (name, value) in rendered {
            output = output.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return output
    }

    /// Légende jointe à l'image d'un speedtest (`speedtestShareCaption`, contrat du 09/11, #1010) :
    /// tout ou rien, les deux débits et une latence, sinon la légende sans chiffre ; latence de
    /// l'image (min, sinon médiane, sinon moyenne, positives comme sur l'image) arrondie demi vers le haut ; un opérateur vide
    /// compte comme absent.
    static func speedtestShareCaption(
        downloadKbps: Int?, uploadKbps: Int?,
        latencyMinMs: Double?, latencyMedianMs: Double?, latencyMeanMs: Double?,
        operator operatorName: String?
    ) -> Text {
        let ping = [latencyMinMs, latencyMedianMs, latencyMeanMs].lazy.compactMap { $0 }.first { $0.isFinite && $0 > 0 }
        guard let downloadKbps, let uploadKbps, let ping else { return Text(key: "speedtest.share.caption") }
        var args: [String: Text.Arg] = [
            "down": .int(downloadKbps), "up": .int(uploadKbps),
            "ping": .int(Int(ping.rounded(.toNearestOrAwayFromZero))),
        ]
        guard let name = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return Text(key: "speedtest.share.caption_measured", args: args)
        }
        args["operator"] = .string(name)
        return Text(key: "speedtest.share.caption_measured_operator", args: args)
    }

    /// Le texte seul d'une clé sans argument (titres du détail, légendes de partage).
    static func label(_ key: String, _ language: ExperienceShareLanguage = .current) -> String {
        render(Text(key: key), language)
    }

    static func format(_ type: ArgType, _ value: Text.Arg, _ language: ExperienceShareLanguage) -> String {
        if case .string(let string) = value { return type == .quality && string == "2160p" ? "4K" : string }
        guard case .int(let number) = value else { return "" }
        let integer = { ExperienceSharePhrases.integer($0, language) }
        let comma = language == .fr ? "," : "."
        switch type {
        case .quality, .text: return "\(number)"
        case .integer: return integer(number)
        case .ms: return "\(integer(number))\u{00A0}ms"
        case .duration:
            // Sous 1 000 ms en ms, sinon en secondes à une décimale, demi vers le haut.
            guard number >= 1_000 else { return "\(integer(number))\u{00A0}ms" }
            let tenths = (number + 50) / 100
            return "\(integer(tenths / 10))\(comma)\(tenths % 10)\u{00A0}s"
        case .rate:
            // Règle commune des débits, en kb/s entiers (comme `SQUnits.throughput`).
            if number < 9_950 {
                let tenths = (number + 50) / 100
                return (tenths % 10 == 0 ? integer(tenths / 10) : "\(integer(tenths / 10))\(comma)\(tenths % 10)") + "\u{00A0}Mb/s"
            }
            let mbps = (number + 500) / 1_000
            guard number >= 999_500 else { return "\(integer(mbps))\u{00A0}Mb/s" }
            let thousandths = String(mbps % 1_000)
            return "\(integer(mbps / 1_000))\(comma)\(String(repeating: "0", count: 3 - thousandths.count))\(thousandths)\u{00A0}Gb/s"
        }
    }

    // MARK: Lecture du contrat

    private static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private static func objects(_ value: Any?) -> [[String: Any]] { (value as? [Any] ?? []).compactMap { $0 as? [String: Any] } }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, abs(number.doubleValue) < 1e12 else { return nil }
        return Int(number.doubleValue.rounded())
    }
}
