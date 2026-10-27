import Foundation

extension ExperienceVideoQuality {
    /// « 4K » pour 2160p, comme les lecteurs vidéo.
    var label: String { self == .p2160 ? "4K" : rawValue }
}

/// Phrases du résultat, une par test (maquette v3 validée le 26/10) : la valeur mesurée,
/// jamais une valeur inventée ; ce qui n'est pas mesuré est dit.
enum ExperienceResultText {
    struct Line: Equatable {
        let headline: String
        var detail: String?
        /// Note vidéo /100, affichée à part.
        var score: Int?
    }

    static func line(_ test: ExperienceTestKind, in tests: ExperienceTestsResult, failure: ExperienceFailureCause? = nil) -> Line {
        switch test {
        case .videoLadder: tests.videoLadder.map(ladder) ?? notMeasured
        case .videoAdaptive: tests.videoAdaptive.map(adaptive) ?? notMeasured
        case .webPage: tests.webPage.map { web($0, failure: failure) } ?? notMeasured
        case .gameAndCalls: tests.gameAndCalls.map { game($0, failure: failure) } ?? notMeasured
        case .upload: tests.upload.map { upload($0, failure: failure) } ?? notMeasured
        }
    }

    static let notMeasured = Line(headline: String(localized: "Non mesuré"))

    // MARK: Vidéo

    /// Meilleur palier tenu sans coupure, ou nil.
    static func bestCleanRung(_ result: ExperienceLadderResult) -> ExperienceRung? {
        result.rungs.filter { $0.state == .measured && $0.stalls.isEmpty }.max { $0.quality < $1.quality }
    }

    static func ladder(_ result: ExperienceLadderResult) -> Line {
        let best = bestCleanRung(result)
        let headline: String
        switch (result.state, best) {
        case (.measured, let best?): headline = String(localized: "Jusqu’à \(best.quality.label) sans coupure")
        case (.interrupted, let best?): headline = String(localized: "Au moins \(best.quality.label) sans coupure")
        case (.measured, nil): headline = String(localized: "Coupures dès 480p")
        default: return stateLine(result.state, reason: result.reason, failure: nil)
        }
        var parts: [String] = []
        if let stalled = result.rungs.first(where: { !$0.stalls.isEmpty }) {
            parts.append(String(localized: "\(stalled.quality.label) : \(stalls(stalled.stalls.count))"))
        }
        if let best, let startup = best.startupMs {
            parts.append(String(localized: "démarrage \(waiting(startup)) en \(best.quality.label)"))
        }
        return Line(headline: headline, detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// Qualité moyenne pondérée par le temps : la plus haute dont le débit tient sous la moyenne.
    static func averageQuality(_ timeByQualityMs: [ExperienceVideoQuality: Int64]) -> (quality: ExperienceVideoQuality, bps: Int64)? {
        let total = timeByQualityMs.values.reduce(0, +)
        guard total > 0 else { return nil }
        let weighted = timeByQualityMs.reduce(0.0) { $0 + Double($1.key.requiredBps) * Double($1.value) } / Double(total)
        let quality = ExperienceVideoQuality.allCases.last { Double($0.requiredBps) <= weighted } ?? .p480
        return (quality, Int64(weighted.rounded()))
    }

    static func adaptive(_ result: ExperienceAdaptiveResult) -> Line {
        guard result.state == .measured else {
            if result.state == .interrupted, let played = result.playbackMs {
                let seconds = Int(played / 1_000), total = Int(ExperienceMethod.adaptivePlaybackMs / 1_000)
                return Line(headline: String(localized: "Interrompu à \(seconds) s sur \(total) · pas de note"))
            }
            return stateLine(result.state, reason: result.reason, failure: nil)
        }
        var parts: [String] = []
        if let average = averageQuality(result.timeByQualityMs) {
            parts.append(String(localized: "\(average.quality.label) en moyenne"))
        }
        let stallList = result.stalls ?? []
        if stallList.isEmpty {
            parts.append(String(localized: "sans coupure"))
        } else {
            let wait = stallList.reduce(0) { $0 + $1.waitMs }
            parts.append(String(localized: "\(stalls(stallList.count)) de \(waiting(wait))"))
        }
        var line = Line(headline: parts.joined(separator: ", "), score: result.score?.total)
        if let score = result.score {
            line.detail = String(localized: "Qualité \(score.quality)/40 · Fluidité \(score.smoothness)/40 · Démarrage \(score.startup)/20 pts")
        }
        return line
    }

    // MARK: Web

    struct WebStats: Equatable {
        let medianMs: Int64
        let minMs: Int64
        let maxMs: Int64
        let failures: Int
        let openings: Int
        var isStable: Bool { Double(maxMs - minMs) < 0.3 * Double(medianMs) }
    }

    static func webStats(_ result: ExperienceWebResult) -> WebStats? {
        let totals = result.openings.compactMap { $0.measured ? $0.totalMs : nil }.sorted()
        guard let first = totals.first, let last = totals.last,
              let median = ExperienceHighlights.median(totals.map(Int.init)) else { return nil }
        return WebStats(medianMs: Int64(median), minMs: first, maxMs: last,
                        failures: result.openings.count - totals.count, openings: result.openings.count)
    }

    static func web(_ result: ExperienceWebResult, failure: ExperienceFailureCause?) -> Line {
        guard result.state == .measured, let stats = webStats(result) else {
            return stateLine(result.state, reason: result.reason, failure: failure)
        }
        let headline = String(localized: "Une page type s’ouvre en \(waiting(stats.medianMs))")
        let stability = stats.isStable ? String(localized: "stable") : String(localized: "irrégulière")
        let measured = stats.openings - stats.failures
        let detail = [String(localized: "Médiane de \(measured) ouvertures"), stability,
                      String(localized: "\(stats.failures) échecs sur \(stats.openings)")]
        return Line(headline: headline, detail: detail.joined(separator: " · "))
    }

    // MARK: Jeu et appels

    static func gameVerdict(medianMs: Int64, jitterMs: Int64?, spikeCount: Int?) -> String {
        func suits(_ usage: ExperienceGameStats.Usage) -> Bool {
            ExperienceGameStats.suits(usage, medianMs: medianMs, jitterMs: jitterMs, spikeCount: spikeCount)
        }
        if suits(.competitiveGaming) { return String(localized: "Convient à tous les usages, jeu compétitif compris") }
        if suits(.casualGaming), suits(.hdVideoCall) {
            return String(localized: "Convient aux appels vidéo et au jeu occasionnel, pas au jeu compétitif")
        }
        if suits(.hdVideoCall) { return String(localized: "Convient aux appels vidéo, pas au jeu") }
        if suits(.audioCall) { return String(localized: "Convient aux appels audio seulement") }
        return String(localized: "Latence trop élevée pour le jeu et les appels")
    }

    static func game(_ result: ExperienceGameResult, failure: ExperienceFailureCause?) -> Line {
        guard result.state == .measured, let median = result.medianMs else {
            return stateLine(result.state, reason: result.reason, failure: failure)
        }
        let jitter = result.jitterMs.map(ExperienceSubmission.roundHalfUp)
        var parts = ["\(median) ms"]
        if let jitter = result.jitterMs { parts.append(String(localized: "gigue \(SQUnits.jitter(jitter))")) }
        if let spikes = result.spikeCount { parts.append(String(localized: "\(spikes) à-coups")) }
        if let max = result.maxMs { parts.append("MAX \(max) ms") }
        return Line(headline: gameVerdict(medianMs: median, jitterMs: jitter, spikeCount: result.spikeCount),
                    detail: parts.joined(separator: " · "))
    }

    // MARK: Envoi

    static func uploadMbps(_ item: ExperienceUploadItem) -> Double? {
        guard item.totalMs > 0 else { return nil }
        return Double(item.bytes) * 8 / Double(item.totalMs) / 1_000
    }

    static func upload(_ result: ExperienceUploadResult, failure: ExperienceFailureCause?) -> Line {
        let photo = result.items.first { $0.kind == .photo }, video = result.items.first { $0.kind == .video }
        guard result.state == .measured, photo != nil || video != nil else { return stateLine(result.state, reason: result.reason, failure: failure) }
        var parts: [String] = []
        if let photo { parts.append(String(localized: "Photo envoyée en \(waiting(photo.totalMs))")) }
        if let video { parts.append(String(localized: "vidéo de 30 s en \(waiting(video.totalMs))")) }
        let rates = [photo, video].compactMap { $0.flatMap(uploadMbps) }.map { SQUnits.throughput(mbps: $0) }
        let detail: String? = switch rates.count {
        case 2: String(localized: "\(rates[0]) et \(rates[1]) en montant")
        case 1: String(localized: "\(rates[0]) en montant")
        default: nil
        }
        return Line(headline: parts.joined(separator: " · "), detail: detail)
    }

    // MARK: États

    static func stateLine(_ state: ExperienceTestState, reason: ExperienceStopReason?, failure: ExperienceFailureCause?) -> Line {
        switch state {
        case .measured: return notMeasured
        case .notTested: return Line(headline: String(localized: "Non mesuré"))
        case .interrupted: return Line(headline: String(localized: "Interrompu"), detail: reason.map(stopReason))
        case .failed:
            switch failure {
            case .serverBusy?: return Line(headline: String(localized: "Échec : serveur de mesure occupé"))
            case .routeChanged?: return Line(headline: String(localized: "Échec : serveur de mesure redirigé"))
            default: return Line(headline: String(localized: "Échec de la mesure"))
            }
        }
    }

    static func stopReason(_ reason: ExperienceStopReason) -> String {
        switch reason {
        case .background: String(localized: "app passée en arrière-plan")
        case .networkChanged: String(localized: "réseau changé")
        case .offline: String(localized: "connexion perdue")
        case .userStopped: String(localized: "test arrêté")
        }
    }

    // MARK: Unités

    /// 850 ms, puis 2,1 s au-delà d'une seconde.
    static func waiting(_ ms: Int64) -> String { ExperienceHighlights.waitingTime(Int(ms)) }

    /// « 1 coupure », « 4 coupures ».
    static func stalls(_ count: Int) -> String {
        String(localized: "\(count) coupures")
    }

    /// « 109,0 Mo », en mégaoctets décimaux comme l'annonce de consommation.
    static func megabytes(_ bytes: Int64) -> String {
        let value = (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(value) Mo")
    }

    /// Durée annoncée avant le lancement : « environ 2 min 30 », « environ 50 s ».
    static func about(seconds: Int) -> String {
        guard seconds >= 60 else { return String(localized: "environ \(seconds) s") }
        let rest = seconds % 60 < 10 ? "0\(seconds % 60)" : "\(seconds % 60)"
        return String(localized: "environ \(seconds / 60) min \(rest)")
    }

    /// « 2 min 39 s », « 58 s », sans coupure de ligne au milieu.
    static func duration(seconds: Int) -> String {
        seconds < 60 ? "\(seconds)\u{00A0}s" : String(localized: "\(seconds / 60) min \(seconds % 60) s")
    }
}
