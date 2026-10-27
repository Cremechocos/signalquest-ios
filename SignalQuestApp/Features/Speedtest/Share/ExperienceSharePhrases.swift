import Foundation

/// Langue de l'image de partage d'un test d'expérience : celle de l'app, français ou anglais.
///
/// Les phrases de l'image sont un contrat commun figé à l'octet (méthode v3, §10, vecteurs
/// `experience-share-phrases-v1`) : elles vivent dans cette table plutôt que dans le
/// catalogue, pour que les vecteurs des deux langues se rejouent quel que soit le simulateur
/// et que les espaces insécables et les pluriels restent exactement ceux du contrat.
enum ExperienceShareLanguage: String, CaseIterable, Sendable {
    case fr, en

    static var current: Self { Bundle.main.preferredLocalizations.first == "en" ? .en : .fr }

    var locale: Locale { Locale(identifier: self == .fr ? "fr_FR" : "en_US") }

    func text(_ fr: String, _ en: String) -> String { self == .fr ? fr : en }
}

/// Phrases courtes de l'image (méthode v3, §10) : une par usage, sur le JSON du contrat
/// `experience-tests-v1`, 60 caractères au plus et jamais de « … ».
enum ExperienceSharePhrases {
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

        func label(_ language: ExperienceShareLanguage) -> String {
            switch self {
            case .video: language.text("Vidéo", "Video")
            case .webPage: "Web"
            case .gameAndCalls: language.text("Jeu et appels", "Gaming & calls")
            case .upload: language.text("Envoi", "Upload")
            }
        }
    }

    /// `measured` si un de ses tests l'est ; sinon `failed`, puis `interrupted`, sinon `not_tested`.
    static func state(_ use: Use, tests: [String: Any]) -> String {
        let states = use.tests.map { state(of: tests[$0.rawValue]) }
        return ["measured", "failed", "interrupted"].first(where: states.contains) ?? "not_tested"
    }

    static func phrase(_ use: Use, tests: [String: Any], language: ExperienceShareLanguage) -> String {
        let state = state(use, tests: tests)
        guard state == "measured" else { return stateText(state, language) }
        let text: String? = switch use {
        case .video: video(tests, language)
        case .webPage: web(measured(tests["webPage"]), language)
        case .gameAndCalls: game(measured(tests["gameAndCalls"]), language)
        case .upload: upload(measured(tests["upload"]), language)
        }
        // Mesuré sans la valeur qui fait la phrase : dit en échec plutôt qu'inventé.
        return text ?? stateText("failed", language)
    }

    static func stateText(_ state: String, _ language: ExperienceShareLanguage) -> String {
        switch state {
        case "failed": language.text("Échec du test", "Test failed")
        case "interrupted": language.text("Test interrompu", "Test interrupted")
        default: language.text("Test non lancé", "Not run")
        }
    }

    /// « Échelle 80 · Adaptative 67 » ; un test non noté y est « non lancée », « en échec » ou « interrompue ».
    static func videoDetail(tests: [String: Any], scores: ExperienceScores, language: ExperienceShareLanguage) -> String {
        func part(_ name: String, _ kind: ExperienceTestKind) -> String {
            if let score = scores.score(for: kind) { return "\(name) \(score)" }
            let word = switch state(of: tests[kind.rawValue]) {
            case "failed": language.text("en échec", "failed")
            case "interrupted": language.text("interrompue", "interrupted")
            default: language.text("non lancée", "not run")
            }
            return "\(name) \(word)"
        }
        return part(language.text("Échelle", "Ladder"), .videoLadder) + " · " + part(language.text("Adaptative", "Adaptive"), .videoAdaptive)
    }

    // MARK: Gabarits

    private static func video(_ tests: [String: Any], _ language: ExperienceShareLanguage) -> String? {
        let ladder = measured(tests["videoLadder"])
        let adaptive = measured(tests["videoAdaptive"])
        // Même marche que la note : la plus haute mesurée sans coupure.
        let held = ladder.map { ladder in
            objects(ladder["rungs"])
                .filter { $0["state"] as? String == "measured" && objects($0["stalls"]).isEmpty }
                .compactMap { ($0["quality"] as? String).flatMap(ExperienceVideoQuality.init(rawValue:)) }
                .max()
        }
        let ladderText = held.map { held in
            held.map { language.text("Jusqu’en \($0.label) sans coupure", "Up to \($0.label) with no stalls") }
                ?? language.text("Aucune qualité sans coupure", "No quality without stalls")
        }
        guard let adaptive else { return ladderText }
        let stalls = objects(adaptive["stalls"]).count
        let stallText = language.text(
            "\(integer(stalls, language)) coupure\(stalls == 1 ? "" : "s")",
            "\(integer(stalls, language)) stall\(stalls == 1 ? "" : "s")"
        )
        if let ladderText {
            return ladderText + (stalls == 0
                ? language.text(", lecture fluide", ", smooth playback")
                : language.text(", \(stallText) en lecture", ", \(stallText) in playback"))
        }
        let playback = stalls == 0
            ? language.text("Lecture fluide", "Smooth playback")
            : language.text("\(stallText) en lecture", "\(stallText) in playback")
        guard let mostPlayed = mostPlayed(adaptive) else { return playback }
        return playback + language.text(", surtout en \(mostPlayed.label)", ", mostly in \(mostPlayed.label)")
    }

    /// Qualité la plus longtemps jouée, la plus haute en cas d'égalité.
    private static func mostPlayed(_ adaptive: [String: Any]) -> ExperienceVideoQuality? {
        let times = (adaptive["timeByQualityMs"] as? [String: Any] ?? [:]).compactMap { key, value -> (ExperienceVideoQuality, Int)? in
            guard let quality = ExperienceVideoQuality(rawValue: key), let ms = int(value), ms > 0 else { return nil }
            return (quality, ms)
        }
        return times.max { ($0.1, $0.0) < ($1.1, $1.0) }?.0
    }

    private static func web(_ test: [String: Any]?, _ language: ExperienceShareLanguage) -> String? {
        guard let test else { return nil }
        let openings = objects(test["openings"])
        let totals = openings.filter { $0["state"] as? String == "measured" }.compactMap { int($0["totalMs"]) }
        guard let median = ExperienceHighlights.median(totals) else { return nil }
        let time = duration(median, language)
        let failed = openings.filter { $0["state"] as? String == "failed" }.count
        guard failed > 0 else { return language.text("Pages ouvertes en \(time)", "Pages opened in \(time)") }
        let count = openings.count
        return language.text(
            "Pages ouvertes en \(time), \(failed) ouverture\(failed == 1 ? "" : "s") sur \(count) en échec",
            "Pages opened in \(time), \(failed) of \(count) opening\(count == 1 ? "" : "s") failed"
        )
    }

    /// Verdict du §4 sur la latence médiane, la gigue arrondie et les à-coups, seuils inclusifs.
    private static func game(_ test: [String: Any]?, _ language: ExperienceShareLanguage) -> String? {
        guard let test, let median = int(test["medianMs"]) else { return nil }
        let jitter = int(test["jitterMs"]).map(Int64.init)
        let spikes = int(test["spikeCount"])
        func suits(_ usage: ExperienceGameStats.Usage) -> Bool {
            ExperienceGameStats.suits(usage, medianMs: Int64(median), jitterMs: jitter, spikeCount: spikes)
        }
        let latency = "\(integer(median, language))\u{00A0}ms"
        let verdict = if suits(.competitiveGaming) {
            language.text("fluide en jeu comme en appel", "smooth for games and calls")
        } else if suits(.casualGaming) {
            language.text("bien pour le jeu occasionnel et les appels", "fine for casual games and calls")
        } else if suits(.hdVideoCall) {
            language.text("assez pour un appel vidéo HD", "enough for an HD video call")
        } else if suits(.audioCall) {
            language.text("assez pour un appel audio", "enough for a voice call")
        } else {
            language.text("trop lent pour jouer ou appeler", "too slow for games or calls")
        }
        return "\(latency), \(verdict)"
    }

    /// Médianes des `totalMs` par type ; le test envoie toujours une photo et une vidéo de 30 s.
    private static func upload(_ test: [String: Any]?, _ language: ExperienceShareLanguage) -> String? {
        guard let test else { return nil }
        func median(_ kind: String) -> String? {
            let totals = objects(test["items"]).filter { $0["kind"] as? String == kind }.compactMap { int($0["totalMs"]) }
            return ExperienceHighlights.median(totals).map { duration($0, language) }
        }
        let video = median("video"), photo = median("photo")
        let clip = "30\u{00A0}s"
        switch (video, photo) {
        case let (video?, photo?):
            return language.text("Vidéo de \(clip) envoyée en \(video), photo en \(photo)", "\(clip) video sent in \(video), photo in \(photo)")
        case let (video?, nil):
            return language.text("Vidéo de \(clip) envoyée en \(video)", "\(clip) video sent in \(video)")
        case let (nil, photo?):
            return language.text("Photo envoyée en \(photo), vidéo en échec", "Photo sent in \(photo), video failed")
        case (nil, nil):
            return nil
        }
    }

    // MARK: Nombres

    /// « 990 ms » ; « 12,4 s » / « 12.4 s » à partir d'une seconde, arrondi demi vers le haut en entiers.
    static func duration(_ ms: Int, _ language: ExperienceShareLanguage) -> String {
        guard ms >= 1_000 else { return "\(integer(ms, language))\u{00A0}ms" }
        let tenths = (ms + 50) / 100
        return "\(integer(tenths / 10, language))\(language.text(",", "."))\(tenths % 10)\u{00A0}s"
    }

    /// Milliers séparés par U+202F en français, par une virgule en anglais.
    static func integer(_ value: Int, _ language: ExperienceShareLanguage) -> String {
        let digits = String(abs(value))
        var groups: [String] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(String(digits[start..<end]), at: 0)
            end = start
        }
        return (value < 0 ? "-" : "") + groups.joined(separator: language.text("\u{202F}", ","))
    }

    // MARK: Lecture du contrat

    private static func state(of value: Any?) -> String {
        (value as? [String: Any])?["state"] as? String ?? "not_tested"
    }

    private static func measured(_ value: Any?) -> [String: Any]? {
        guard let test = value as? [String: Any], test["state"] as? String == "measured" else { return nil }
        return test
    }

    private static func objects(_ value: Any?) -> [[String: Any]] { (value as? [Any] ?? []).compactMap { $0 as? [String: Any] } }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, abs(number.doubleValue) < 1e9 else { return nil }
        return Int(number.doubleValue.rounded())
    }
}
