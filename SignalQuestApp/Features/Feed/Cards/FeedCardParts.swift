import SwiftUI
import MapKit

// Pièces communes des cartes de posts automatiques (refonte du 04/11, maquettes
// validées par Alexandre) : la ligne de type, la ligne réseau, la capsule qui
// ouvre l'objet, la jauge de débit et l'aperçu de plan d'un lieu.

// MARK: - Ligne de type

/// Ce qu'est le post, avant tout le reste : pastille ronde teintée avec un
/// symbole SF, le nom du type, et les points gagnés à droite.
struct FeedKindLine: View {
    enum Tint {
        case accent, success, warning, danger

        var ink: Color {
            switch self {
            case .accent: return SQColor.accentInk
            case .success: return SQColor.success
            case .warning: return SQColor.warning
            case .danger: return SQColor.dangerInk
            }
        }

        var soft: Color {
            switch self {
            case .accent: return SQColor.accentSoft
            case .success: return SQColor.successSoft
            case .warning: return SQColor.warningSoft
            case .danger: return SQColor.dangerSoft
            }
        }
    }

    let symbol: String
    let title: String
    var tint: Tint = .accent
    var points: Int? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.xs2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: SQSpace.sm))
        layout {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint.ink)
                    .frame(width: 28, height: 28)
                    .background(tint.soft, in: Circle())
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if let points, points > 0 {
                SQEditorialTag(text: String(localized: "+\(points) pts"), color: SQColor.success)
                    .accessibilityLabel(String(localized: "\(points) points gagnés"))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed.kind")
    }
}

extension UnifiedSocialFeedItem {
    /// Points gagnés par le post automatique ; rien à zéro ou sans valeur.
    var earnedPoints: Int? {
        switch metadata?["points"] {
        case .number(let value)? where value.isFinite && value > 0 && value < 1e9: return Int(value)
        case .string(let value)?: return Int(value).flatMap { $0 > 0 ? $0 : nil }
        default: return nil
        }
    }

    /// Fiche d'antenne d'une identification ou d'une photo (contrat des posts automatiques v1,
    /// règle d'Alexandre du 14/11 « Numéro ANFR seul suffit ») : un numéro de support ANFR
    /// (3 à 10 chiffres, France et outre-mer) est unique et s'ouvre seul, avec le marché et
    /// l'opérateur s'ils sont servis ; tout autre identifiant (Canada…) exige la clé SITE-1
    /// complète ; un id de 25 caractères est un site communautaire, jamais une fiche d'antenne.
    /// Sans `siteId` (zone privée), pas de lien. Rien n'est deviné.
    var antennaLink: (siteId: String, market: String?, operatorKey: String?)? {
        guard let siteId = metadataString("siteId") else { return nil }
        let market = metadataString("marketCode"), operatorKey = metadataString("operatorKey")
        if Self.isANFRSupportNumber(siteId) { return (siteId, market, operatorKey) }
        guard !Self.isCommunitySiteId(siteId), let market, let operatorKey else { return nil }
        return (siteId, market, operatorKey)
    }

    static func isANFRSupportNumber(_ id: String) -> Bool {
        (3...10).contains(id.count) && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Identifiant de site communautaire (25 caractères) : il n'ouvre jamais une fiche d'antenne.
    static func isCommunitySiteId(_ id: String) -> Bool { id.count == 25 }

    func metadataString(_ key: String) -> String? {
        switch metadata?[key] {
        case .string(let value)?:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let value)? where value.isFinite && abs(value) < 1e15:
            return value == value.rounded() ? String(Int(value)) : String(value)
        default: return nil
        }
    }

    func metadataNumber(_ key: String) -> Double? {
        switch metadata?[key] {
        case .number(let value)? where value.isFinite: return value
        case .string(let value)?: return Double(value)
        default: return nil
        }
    }

    /// Position arrondie servie avec le post (3 décimales, environ 100 m) : celle
    /// du post, sinon celle de son résumé.
    var cardCoordinate: CLLocationCoordinate2D? {
        let lat = latitude ?? signal?.latitude
        let lon = longitude ?? signal?.longitude
        guard let lat, let lon, lat.isFinite, lon.isFinite, lat != 0 || lon != 0,
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Ligne réseau

/// Opérateur en toutes lettres, génération dans sa couleur du contrat, puis
/// fréquence ou précision. En Wi-Fi : le symbole et « Wi-Fi (fournisseur) ».
struct FeedNetworkLine: View {
    let operatorName: String?
    let technologies: [String]
    var detail: String? = nil

    init(operator rawOperator: String?, technology: String?, detail: String? = nil) {
        self.init(operator: rawOperator, technologies: technology.map { [$0] } ?? [], detail: detail)
    }

    init(operator rawOperator: String?, technologies: [String], detail: String? = nil) {
        let trimmed = rawOperator?.trimmingCharacters(in: .whitespacesAndNewlines)
        operatorName = trimmed?.isEmpty == false ? trimmed : nil
        self.technologies = technologies
        self.detail = detail
    }

    private var isWiFi: Bool { technologies.contains { TechAccent.shortLabel(for: $0) == "Wi-Fi" } }

    /// Une pastille par génération reconnue, de la plus récente à la plus ancienne.
    private var generations: [SQQualityScale.Generation] {
        let order: [SQQualityScale.Generation] = [.fiveG, .fourG, .threeG, .twoG]
        let found = Set(technologies.map { SQQualityScale.Generation(technology: $0) })
        return order.filter { found.contains($0) }
    }

    var isEmpty: Bool { operatorName == nil && generations.isEmpty && detail == nil && !isWiFi }

    var body: some View {
        if !isEmpty {
            FlowRow(spacing: SQSpace.xs2) {
                if isWiFi {
                    Label {
                        Text(verbatim: operatorName.map { "Wi-Fi (\($0))" } ?? "Wi-Fi")
                    } icon: {
                        Image(systemName: "wifi").accessibilityHidden(true)
                    }
                    .font(SQType.subhead(.semibold))
                    .foregroundStyle(SQColor.label)
                } else {
                    if let operatorName {
                        Text(verbatim: SQBrand.operatorName(operatorName) ?? operatorName)
                            .font(SQType.subhead(.semibold))
                            .foregroundStyle(SQColor.label)
                    }
                    ForEach(generations, id: \.self) { generation in
                        Text(verbatim: generation.label)
                            .font(SQFont.body(11.5, .bold, relativeTo: .caption))
                            // Teintes foncées du contrat : le blanc y reste lisible.
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(generation.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                if let detail {
                    Text(verbatim: "· \(detail)")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spoken))
            .accessibilityIdentifier("feed.network")
        }
    }

    private var spoken: String {
        var parts: [String] = []
        if isWiFi {
            parts.append(operatorName.map { "Wi-Fi (\($0))" } ?? "Wi-Fi")
        } else {
            if let operatorName { parts.append(SQBrand.operatorName(operatorName) ?? operatorName) }
            parts += generations.map(\.label)
        }
        if let detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

/// Rangée qui passe à la ligne quand elle déborde (iOS 16 : `Layout`).
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: .init(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: width, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? min(size.width, width) : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Capsule « Voir… »

/// Ce que la capsule ouvre. Sans action posée par l'écran du fil, elle ouvre
/// la publication, comme le reste de la carte.
enum FeedCardDestination: Equatable {
    case post
    case link(FeedActivity.Link)
}

private struct FeedOpenLinkKey: EnvironmentKey {
    static var defaultValue: ((FeedActivity.Link) -> Void)? { nil }
}

extension EnvironmentValues {
    /// Ouvre la cible d'une carte (site, panne, progression). Posée par le fil.
    var feedOpenLink: ((FeedActivity.Link) -> Void)? {
        get { self[FeedOpenLinkKey.self] }
        set { self[FeedOpenLinkKey.self] = newValue }
    }
}

/// Capsule de 44 pt qui mène à l'objet du post : le test, le tracé, le site, la panne.
struct FeedOpenCapsule: View {
    let title: String
    var symbol: String? = nil
    var destination: FeedCardDestination = .post
    var prominent = true
    let onOpenPost: () -> Void
    @Environment(\.feedOpenLink) private var openLink

    var body: some View {
        Button {
            Haptics.light()
            switch destination {
            case .post: onOpenPost()
            case .link(let link):
                if let openLink { openLink(link) } else { onOpenPost() }
            }
        } label: {
            HStack(spacing: SQSpace.xs2) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(SQType.callout(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if symbol == nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(prominent ? SQColor.onInk : SQColor.label)
            .padding(.horizontal, SQSpace.lg)
            .frame(minHeight: SQSpace.primaryActionHeight)
            .background(prominent ? SQColor.label : SQColor.surfaceMuted, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityIdentifier("feed.open")
    }
}

// MARK: - Jauge de débit

/// Les 6 paliers de débit du contrat (v2), aux couleurs de la couche speedtest de la
/// carte (`SQQualityScale.Throughput.hex`, les mêmes en clair et en sombre).
/// Un palier par couleur, de largeur égale ; le repère avance en échelle log
/// dans son palier. Le dernier va de 1 000 à 3 000 Mbit/s : la 5G dépasse
/// souvent 1 000 et ne doit pas rester collée au bord.
struct FeedSpeedScale: View {
    let mbps: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var tickHeight: CGFloat = 14

    /// Du plus lent au plus rapide.
    static let tiers: [SQQualityScale.Throughput] = SQQualityScale.Throughput.allCases.reversed()
    static let topMbps: Double = 3_000

    /// Position du repère, de 0 à 1.
    static func position(mbps: Double) -> Double {
        guard mbps.isFinite, mbps > 0 else { return 0 }
        let tier = SQQualityScale.Throughput(mbps: mbps)
        guard let index = tiers.firstIndex(of: tier) else { return 0 }
        let lower = max(tier.lowerBoundMbps, 1)
        let upper = index + 1 < tiers.count ? tiers[index + 1].lowerBoundMbps : topMbps
        let clamped = min(max(mbps, lower), upper)
        let fraction = upper > lower ? log(clamped / lower) / log(upper / lower) : 0
        return (Double(index) + min(max(fraction, 0), 1)) / Double(tiers.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Self.tiers, id: \.self) { tier in
                            Rectangle().fill(tier.color)
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule(style: .continuous))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(SQColor.label)
                        .frame(width: 4, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).stroke(SQColor.surface, lineWidth: 2))
                        .offset(x: min(max(width * Self.position(mbps: mbps) - 2, 0), width - 4))
                }
                .frame(height: 18)
            }
            .frame(height: 18)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(Self.tiers.dropFirst().enumerated()), id: \.offset) { offset, tier in
                        // Aux tailles AX, seules les décades tiennent sans se chevaucher.
                        if !dynamicTypeSize.isAccessibilitySize || [10, 100, 1_000].contains(Int(tier.lowerBoundMbps)) {
                            tick(Int(tier.lowerBoundMbps).formatted())
                                .position(x: proxy.size.width * CGFloat(offset + 1) / CGFloat(Self.tiers.count), y: tickHeight / 2)
                        }
                    }
                }
            }
            .frame(height: tickHeight)
        }
        .padding(.horizontal, SQSpace.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Échelle de débit"))
        .accessibilityValue(Text(SQQualityScale.Throughput(mbps: mbps).label))
        .accessibilityIdentifier("feed.speed.scale")
    }

    private func tick(_ value: String) -> some View {
        Text(verbatim: value)
            .font(SQFont.body(10.5, .medium, relativeTo: .caption2))
            .monospacedDigit()
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize()
    }
}

// MARK: - Aperçu de plan d'un lieu

/// Plan fixe autour d'un point (jamais une carte vivante dans le fil), avec un
/// repère brique au centre et, au-dessus, une bulle facultative. Même rendu que
/// la miniature du parcours : fond neutre tout de suite, plan en fondu ensuite.
struct FeedPlaceSnapshot<Bubble: View>: View {
    let cacheKey: String
    let coordinate: CLLocationCoordinate2D
    var aspect: CGFloat = 16 / 9
    var marker: String? = nil
    @ViewBuilder var bubble: () -> Bubble

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var background: UIImage?

    var body: some View {
        let rect = RouteSnapshotCache.frame(for: [coordinate], aspect: aspect)
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(SQColor.surfaceMuted)
            .overlay {
                if let background {
                    Image(uiImage: background).resizable().transition(.opacity)
                }
            }
            .overlay {
                GeometryReader { proxy in
                    let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    ZStack {
                        pin.position(center)
                        // Bas de la bulle juste au-dessus du repère, sa pointe sur le point.
                        bubble()
                            .fixedSize()
                            .frame(width: proxy.size.width, height: max(center.y - bubbleGap, 0), alignment: .bottom)
                            .position(x: center.x, y: max(center.y - bubbleGap, 0) / 2)
                    }
                    .task(id: key(proxy.size)) {
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
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// Écart entre le point et le bas de la bulle (la pointe en occupe 6).
    private var bubbleGap: CGFloat { 16 }

    private var pin: some View {
        ZStack {
            Circle().fill(SQColor.accent.opacity(0.12)).frame(width: 64, height: 64)
            Circle().fill(SQColor.accent.opacity(0.2)).frame(width: 34, height: 34)
            if let marker {
                Image(systemName: marker)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SQColor.onAccent)
                    .frame(width: 28, height: 28)
                    .background(SQColor.accent, in: Circle())
            } else {
                Circle().fill(SQColor.accent).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(SQColor.surface, lineWidth: 3))
            }
        }
        .accessibilityHidden(true)
    }

    private func key(_ size: CGSize) -> String {
        "\(cacheKey)|place|\(colorScheme == .dark ? "dark" : "light")|\(Int(size.width.rounded()))"
    }
}

/// Bulle posée sur un plan : surface, ombre courte et pointe vers le repère.
struct FeedMapBubble<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(SQColor.surface)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(45))
                    .offset(y: 6)
            }
            .shadow(color: SQColor.shadowCard, radius: 10, y: 4)
    }
}
