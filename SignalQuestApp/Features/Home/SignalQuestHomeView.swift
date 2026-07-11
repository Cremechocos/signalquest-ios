import SwiftUI
import CoreLocation

/// Accueil « Crème & Terre cuite » : salutation, état réseau en direct,
/// grille 2×2 d'actions (Tester en tuile accent), données communautaires
/// AUTOUR DE LA POSITION (pouls + dernières mesures proches) et dernière
/// mesure locale. Le feed social reste dans Communauté.
struct SignalQuestHomeView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    let user: AuthUser

    @State private var latestMeasurement: SpeedtestRunResult?
    @State private var networkStatus: NetworkPathStatus = .unknown
    /// Données communautaires autour de la position (nil/vides = section masquée).
    @State private var pulse: NetworkPulse?
    @State private var nearbyMeasures: [AndroidSpeedtestMarker] = []
    @State private var userLocation: CLLocation?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg + 2) {
                header
                networkSummary
                actionsGrid
                nearbySection
                latestMeasurementSection
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
        }
        .toolbar(.hidden, for: .navigationBar)
        .signalQuestBackground()
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private var firstName: String {
        user.name?.split(separator: " ").first.map(String.init) ?? "à toi"
    }

    // MARK: Header — avatar + salutation + cloche

    private var header: some View {
        HStack(spacing: SQSpace.md + 2) {
            SQAvatar(url: user.avatarUrl, name: user.name ?? "S", size: 54)
            VStack(alignment: .leading, spacing: 0) {
                Text("Bonjour,")
                    .font(SQFont.body(14))
                    .foregroundStyle(SQColor.labelSecondary)
                Text(firstName)
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
            }
            Spacer()
            NavigationLink {
                NotificationsCenterView(service: services.notifications)
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .background(SQColor.surface, in: Circle())
                    .sqShadowSoft()
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Notifications")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Carte état réseau

    private var networkSummary: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: networkStatus.connection == .cellular
                  ? "dot.radiowaves.left.and.right"
                  : "wifi")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(networkTint)
                .frame(width: 46, height: 46)
                .background(networkTintSoft, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(networkTitle)
                    .font(SQFont.body(16, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(networkSubtitle)
                    .font(SQFont.body(13.5))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SQSpace.sm)
            Text(networkBadge)
                .font(SQFont.body(12, .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(networkTint)
                .background(networkTintSoft, in: Capsule(style: .continuous))
        }
        .padding(.vertical, SQSpace.lg + 2)
        .padding(.horizontal, SQSpace.xl)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
        .accessibilityElement(children: .combine)
    }

    private var isOnline: Bool { services.networkPath.isOnline }

    private var networkTitle: String {
        guard isOnline else { return "Hors connexion" }
        return networkStatus.isConstrained ? "Réseau limité" : "Réseau au top"
    }

    private var networkSubtitle: String {
        guard isOnline else { return "Vérifie ta connexion" }
        switch networkStatus.connection {
        case .cellular:
            let tech = networkStatus.cellularTechnology?.displayName
            return ["Cellulaire", tech, networkStatus.operatorName]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        case .other: return "Connexion inconnue"
        }
    }

    private var networkBadge: String {
        guard isOnline else { return "Coupé" }
        return networkStatus.isConstrained ? "Limité" : "Stable"
    }

    private var networkTint: Color {
        guard isOnline else { return SQColor.danger }
        return networkStatus.isConstrained ? SQColor.warning : SQColor.success
    }

    private var networkTintSoft: Color {
        guard isOnline else { return SQColor.dangerSoft }
        return networkStatus.isConstrained ? SQColor.warningSoft : SQColor.successSoft
    }

    // MARK: Grille 2×2 d'actions

    private var actionsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 14) {
            actionTile(
                title: "Tester",
                subtitle: "Débit & latence en 30 s",
                systemImage: "speedometer",
                accented: true
            ) { router.selectedTab = .speed }

            actionTile(
                title: "Carte",
                subtitle: "Antennes & couverture",
                systemImage: "map"
            ) { router.selectedTab = .map }

            actionTile(
                title: "Communauté",
                subtitle: "Fil, stories, entraide",
                systemImage: "person.2"
            ) { router.selectedTab = .community }

            actionTile(
                title: "Messages",
                subtitle: messagesSubtitle,
                systemImage: "bubble.left.and.bubble.right",
                badgeCount: services.unreadConversations
            ) { router.route(toConversation: nil) }
        }
    }

    private var messagesSubtitle: String {
        let unread = services.unreadConversations
        if unread <= 0 { return "Conversations chiffrées" }
        return unread == 1 ? "1 non lu" : "\(unread) non lus"
    }

    private func actionTile(
        title: String,
        subtitle: String,
        systemImage: String,
        accented: Bool = false,
        badgeCount: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(accented ? SQColor.onAccent : SQColor.brandRed)
                        .frame(width: 42, height: 42)
                        .background(
                            accented ? AnyShapeStyle(SQColor.onAccent.opacity(0.18)) : AnyShapeStyle(SQColor.accentSoft),
                            in: Circle()
                        )
                    if badgeCount > 0 {
                        Text("\(min(badgeCount, 99))")
                            .font(SQFont.bodyFixed(11, .bold))
                            .foregroundStyle(SQColor.onAccent)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(SQColor.brandRed, in: Circle())
                            .offset(x: 6, y: -4)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SQFont.display(16.5, .semibold))
                        .foregroundStyle(accented ? SQColor.onAccent : SQColor.label)
                    Text(subtitle)
                        .font(SQFont.body(12.5))
                        .foregroundStyle(accented ? SQColor.onAccent.opacity(0.75) : SQColor.labelSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.lg + 2)
            .background(
                accented ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
            )
            .modifier(HomeTileShadow(accented: accented))
            .contentShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("\(title). \(subtitle)")
    }

    // MARK: Autour de toi — données communautaires proches

    @ViewBuilder
    private var nearbySection: some View {
        if pulse?.hasData == true || !nearbyMeasures.isEmpty {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Autour de toi")
                        .font(SQFont.display(20, .bold))
                        .foregroundStyle(SQColor.label)
                    Spacer()
                    if let count = pulse?.measurementsCount, count > 0 {
                        Text("\(count) mesures")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }

                VStack(spacing: SQSpace.md) {
                    if let pulse, pulse.hasData {
                        pulseRow(pulse)
                    }
                    if !nearbyMeasures.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(nearbyMeasures.enumerated()), id: \.element.id) { index, measure in
                                nearbyMeasureRow(measure)
                                if index < nearbyMeasures.count - 1 {
                                    Divider()
                                        .overlay(SQColor.separator)
                                        .padding(.leading, 52)
                                }
                            }
                        }
                    }
                }
                .padding(SQSpace.lg)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .sqShadowCard()
            }
        }
    }

    /// Agrégat de zone (pouls réseau) : 3 mini-tuiles RSRP / débit médian / meilleur op.
    private func pulseRow(_ pulse: NetworkPulse) -> some View {
        HStack(spacing: SQSpace.sm + 2) {
            if let rsrp = pulse.avgRsrpDbm {
                pulseTile(value: "\(rsrp)", unit: "dBm moyen")
            }
            if let median = pulse.medianDownloadMbps {
                pulseTile(value: "\(median)", unit: "Mb/s médian")
            }
            if let best = pulse.bestOperator, !best.isEmpty {
                pulseTile(value: best, unit: "meilleur op.")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pouls réseau autour de toi")
    }

    private func pulseTile(value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(SQFont.display(17, .bold))
                .foregroundStyle(SQColor.brandRed)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(unit)
                .font(SQFont.body(11))
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.sm + 2)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// Une mesure communautaire proche : techno teintée, débit, contexte, distance.
    private func nearbyMeasureRow(_ measure: AndroidSpeedtestMarker) -> some View {
        Button {
            Haptics.selection()
            router.selectedTab = .map
        } label: {
            HStack(spacing: SQSpace.md) {
                ZStack {
                    Circle().fill(TechAccent.color(for: measure.tech))
                    if let label = Self.techShortLabel(measure.tech) {
                        Text(label)
                            .font(SQFont.bodyFixed(12, .bold))
                            .foregroundStyle(SQColor.onAccent)
                    } else {
                        // Techno inconnue (ex. « CELLULAR » brut) : icône antenne.
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SQColor.onAccent)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("\(Int(measure.downloadMbps)) Mbps")
                            .font(SQFont.body(15, .semibold))
                            .foregroundStyle(SQColor.label)
                        if let ping = measure.pingMs {
                            Text("· \(Int(ping)) ms")
                                .font(SQFont.body(13))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Text(nearbyContext(for: measure))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
            }
            .padding(.vertical, SQSpace.sm + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mesure communautaire : \(Int(measure.downloadMbps)) mégabits. \(nearbyContext(for: measure)). Ouvre la carte.")
    }

    /// Libellé court de techno pour la pastille (« 5G », « 4G », « Wi-Fi »)
    /// ou nil si la valeur backend est trop brute pour être affichée.
    private static func techShortLabel(_ tech: String?) -> String? {
        guard let tech, !tech.isEmpty else { return nil }
        let upper = tech.uppercased()
        if upper.contains("5G") || upper.contains("NR") { return "5G" }
        if upper.contains("4G") || upper.contains("LTE") { return "4G" }
        if upper.contains("3G") || upper.contains("UMTS") { return "3G" }
        if upper.contains("2G") || upper.contains("GSM") { return "2G" }
        if upper.contains("WIFI") || upper.contains("WI-FI") { return "Wi-Fi" }
        return nil
    }

    /// « Orange · il y a 2 h · à 450 m » — ce qui est connu, dans cet ordre.
    private func nearbyContext(for measure: AndroidSpeedtestMarker) -> String {
        var parts: [String] = []
        if let op = measure.`operator`, !op.isEmpty { parts.append(op) }
        if let date = measure.timestamp {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        if let location = userLocation {
            let distance = location.distance(from: CLLocation(latitude: measure.lat, longitude: measure.lng))
            parts.append("à \(SignalFormatters.meters(distance))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Dernière mesure

    @ViewBuilder
    private var latestMeasurementSection: some View {
        if let measurement = latestMeasurement {
            Button {
                Haptics.selection()
                router.selectedTab = .speed
            } label: {
                HStack(spacing: SQSpace.md) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dernière mesure · \(measurement.createdAt.formatted(date: .omitted, time: .shortened))")
                            .font(SQFont.body(13.5))
                            .foregroundStyle(SQColor.labelSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(measurement.downloadAverageMbps.formatted(.number.precision(.fractionLength(0))))
                                .font(SQFont.display(30, .bold))
                                .foregroundStyle(SQColor.label)
                            Text("Mbps")
                                .font(SQFont.body(15, .medium))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Spacer()
                    if let ping = measurement.pingMinMs ?? measurement.pingMs {
                        Text("\(ping.formatted(.number.precision(.fractionLength(0)))) ms")
                            .font(SQFont.body(13, .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(SQColor.label)
                            .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
                    }
                    if let tech = measurementTech(measurement) {
                        Text(tech)
                            .font(SQFont.body(13, .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(SQColor.onAccent)
                            .background(SQColor.brandRed, in: Capsule(style: .continuous))
                    }
                }
                .padding(.vertical, SQSpace.lg + 2)
                .padding(.horizontal, SQSpace.xl)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .sqShadowCard()
                .contentShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Dernière mesure : \(Int(measurement.downloadAverageMbps)) mégabits par seconde. Ouvre le Speedtest.")
        } else {
            EmptyStateView(
                title: "Aucune mesure locale",
                message: "Lance un premier test pour créer ton repère.",
                systemImage: "waveform.path.ecg"
            )
        }
    }

    /// Capsule techno de la dernière mesure : « 5G » / « 4G » / « Wi-Fi ».
    private func measurementTech(_ measurement: SpeedtestRunResult) -> String? {
        if let tech = measurement.cellularTechnology?.displayName {
            // « 5G NSA/SA » → « 5G » pour la capsule compacte.
            return tech.hasPrefix("5G") ? "5G" : tech
        }
        switch measurement.connectionType {
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        default: return nil
        }
    }

    private func refresh() async {
        services.networkPath.refreshNow()
        networkStatus = services.networkPath.status
        latestMeasurement = await services.speedtest.history().first
        await refreshNearby()
    }

    /// Charge le pouls réseau + les dernières mesures communautaires autour de
    /// la position. Best-effort : sans position ou sans données, la section
    /// reste simplement masquée (jamais d'erreur affichée sur l'Accueil).
    private func refreshNearby() async {
        guard let location = await services.location.currentLocation(timeoutSeconds: 6) else { return }
        userLocation = location
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude

        async let pulseTask: NetworkPulse? = try? services.feed.networkPulse(latitude: lat, longitude: lng)
        async let markersTask: [AndroidSpeedtestMarker] = nearbyMarkers(latitude: lat, longitude: lng, around: location)

        pulse = await pulseTask
        nearbyMeasures = await markersTask
    }

    /// Mesures communautaires dans un rayon ~3 km, les plus récentes d'abord.
    private func nearbyMarkers(latitude: Double, longitude: Double, around location: CLLocation) async -> [AndroidSpeedtestMarker] {
        let market = await services.markets.marketForLocation(latitude: latitude, longitude: longitude)?.code ?? "FR"
        // ±0,03° ≈ 3,3 km N-S ; l'e-o varie avec la latitude mais reste du même ordre.
        let bounds = MapBounds(
            north: latitude + 0.03,
            south: latitude - 0.03,
            east: longitude + 0.045,
            west: longitude - 0.045
        )
        guard let tiles = try? await services.map.speedtestTiles(
            bounds: bounds, zoom: 13, market: market, operatorName: "ALL", days: 30, bands: []
        ) else { return [] }

        return tiles
            .flatMap(\.markers)
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            .prefix(3)
            .map { $0 }
    }
}

/// Ombre de tuile : accent sous la tuile Tester, carte sinon.
private struct HomeTileShadow: ViewModifier {
    let accented: Bool
    func body(content: Content) -> some View {
        if accented { content.sqShadowAccent() } else { content.sqShadowCard() }
    }
}
