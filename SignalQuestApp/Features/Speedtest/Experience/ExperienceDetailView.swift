import SwiftUI

/// Détail d'un test du résultat (maquette v3, « Détail ») : chaque valeur mesurée, ce qui ne
/// l'est pas, la consommation du test et la méthode. Rien n'est recalculé ni estimé ici.
struct ExperienceDetailView: View {
    let tests: ExperienceTestsResult
    var failure: ExperienceFailureCause?
    var usage: ExperienceTestUsage?
    /// Âge du speedtest dont les latences sous charge ont été reprises, quand on le connaît.
    var reusedSpeedtestAge: TimeInterval?
    let test: ExperienceTestKind
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ExperienceBackBar(title: test.title, action: back)
            Text(verbatim: line.headline)
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("experience.detail.headline")

            content

            if let usage {
                Text("Données utilisées : \(ExperienceResultText.megabytes(usage.bytes)) · durée \(ExperienceResultText.duration(seconds: Int(usage.durationMs / 1_000)))")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            ExperienceMethodNote(test: test)
        }
        .accessibilityIdentifier("experience.detail.\(test.rawValue)")
    }

    private var line: ExperienceResultText.Line {
        ExperienceResultText.line(test, in: tests, failure: failure)
    }

    @ViewBuilder
    private var content: some View {
        switch test {
        case .videoLadder: if let result = tests.videoLadder { ladder(result) }
        case .videoAdaptive: if let result = tests.videoAdaptive { adaptive(result) }
        case .webPage: if let result = tests.webPage { web(result) }
        case .gameAndCalls: if let result = tests.gameAndCalls { game(result) }
        case .upload: if let result = tests.upload { upload(result) }
        }
    }

    // MARK: Vidéo — échelle

    private func ladder(_ result: ExperienceLadderResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ExperienceDetailCard {
                ForEach(Array(result.rungs.enumerated()), id: \.offset) { index, rung in
                    if index > 0 { Divider() }
                    ExperienceDetailRow(
                        title: "\(rung.quality.label) · \(SQUnits.throughput(mbps: Double(rung.quality.requiredBps) / 1_000_000))",
                        trailing: ExperienceResultText.rungVerdict(rung),
                        detail: ExperienceResultText.rungDetail(rung),
                        emphasis: rung.state == .measured && rung.stalls.isEmpty
                    )
                }
            }
            if let stalled = result.rungs.first(where: { !$0.stalls.isEmpty }) {
                Text("Coupures en \(stalled.quality.label) à \(ExperienceResultText.stallTimes(stalled.stalls)) de lecture")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Vidéo — lecteur adaptatif

    private func adaptive(_ result: ExperienceAdaptiveResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if !result.timeByQualityMs.isEmpty {
                ExperienceDetailCard(title: "Temps par qualité") {
                    ExperienceQualityBars(timeByQualityMs: result.timeByQualityMs)
                }
            }
            ExperienceDetailCard {
                if let startup = result.startupMs {
                    ExperienceFactRow(label: "Démarrage de la vidéo", value: ExperienceResultText.waiting(startup))
                }
                if let average = ExperienceResultText.averageQuality(result.timeByQualityMs) {
                    ExperienceFactRow(label: "Qualité moyenne",
                              value: "\(average.quality.label) · \(SQUnits.throughput(mbps: Double(average.bps) / 1_000_000))")
                }
                if let up = result.switchesUp, let down = result.switchesDown {
                    ExperienceFactRow(label: "Changements de qualité", value: ExperienceResultText.switches(up: up, down: down))
                }
                if let stalls = result.stalls {
                    ExperienceFactRow(label: "Coupures vidéo", value: stallSummary(stalls))
                }
                if let played = result.playbackMs {
                    ExperienceFactRow(label: "Lecture", value: "\(ExperienceResultText.decimalSeconds(played))\u{00A0}s / \(ExperienceMethod.adaptivePlaybackMs / 1_000)\u{00A0}s")
                }
            }
            if let score = result.score {
                ExperienceDetailCard(title: "Note vidéo SignalQuest") {
                    ExperienceScorePart(label: "Qualité", points: score.quality, outOf: 40,
                                        explanation: String(localized: "\(ExperienceResultText.qualityPoints(result.timeByQualityMs)), pondérés par le temps"))
                    Divider()
                    ExperienceScorePart(label: "Fluidité", points: score.smoothness, outOf: 40,
                                        explanation: ExperienceResultText.smoothnessFormula(result.stalls ?? [], result: score.smoothness))
                    Divider()
                    ExperienceScorePart(label: "Démarrage de la vidéo", points: score.startup, outOf: 20,
                                        explanation: result.startupMs.map(ExperienceResultText.startupRule))
                    Divider()
                    ExperienceFactRow(label: "Total", value: "\(score.quality) + \(score.smoothness) + \(score.startup) = \(score.total) / 100")
                }
            } else if result.state != .measured {
                ExperienceNotMeasuredNote(text: String(localized: "Pas de note : la lecture n’est pas allée au bout."))
            }
        }
    }

    private func stallSummary(_ list: [ExperienceStall]) -> String {
        guard !list.isEmpty else { return String(localized: "Aucune") }
        let wait = list.reduce(Int64(0)) { $0 + $1.waitMs }
        return "\(ExperienceResultText.stalls(list.count)) · \(ExperienceResultText.waiting(wait)) · \(String(localized: "à \(ExperienceResultText.stallTimes(list)) de lecture"))"
    }

    // MARK: Web

    private func web(_ result: ExperienceWebResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if let stats = ExperienceResultText.webStats(result) {
                ExperienceDetailCard {
                    ExperienceFactRow(label: "Régularité", value: stats.isStable ? String(localized: "Stable") : String(localized: "Irrégulière"))
                    ExperienceFactRow(label: "Échecs", value: "\(stats.failures) / \(stats.openings)")
                    ExperienceFactRow(label: "Médiane", value: "\(stats.medianMs.formatted()) ms")
                    ExperienceFactRow(label: "Min", value: "\(stats.minMs.formatted()) ms")
                    ExperienceFactRow(label: "MAX", value: "\(stats.maxMs.formatted()) ms")
                    ExperienceFactRow(label: "Écart MAX − min", value: ExperienceResultText.webSpread(stats))
                }
            }
            ForEach(Array(result.openings.enumerated()), id: \.offset) { index, opening in
                ExperienceDetailCard(title: String(localized: "Ouverture \(index + 1)")) {
                    if opening.measured {
                        if let dns = opening.dnsMs {
                            ExperienceFactRow(label: "DNS", value: "\(dns.formatted()) ms")
                        } else if opening.dnsCached == true {
                            ExperienceFactRow(label: "DNS", value: String(localized: "En cache"))
                        }
                        if let connect = opening.connectMs { ExperienceFactRow(label: "Connexion TCP", value: "\(connect.formatted()) ms") }
                        if let tls = opening.tlsMs { ExperienceFactRow(label: "TLS", value: "\(tls.formatted()) ms") }
                        if let firstByte = opening.firstByteMs { ExperienceFactRow(label: "Premier octet", value: "\(firstByte.formatted()) ms") }
                        if let content = opening.contentMs { ExperienceFactRow(label: "Contenu", value: "\(content.formatted()) ms") }
                        if let total = opening.totalMs { ExperienceFactRow(label: "Total", value: "\(total.formatted()) ms") }
                    } else {
                        ExperienceFactRow(label: "Total", value: String(localized: "Échec"))
                    }
                }
            }
            if result.openings.isEmpty, result.state != .measured {
                ExperienceNotMeasuredNote(text: String(localized: "Aucune ouverture mesurée."))
            }
        }
    }

    // MARK: Jeu et appels

    @ViewBuilder
    private func game(_ result: ExperienceGameResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if result.series.count >= 2, let median = result.medianMs {
                ExperienceDetailCard(title: String(localized: "Latence sur 30 s · \(result.series.count) mesures")) {
                    ExperienceLatencyChart(series: result.series, medianMs: Int(median))
                }
            }
            if let median = result.medianMs {
                ExperienceDetailCard {
                    ExperienceFactRow(label: "Latence médiane", value: "\(median) ms")
                    if let jitter = result.jitterMs { ExperienceFactRow(label: "Gigue", value: SQUnits.jitter(jitter)) }
                    if let spikes = result.spikeCount {
                        ExperienceFactRow(label: "À-coups", value: ExperienceResultText.spikes(count: spikes, share: result.spikeShare))
                    }
                    if let maximum = result.maxMs { ExperienceFactRow(label: "Latence MAX", value: "\(maximum) ms") }
                    ExperienceFactRow(label: "Pertes de paquets", value: String(localized: "Non mesurées"))
                }
                underLoad(result.underLoad)
                ExperienceDetailCard(title: "Verdict par usage") {
                    let usages = ExperienceGameStats.Usage.allCases
                    ForEach(Array(usages.enumerated()), id: \.offset) { index, usage in
                        if index > 0 { Divider() }
                        ExperienceUsageVerdict(
                            usage: usage,
                            criteria: ExperienceResultText.criteria(usage, medianMs: median, jitterMs: result.jitterMs, spikeCount: result.spikeCount)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func underLoad(_ value: ExperienceUnderLoad?) -> some View {
        ExperienceDetailCard(title: "Latence sous charge") {
            if let value {
                HStack(alignment: .firstTextBaseline) {
                    Text("Écart \(value.deltaMs >= 0 ? "+" : "")\(value.deltaMs) ms")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: value.grade)
                        .font(SQFont.display(20, .heavy, relativeTo: .title3))
                        .foregroundStyle(SQColor.onAccent)
                        .frame(minWidth: 36, minHeight: 36)
                        .background(SQColor.accent, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                        .accessibilityLabel(Text("Note \(value.grade)"))
                }
                .accessibilityElement(children: .combine)
                ExperienceFactRow(label: "Au repos", value: "\(value.idleMs) ms")
                ExperienceFactRow(label: "Pendant un téléchargement",
                          value: value.loadedDownMs.map { "\($0) ms" } ?? String(localized: "Non mesurée"))
                ExperienceFactRow(label: "Pendant un envoi",
                          value: value.loadedUpMs.map { "\($0) ms" } ?? String(localized: "Non mesurée"))
                Text(verbatim: ExperienceResultText.underLoadSource(value.source, reusedAge: reusedSpeedtestAge))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Non mesurée")
                    .font(SQType.subhead(.regular))
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    // MARK: Envoi

    private func upload(_ result: ExperienceUploadResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in
                ExperienceDetailCard(title: item.kind == .photo ? String(localized: "Photo · 5 Mo") : String(localized: "Vidéo · 30 Mo (≈ 30 s en 1080p)")) {
                    ExperienceFactRow(label: "Durée d’envoi", value: ExperienceResultText.waiting(item.totalMs))
                    if let rate = ExperienceResultText.uploadMbps(item) {
                        ExperienceFactRow(label: "Débit montant moyen", value: SQUnits.throughput(mbps: rate))
                    }
                    if let ratio = ExperienceResultText.uploadRealTimeRatio(item) {
                        ExperienceFactRow(label: "Rapport à la durée de la vidéo", value: ratio)
                    }
                }
            }
            if result.items.isEmpty, result.state != .measured {
                ExperienceNotMeasuredNote(text: String(localized: "Aucun fichier envoyé jusqu’au bout."))
            }
        }
    }
}

extension ExperienceDetailView {
    /// Le test qu'on vient de lancer.
    init(model: ExperienceTestsModel, finished: ExperienceFinished, test: ExperienceTestKind) {
        self.init(tests: finished.run.tests, failure: finished.run.failures[test], usage: finished.run.usage[test],
                  reusedSpeedtestAge: finished.reusedSpeedtestAge, test: test, back: { model.back() })
    }
}

// MARK: - Consommation et durée

struct ExperienceUsageView: View {
    @ObservedObject var model: ExperienceTestsModel
    let finished: ExperienceFinished

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ExperienceBackBar(title: "Consommation et durée") { model.back() }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ExperienceResultText.megabytes(finished.run.bytesUsed)) utilisés")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                Text("sur \(ExperienceResultText.megabytes(maxBytes: finished.maxBytes)) au maximum · sans plafond")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)

            ExperienceDetailCard {
                ForEach(tests, id: \.self) { test in
                    ExperienceFactRow(label: test.title, value: value(test))
                }
            }
            ExperienceDetailCard {
                ExperienceFactRow(label: "Durée annoncée", value: ExperienceResultText.about(seconds: ExperienceEstimate.durationSeconds(finished.selected)))
                ExperienceFactRow(label: "Durée mesurée", value: ExperienceResultText.duration(seconds: Int(finished.run.durationMs / 1_000)))
            }
        }
        .accessibilityIdentifier("experience.usage")
    }

    private var tests: [ExperienceTestKind] { ExperienceMethod.order.filter(finished.selected.contains) }

    private func value(_ test: ExperienceTestKind) -> String {
        let max = ExperienceBudget.maxBytes(test, recentLatencyReused: finished.reusedSpeedtestAge != nil)
        guard let usage = finished.run.usage[test] else { return String(localized: "Non lancé") }
        return ExperienceResultText.usage(usage, maxBytes: max)
    }
}

// MARK: - Éléments

/// « ‹ Résultat » et le titre de la page.
private struct ExperienceBackBar: View {
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Button {
                Haptics.selection()
                action()
            } label: {
                Label("Résultat", systemImage: "chevron.left")
                    .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel(Text("Retour au résultat"))
            .accessibilityIdentifier("experience.back")
            Text(LocalizedStringKey(title))
                .font(SQFont.body(10, .bold, relativeTo: .caption))
                .tracking(10 * 0.12)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Carte du détail, avec un titre facultatif (clé de catalogue).
private struct ExperienceDetailCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            if let title {
                Text(LocalizedStringKey(title))
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.cardPadding)
        .sqCardBackground()
    }
}

/// Un palier : qualité et débit nécessaire, son verdict à droite, ses mesures dessous.
private struct ExperienceDetailRow: View {
    let title: String
    let trailing: String
    let detail: String?
    let emphasis: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                titleText
                verdictText
            } else {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    titleText.frame(maxWidth: .infinity, alignment: .leading)
                    verdictText
                }
            }
            if let detail {
                Text(verbatim: detail)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(verbatim: title)
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.label)
            .monospacedDigit()
    }

    private var verdictText: some View {
        Text(verbatim: trailing)
            .font(SQType.subhead(emphasis ? .semibold : .regular))
            .foregroundStyle(emphasis ? SQColor.label : SQColor.labelSecondary)
            .monospacedDigit()
    }
}

/// Temps passé à chaque qualité, en barres proportionnelles à la lecture.
private struct ExperienceQualityBars: View {
    let timeByQualityMs: [ExperienceVideoQuality: Int64]

    var body: some View {
        let total = max(1, timeByQualityMs.values.reduce(0, +))
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            ForEach(ExperienceVideoQuality.allCases, id: \.self) { quality in
                let ms = timeByQualityMs[quality] ?? 0
                HStack(spacing: SQSpace.sm) {
                    Text(verbatim: quality.label)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.label)
                        .frame(width: 48, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(SQColor.chip)
                            .overlay(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(SQColor.accent)
                                    .frame(width: proxy.size.width * CGFloat(ms) / CGFloat(total))
                            }
                    }
                    .frame(height: 8)
                    Text(verbatim: "\(ExperienceResultText.decimalSeconds(ms))\u{00A0}s")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(quality.label), \(ExperienceResultText.decimalSeconds(ms)) s"))
            }
        }
    }
}

/// Une part de la note : points, barème et le calcul appliqué.
private struct ExperienceScorePart: View {
    let label: String
    let points: Int
    let outOf: Int
    let explanation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ExperienceFactRow(label: label, value: "\(points) / \(outOf) pts")
            if let explanation {
                Text(verbatim: explanation)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Un usage du jeu et des appels : verdict, puis chaque critère contre son seuil.
private struct ExperienceUsageVerdict: View {
    let usage: ExperienceGameStats.Usage
    let criteria: [ExperienceResultText.Criterion]

    var body: some View {
        let suits = criteria.allSatisfy(\.met)
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(LocalizedStringKey(title))
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label(suits ? "Convient" : "Ne convient pas", systemImage: suits ? "checkmark.circle.fill" : "xmark.circle")
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(suits ? SQColor.label : SQColor.labelSecondary)
            }
            ForEach(Array(criteria.enumerated()), id: \.offset) { _, criterion in
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.xs) {
                    Image(systemName: criterion.met ? "checkmark" : "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(criterion.met ? SQColor.label : SQColor.dangerInk)
                        .accessibilityHidden(true)
                    Text(verbatim: "\(criterion.label) \(criterion.value) · \(criterion.threshold)")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch usage {
        case .competitiveGaming: "Jeu compétitif"
        case .casualGaming: "Jeu occasionnel"
        case .hdVideoCall: "Appel vidéo HD"
        case .audioCall: "Appel audio"
        }
    }
}

/// Les 300 latences dans l'ordre, avec la médiane : un tracé simple, à l'échelle.
private struct ExperienceLatencyChart: View {
    let series: [Int]
    let medianMs: Int

    var body: some View {
        let top = Double(max(200, series.max() ?? 0))
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            GeometryReader { proxy in
                let size = proxy.size
                let step = size.width / CGFloat(max(1, series.count - 1))
                ZStack(alignment: .topLeading) {
                    Path { path in
                        for (index, value) in series.enumerated() {
                            let point = CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(Double(value) / top)))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(SQColor.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    Path { path in
                        let y = size.height * (1 - CGFloat(Double(medianMs) / top))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(SQColor.labelTertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .frame(height: 96)
            HStack {
                Text(verbatim: "0\u{00A0}s")
                Spacer()
                Text("médiane \(medianMs) ms · échelle 0 à \(Int(top)) ms")
                Spacer()
                Text(verbatim: "30\u{00A0}s")
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Courbe de latence sur 30 s, médiane \(medianMs) ms"))
    }
}

private struct ExperienceNotMeasuredNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(SQType.subhead(.regular))
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// « Comment c'est mesuré » : la méthode v3, la même sur Android, iOS et le web.
private struct ExperienceMethodNote: View {
    let test: ExperienceTestKind

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text("Comment c’est mesuré")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: text)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.cardPadding)
        .sqCardBackground(SQColor.surfaceMuted)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experience.method")
    }

    private var text: String {
        switch test {
        case .videoLadder:
            String(localized: "Segments de 2 s depuis le serveur de mesure Cloudflare, à 1,5 · 3 · 6 · 12 · 20 Mb/s (480p à 4K), 5 par qualité. On ne monte d’une qualité que sans coupure. Une coupure = tampon vide ; l’attente d’un segment est coupée à 6 s. Marge = débit reçu ÷ débit nécessaire. Aucune image n’est décodée.")
        case .videoAdaptive:
            String(localized: "30 s de lecture, départ en 480p ; qualité la plus haute sous 80 % du débit des 3 derniers segments, un cran à la fois ; montée si le tampon atteint 8 s, descente sous 4 s. Note /100 = Qualité 40 (4K 40 · 1440p 34 · 1080p 28 · 720p 18 · 480p 8, pondérée par le temps) + Fluidité 40 (− 10 par coupure, − 5 par seconde d’attente) + Démarrage 20 (≤ 1 s 20 · ≤ 2 s 15 · ≤ 4 s 8). Note SignalQuest, pas une norme ; absente si la lecture est interrompue.")
        case .webPage:
            String(localized: "3 ouvertures, chacune sur une connexion neuve et en 10 s au plus : DNS, connexion, TLS, premier octet, puis une page de 2,3 Mo en 6 requêtes parallèles. Stable si MAX − min reste sous 30 % de la médiane. Rendu et JavaScript non mesurés.")
        case .gameAndCalls:
            String(localized: "30 s de sondes TCP, 10 par seconde. Gigue = moyenne des écarts entre deux mesures successives ; à-coups = mesures au-dessus de la médiane + 100 ms. Sous charge : reprise d’un speedtest du même réseau de moins de 10 min, sinon 5 s de charge par sens ; note A ≤ 5 ms · B ≤ 30 · C ≤ 60 · D ≤ 200 · F au-delà. Pertes de paquets : non mesurées.")
        case .upload:
            String(localized: "Photo de 5 Mo puis vidéo de 30 Mo, au contenu incompressible, vers le point d’envoi du serveur de mesure Cloudflare. Débit = octets envoyés ÷ temps jusqu’à la réponse du serveur, sur une horloge monotone.")
        }
    }
}

/// Libellé, pointillés et valeur comme `SQFactRow`, mais le libellé garde sa ligne : la
/// valeur passe dessous quand la place manque, plutôt que de couper « Démarrage de / la vidéo ».
private struct ExperienceFactRow: View {
    let label: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                labelText.fixedSize()
                SQDotLeader()
                    .frame(height: 1)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                valueText.fixedSize()
            }
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                labelText
                valueText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(LocalizedStringKey(label))
            .font(SQType.subhead(.regular))
            .foregroundStyle(SQColor.labelSecondary)
    }

    private var valueText: some View {
        Text(verbatim: value)
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.label)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}
