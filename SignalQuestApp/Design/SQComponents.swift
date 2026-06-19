import SwiftUI
import MapKit

struct TechBadge: View {
    let text: String
    var color: Color = SQColor.brandBlue

    var body: some View {
        Text(text.uppercased())
            .font(SQType.micro)
            .padding(.horizontal, SQSpace.sm + 2)
            .padding(.vertical, SQSpace.xs + 2)
            .background(color.opacity(0.18), in: Capsule())
            .overlay { Capsule().stroke(color.opacity(0.42), lineWidth: 1) }
            .foregroundStyle(color)
    }
}

struct MetricPill: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(SQColor.brandOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
                Text(value)
                    .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, SQSpace.sm + 2)
        .padding(.vertical, SQSpace.sm)
        .background(.thinMaterial, in: Capsule())
        .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1) }
    }
}

struct SQAvatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(SQGradient.signal)
            if let url {
                RemoteImage(url: url, maxDimension: size, contentMode: .fill) {
                    initials
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().stroke(SQColor.separator, lineWidth: 1) }
    }

    private var initials: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(SQFont.archivo(max(13, size * 0.38), .bold))
            .foregroundStyle(.white)
    }
}

struct StoryBubble: View {
    let story: SocialStory
    var viewed: Bool? = nil

    var body: some View {
        let isViewed = viewed ?? (story.viewedByMe == true)
        VStack(spacing: SQSpace.sm) {
            SQAvatar(url: story.author.avatarUrl, name: story.author.displayName, size: 62)
                .padding(3)
                .overlay {
                    if isViewed {
                        Circle().strokeBorder(SQColor.separator, lineWidth: 1.5)
                    } else {
                        SQStoryRing(lineWidth: 3)
                    }
                }
            Text(story.author.displayName)
                .font(SQType.caption)
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .frame(width: 74)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SignalBarsView: View {
    let summary: SocialSignalSummary?

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            if summary?.rsrp == nil && summary?.technology == nil {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                Text("Radio indisponible sur iOS")
                    .font(SQType.caption)
            } else {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index <= level ? AnyShapeStyle(SQColor.success) : AnyShapeStyle(SQColor.fill))
                        .frame(width: 6, height: CGFloat(8 + index * 5))
                }
                if let technology = summary?.technology {
                    Text(technology)
                        .font(SQType.micro)
                }
            }
        }
        .foregroundStyle(SQColor.labelSecondary)
        .accessibilityLabel("Résumé radio serveur")
    }

    private var level: Int {
        guard let rsrp = summary?.rsrp else { return summary?.technology == nil ? -1 : 2 }
        if rsrp > -85 { return 3 }
        if rsrp > -100 { return 2 }
        if rsrp > -112 { return 1 }
        return 0
    }
}

struct SignalSummaryCard: View {
    let summary: SocialSignalSummary?

    var body: some View {
        GlassCard(cornerRadius: SQRadius.xl) {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack {
                    Label("Signal", systemImage: "antenna.radiowaves.left.and.right")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Spacer()
                    SignalBarsView(summary: summary)
                }
                if let summary {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SQSpace.sm + 2) {
                        MetricPill(title: "Download", value: summary.downloadMbps.map { "\(Int($0)) Mbps" } ?? "-", systemImage: "arrow.down")
                        MetricPill(title: "Ping", value: summary.pingMs.map { "\(Int($0)) ms" } ?? "-", systemImage: "timer")
                        MetricPill(title: "Opérateur", value: summary.operator ?? "-", systemImage: "network")
                        MetricPill(title: "Ville", value: summary.city ?? "-", systemImage: "mappin")
                    }
                } else {
                    Text("Métriques radio communautaires")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
    }
}

struct SpeedGaugeView: View {
    let value: Double
    let phase: SpeedtestPhase

    var body: some View {
        ZStack {
            Circle()
                .stroke(SQColor.fill, lineWidth: 24)
            Circle()
                .trim(from: 0, to: min(value / 1000, 1))
                .stroke(SQGradient.speed, style: StrokeStyle(lineWidth: 24, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .sqAnimation(.snappy(duration: 0.32), value: value)
            VStack(spacing: 6) {
                Text("\(Int(value))")
                    .font(SQFont.display(54, .bold))
                    .foregroundStyle(SQColor.label)
                    .contentTransition(.numericText())
                Text("Mbps")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.labelSecondary)
                Text(phase.label)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.brandOrange)
            }
        }
        .frame(width: 240, height: 240)
    }
}

struct SpeedtestResultCard: View {
    let result: SpeedtestRunResult

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                Label("Résultat", systemImage: "iphone")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SQSpace.sm + 2) {
                    MetricPill(title: "DL moyen", value: "\(Int(result.downloadAverageMbps)) Mbps", systemImage: "arrow.down.circle")
                    MetricPill(title: "DL max", value: "\(Int(result.downloadMaxMbps)) Mbps", systemImage: "bolt.circle")
                    MetricPill(title: "UL moyen", value: result.uploadAverageMbps.map { "\(Int($0)) Mbps" } ?? "Non mesuré", systemImage: "arrow.up.circle")
                    MetricPill(title: "UL max", value: result.uploadMaxMbps.map { "\(Int($0)) Mbps" } ?? "Non mesuré", systemImage: "bolt.circle")
                    MetricPill(title: "Ping min", value: result.pingMinMs.map { "\(Int($0)) ms" } ?? "-", systemImage: "timer")
                    MetricPill(title: "Ping moy.", value: result.pingMs.map { "\(Int($0)) ms" } ?? "-", systemImage: "timer.circle")
                    MetricPill(title: "Jitter", value: result.jitterMs.map { "\(Int($0)) ms" } ?? "-", systemImage: "waveform.path.ecg")
                    MetricPill(title: "Réseau", value: result.networkDisplayName, systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
    }
}

struct MapFilterBar: View {
    @Binding var filters: Set<MapDisplayItem.Kind>

    private let values: [(MapDisplayItem.Kind, String, String)] = [
        (.antenna, "Antennes", "antenna.radiowaves.left.and.right"),
        (.speedtest, "Speedtests", "speedometer"),
        (.photo, "Photos", "photo"),
        (.friend, "Amis", "person.2"),
        (.coverage, "Couverture", "dot.radiowaves.left.and.right"),
        (.outage, "Pannes", "exclamationmark.triangle"),
        (.planned, "Prev.", "calendar.badge.clock")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(values, id: \.0.rawValue) { kind, title, icon in
                    let isOn = filters.contains(kind)
                    Button {
                        Haptics.light()
                        if isOn {
                            filters.remove(kind)
                        } else {
                            filters.insert(kind)
                        }
                    } label: {
                        Label(title, systemImage: icon)
                            .font(SQType.micro)
                            .padding(.horizontal, SQSpace.md - 1)
                            .padding(.vertical, SQSpace.sm)
                            .background(isOn ? SQColor.brandOrange.opacity(0.18) : SQColor.fill, in: Capsule())
                            .overlay { Capsule().stroke(isOn ? SQColor.brandOrange.opacity(0.55) : SQColor.separator, lineWidth: 1) }
                            .foregroundStyle(isOn ? SQColor.brandOrange : SQColor.label)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

struct MapItemSheet: View {
    let item: MapDisplayItem
    @EnvironmentObject private var services: AppServices
    @State private var speedtestDetail: SpeedtestDetail?
    @State private var detailError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                SQSheetHandle()
                switch item.kind {
                case .speedtest:
                    speedtestContent
                case .coverage:
                    coverageContent
                default:
                    genericContent
                }
                HStack {
                    GradientButton("Partager", systemImage: "paperplane") {}
                    Button {} label: {
                        Image(systemName: "plus.bubble")
                            .frame(width: 48, height: 48)
                            .background(.thinMaterial, in: Circle())
                            .foregroundStyle(SQColor.label)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .task(id: item.backendId) { await loadSpeedtestDetailIfNeeded() }
        .presentationDetents([.height(360), .medium, .large])
        .presentationBackgroundCompat(.ultraThinMaterial)
    }

    private var speedtestContent: some View {
        let detail = speedtestDetail
        let local = item.details
        let downloadAverage = detail?.averageSpeed ?? detail?.downloadAvg ?? detail?.downloadSpeed ?? local?.downloadMbps
        let downloadMax = detail?.downloadMax ?? detail?.downloadPeakMbps ?? detail?.maxSpeed ?? detail?.downloadSpeed ?? local?.downloadMbps
        let uploadAverage = detail?.uploadAvg ?? detail?.uploadSpeed ?? local?.uploadMbps
        let uploadMax = detail?.uploadMax ?? detail?.uploadPeakMbps ?? detail?.uploadSpeed ?? local?.uploadMbps
        let pingMin = detail?.pingMin ?? detail?.ping ?? local?.pingMs
        let pingAverage = detail?.pingAvg ?? detail?.ping ?? local?.pingMs
        let tech = detail?.networkType ?? local?.tech
        let network = [detail?.connectionType, detail?.networkType].compactMap { $0 }.joined(separator: " / ")
        return VStack(alignment: .leading, spacing: SQSpace.md + 2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(SignalFormatters.speed(downloadAverage))
                        .font(SQType.display)
                        .foregroundStyle(speedColor(downloadAverage))
                    Text("Speed Test")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer()
                TechBadge(text: tech ?? "Speedtest", color: SQColor.brandBlue)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                CardMetricTile(label: "DL moyen", value: SignalFormatters.speed(downloadAverage), highlight: true, accent: speedColor(downloadAverage))
                CardMetricTile(label: "DL max", value: SignalFormatters.speed(downloadMax))
                CardMetricTile(label: "UL moyen", value: SignalFormatters.speed(uploadAverage))
                CardMetricTile(label: "UL max", value: SignalFormatters.speed(uploadMax))
                CardMetricTile(label: "Ping min", value: SignalFormatters.ms(pingMin))
                CardMetricTile(label: "Ping moy.", value: SignalFormatters.ms(pingAverage))
                CardMetricTile(label: "Jitter", value: SignalFormatters.ms(detail?.jitter))
                CardMetricTile(label: "Réseau", value: network.isEmpty ? (tech ?? "—") : network)
            }
            detailRows([
                ("Opérateur", detail?.mobileOperator ?? local?.operatorName),
                ("Réseau", network),
                ("Serveur", detail?.downloadServerName ?? detail?.server),
                ("Streams", detail?.streams.map(String.init)),
                ("Durée", SignalFormatters.duration(detail?.testDuration)),
                ("Appareil", [detail?.deviceType, detail?.deviceModel].compactMap { $0 }.joined(separator: " ")),
                ("Date", formatDate(detail?.timestamp ?? local?.timestamp)),
                ("Position", coordinatesText(lat: detail?.latitude ?? item.coordinate.latitude, lon: detail?.longitude ?? item.coordinate.longitude))
            ])
            if let detailError {
                Label(detailError, systemImage: "exclamationmark.triangle")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.warning)
            }
        }
    }

    private var coverageContent: some View {
        let details = item.details
        let rsrp = details?.rsrp ?? details?.avgRsrp
        return VStack(alignment: .leading, spacing: SQSpace.md + 2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(SignalFormatters.dbm(rsrp))
                        .font(SQType.display)
                        .foregroundStyle(coverageColor(rsrp))
                    HStack(spacing: 6) {
                        Text(details?.clusterCount == nil ? "Couverture" : "Couverture agrégée")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                        if let tech = details?.tech {
                            TechBadge(text: tech, color: TechAccent.color(for: tech))
                        }
                        if let band = details?.band {
                            TechBadge(text: "B\(band)", color: SQColor.brandOrange)
                        }
                    }
                }
                Spacer()
                TechBadge(text: item.kind.rawValue, color: SQColor.brandGreen)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                CardMetricTile(label: "RSRP", value: SignalFormatters.dbm(rsrp), highlight: true, accent: coverageColor(rsrp))
                CardMetricTile(label: "RSRQ", value: SignalFormatters.db(details?.rsrq))
                CardMetricTile(label: "SNR", value: SignalFormatters.db(details?.snr))
                CardMetricTile(label: "Points", value: SignalFormatters.count(details?.clusterCount ?? details?.sampleCount))
                CardMetricTile(label: "Clusters", value: SignalFormatters.count(details?.returnedClusters ?? details?.totalClusters))
                CardMetricTile(label: "Type", value: details?.cellType ?? details?.representation ?? "—")
            }
            detailRows([
                ("Opérateur", details?.operatorName),
                ("Groupe", details?.groupId),
                ("Primaire", details?.isPrimary.map { $0 ? "Oui" : "Non" }),
                ("Date", formatDate(details?.timestamp)),
                ("Position", coordinatesText(lat: item.coordinate.latitude, lon: item.coordinate.longitude)),
                ("Source", details?.note ?? "Backend SignalQuest")
            ])
        }
    }

    private var genericContent: some View {
        VStack(alignment: .leading, spacing: SQSpace.lg) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                    Text(item.subtitle)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer()
                TechBadge(text: item.kind.rawValue, color: SQColor.brandGreen)
            }
            if let metric = item.metric {
                MetricPill(title: "Donnée", value: metric, systemImage: "waveform.path.ecg")
            }
        }
    }

    private func loadSpeedtestDetailIfNeeded() async {
        guard item.kind == .speedtest, let id = item.backendId, !id.hasPrefix("speed-cluster") else { return }
        do {
            speedtestDetail = try await services.speedtest.details(id: id)
            detailError = nil
        } catch {
            detailError = "Détail API indisponible: \(error.localizedDescription)"
        }
    }

    private func detailRows(_ rows: [(String, String?)]) -> some View {
        let visibleRows = rows.filter { value in
            guard let text = value.1?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty && text != "—"
        }
        return VStack(spacing: SQSpace.sm) {
            ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0)
                        .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.labelSecondary)
                    Spacer(minLength: 12)
                    Text(row.1 ?? "—")
                        .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, SQSpace.sm)
                .padding(.horizontal, SQSpace.sm + 2)
                .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
        }
    }

    private func formatDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func coordinatesText(lat: Double?, lon: Double?) -> String? {
        guard let lat, let lon else { return nil }
        return String(format: "%.5f, %.5f", lat, lon)
    }

    private func speedColor(_ speed: Double?) -> Color {
        guard let speed else { return SQColor.brandBlue }
        switch speed {
        case 1000...: return SQColor.success
        case 500..<1000: return Color(red: 0.13, green: 0.77, blue: 0.37)
        case 200..<500: return Color(red: 0.34, green: 0.78, blue: 0.27)
        case 100..<200: return SQColor.warning
        case 40..<100: return SQColor.brandOrange
        default: return SQColor.danger
        }
    }

    private func coverageColor(_ rsrp: Double?) -> Color {
        guard let rsrp else { return SQColor.brandBlue }
        switch rsrp {
        case (-85)...: return SQColor.success
        case -95..<(-85): return Color(red: 0.52, green: 0.80, blue: 0.09)
        case -105..<(-95): return SQColor.warning
        case -115..<(-105): return SQColor.brandOrange
        default: return SQColor.danger
        }
    }
}

struct PhotoTile: View {
    let photo: Photo

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: photo.thumbnailUrl ?? photo.imageUrl, maxDimension: 360, contentMode: .fill) {
                Rectangle().fill(SQColor.fill)
            }
            .frame(height: 172)
            .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))

            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(photo.displayCaption)
                    .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
                    .lineLimit(2)
                Text("\(photo.likeCount ?? photo.likes ?? 0) likes")
                    .font(SQType.micro)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(SQSpace.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
    }
}

struct LeaderboardPodium: View {
    let entries: [LeaderboardEntry]

    var body: some View {
        HStack(alignment: .bottom, spacing: SQSpace.sm + 2) {
            ForEach(podiumEntries, id: \.rank) { entry in
                VStack(spacing: SQSpace.sm) {
                    SQAvatar(url: entry.user.avatarUrl, name: entry.user.displayName, size: entry.rank == 1 ? 64 : 52)
                    Text(entry.user.displayName)
                        .font(SQFont.archivo(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    Text("\(Int(entry.value)) \(entry.unit)")
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                    RoundedRectangle(cornerRadius: SQRadius.md)
                        .fill(entry.rank == 1
                              ? AnyShapeStyle(SQGradient.signal)
                              : AnyShapeStyle(LinearGradient(colors: [SQColor.surface, SQColor.surfaceMuted], startPoint: .top, endPoint: .bottom)))
                        .frame(height: entry.rank == 1 ? 88 : 64)
                        .overlay(
                            Text("#\(entry.rank)")
                                .font(SQFont.archivo(17, .bold, relativeTo: .headline))
                                .foregroundStyle(entry.rank == 1 ? .white : SQColor.label)
                        )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var podiumEntries: [LeaderboardEntry] {
        let top = Array(entries.prefix(3))
        return top.sorted { lhs, rhs in
            let order = [2: 0, 1: 1, 3: 2]
            return (order[lhs.rank] ?? lhs.rank) < (order[rhs.rank] ?? rhs.rank)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: SQSpace.md) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(SQGradient.signal)
            Text(title)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text(message)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(SQSpace.xxl + 2)
    }
}

struct ErrorStateView: View {
    let title: String
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        GlassCard {
            VStack(spacing: SQSpace.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(SQColor.warning)
                Text(title)
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Text(message)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                if let retry {
                    Button("Réessayer", action: retry)
                        .buttonStyle(.borderedProminent)
                        .tint(SQColor.brandOrange)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Squelette de chargement du feed : imite la structure réelle d'une
/// `FeedItemCard` (avatar + auteur, média, texte, barre d'actions) pour éviter
/// le saut de mise en page à l'arrivée des données. À combiner avec `sqShimmer()`.
struct LoadingSkeleton: View {
    var count: Int = 3
    var showsMedia: Bool = true

    var body: some View {
        VStack(spacing: SQSpace.md + 2) {
            ForEach(0..<count, id: \.self) { _ in
                card
            }
        }
    }

    private var block: some View { SkeletonBlock() }

    private var card: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.sm) {
                Circle().fill(SQColor.fill).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 7) {
                    SkeletonBlock(width: 130, height: 12)
                    SkeletonBlock(width: 84, height: 10)
                }
                Spacer(minLength: 0)
            }
            if showsMedia {
                SkeletonBlock(height: 150, radius: SQRadius.lg)
            }
            SkeletonBlock(height: 11)
            SkeletonBlock(width: 220, height: 11)
            HStack(spacing: SQSpace.lg) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBlock(width: 46, height: 14, radius: SQRadius.sm)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
    }
}

/// Bloc gris arrondi de base d'un squelette (largeur pleine par défaut).
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = SQRadius.sm

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(SQColor.fill)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Squelette d'une liste de conversations : avatar + titre + aperçu, calqué sur
/// `conversationRow`. À combiner avec `sqShimmer()`.
struct ConversationListSkeleton: View {
    var count: Int = 7

    var body: some View {
        VStack(spacing: SQSpace.lg) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: SQSpace.md) {
                    Circle().fill(SQColor.fill).frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(width: 150, height: 13)
                        SkeletonBlock(width: 220, height: 11)
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 34, height: 10)
                }
            }
        }
    }
}

// MARK: - New primitives

/// Drag handle used at the top of every custom sheet.
struct SQSheetHandle: View {
    var body: some View {
        Capsule()
            .fill(SQColor.labelTertiary)
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xs)
    }
}

/// Compact rounded search field. Replaces ad-hoc TextField + magnifying-glass rows.
struct SQSearchField: View {
    @Binding var text: String
    var placeholder: String = "Rechercher"
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SQColor.labelSecondary)
            TextField(placeholder, text: $text)
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
                .foregroundStyle(SQColor.label)
            if !text.isEmpty {
                Button {
                    text = ""
                    Haptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SQColor.labelTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .frame(height: 38)
        .background(SQColor.fill, in: Capsule())
    }
}

/// Pill segmented filter used in Messages, Friends, Photos, Leaderboards, etc.
struct SQSegmentedFilter<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String, icon: String?)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let isSelected = option.value == selection
                    Button {
                        Haptics.selection()
                        selection = option.value
                    } label: {
                        HStack(spacing: SQSpace.xs + 2) {
                            if let icon = option.icon {
                                Image(systemName: icon)
                            }
                            Text(option.label)
                        }
                        .font(SQFont.archivo(14, .semibold, relativeTo: .subheadline))
                        .padding(.horizontal, SQSpace.md + 2)
                        .padding(.vertical, SQSpace.sm)
                        .background(isSelected ? AnyShapeStyle(SQColor.brandOrange) : AnyShapeStyle(SQColor.fill), in: Capsule())
                        .foregroundStyle(isSelected ? .white : SQColor.label)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

/// Compact "icon + value + optional label" chip for inline stats.
struct SQChipMetric: View {
    let value: String
    var label: String? = nil
    var systemImage: String? = nil

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: SQSpace.xs + 2) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(SQColor.brandOrange)
                }
                Text(value)
                    .font(SQFont.archivo(17, .bold, relativeTo: .headline))
                    .foregroundStyle(SQColor.label)
            }
            if let label {
                Text(label)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Lightweight section header — title only, optional trailing action.
struct SQSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
            Spacer()
            trailing()
        }
    }
}

/// Full-bleed media wrapper with optional bottom scrim for caption overlays.
struct SQFullBleedMedia<Content: View>: View {
    let cornerRadius: CGFloat
    let scrim: Bool
    @ViewBuilder var content: () -> Content

    init(cornerRadius: CGFloat = 0, scrim: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.scrim = scrim
        self.content = content
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .bottom) {
            content()
            if scrim {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
    }
}

/// Floating action button (FAB). Used for composer/story triggers.
struct SQFAB: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(SQGradient.signal, in: Circle())
                .shadow(color: .black.opacity(0.20), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private extension SpeedtestPhase {
    var label: String {
        switch self {
        case .idle:
            return "Prêt"
        case .ping:
            return "Latence"
        case .download:
            return "Download"
        case .upload:
            return "Upload"
        case .saving:
            return "Sync"
        case .finished:
            return "Terminé"
        case .failed:
            return "Erreur"
        }
    }
}
