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
    /// Verdict de qualité réseau (opérateur SIM, données communautaires) qui pilote
    /// la pastille d'état. `nil` = pas encore chargé ou zone sans mesures.
    @State private var networkQuality: NearbyNetworkQuality?
    /// Sheet expliquant la source et le calcul du verdict réseau.
    @State private var showQualityDetail = false
    /// Comparaison des opérateurs au tap sur une tuile du pouls (métrique choisie).
    @State private var comparisonMetric: NearbyOperatorMetric = .download
    @State private var showOperatorComparison = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    /// Rayon commun de la section « Autour de toi » (mesures, pouls, comparaison).
    private static let nearbyRadiusMeters = 1000
    /// Demi-fenêtre englobant le cercle de 1 km (le filtrage distance affine ensuite).
    private static let nearbyHalfSpanLat = 0.011
    private static let nearbyHalfSpanLng = 0.016

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
        // Directement sur le ScrollView : signalQuestBackground() enveloppe
        // dans un ZStack, et onScrollGeometryChange n'observe que la vue à
        // laquelle il est appliqué.
        .sqDockAutoMinimize()
        .toolbar(.hidden, for: .navigationBar)
        .signalQuestBackground()
        .task { await refresh() }
        .refreshable { await refresh(forceFresh: true) }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        // Revenir sur l'onglet Accueil (après un test, une visite carte…) rafraîchit
        // les données de zone sans attendre un pull manuel.
        .onChangeCompat(of: router.selectedTab) { _, tab in
            if tab == .home { Task { await refreshNearby(forceFresh: false) } }
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
        Group {
            if networkQuality != nil {
                Button {
                    Haptics.selection()
                    showQualityDetail = true
                } label: { networkSummaryCard }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel("\(networkTitle). \(networkSubtitle)")
                .accessibilityHint("Comprendre d'où vient ce verdict")
            } else {
                networkSummaryCard
                    .accessibilityElement(children: .combine)
            }
        }
        .sheet(isPresented: $showQualityDetail) {
            if let quality = networkQuality {
                NearbyNetworkQualityDetailSheet(quality: quality)
            }
        }
    }

    private var networkSummaryCard: some View {
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
            // Indice discret que la carte est cliquable (verdict explicable).
            if networkQuality != nil {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SQColor.labelTertiary)
            }
        }
        .padding(.vertical, SQSpace.lg + 2)
        .padding(.horizontal, SQSpace.xl)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    private var isOnline: Bool { services.networkPath.isOnline }

    // Priorité du verdict affiché : hors-ligne → mode données réduites (contrainte
    // système réelle) → qualité communautaire de l'opérateur SIM → état neutre en
    // attendant les données. On n'annonce plus « au top » par défaut : le libellé
    // vert ne s'affiche que si les mesures de la zone le confirment.

    private var networkTitle: String {
        guard isOnline else { return "Hors connexion" }
        if networkStatus.isConstrained { return "Réseau limité" }
        if let quality = networkQuality { return quality.level.homeNetworkTitle }
        return "Connecté"
    }

    private var networkSubtitle: String {
        guard isOnline else { return "Vérifie ta connexion" }
        // Verdict dispo (hors mode données réduites) : opérateur SIM + le débit
        // médian communautaire. Le détail RSRP vit dans la sheet explicative
        // (peu lisible en un coup d'œil sur la pastille).
        if !networkStatus.isConstrained, let quality = networkQuality {
            if let mbps = quality.medianDownloadMbps {
                return "\(quality.operatorLabel) · \(mbps) Mb/s"
            }
            return "\(quality.operatorLabel) · \(quality.sampleCount) mesures"
        }
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
        if networkStatus.isConstrained { return "Limité" }
        if let quality = networkQuality { return quality.level.title }
        return "En ligne"
    }

    private var networkTint: Color {
        guard isOnline else { return SQColor.danger }
        if networkStatus.isConstrained { return SQColor.warning }
        if let quality = networkQuality { return quality.level.swiftUIColor }
        return SQColor.labelSecondary
    }

    private var networkTintSoft: Color {
        guard isOnline else { return SQColor.dangerSoft }
        if networkStatus.isConstrained { return SQColor.warningSoft }
        if let quality = networkQuality { return quality.level.swiftUIColor.opacity(0.14) }
        return SQColor.surfaceMuted
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
    /// Tappable vers la comparaison des opérateurs dès qu'au moins deux sont mesurés.
    private func pulseRow(_ pulse: NetworkPulse) -> some View {
        HStack(spacing: SQSpace.sm + 2) {
            if let rsrp = pulse.avgRsrpDbm {
                pulseTileButton(value: "\(rsrp)", unit: "dBm moyen", metric: .signal)
            }
            if let median = pulse.medianDownloadMbps {
                pulseTileButton(value: "\(median)", unit: "Mb/s médian", metric: .download)
            }
            if let best = pulse.bestOperator, !best.isEmpty {
                pulseTileButton(value: best, unit: "meilleur op.", metric: .download)
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showOperatorComparison) {
            if let location = userLocation {
                NearbyOperatorComparisonSheet(
                    metric: comparisonMetric,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    radiusMeters: Self.nearbyRadiusMeters
                )
                .environmentObject(services)
            }
        }
    }

    /// Tuile du pouls, cliquable vers la comparaison des opérateurs sur sa métrique
    /// (dBm → signal, Mb/s & meilleur op. → débit).
    private func pulseTileButton(value: String, unit: String, metric: NearbyOperatorMetric) -> some View {
        Button {
            guard userLocation != nil else { return }
            Haptics.selection()
            comparisonMetric = metric
            showOperatorComparison = true
        } label: {
            pulseTile(value: value, unit: unit)
        }
        .buttonStyle(.plain)
        .disabled(userLocation == nil)
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

    private func refresh(forceFresh: Bool = false) async {
        services.networkPath.refreshNow()
        networkStatus = services.networkPath.status
        latestMeasurement = await services.speedtest.history().first
        await refreshNearby(forceFresh: forceFresh)
    }

    /// Charge le pouls réseau, les dernières mesures communautaires et le verdict
    /// de qualité (opérateur SIM) autour de la position. Best-effort : sans
    /// position ou sans données, la section reste masquée et la pastille retombe
    /// sur un état neutre (jamais d'erreur affichée sur l'Accueil).
    /// `forceFresh` (pull-to-refresh) contourne le cache de tuiles.
    private func refreshNearby(forceFresh: Bool) async {
        guard let location = await services.location.currentLocation(timeoutSeconds: 6) else { return }
        userLocation = location
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        // Pull-to-refresh : tuiles fraîches forcées (bypass du cache disque d'1 h) ;
        // sinon on tolère jusqu'à 90 s de cache pour ne pas marteler l'API.
        let maxAge: TimeInterval = forceFresh ? 0 : 90
        let isCellular = services.networkPath.status.connection == .cellular
        let simMnc = services.networkPath.simPLMN().mnc

        // Pouls recadré sur le même rayon que le reste (1 km), tous opérateurs.
        async let pulseTask: NetworkPulse? = try? services.feed.networkPulse(
            latitude: lat, longitude: lng, radiusMeters: Self.nearbyRadiusMeters
        )
        // Liste = les plus RÉCENTS (le snapshot social porte des timestamps fiables,
        // contrairement aux tuiles carto). Comparaison = tuiles (volume sur 30 j).
        async let recentTask: [AndroidSpeedtestMarker] = recentNearbySpeedtests(latitude: lat, longitude: lng)
        async let tilesTask: [AndroidSpeedtestMarker] = nearbySpeedtests(latitude: lat, longitude: lng, around: location, maxAge: maxAge)
        async let qualityTask: NearbyNetworkQuality? = services.nearbyQuality.verdict(
            latitude: lat, longitude: lng, isCellular: isCellular, simMnc: simMnc, maxAge: maxAge
        )

        pulse = await pulseTask
        let tiles = await tilesTask
        let recent = await recentTask
        // Liste = les plus RÉCENTS (endpoint dédié) ; repli sur les plus proches
        // (tuiles) si l'endpoint n'a rien renvoyé (ou n'est pas encore déployé).
        if !recent.isEmpty {
            nearbyMeasures = recent
        } else {
            let center = location
            nearbyMeasures = tiles
                .map { ($0, center.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng))) }
                .sorted { $0.1 < $1.1 }
                .prefix(3)
                .map { $0.0 }
        }
        networkQuality = await qualityTask
    }

    /// Tous les speedtests communautaires à ≤ 1 km RÉELS de la position (la maille
    /// des tuiles déborde largement, d'où le filtrage par distance).
    private func nearbySpeedtests(latitude: Double, longitude: Double, around location: CLLocation, maxAge: TimeInterval) async -> [AndroidSpeedtestMarker] {
        let market = await services.markets.marketForLocation(latitude: latitude, longitude: longitude)?.code ?? "FR"
        let bounds = MapBounds(
            north: latitude + Self.nearbyHalfSpanLat,
            south: latitude - Self.nearbyHalfSpanLat,
            east: longitude + Self.nearbyHalfSpanLng,
            west: longitude - Self.nearbyHalfSpanLng
        )
        guard let tiles = try? await services.map.speedtestTiles(
            bounds: bounds, zoom: 14, market: market, operatorName: "ALL", days: 30, bands: [], maxAge: maxAge
        ) else { return [] }
        let center = location
        let radius = Double(Self.nearbyRadiusMeters)
        return tiles
            .flatMap(\.markers)
            .filter { center.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng)) <= radius }
    }

    /// Les 3 speedtests communautaires les PLUS RÉCENTS à ≤ 1 km, via l'endpoint
    /// dédié `/api/social/nearby-speedtests` (SELECT trié par date côté serveur —
    /// les tuiles carto n'ont pas de date fiable, le snapshot social trop peu de points).
    private func recentNearbySpeedtests(latitude: Double, longitude: Double) async -> [AndroidSpeedtestMarker] {
        let recent = (try? await services.feed.nearbyRecentSpeedtests(
            latitude: latitude, longitude: longitude, radiusMeters: Self.nearbyRadiusMeters, limit: 3
        )) ?? []
        return Array(recent.prefix(3))
    }
}

/// Ombre de tuile : accent sous la tuile Tester, carte sinon.
private struct HomeTileShadow: ViewModifier {
    let accented: Bool
    func body(content: Content) -> some View {
        if accented { content.sqShadowAccent() } else { content.sqShadowCard() }
    }
}
