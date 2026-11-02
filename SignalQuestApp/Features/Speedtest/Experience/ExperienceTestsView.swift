import SwiftUI

/// Mode « Expérience » de l'onglet Speedtest (maquette v3 du 26/10) : l'entrée avec les
/// cinq tests, le direct pendant la mesure, puis le résultat ou l'état de fin.
/// Aucun plafond : en données mobiles, un avertissement dit seulement la consommation.
struct ExperienceTestsView: View {
    @ObservedObject var model: ExperienceTestsModel
    /// Remonte en haut de l'onglet : une page de détail s'ouvre depuis le bas du résultat.
    var scrollToTop: () -> Void = {}

    var body: some View {
        VStack(spacing: SQSpace.lg) {
            if model.running {
                ExperienceRunningView(model: model)
            } else if let finished = model.finished {
                switch model.page {
                case .home: ExperienceResultView(model: model, finished: finished)
                case .detail(let test): ExperienceDetailView(model: model, finished: finished, test: test)
                case .usage: ExperienceUsageView(model: model, finished: finished)
                }
            } else {
                ExperienceEntryView(model: model)
            }
        }
        .onChangeCompat(of: model.page) { _, _ in scrollToTop() }
        .task { await model.refreshLastTest() }
    }
}

extension ExperienceTestKind {
    /// Ce que mesure le test, sous son titre à l'entrée.
    var entrySubtitle: String {
        switch self {
        case .videoLadder: String(localized: "480p à 4K")
        case .videoAdaptive: String(localized: "30 s · note /100")
        case .webPage: String(localized: "3 ouvertures")
        case .gameAndCalls: String(localized: "30 s + charge")
        case .upload: String(localized: "Photo 5 Mo · vidéo 30 Mo")
        }
    }

    /// Pictogramme du test : liste d'entrée et étapes du direct.
    var systemImage: String {
        switch self {
        case .videoLadder: "chart.bar.fill"
        case .videoAdaptive: "play.rectangle.fill"
        case .webPage: "globe"
        case .gameAndCalls: "gamecontroller.fill"
        case .upload: "arrow.up.doc.fill"
        }
    }

    /// Libellé court de la frise du direct.
    var shortTitle: String {
        switch self {
        case .videoLadder: String(localized: "Échelle")
        case .videoAdaptive: String(localized: "Adaptatif")
        case .webPage: String(localized: "Web")
        case .gameAndCalls: String(localized: "Jeu")
        case .upload: String(localized: "Envoi")
        }
    }
}

extension ExperienceNetworkDisplay {
    /// « 4G », « 5G NSA », « Wi-Fi » ; rien quand le lien n'est pas connu.
    var label: String? {
        switch connection {
        case .wifi: String(localized: "Wi-Fi")
        case .wired: String(localized: "Ethernet")
        case .cellular: technology?.rawValue ?? String(localized: "Réseau mobile")
        default: nil
        }
    }
}

// MARK: - Entrée

private struct ExperienceEntryView: View {
    @ObservedObject var model: ExperienceTestsModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: SQSpace.md) {
            if model.offlineAtStart {
                offlineCard
            }
            VStack(spacing: 0) {
                ForEach(ExperienceMethod.order, id: \.self) { test in
                    row(test)
                    if test != ExperienceMethod.order.last {
                        Divider().padding(.leading, SQSpace.cardPadding + 38 + SQSpace.md)
                    }
                }
            }
            .sqCardBackground()

            budgetCard
            launchButton
            if let last = model.lastTest {
                ExperienceLastTestLine(item: last)
            }
        }
    }

    private func row(_ test: ExperienceTestKind) -> some View {
        let isOn = model.selected.contains(test)
        let megabytes = ExperienceBudget.megabytesCeil(ExperienceBudget.maxBytes(test))
        let seconds = ExperienceEstimate.durationSeconds(test)
        return Button {
            Haptics.selection()
            model.toggle(test)
        } label: {
            HStack(spacing: SQSpace.md) {
                SQIconPastille(systemImage: test.systemImage, size: 38,
                               tint: isOn ? SQColor.accentInk : SQColor.labelSecondary,
                               fill: isOn ? SQColor.accentSoft : SQColor.chip)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(test.title))
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: test.entrySubtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    // Tailles AX : la colonne de droite cassait les titres au milieu des mots.
                    if dynamicTypeSize.isAccessibilitySize {
                        Text(verbatim: "\(String(localized: "≤ \(megabytes) Mo")) · \(String(localized: "≈ \(seconds) s"))")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.label)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("≤ \(megabytes) Mo")
                            .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(SQColor.label)
                        Text("≈ \(seconds) s")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .monospacedDigit()
                }
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isOn ? SQColor.accent : SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.cardPadding)
            .padding(.vertical, SQSpace.sm2)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("experience.test.\(test.rawValue)")
    }

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            if let network = model.network.label {
                Text("Réseau mesuré : \(network)")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Text("Consommation maximale \(model.maxMegabytes) Mo · \(ExperienceResultText.about(seconds: model.estimatedSeconds))")
                .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(SQColor.label)
                .monospacedDigit()
            if model.network.isMobile, !model.selected.isEmpty {
                Label {
                    Text("Données mobiles : jusqu’à \(model.maxMegabytes) Mo décomptés du forfait")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.label)
                .accessibilityIdentifier("experience.mobileDataWarning")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.cardPadding)
        .sqCardBackground(SQColor.surfaceMuted)
    }

    private var launchButton: some View {
        let count = model.selected.count
        return GradientButton(
            verbatim: count == 0 ? String(localized: "Choisir au moins un test") : String(localized: "Lancer \(count) tests"),
            systemImage: count == 0 ? nil : "play.fill"
        ) {
            Task { await model.start() }
        }
        .disabled(count == 0)
        .accessibilityIdentifier("experience.start")
    }

    private var offlineCard: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SQColor.dangerInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pas de connexion")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Text("Rien n’a été consommé.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Réessayer") {
                Haptics.light()
                Task { await model.start() }
            }
            .font(SQFont.body(14, .bold, relativeTo: .subheadline))
            .foregroundStyle(SQColor.label)
            .padding(.horizontal, SQSpace.lg)
            .frame(minHeight: 44)
            .background(SQColor.chip, in: Capsule(style: .continuous))
            .buttonStyle(SQPressButtonStyle())
        }
        .padding(SQSpace.cardPadding)
        .sqCardBackground(SQColor.dangerSoft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("experience.offline")
    }
}

/// « Dernier test · hier 18:42 » et ses valeurs, comme la carte du fil.
private struct ExperienceLastTestLine: View {
    let item: ExperienceHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Dernier test · \(item.measuredAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
                .font(SQFont.body(9.5, .bold, relativeTo: .caption2))
                .tracking(9.5 * 0.18)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
            Text(verbatim: summary)
                .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .sqCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experience.lastTest")
    }

    private var summary: String {
        item.highlights.feedMetrics
            .map { "\(String(localized: String.LocalizationValue($0.label))) \($0.value)" }
            .joined(separator: " · ")
    }
}

// MARK: - En cours

private struct ExperienceRunningView: View {
    @ObservedObject var model: ExperienceTestsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rankTitle)
                        .font(SQFont.body(10, .bold, relativeTo: .caption))
                        .tracking(10 * 0.16)
                        .textCase(.uppercase)
                        .foregroundStyle(SQColor.labelSecondary)
                    Text(LocalizedStringKey(model.live?.test.title ?? "Préparation"))
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let test = model.live?.test {
                    SQIconPastille(systemImage: test.systemImage, size: 44, tint: SQColor.accentInk, fill: SQColor.accentSoft)
                }
            }

            if let live = model.live {
                FeedMetricGrid(metrics: Self.metrics(live))
            } else {
                HStack(spacing: SQSpace.sm) {
                    ProgressView()
                    Text("Préparation du test")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
            }

            ExperienceSteps(
                order: ExperienceMethod.order.filter(model.selected.contains),
                current: model.liveRank.map { $0.index - 1 } ?? -1
            )

            Text("Données utilisées : \(ExperienceResultText.megabytes(model.live?.bytesUsed ?? 0)) sur \(model.maxMegabytes) au maximum")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)

            GradientButton("Arrêter", systemImage: "stop.fill", style: .secondary) {
                model.stop()
            }
            .accessibilityIdentifier("experience.stop")
        }
        .padding(SQSpace.lg)
        .sqCardBackground()
        .accessibilityIdentifier("experience.running")
    }

    private var rankTitle: String {
        if let rank = model.liveRank {
            return String(localized: "Test d’expérience · \(rank.index) sur \(rank.total)")
        }
        return String(localized: "Test d’expérience")
    }

    /// Ce que le moteur mesure à l'instant ; jamais de valeur inventée avant la première mesure.
    static func metrics(_ live: ExperienceLive) -> [FeedMetricGrid.Metric] {
        switch live.test {
        case .videoLadder, .videoAdaptive:
            var metrics: [FeedMetricGrid.Metric] = []
            if let quality = live.quality { metrics.append(.init(label: "Qualité", value: quality.label, highlight: true)) }
            metrics.append(.init(label: "Tampon", value: ExperienceResultText.waiting(live.bufferAheadMs)))
            metrics.append(.init(label: "Coupures vidéo", value: "\(live.stallCount)"))
            if live.test == .videoAdaptive {
                let total = ExperienceMethod.adaptivePlaybackMs / 1_000
                metrics.append(.init(label: "Lecture", value: "\(max(0, live.playedMs) / 1_000) s / \(total) s"))
            }
            return metrics
        case .webPage:
            return [.init(label: "Ouverture", value: "\(live.step) / \(ExperienceMethod.webOpenings)", highlight: true)]
        case .gameAndCalls:
            // Sondes finies : courte charge montante et descendante, sans valeur intermédiaire.
            if live.step >= ExperienceMethod.gameProbeSlots {
                return [.init(label: "Latence sous charge", value: String(localized: "Mesure en cours"), highlight: true)]
            }
            var metrics: [FeedMetricGrid.Metric] = []
            if let rtt = live.latestRttMs { metrics.append(.init(label: "Latence", value: "\(rtt) ms", highlight: true)) }
            metrics.append(.init(label: "Mesures", value: "\(live.step) / \(ExperienceMethod.gameProbeSlots)"))
            return metrics
        case .upload:
            let value = live.step <= 1 ? String(localized: "Photo · 5 Mo") : String(localized: "Vidéo · 30 Mo")
            return [.init(label: "Envoi", value: value, highlight: true)]
        }
    }
}

// MARK: - Résultat

private struct ExperienceResultView: View {
    @ObservedObject var model: ExperienceTestsModel
    let finished: ExperienceFinished
    @State private var shareInput: ExperienceShareInput?

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            header
            if finished.finish != .completed {
                stopBanner
            }
            let scores = ExperienceScores(finished.run.tests)
            if !scores.isEmpty {
                ExperienceOverallScoreCard(scores: scores)
            }
            ExperienceUseList(
                items: ExperienceUseItem.items(finished.run.tests, failures: finished.run.failures, only: finished.selected),
                identifier: "experience.result",
                open: model.openDetail
            )

            usageLine
            saveLine
            if ExperienceTestKind.allCases.contains(where: { finished.run.tests.state(of: $0) == .measured }) {
                GradientButton("Partager le résultat", systemImage: "square.and.arrow.up", style: .secondary) {
                    Haptics.light()
                    shareInput = ExperienceShareInput(
                        tests: ExperienceSubmission.tests(finished.run.tests), scores: ExperienceScores(finished.run.tests),
                        measuredAt: finished.endedAt, connectionType: finished.network.connectionType,
                        technology: finished.network.technology?.rawValue, operatorKey: finished.operatorKey
                    )
                }
                .accessibilityIdentifier("experience.share")
            }
            actionButton
        }
        .accessibilityIdentifier("experience.result")
        .sheet(item: $shareInput) { ExperienceSharePreviewSheet(input: $0) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Test d’expérience · \(finished.endedAt.formatted(date: .omitted, time: .shortened))")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let network = finished.network.label {
                Text(verbatim: network)
                    .font(SQFont.body(12.5, .semibold, relativeTo: .footnote))
                    .foregroundStyle(SQColor.chipInk)
                    .padding(.horizontal, SQSpace.sm2)
                    .padding(.vertical, SQSpace.xs)
                    .background(SQColor.chip, in: Capsule(style: .continuous))
            }
        }
    }

    /// Fin avant terme : la cause, et la garantie que les mesures finies sont gardées.
    private var stopBanner: some View {
        let title: String = switch finished.finish {
        case .userStopped: String(localized: "Test arrêté")
        case .networkChanged: String(localized: "Réseau changé pendant le test")
        case .background: String(localized: "App passée en arrière-plan pendant le test")
        case .offline: String(localized: "Connexion perdue pendant le test")
        case .completed: ""
        }
        return HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: finished.finish == .userStopped ? "stop.circle" : "exclamationmark.triangle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(SQFont.body(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                Text("Mesures finies gardées")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SQSpace.cardPadding)
        .sqCardBackground(SQColor.warningSoft)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("experience.stopBanner")
    }

    private var usageLine: some View {
        Button {
            Haptics.selection()
            model.openUsage()
        } label: {
            HStack(spacing: SQSpace.lg) {
                ExperienceFigure(label: "Données utilisées", value: ExperienceResultText.megabytes(finished.run.bytesUsed))
                ExperienceFigure(label: "Durée", value: ExperienceResultText.duration(seconds: Int(finished.run.durationMs / 1_000)))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Ouvre la consommation par test"))
        .accessibilityIdentifier("experience.usageLine")
    }

    @ViewBuilder
    private var saveLine: some View {
        let text: String? = switch finished.save {
        case .none: String(localized: "Rien n’a été mesuré : rien n’est enregistré.")
        case .saving: String(localized: "Enregistrement…")
        case .queued: String(localized: "Enregistré · envoi au compte en attente")
        case .localOnly: String(localized: "Enregistré sur cet appareil, sans compte")
        case .keptOnPhone: String(localized: "Gardé sur cet appareil seulement")
        }
        if let text {
            Label {
                Text(verbatim: text)
            } icon: {
                Image(systemName: finished.save == .none ? "xmark.circle" : "checkmark.circle")
            }
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("experience.saveState")
        }
    }

    /// Interrompu par l'extérieur : « Relancer » ; sinon « Nouveau test ».
    private var actionButton: some View {
        let relaunch = finished.finish == .networkChanged || finished.finish == .background || finished.finish == .offline
        return GradientButton(relaunch ? "Relancer" : "Nouveau test", systemImage: relaunch ? "arrow.clockwise" : "arrow.counterclockwise") {
            model.newTest()
            if relaunch { Task { await model.start() } }
        }
        .accessibilityIdentifier("experience.newTest")
    }
}

/// Étapes du lancement, reliées : faites (coche), en cours (pictogramme sur brique),
/// à venir (pictogramme discret). Aux tailles AX, les pastilles seules : le titre dit le test.
private struct ExperienceSteps: View {
    let order: [ExperienceTestKind]
    let current: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.element) { index, test in
                VStack(spacing: SQSpace.xs) {
                    ZStack {
                        HStack(spacing: 0) {
                            link(visible: index > 0, done: index <= current)
                            link(visible: index < order.count - 1, done: index < current)
                        }
                        dot(index, test)
                    }
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(verbatim: test.shortTitle)
                            .font(SQFont.body(11, index == current ? .bold : .medium, relativeTo: .caption2))
                            .foregroundStyle(index == current ? SQColor.label : SQColor.labelSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: test.shortTitle) + Text(verbatim: ", ")
                    + Text(index == current ? "en cours" : index < current ? "fini" : "à venir"))
            }
        }
    }

    private func link(visible: Bool, done: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(visible ? (done ? SQColor.accentSoft : SQColor.chip) : Color.clear)
            .frame(height: 3)
    }

    private func dot(_ index: Int, _ test: ExperienceTestKind) -> some View {
        let isCurrent = index == current, isDone = index < current
        return Image(systemName: isDone ? "checkmark" : test.systemImage)
            .font(.system(size: isCurrent ? 15 : 13, weight: .bold))
            .foregroundStyle(isCurrent ? SQColor.onAccent : isDone ? SQColor.accentInk : SQColor.labelSecondary)
            .frame(width: isCurrent ? 38 : 32, height: isCurrent ? 38 : 32)
            .background(isCurrent ? SQColor.accent : isDone ? SQColor.accentSoft : SQColor.chip, in: Circle())
            .shadow(color: isCurrent ? SQColor.accent.opacity(0.28) : .clear, radius: 6, y: 3)
            // Même hauteur pour toutes les étapes : les libellés restent sur une ligne.
            .frame(width: 38, height: 38)
    }
}

/// Un chiffre et son libellé, sous le résultat.
private struct ExperienceFigure: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            Text(verbatim: value)
                .font(SQFont.body(16, .bold, relativeTo: .headline))
                .foregroundStyle(SQColor.label)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(label)) + Text(verbatim: " : \(value)"))
    }
}

/// Note globale /100 (`experience-score-v1`) : moyenne des usages notés, chacun du même
/// poids (choix d'Alexandre). La note de chaque usage est sur sa ligne, plus ici
/// (presentation-v1 : pas de tuile en double). Partagée avec la fiche d'un test de l'historique.
struct ExperienceOverallScoreCard: View {
    let scores: ExperienceScores
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// « Moyenne des 4 usages », ou ce qui manque pour avoir une note globale.
    private var caption: String {
        switch (scores.overall, scores.ratedUses) {
        case (nil, _): String(localized: "Note globale à partir de 2 usages notés")
        case (_, 4): String(localized: "Moyenne des 4 usages")
        case (_, let count): String(localized: "Moyenne des \(count) usages notés")
        }
    }

    var body: some View {
        // Aux tailles d'accessibilité, la note passe au-dessus du titre : « Note globale » ne se coupe pas.
        let header = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: SQSpace.md))
        VStack(alignment: .leading, spacing: SQSpace.md) {
            header {
                if let overall = scores.overall {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: "\(overall)")
                            .font(SQFont.display(40, .heavy, relativeTo: .largeTitle))
                            .foregroundStyle(SQColor.label)
                            .monospacedDigit()
                        Text(verbatim: "/100")
                            .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Note globale")
                        .font(SQFont.body(15, .bold, relativeTo: .headline))
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: caption)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(SQSpace.cardPadding)
        .sqCardBackground()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityIdentifier("experience.overallScore")
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let overall = scores.overall { parts.append(String(localized: "Note globale \(overall) sur 100")) }
        parts.append(caption)
        return parts.joined(separator: ". ")
    }
}
