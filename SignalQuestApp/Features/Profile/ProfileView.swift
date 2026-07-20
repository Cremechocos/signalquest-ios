import SwiftUI

/// Enveloppe `Identifiable` autour d'un identifiant de signalement, pour piloter
/// une `.sheet(item:)` sur deep link (l'`id` `String` seul n'est pas `Identifiable`).
struct AntennaReportDeepLink: Identifiable {
    let id: String
}

/// Profil « Crème & Terre cuite » : en-tête centré (avatar 88 + ombre accent),
/// carte stats 4 cellules, carte progression (niveau/points), menu en carte
/// unique rayon 22 et déconnexion en capsule danger. Header custom scrollable
/// (pas de titre nav système).
struct ProfileView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var router: AppRouter
    let user: AuthUser
    @State private var showEdit = false
    @State private var stats: UserStats?
    @State private var statsError: String?
    @State private var progression: GamificationProfile?
    /// Fil de signalement à ouvrir en sheet (tap sur une notification
    /// `antenna_report_reply`), résolu depuis `router.openAntennaReportId`.
    @State private var deepLinkReport: AntennaReportDeepLink?

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.lg + 2) {
                profileHeader
                    .sqFadeUp()
                if let stats {
                    statsCard(stats)
                        .sqFadeUp()
                } else if let statsError {
                    ErrorStateView(title: "Stats indisponibles", message: statsError)
                        .sqFadeUp()
                }

                if let progression, let level = progression.level,
                   let goal = progression.xpToNextLevel, goal > 0 {
                    progressionCard(level: level, points: progression.points ?? 0, goal: goal)
                        .sqFadeUp()
                }

                GradientButton("Éditer le profil", systemImage: "person.crop.circle", style: .secondary) {
                    showEdit = true
                }
                .sqFadeUp()

                // Pas de sqFadeUp sur la carte menu : plus haute que le viewport,
                // la scrollTransition ne l'amène jamais à l'identité → elle
                // resterait estompée en permanence tant qu'on ne scrolle pas.
                menuCard

                GradientButton("Déconnexion", systemImage: "rectangle.portrait.and.arrow.right", style: .destructive) {
                    Task { await session.logout() }
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        // Directement sur le ScrollView (avant le ZStack de signalQuestBackground).
        .sqDockAutoMinimize()
        .toolbar(.hidden, for: .navigationBar)
        .signalQuestBackground()
        .sheet(isPresented: $showEdit) {
            EditProfileView(user: user)
        }
        // Deep link « antenna_report_reply » : ouvre DIRECTEMENT le fil du bon
        // signalement, en sheet (l'onglet Profil héberge « Mes signalements »).
        .sheet(item: $deepLinkReport) { link in
            NavigationStack {
                AntennaReportThreadView(
                    service: services.antennaReports,
                    reportId: link.id,
                    onClose: { deepLinkReport = nil }
                )
            }
        }
        .onAppear { consumeAntennaReportDeepLink() }
        .onChangeCompat(of: router.openAntennaReportId) { _, _ in consumeAntennaReportDeepLink() }
        .task { await loadStats() }
        .refreshable { await loadStats() }
    }

    /// Consomme l'intention de deep link posée par le routeur (idempotent : on
    /// remet la valeur à `nil` une fois lue, comme `openSiteFromRouterIfNeeded`).
    private func consumeAntennaReportDeepLink() {
        guard let id = router.openAntennaReportId else { return }
        router.openAntennaReportId = nil
        deepLinkReport = AntennaReportDeepLink(id: id)
    }

    // MARK: - En-tête

    private var profileHeader: some View {
        VStack(spacing: SQSpace.sm + 2) {
            SQAvatar(url: user.avatarUrl, name: user.displayName, size: 88)
                .sqShadowAccent()
                .accessibilityHidden(true)
            VStack(spacing: SQSpace.xxs) {
                Text(user.displayName)
                    .font(SQFont.display(26, .bold))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.center)
                Text(user.handle.flatMap { $0.isEmpty ? nil : "@\($0)" } ?? "Ajoute un nom d’utilisateur")
                    .font(SQFont.body(14, .medium))
                    .foregroundStyle((user.handle?.isEmpty ?? true) ? SQColor.labelTertiary : SQColor.labelSecondary)
            }
            if user.twoFactorEnabled == true {
                Text("2FA activée ✓")
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(SQColor.success)
                    .padding(.horizontal, SQSpace.md - 1)
                    .padding(.vertical, SQSpace.xs + 1)
                    .background(SQColor.successSoft, in: Capsule(style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stats

    // Pas de cellule « Niveau » : la carte de progression juste en dessous
    // porte déjà le niveau + la jauge (doublon signalé).
    private func statsCard(_ stats: UserStats) -> some View {
        HStack(spacing: 0) {
            statCell(label: "Points", value: stats.totalPoints.map { $0.formatted() } ?? "—", accent: true)
            statDivider
            statCell(label: "Tests", value: stats.totalSpeedtests.map { $0.formatted() } ?? "—")
            if let validations = stats.totalValidations {
                statDivider
                statCell(label: "Valid.", value: validations.formatted())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.lg)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    private func statCell(label: String, value: String, accent: Bool = false) -> some View {
        VStack(spacing: SQSpace.xxs) {
            Text(value)
                .font(SQFont.display(22, .bold))
                .monospacedDigit()
                .foregroundStyle(accent ? SQColor.brandRed : SQColor.label)
                .contentTransition(.numericText())
            Text(label)
                .font(SQFont.body(11.5))
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(width: 1, height: 34)
    }

    // MARK: - Progression

    private func progressionCard(level: Int, points: Int, goal: Int) -> some View {
        // Même sémantique que la jauge de GamificationView : progression
        // dans le niveau courant = points % palier.
        let inLevel = points % goal
        let progress = min(1, Double(inLevel) / Double(goal))
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack {
                Text("Niveau \(level)")
                    .font(SQFont.body(12.5, .medium))
                    .foregroundStyle(SQColor.labelSecondary)
                Spacer()
                Text("\(inLevel.formatted()) / \(goal.formatted()) pts")
                    .font(SQFont.body(12.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(SQColor.surfaceMuted)
                    if progress > 0 {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(SQColor.brandRed)
                            .frame(width: max(10, proxy.size.width * progress))
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement()
            .accessibilityLabel("Progression vers le niveau suivant")
            .accessibilityValue("\(Int(progress * 100)) %")
        }
        .padding(.vertical, SQSpace.lg)
        .padding(.horizontal, SQSpace.lg + 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    // MARK: - Menu

    private var menuCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                GamificationView(service: services.gamification)
            } label: {
                menuRow(title: "Récompenses", icon: "rosette")
            }
            menuSeparator
            NavigationLink {
                PaywallView(store: services.entitlements, entryPoint: .profile)
            } label: {
                menuRow(title: "Abonnements", icon: "checkmark.seal.fill")
            }
            menuSeparator
            NavigationLink {
                LeaderboardsView(service: services.leaderboards, gamification: services.gamification, user: user)
            } label: {
                menuRow(title: "Classements", icon: "trophy")
            }
            menuSeparator
            NavigationLink {
                FriendsListView(service: services.friends)
            } label: {
                menuRow(title: "Amis", icon: "person.2.fill")
            }
            menuSeparator
            NavigationLink {
                PhotosView(service: services.photos)
            } label: {
                menuRow(title: "Photos", icon: "photo.stack")
            }
            menuSeparator
            NavigationLink {
                SessionsListView(service: services.sessions)
            } label: {
                menuRow(title: "Mes sessions / Logs", icon: "point.topleft.down.curvedto.point.bottomright.up")
            }
            menuSeparator
            NavigationLink {
                MyMeasurementsView(service: services.sessions)
            } label: {
                menuRow(title: "Mes mesures", icon: "mappin.and.ellipse")
            }
            menuSeparator
            NavigationLink {
                MyIdentificationsView(service: services.identify)
            } label: {
                menuRow(title: "Mes identifications", icon: "checkmark.seal")
            }
            menuSeparator
            NavigationLink {
                RadioLogImportView(service: services.radioLogImport)
            } label: {
                menuRow(title: "Importer des logs radio", icon: "square.and.arrow.down")
            }
            menuSeparator
            NavigationLink {
                AntennaReportsListView(service: services.antennaReports)
            } label: {
                menuRow(title: "Mes signalements d'antenne", icon: "exclamationmark.bubble")
            }
            menuSeparator
            NavigationLink {
                ANFRMapView(service: services.anfr)
            } label: {
                menuRow(title: "Carte ANFR", icon: "antenna.radiowaves.left.and.right")
            }
            menuSeparator
            NavigationLink {
                ANFRStatsView(service: services.anfr)
            } label: {
                menuRow(title: "Statistiques ANFR", icon: "chart.bar.xaxis")
            }
            menuSeparator
            NavigationLink {
                NotificationsCenterView(service: services.notifications)
            } label: {
                menuRow(title: "Notifications", icon: "bell.fill")
            }
            menuSeparator
            NavigationLink {
                CallHistoryView(service: services.calls)
            } label: {
                menuRow(title: "Appels", icon: "phone.circle")
            }
            menuSeparator
            NavigationLink {
                PrivacySettingsView(service: services.privacy)
            } label: {
                menuRow(title: "Confidentialité", icon: "hand.raised.fill")
            }
            menuSeparator
            NavigationLink {
                SettingsView(userService: services.users, authService: services.auth)
            } label: {
                menuRow(title: "Réglages", icon: "gearshape.fill")
            }
        }
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    private var menuSeparator: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(height: 1)
            .padding(.leading, 65)
    }

    private func menuRow(title: String, icon: String) -> some View {
        HStack(spacing: SQSpace.md + 1) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 36, height: 36)
                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(SQFont.body(15.5, .medium))
                .foregroundStyle(SQColor.label)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md + 2)
        .contentShape(Rectangle())
    }

    // MARK: - Données

    private func loadStats() async {
        // Progression (niveau / points / palier) : même source de données que
        // GamificationView (service existant) ; en cas d'échec, la carte de
        // progression est simplement omise.
        async let profileTask = services.gamification.profile()
        do {
            stats = try await services.users.stats()
            statsError = nil
        } catch {
            statsError = error.localizedDescription
        }
        progression = try? await profileTask
    }
}
