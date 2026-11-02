import SwiftUI

/// Détail d'un test (lot X3, `presentation-v1`) : la phrase de l'usage, un graphique, trois
/// valeurs au plus, puis la méthode repliée sous « Comment c'est calculé ». Rien n'est
/// recalculé ni estimé ici : les phrases et les libellés viennent du catalogue commun.
struct ExperienceDetailView: View {
    let tests: ExperienceTestsResult
    var failure: ExperienceFailureCause?
    var usage: ExperienceTestUsage?
    var methodology: String?
    let test: ExperienceTestKind
    let back: () -> Void
    private let language = ExperienceShareLanguage.current

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ExperienceBackBar(title: test.title, action: back)
            if let item {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    ForEach(Array(headlines(item).enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.rendered(language))
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // La valeur clé de la vidéo est celle de l'échelle (son démarrage) : pas sur le lecteur adaptatif.
                    if test != .videoAdaptive, let keyValue = item.presentation.keyValue {
                        Text(verbatim: keyValue.rendered(language))
                            .font(SQType.subhead(.regular))
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("experience.detail.headline")
            }

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

    /// L'usage du test, avec la phrase locale d'un échec juste après le test.
    private var item: ExperienceUseItem? {
        ExperienceUseItem.items(tests, methodology: methodology, failures: failure.map { [test: $0] } ?? [:])
            .first { $0.use.tests.contains(test) }
    }

    /// La vidéo a deux phrases, une par test : on garde celle du test ouvert.
    private func headlines(_ item: ExperienceUseItem) -> [ExperiencePresentation.Text] {
        let prefix: String? = switch test {
        case .videoLadder: "experience.video.ladder"
        case .videoAdaptive: "experience.video.adaptive"
        default: nil
        }
        guard let prefix else { return item.lines }
        let own = item.lines.filter { $0.key.hasPrefix(prefix) }
        return own.isEmpty ? item.lines : own
    }

    private func label(_ key: String) -> String { ExperiencePresentation.label("experience.detail.\(key)", language) }
    private func ms(_ value: Int64) -> String { ExperiencePresentation.format(.ms, .int(Int(value)), language) }
    private func duration(_ value: Int64) -> String { ExperiencePresentation.format(.duration, .int(Int(value)), language) }

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
        ExperienceDetailCard {
            ForEach(Array(result.rungs.enumerated()), id: \.offset) { index, rung in
                if index > 0 { Divider() }
                ExperienceDetailRow(
                    title: "\(rung.quality.label) · \(SQUnits.throughput(mbps: Double(rung.quality.requiredBps) / 1_000_000))",
                    trailing: ExperienceResultText.rungVerdict(rung),
                    detail: nil,
                    emphasis: rung.state == .measured && rung.stalls.isEmpty
                )
            }
        }
    }

    // MARK: Vidéo — lecteur adaptatif

    private func adaptive(_ result: ExperienceAdaptiveResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if !result.timeByQualityMs.isEmpty {
                ExperienceDetailCard {
                    ExperienceQualityBars(timeByQualityMs: result.timeByQualityMs)
                }
            }
            if result.startupMs != nil || result.stalls != nil {
                ExperienceDetailCard {
                    if let startup = result.startupMs {
                        ExperienceFactRow(label: label("startup"), value: duration(startup))
                    }
                    if let stalls = result.stalls {
                        ExperienceFactRow(label: label("stalls"), value: ExperiencePresentation.format(.integer, .int(stalls.count), language))
                    }
                }
            }
        }
    }

    // MARK: Web

    @ViewBuilder
    private func web(_ result: ExperienceWebResult) -> some View {
        let times = result.openings.filter(\.measured).compactMap(\.totalMs).map { Int($0) }
        if !result.openings.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                ExperienceDetailCard {
                    ExperienceOpeningBars(openings: result.openings, format: duration)
                }
                ExperienceDetailCard {
                    if let median = ExperienceHighlights.median(times), let slowest = times.max() {
                        ExperienceFactRow(label: label("typical_time"), value: duration(Int64(median)))
                        ExperienceFactRow(label: label("slowest"), value: duration(Int64(slowest)))
                    }
                    ExperienceFactRow(label: label("failures"), value: "\(result.openings.count - times.count) / \(result.openings.count)")
                }
            }
        }
    }

    // MARK: Jeu et appels

    @ViewBuilder
    private func game(_ result: ExperienceGameResult) -> some View {
        if let median = result.medianMs {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                if result.series.count >= 2 {
                    ExperienceDetailCard {
                        ExperienceLatencyChart(
                            series: result.series, medianMs: Int(median),
                            thresholdMs: ExperiencePresentation.spikeThresholdMs(medianMs: Int(median), methodology: methodology ?? ExperienceMethod.methodology),
                            language: language
                        )
                    }
                }
                ExperienceDetailCard {
                    ExperienceFactRow(label: label("responsiveness"), value: ms(median))
                    if let jitter = result.jitterMs {
                        ExperienceFactRow(label: label("variation"), value: ms(Int64(jitter.rounded())))
                    }
                    if let delta = result.underLoad?.deltaMs {
                        Text(verbatim: ExperiencePresentation.Text(key: "experience.detail.under_load", args: ["delta": .int(Int(delta))]).rendered(language))
                            .font(SQType.subhead(.regular))
                            .foregroundStyle(SQColor.labelSecondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Envoi

    @ViewBuilder
    private func upload(_ result: ExperienceUploadResult) -> some View {
        if !result.items.isEmpty {
            ExperienceDetailCard {
                ForEach(Array(result.items.enumerated()), id: \.offset) { _, item in
                    ExperienceFactRow(label: item.kind == .photo ? String(localized: "Photo · 5 Mo") : String(localized: "Vidéo · 30 Mo"),
                                      value: duration(item.totalMs))
                }
            }
        }
    }
}

extension ExperienceDetailView {
    /// Le test qu'on vient de lancer.
    init(model: ExperienceTestsModel, finished: ExperienceFinished, test: ExperienceTestKind) {
        self.init(tests: finished.run.tests, failure: finished.run.failures[test], usage: finished.run.usage[test],
                  test: test, back: { model.back() })
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

/// Les 300 latences dans l'ordre, à l'échelle, avec la médiane et le seuil des pointes
/// (`spikeThresholdMs`, le même que le décompte, jamais une constante).
private struct ExperienceLatencyChart: View {
    let series: [Int]
    let medianMs: Int
    let thresholdMs: Int
    let language: ExperienceShareLanguage

    var body: some View {
        let top = Double(max(200, thresholdMs + 20, series.max() ?? 0))
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            GeometryReader { proxy in
                let size = proxy.size
                let step = size.width / CGFloat(max(1, series.count - 1))
                let y = { (ms: Int) in size.height * (1 - CGFloat(Double(ms) / top)) }
                ZStack(alignment: .topLeading) {
                    Path { path in
                        for (index, value) in series.enumerated() {
                            let point = CGPoint(x: CGFloat(index) * step, y: y(value))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(SQColor.accent, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y(medianMs)))
                        path.addLine(to: CGPoint(x: size.width, y: y(medianMs)))
                    }
                    .stroke(SQColor.labelTertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y(thresholdMs)))
                        path.addLine(to: CGPoint(x: size.width, y: y(thresholdMs)))
                    }
                    .stroke(SQColor.dangerInk, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
            .frame(height: 96)
            Text(verbatim: peaks)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(ExperiencePresentation.label("experience.detail.responsiveness", language)) \(ExperiencePresentation.format(.ms, .int(medianMs), language)), \(peaks)"))
    }

    private var peaks: String {
        ExperiencePresentation.Text(key: "experience.detail.peaks_above", args: ["ms": .int(thresholdMs)]).rendered(language)
    }
}

/// Les ouvertures de page, en barres proportionnelles à la plus lente ; un échec est nommé.
private struct ExperienceOpeningBars: View {
    let openings: [ExperienceWebOpening]
    let format: (Int64) -> String

    var body: some View {
        let slowest = max(1, openings.compactMap { $0.measured ? $0.totalMs : nil }.max() ?? 1)
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            ForEach(Array(openings.enumerated()), id: \.offset) { index, opening in
                let total = opening.measured ? opening.totalMs : nil
                HStack(spacing: SQSpace.sm) {
                    Text(verbatim: "\(index + 1)")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                        .frame(minWidth: 16, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule(style: .continuous)
                            .fill(SQColor.chip)
                            .overlay(alignment: .leading) {
                                if let total {
                                    Capsule(style: .continuous)
                                        .fill(SQColor.accent)
                                        .frame(width: proxy.size.width * CGFloat(total) / CGFloat(slowest))
                                }
                            }
                    }
                    .frame(height: 8)
                    Text(verbatim: total.map(format) ?? String(localized: "Échec"))
                        .font(SQType.caption)
                        .foregroundStyle(total == nil ? SQColor.dangerInk : SQColor.labelSecondary)
                        .monospacedDigit()
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Ouverture \(index + 1)") + Text(verbatim: ", \(total.map(format) ?? String(localized: "Échec"))"))
            }
        }
    }
}

/// « Comment c'est calculé », replié : la méthode v3, la même sur Android, iOS et le web.
private struct ExperienceMethodNote: View {
    let test: ExperienceTestKind
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Button {
                Haptics.selection()
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: SQSpace.sm) {
                    Text(verbatim: ExperiencePresentation.label("experience.detail.how_calculated"))
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(expanded ? "Déplié" : "Replié"))
            if expanded {
                Text(verbatim: text)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, SQSpace.cardPadding)
        .padding(.vertical, SQSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.surfaceMuted)
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
            String(localized: "30 s de sondes TCP, 10 par seconde. Variation (gigue) = moyenne des écarts entre deux mesures successives ; pointes = mesures au-dessus du seuil tracé sur le graphique. Sous charge : reprise d’un speedtest du même réseau de moins de 10 min, sinon 5 s de charge par sens ; on affiche l’écart avec la latence au repos. Pertes de paquets : non mesurées.")
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
