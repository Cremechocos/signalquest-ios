import SwiftUI

/// Accueil « Crème & Terre cuite » : salutation, état réseau en direct,
/// grille 2×2 d'actions (Tester en tuile accent) et dernière mesure.
/// Le feed social reste dans Communauté.
struct SignalQuestHomeView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    let user: AuthUser

    @State private var latestMeasurement: SpeedtestRunResult?
    @State private var networkStatus: NetworkPathStatus = .unknown

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
    }
}

/// Ombre de tuile : accent sous la tuile Tester, carte sinon.
private struct HomeTileShadow: ViewModifier {
    let accented: Bool
    func body(content: Content) -> some View {
        if accented { content.sqShadowAccent() } else { content.sqShadowCard() }
    }
}
