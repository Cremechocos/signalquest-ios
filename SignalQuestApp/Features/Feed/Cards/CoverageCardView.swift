import SwiftUI
import MapKit
import Network
import os

/// Specialised feed card for `kind = coverage` (or `session`) : Distance /
/// Durée / Mesures / Signal moy. Une mesure isolée montre sa techno et son
/// signal ; Cell et PCI restent dans le détail (lot F).
struct CoverageCardView: View {
    let item: UnifiedSocialFeedItem
    var onTap: () -> Void
    var onLike: () -> Void
    var onRepost: () -> Void
    var onComment: () -> Void
    var onFavorite: () -> Void
    var onShare: () -> Void
    var onAuthorTap: (() -> Void)? = nil
    /// Réaction emoji (appui long sur ❤️). Repli sur onLike si absent.
    var onReact: ((String) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var signal: SocialSignalSummary? { item.signal }
    private var accent: Color { TechAccent.color(for: signal?.technology ?? bestDetectedTech) }
    private var hasSessionAggregate: Bool {
        signal?.distanceMeters != nil || signal?.pointsCount != nil
    }

    /// Tracé d'une session ou d'un drive test (au moins 2 points), vide sans tracé, nil sinon :
    /// la même règle que le détail, jamais de repli sur une position isolée.
    private var trace: [CLLocationCoordinate2D]? { SignalDetailSheet.trace(kind: item.kind, signal: signal) }

    /// Points du tracé avec leur signal (#957) ; vide quand le serveur ne sert pas
    /// encore la techno par point : le tracé garde alors une seule couleur.
    private var tracePoints: [SessionSignalTrace.Point] {
        let points = signal?.mapPoints ?? []
        guard points.contains(where: { $0.technology != nil }) else { return [] }
        return points.map { SessionSignalTrace.Point(technology: $0.technology, signalStrength: $0.signalStrength) }
    }

    /// Tracé dont aucun point ne porte sa techno : gris « pas de mesure », comme un point
    /// sans techno, jamais la couleur de `signal.technology`, qui est la génération la plus
    /// haute rencontrée (Q4 du contrat des posts automatiques, Alexandre 14/11 : tracé seul).
    static let traceFallbackState: SQQualityScale.Signal = .unknown

    /// Meilleure génération détectée (5G > 4G > 3G > 2G) plutôt que le premier élément
    /// du tableau (ordre arbitraire) : une session 5G NSA détecte « 4G » ET « 5G » — il ne
    /// faut pas afficher « 4G ». Sert de repli quand le backend n'expose pas `technology`.
    private var bestDetectedTech: String? {
        signal?.detectedTechs.max { Self.generationRank($0) < Self.generationRank($1) }
    }

    private static func generationRank(_ tech: String) -> Int {
        let t = tech.uppercased()
        if t.contains("5G") || t.contains("NR") { return 5 }
        if t.contains("4G") || t.contains("LTE") { return 4 }
        if t.contains("3G") || t.contains("UMTS") || t.contains("HSPA") || t.contains("WCDMA") { return 3 }
        if t.contains("2G") || t.contains("GSM") || t.contains("EDGE") || t.contains("GPRS") { return 2 }
        return 0
    }

    var body: some View {
        Button(action: onTap) {
            if let block = item.session {
                sessionPostContent(block)
            } else {
                legacyContent
            }
        }
        .buttonStyle(SQPressButtonStyle())
    }

    // MARK: Post de fin de trajet (DT-POST-1 r2)

    /// Le résumé du trajet tel que la page Trajet le calcule : tracé, trois tuiles, une ligne
    /// par SIM quand l'analyse est prête, speedtests et repères s'il y en a. Ni lieu ni adresse
    /// (choix du 12/11) : le post ne dit pas d'où part le trajet.
    private func sessionPostContent(_ block: SocialSessionPostBlock) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md2) {
            CardHeader(
                author: item.author,
                place: nil,
                createdAt: item.createdAt,
                kindBadge: nil,
                kindColor: SQColor.brandRed,
                onAuthorTap: onAuthorTap,
                isPinned: item.isPinned
            )
            FeedKindLine(symbol: block.source == .driveTest ? "car" : "point.topleft.down.curvedto.point.bottomright.up",
                         title: SessionPostText.title(block.source), points: item.earnedPoints)
            // Trajet privé (D2) : pas de tracé servi, la carte commence aux tuiles.
            if let trace, !trace.isEmpty {
                CoverageRouteThumbnail(
                    postId: item.id, coordinates: trace, lineColor: Self.traceFallbackState.color,
                    states: tracePoints.isEmpty ? nil : SessionSignalTrace.states(tracePoints),
                    spokenSummary: tracePoints.isEmpty ? nil : SessionSignalTrace.spokenSummary(tracePoints)
                )
            }
            SessionPostSummary(block: block)
            FeedOpenCapsule(
                title: String(localized: "Voir le trajet"),
                symbol: "map",
                destination: .link(.session(id: block.id, title: nil)),
                onOpenPost: onTap
            )
            CardActionsBar(
                item: item,
                onLike: onLike,
                onRepost: onRepost,
                onComment: onComment,
                onFavorite: onFavorite,
                onShare: onShare,
                onReact: onReact
            )
        }
        .padding(SQSpace.lg)
        .sqEditorialCard()
    }

    private var legacyContent: some View {
            VStack(alignment: .leading, spacing: SQSpace.md2) {
                CardHeader(
                    author: item.author,
                    place: signal?.city ?? item.readablePlaceLabel,
                    createdAt: item.createdAt,
                    kindBadge: nil,
                    kindColor: SQColor.brandRed,
                    onAuthorTap: onAuthorTap,
                    isPinned: item.isPinned
                )

                if let trace, !trace.isEmpty {
                    FeedKindLine(symbol: "point.topleft.down.curvedto.point.bottomright.up",
                                 title: String(localized: "Session de couverture"), points: item.earnedPoints)
                    CoverageRouteThumbnail(
                        postId: item.id, coordinates: trace, lineColor: Self.traceFallbackState.color,
                        states: tracePoints.isEmpty ? nil : SessionSignalTrace.states(tracePoints),
                        spokenSummary: tracePoints.isEmpty ? nil : SessionSignalTrace.spokenSummary(tracePoints)
                    )
                } else {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            coverageHeading
                            if !subtitleNamesTech && !hasSessionAggregate { techTag }
                        }
                    } else {
                        HStack(alignment: .center, spacing: SQSpace.md) {
                            coverageHeading
                            Spacer()
                            if !subtitleNamesTech && !hasSessionAggregate { techTag }
                        }
                    }
                }
                }

                // Tuile mise en avant en accent brique (DA), pas en couleur techno.
                FeedMetricGrid(metrics: metrics)

                if hasSessionAggregate {
                    FeedNetworkLine(operator: signal?.operator, technologies: sessionTechnologies, detail: measuresDetail)
                }

                if let footer = footer {
                    Text(footer)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let text = item.cardText {
                    Text(text)
                        .font(SQType.body)
                        .lineSpacing(3)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let trace, !trace.isEmpty {
                    // Contrat du tracé : la carte principale, sur cette session seule ; le post sinon.
                    FeedOpenCapsule(
                        title: String(localized: "Voir le tracé"),
                        symbol: "map",
                        destination: item.metadataString("sessionId").map { .link(.session(id: $0, title: nil)) } ?? .post,
                        onOpenPost: onTap
                    )
                }

                CardActionsBar(
                    item: item,
                    onLike: onLike,
                    onRepost: onRepost,
                    onComment: onComment,
                    onFavorite: onFavorite,
                    onShare: onShare,
                    onReact: onReact
                )
            }
            .padding(SQSpace.lg)
            .sqEditorialCard()
    }

    private var metrics: [FeedMetricGrid.Metric] {
        guard hasSessionAggregate else {
            return [
                .init(label: "Tech", value: signal?.technology ?? "—", highlight: true),
                .init(label: "Signal", value: SignalFormatters.dbm(signal?.averageSignalDbm ?? signal?.rsrp))
            ]
        }
        // Trois états de la distance, communs aux trois apps : mesurée → mise en avant ; à 0 m ou
        // sans tracé → un tiret, sans mise en avant ; non servie → pas de tuile (« mesuré à zéro »
        // et « pas de mesure » ne se confondent pas).
        let distance = Self.distanceMetric(meters: signal?.distanceMeters, hasTrace: !(trace ?? []).isEmpty)
        var metrics = Array([distance].compactMap { $0 }) + [
            .init(label: "Durée", value: SignalFormatters.duration(signal?.durationSeconds))
        ]
        // Le signal moyen, à côté du tracé coloré qui lui sert de repère (refonte du 04/11).
        // Le nombre de mesures passe sur la ligne réseau (« · 3 mesures »).
        if let average = signal?.averageSignalDbm {
            metrics.append(.init(label: "Moyenne du signal", value: SignalFormatters.dbm(average)))
        }
        return metrics
    }

    static func distanceMetric(meters: Double?, hasTrace: Bool) -> FeedMetricGrid.Metric? {
        guard let meters else { return nil }
        return hasTrace && meters > 0
            ? .init(label: "Distance", value: SignalFormatters.meters(meters), highlight: true)
            : .init(label: "Distance", value: "—")
    }

    /// Générations rencontrées pendant la session, de la plus récente à la plus ancienne.
    private var sessionTechnologies: [String] {
        let techs = signal?.detectedTechs ?? []
        return techs.isEmpty ? [signal?.technology].compactMap { $0 } : techs
    }

    /// « 3 mesures » : des points de mesure, pas des points de jeu (F-18).
    private var measuresDetail: String? {
        guard let count = signal?.pointsCount, count > 0 else { return nil }
        return String(localized: "\(count) mesures")
    }

    private var tagTech: String { signal?.technology ?? bestDetectedTech ?? "—" }

    /// Carte sans tracé : le sous-titre (« Bouygues Telecom · 4G ») nomme déjà la technologie,
    /// la pastille ferait doublon. Sur le tracé, elle reste : il n'y a pas de sous-titre.
    /// Règle commune : la technologie de la pastille figure parmi celles du sous-titre, comparée
    /// technologie par technologie (« 4G · 5G NSA » nomme 4G). Absente du sous-titre, elle reste :
    /// mieux vaut voir l'incohérence.
    private var subtitleNamesTech: Bool { Self.subtitle(shownSubtitle, names: tagTech) }

    static func subtitle(_ subtitle: String?, names tech: String) -> Bool {
        guard let subtitle else { return false }
        let parts = subtitle.components(separatedBy: CharacterSet(charactersIn: "·/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.contains(tech)
    }

    /// Déjà dite par le sous-titre (« 4G / 5G NSA »), la technologie de la
    /// pastille n'est pas relue par VoiceOver (lot F, F-49).
    private var techTag: some View {
        SQEditorialTag(text: tagTech, color: accent)
            .accessibilityHidden(subtitleNamesTech)
    }

    private var coverageHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hasSessionAggregate ? "Session de couverture" : "Mesure de couverture")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            if let shownSubtitle {
                Text(shownSubtitle)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Session avec tracé : pas de sous-titre (contrat social-session-preview), la carte
    /// et sa pastille disent déjà l'essentiel. Avant que le serveur serve l'opérateur,
    /// ce sous-titre ne valait que le repli « Parcours radio ».
    private var shownSubtitle: String? {
        // Session : opérateur et générations sont sur la ligne réseau, sous les tuiles.
        hasSessionAggregate ? nil : subtitle
    }

    /// Mesures et distance sont déjà dans les tuiles : le sous-titre dit les
    /// technologies rencontrées (F-18).
    private var subtitle: String {
        var parts: [String] = []
        if !hasSessionAggregate {
            if let op = signal?.operator { parts.append(op) }
            if let tech = signal?.technology { parts.append(tech) }
        }
        if hasSessionAggregate, let op = signal?.operator {
            parts.append(SQBrand.operatorName(op) ?? op)
        }
        let techs = signal?.detectedTechs.prefix(3).joined(separator: " / ") ?? ""
        if !techs.isEmpty && hasSessionAggregate { parts.append(techs) }
        return parts.joined(separator: " · ").nonEmpty ?? String(localized: "Parcours radio")
    }

    private var footer: String? {
        // Session : le signal reste dans le détail, la carte s'en tient à trois chiffres.
        guard !hasSessionAggregate else { return nil }
        var parts: [String] = []
        if let min = signal?.minSignalDbm, let max = signal?.maxSignalDbm {
            // « de -118 à -81 dBm » : le plus faible puis le plus fort (F-18).
            parts.append(String(localized: "Signal de \(Int(min.rounded())) à \(SignalFormatters.dbm(max))"))
        } else if let avg = signal?.averageSignalDbm {
            parts.append(String(localized: "Signal \(SignalFormatters.dbm(avg))"))
        }
        // Le modèle d'appareil n'apprend rien aux autres : il reste dans le
        // détail de ses propres publications (lot F, F-05).
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Post de fin de trajet

/// Textes du post de fin de trajet (DT-POST-1 r2 §3) : les nombres sont servis, l'app formate.
enum SessionPostText {
    static func title(_ source: SocialSessionPostBlock.Source) -> String {
        switch source {
        case .driveTest: return String(localized: "Drive Test terminé")
        case .coverage: return String(localized: "Session de couverture terminée")
        }
    }

    /// Distance (km à une décimale), durée (minutes entières, comme la page Trajet), relevés.
    static func metrics(_ block: SocialSessionPostBlock) -> [FeedMetricGrid.Metric] {
        var metrics: [FeedMetricGrid.Metric] = []
        if let meters = block.distanceMeters {
            metrics.append(.init(label: String(localized: "Distance"),
                                 value: meters > 0 ? distance(meters: meters) : "—", highlight: meters > 0))
        }
        if let seconds = block.durationSeconds {
            metrics.append(.init(label: String(localized: "Durée"), value: SignalFormatters.duration(Double(seconds))))
        }
        if let points = block.logicalPoints {
            metrics.append(.init(label: String(localized: "Relevés"), value: points.formatted()))
        }
        return metrics
    }

    /// Km à une décimale, arrondis au plus proche, la moitié vers le haut comme le serveur
    /// (12 250 m → « 12,3 km ») : le format d'Apple arrondirait l'égalité au pair (« 12,2 »).
    /// Les mètres entiers passent d'abord aux 100 m, puis le format n'a plus d'égalité à trancher.
    static func distance(meters: Int) -> String {
        guard SQUnits.current == .metric, meters >= 950 else { return SQUnits.distance(meters: Double(meters)) }
        return SQUnits.distance(meters: Double((meters + 50) / 100 * 100))
    }

    /// « Bon · 1 trou », ou « Peu fiable · Trop peu de mesures » (contrat §3.2).
    static func headline(_ series: SocialSessionPostBlock.Series) -> String? {
        if series.isUnreliable { return String(localized: "Peu fiable · Trop peu de mesures") }
        let parts = [SessionAnalysisText.levelLabel(series.level), series.holes.map(SessionAnalysisText.holesLabel)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// « 5G 34 % · couvert 98 % · bon signal 71 % » ; une part absente est omise.
    static func shares(_ series: SocialSessionPostBlock.Series) -> String? {
        let parts = [
            series.pct5g.map { String(localized: "5G \(percent($0))") },
            series.coveragePct.map { String(localized: "couvert \(percent($0))") },
            series.goodSignalPct.map { String(localized: "bon signal \(percent($0))") },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// « 2 speedtests · médiane ↓ 855 Mb/s · ↑ 92 Mb/s » ; rien sans speedtest.
    static func speedtests(_ speedtests: SocialSessionPostBlock.Speedtests?) -> String? {
        guard let speedtests, speedtests.count > 0 else { return nil }
        var parts = [String(localized: "\(speedtests.count) speedtests")]
        let rates = [
            speedtests.downloadMedianMbps.map { "↓ \(SignalFormatters.speed($0))" },
            speedtests.uploadMedianMbps.map { "↑ \(SignalFormatters.speed($0))" },
        ].compactMap { $0 }
        if !rates.isEmpty { parts.append(String(localized: "médiane \(rates.joined(separator: " · "))")) }
        return parts.joined(separator: " · ")
    }

    /// « Repères : tunnel ×2 · pont ×1 », le type tel que le membre l'a choisi.
    static func annotations(_ annotations: [SocialSessionPostBlock.Annotation]) -> String? {
        guard !annotations.isEmpty else { return nil }
        let list = annotations.map { "\(annotationLabel($0.type)) ×\($0.count)" }.joined(separator: " · ")
        return String(localized: "Repères : \(list)")
    }

    /// Un repère est le libellé que l'auteur a choisi, affiché tel quel, sauf les trois codes
    /// des repères automatiques d'Android (comparaison stricte, casse comprise ; Android 12/11).
    static func annotationLabel(_ type: String) -> String {
        switch type {
        case "AUTO_RSRP_DROP": return String(localized: "Chute RSRP")
        case "AUTO_HANDOVER_STORM": return String(localized: "Tempête de handovers")
        case "AUTO_NO_SERVICE": return String(localized: "Perte de service")
        default: return type
        }
    }

    private static func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Une ligne par série opérateur × SIM, dans l'ordre servi (celui de la page Trajet).
private struct SessionPostSeriesList: View {
    let series: [SocialSessionPostBlock.Series]

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            ForEach(Array(series.enumerated()), id: \.element.id) { position, line in
                if position > 0 { Divider() }
                row(line)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func row(_ line: SocialSessionPostBlock.Series) -> some View {
        HStack(alignment: .top, spacing: SQSpace.sm) {
            Circle()
                .fill(SQBrand.operatorColor(line.operatorKey))
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    Text(verbatim: line.operatorLabel)
                        .font(SQFont.body(15, .semibold))
                    Spacer(minLength: 0)
                    if let score = line.score {
                        Text(verbatim: "\(score)/100")
                            .font(SQFont.body(15, .bold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(SQColor.label)
                // TRAJET-SIM : la marque de la SIM sous la ligne, jamais dans son titre.
                ForEach(Array(SessionTripBrand.mentions(line.operatorDisplay).enumerated()), id: \.offset) { _, mention in
                    Text(verbatim: SessionTripBrand.text(mention))
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                }
                if let headline = SessionPostText.headline(line) {
                    Text(verbatim: headline)
                        .font(SQType.callout)
                        .foregroundStyle(line.isUnreliable ? OutageTint.degradedInk : SQColor.label)
                }
                if let shares = SessionPostText.shares(line) {
                    Text(verbatim: shares)
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Miniature du parcours

/// Parcours d'une session au format 16:9 : le tracé d'abord, le fond de plan ensuite
/// (contrat social-session-preview, « Rendu dans les apps »).
///
/// Le tracé est vectoriel et s'affiche tout de suite sur un fond neutre : projeter 64 points
/// ne coûte rien, et le parcours reste lisible même si le plan n'arrive jamais (réseau lent,
/// défilement rapide, appareil modeste). Le plan (`MKMapSnapshotter`, jamais de carte
/// vivante dans le fil) se pose dessous en fondu, rendu à l'apparition, un seul à la fois,
/// abandonné si la carte sort de l'écran avant la fin.
///
/// ⚠️ Volontairement SANS marqueur de départ ni d'arrivée : aucun point du tracé n'est
/// retiré (règle produit), mais un point « départ » désignerait le domicile du doigt.
/// Ne pas « compléter » la miniature avec des épingles.
private struct CoverageRouteThumbnail: View {
    let postId: String
    let coordinates: [CLLocationCoordinate2D]
    let lineColor: Color
    /// État de chaque point (contrat session-signal-trace) ; nil : une seule couleur.
    var states: [SQQualityScale.Signal]? = nil
    var spokenSummary: String? = nil

    // 2:1 plutôt que 16:9 : la carte du fil reste compacte (Alexandre, 12/11).
    private static let aspect: CGFloat = 2

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var background: UIImage?

    var body: some View {
        let rect = RouteSnapshotCache.frame(for: coordinates, aspect: Self.aspect)
        // Hauteur réservée d'avance : rien ne saute pendant le défilement.
        Color.clear
            .aspectRatio(Self.aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(SQColor.surfaceMuted)
            .overlay {
                if let background {
                    Image(uiImage: background).resizable().transition(.opacity)
                }
            }
            .overlay {
                let points = RouteSnapshotCache.project(coordinates, in: rect)
                if let states, states.count == points.count {
                    // Chaque segment prend l'état de son point d'arrivée ; « sans réseau
                    // constaté » en pointillé ardoise, jamais une teinte de l'échelle.
                    ZStack {
                        ForEach(1..<points.count, id: \.self) { index in
                            let state = states[index]
                            RouteShape(points: [points[index - 1], points[index]])
                                .stroke(state.color, style: state.isHatched
                                    ? StrokeStyle(lineWidth: 4, lineCap: .round, dash: [4, 6])
                                    : StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        }
                    }
                } else {
                    RouteShape(points: points)
                        .stroke(lineColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            .overlay {
                GeometryReader { proxy in
                    Color.clear.task(id: key(proxy.size)) {
                        let key = key(proxy.size)
                        background = RouteSnapshotCache.shared.cached(key)
                        guard background == nil, proxy.size.width > 1 else { return }
                        let image = await RouteSnapshotCache.shared.background(
                            of: rect, size: proxy.size, scale: displayScale, dark: colorScheme == .dark, key: key
                        )
                        withAnimation(reduceMotion ? nil : SQMotion.standard) { background = image }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel(Text("Carte du parcours"))
            .accessibilityValue(Text(verbatim: spokenSummary ?? ""))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("feed.coverage.route")
    }

    private func key(_ size: CGSize) -> String {
        "\(postId)|\(colorScheme == .dark ? "dark" : "light")|\(Int(size.width.rounded()))"
    }
}

/// `MKMapSnapshotter` n'est pas `Sendable` ; `start` et `cancel` sont sûrs depuis tout fil.
private final class SnapshotterBox: @unchecked Sendable {
    let value: MKMapSnapshotter
    init(_ value: MKMapSnapshotter) { self.value = value }
}

/// Termine une seule fois l'attente d'un plan, depuis n'importe quel fil.
final class SnapshotOutcome: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(CheckedContinuation<UIImage?, Never>?, Bool)>(initialState: (nil, false))

    func attach(_ continuation: CheckedContinuation<UIImage?, Never>) {
        let finished = lock.withLock { state -> Bool in
            if state.1 { return true }
            state.0 = continuation
            return false
        }
        if finished { continuation.resume(returning: nil) }
    }

    func finish(_ image: UIImage?) {
        let continuation = lock.withLock { state -> CheckedContinuation<UIImage?, Never>? in
            if state.1 { return nil }
            state.1 = true
            defer { state.0 = nil }
            return state.0
        }
        continuation?.resume(returning: image)
    }
}

/// Polyligne en coordonnées normalisées (0…1) dans le cadre de la vue.
private struct RouteShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Fonds de plan des miniatures de parcours : un rendu à la fois sur tout le fil, cache
/// borné en octets (une miniature pleine largeur en @3x pèse environ 3 Mo).
@MainActor
final class RouteSnapshotCache {
    static let shared = RouteSnapshotCache()

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // 1 % de la mémoire physique, au plus 40 Mo.
        cache.totalCostLimit = Int(min(40_000_000, ProcessInfo.processInfo.physicalMemory / 100))
        return cache
    }()
    /// Un instantané à la fois : les suivants attendent leur tour, dans l'ordre d'arrivée.
    private var isRendering = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let pathMonitor = NWPathMonitor()
    private var isConstrained = false

    private init() {
        pathMonitor.pathUpdateHandler = { path in
            let constrained = path.isConstrained
            Task { @MainActor in RouteSnapshotCache.shared.isConstrained = constrained }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// Appareil modeste, mode économie d'énergie ou données réduites : pas de fond du tout,
    /// le tracé sur fond neutre suffit.
    private var skipsBackground: Bool {
        isConstrained || ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.physicalMemory < 3_000_000_000
    }

    func cached(_ key: String) -> UIImage? { images.object(forKey: key as NSString) }

    func background(of rect: MKMapRect, size: CGSize, scale: CGFloat, dark: Bool, key: String) async -> UIImage? {
        guard !skipsBackground else { return nil }
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.scale = scale
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        return await inTurn(key: key) {
            let snapshotter = SnapshotterBox(MKMapSnapshotter(options: options))
            return await Self.render(timeout: 15,
                                     start: { done in snapshotter.value.start(with: .main) { snapshot, _ in done(snapshot?.image) } },
                                     cancel: { snapshotter.value.cancel() })
        }
    }

    /// Un rendu à la fois sur tout le fil ; le tour est rendu quoi qu'il arrive au rendu.
    func inTurn(key: String, _ work: () async -> UIImage?) async -> UIImage? {
        await takeTurn()
        defer { endTurn() }
        // Carte sortie de l'écran pendant l'attente : rien à rendre.
        guard !Task.isCancelled else { return nil }
        if let image = cached(key) { return image }
        guard let image = await work(), !Task.isCancelled else { return nil }
        images.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.scale * image.size.height * image.scale * 4))
        return image
    }

    /// Reprise unique, quel que soit l'événement qui arrive le premier : plan rendu, délai
    /// dépassé (réseau muet : la file ne doit pas rester bloquée) ou carte sortie de l'écran.
    /// MapKit ne promet pas de rappeler après une annulation : on n'attend jamais son rappel.
    static func render(timeout: TimeInterval,
                       start: @MainActor (@escaping @Sendable (UIImage?) -> Void) -> Void,
                       cancel: @escaping @Sendable () -> Void) async -> UIImage? {
        let outcome = SnapshotOutcome()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                outcome.attach(continuation)
                MainActor.assumeIsolated { start { outcome.finish($0) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    cancel()
                    outcome.finish(nil)
                }
            }
        } onCancel: {
            cancel()
            outcome.finish(nil)
        }
    }

    private func takeTurn() async {
        guard isRendering else { isRendering = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty { isRendering = false } else { waiting.removeFirst().resume() }
    }

    /// Emprise du tracé avec une marge, au moins 250 m de demi-côté autour du centre (sinon une
    /// session courte tiendrait sur un pixel), au format de la miniature, sans jamais recadrer.
    nonisolated static func frame(for coordinates: [CLLocationCoordinate2D], aspect: CGFloat) -> MKMapRect {
        let bounds = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
        let minSide = MKMapPointsPerMeterAtLatitude(MKMapPoint(x: bounds.midX, y: bounds.midY).coordinate.latitude) * 500
        let width = max(bounds.width * 1.25, minSide)
        let height = max(bounds.height * 1.25, minSide)
        let fittedWidth = max(width, height * Double(aspect))
        let fittedHeight = max(height, width / Double(max(aspect, 0.01)))
        return MKMapRect(x: bounds.midX - fittedWidth / 2, y: bounds.midY - fittedHeight / 2,
                         width: fittedWidth, height: fittedHeight)
    }

    /// Projection plane (Mercator) des points dans l'emprise : la même que le plan rendu.
    nonisolated static func project(_ coordinates: [CLLocationCoordinate2D], in rect: MKMapRect) -> [CGPoint] {
        coordinates.map { coordinate in
            let point = MKMapPoint(coordinate)
            return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
        }
    }
}

/// Tuiles, une ligne par SIM, speedtests et repères d'un post de trajet : le même
/// résumé dans le fil et dans le détail du post (DT-POST-1, 12/11).
struct SessionPostSummary: View {
    let block: SocialSessionPostBlock

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md2) {
            FeedMetricGrid(metrics: SessionPostText.metrics(block))
            if !block.series.isEmpty {
                SessionPostSeriesList(series: block.series)
            }
            let extras = [SessionPostText.speedtests(block.speedtests), SessionPostText.annotations(block.annotations)]
            if extras.contains(where: { $0 != nil }) {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    if let line = extras[0] {
                        Label(line, systemImage: "speedometer")
                    }
                    if let line = extras[1] {
                        Label(line, systemImage: "flag")
                    }
                }
                .font(SQType.caption)
                .monospacedDigit()
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
