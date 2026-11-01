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
                    CoverageRouteThumbnail(postId: item.id, coordinates: trace, lineColor: accent)
                        // En haut : le bas gauche porte la mention « Plans » d'Apple, à laisser visible.
                        .overlay(alignment: .topLeading) { techTag.padding(SQSpace.sm) }
                    coverageHeading
                } else {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            coverageHeading
                            techTag
                        }
                    } else {
                        HStack(alignment: .center, spacing: SQSpace.md) {
                            coverageHeading
                            Spacer()
                            techTag
                        }
                    }
                }
                }

                // Tuile mise en avant en accent brique (DA), pas en couleur techno.
                FeedMetricGrid(metrics: metrics)

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
        .buttonStyle(SQPressButtonStyle())
    }

    private var metrics: [FeedMetricGrid.Metric] {
        guard hasSessionAggregate else {
            return [
                .init(label: "Tech", value: signal?.technology ?? "—", highlight: true),
                .init(label: "Signal", value: SignalFormatters.dbm(signal?.averageSignalDbm ?? signal?.rsrp))
            ]
        }
        return [
            .init(label: "Distance", value: SignalFormatters.meters(signal?.distanceMeters), highlight: true),
            .init(label: "Durée", value: SignalFormatters.duration(signal?.durationSeconds)),
            // Des points de mesure, pas des points de jeu (F-18).
            .init(label: "Mesures", value: signal?.pointsCount.map { $0.formatted() } ?? "—")
            // Le signal en dBm (moyen, min, max) reste dans le détail : sans repère, il
            // n'apprend rien à qui fait défiler.
        ]
    }

    /// Déjà dite par le sous-titre (« 4G / 5G NSA »), la technologie de la
    /// pastille n'est pas relue par VoiceOver (lot F, F-49).
    private var techTag: some View {
        let tech = signal?.technology ?? bestDetectedTech ?? "—"
        return SQEditorialTag(text: tech, color: accent)
            .accessibilityHidden(subtitle.contains(tech))
    }

    private var coverageHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hasSessionAggregate ? "Session de couverture" : "Mesure de couverture")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text(subtitle)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        // Avec un tracé, la pastille posée dessus dit la technologie.
        let techs = signal?.detectedTechs.prefix(3).joined(separator: " / ") ?? ""
        if !techs.isEmpty && hasSessionAggregate && (trace ?? []).isEmpty { parts.append(techs) }
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

    private static let aspect: CGFloat = 16 / 9

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
                RouteShape(points: RouteSnapshotCache.project(coordinates, in: rect))
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
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
