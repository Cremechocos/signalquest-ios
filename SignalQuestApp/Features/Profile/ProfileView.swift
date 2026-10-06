import SwiftUI

/// Enveloppe `Identifiable` autour d'un identifiant de signalement, pour piloter
/// une `.sheet(item:)` sur deep link (l'`id` `String` seul n'est pas `Identifiable`).
struct AntennaReportDeepLink: Identifiable {
    let id: String
}

/// Sans identifiant de box, on ouvre quand même Sentinelle : une alerte de
/// coupure doit mener à l'écran, même si le payload est incomplet.
struct SentinelleDeepLink: Identifiable {
    let id: String
    var targetId: String? { id.isEmpty ? nil : id }
}

/// Demande d'approbation E2EE v2 issue d'un push validé localement. Le détail
/// complet est toujours relu sur le serveur avant d'être présenté à l'utilisateur.
struct E2EEDeviceApprovalDeepLink: Identifiable {
    let id: String
}

/// QR d'approbation ouvert par le lien universel ; `id` est la chaîne v3.
struct E2EEApprovalQRDeepLink: Identifiable {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let user: AuthUser
    /// Écrans nourris par l'app Android, montrés seulement avec des données.
    @StateObject private var androidPresence: AndroidDataPresence
    @State private var showEdit = false
    @State private var stats: UserStats?
    @State private var statsError: String?
    @State private var progression: GamificationProfile?
    /// « À faire » de l'espace personnel (plan 3, vague 2).
    @State private var overview: UserOverview?
    /// Fil de signalement à ouvrir en sheet (tap sur une notification
    /// `antenna_report_reply`), résolu depuis `router.openAntennaReportId`.
    @State private var deepLinkReport: AntennaReportDeepLink?
    /// Écran Sentinelle à ouvrir en sheet (tap sur une notification de coupure).
    @State private var deepLinkSentinelle: SentinelleDeepLink?
    /// Box partagée ouverte depuis un lien universel.
    @State private var deepLinkShare: SentinelleDeepLink?
    /// Nouvel appareil à examiner après un tap sur une notification E2EE v2.
    @State private var deepLinkE2EEApproval: E2EEDeviceApprovalDeepLink?
    @State private var deepLinkE2EEApprovalQR: E2EEApprovalQRDeepLink?
    @State private var showE2EEIdentityReset = false
    /// Écran Notifications ouvert depuis les Réglages d'iOS (TRX-21).
    @State private var showNotificationSettings = false
    /// La déconnexion se confirme : un appui accidentel coupait la session (TRX-31).
    @State private var confirmLogout = false

    init(user: AuthUser) {
        self.user = user
        _androidPresence = StateObject(wrappedValue: AndroidDataPresence(ownerScope: "user:\(user.id)"))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.lg + 2) {
                profileHeader
                    .sqFadeUp()
                if user.isEmailVerificationPending {
                    EmailVerificationCard(userID: user.id, email: user.email)
                }
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

                // Récompenses, Classements, Territoires : juste sous le niveau
                // et les points auxquels ils se rapportent.
                progressionTiles

                GradientButton("Éditer le profil", systemImage: "person.crop.circle", style: .secondary) {
                    showEdit = true
                }

                // Pas de sqFadeUp sur la carte menu : plus haute que le viewport,
                // la scrollTransition ne l'amène jamais à l'identité → elle
                // resterait estompée en permanence tant qu'on ne scrolle pas.
                menuCard

                GradientButton("Déconnexion", systemImage: "rectangle.portrait.and.arrow.right", style: .destructive) {
                    confirmLogout = true
                }
                .confirmationDialog("Te déconnecter ?", isPresented: $confirmLogout, titleVisibility: .visible) {
                    Button("Se déconnecter", role: .destructive) {
                        Task { await session.logout() }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("Tu pourras te reconnecter à tout moment avec ton compte.")
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
        // Sentinelle vit dans les réglages, eux-mêmes sous l'onglet Profil : une
        // sheet évite d'avoir à dérouler cette pile pour arriver à la box.
        .sheet(item: $deepLinkSentinelle) { link in
            NavigationStack {
                SentinelleView(service: services.sentinelle, initialTargetId: link.targetId)
            }
        }
        .sheet(item: $deepLinkShare) { link in
            NavigationStack {
                // La page Sentinelle habituelle, avec le jeton : l'écran dédié
                // a été retiré, son contenu a sa place dans la liste.
                SentinelleView(service: services.sentinelle, initialShareSlug: link.id)
            }
        }
        .sheet(item: $deepLinkE2EEApproval) { link in
            NavigationStack {
                E2EEV2TrustedDevicesView(api: services.api, initialApprovalId: link.id)
            }
        }
        .sheet(item: $deepLinkE2EEApprovalQR) { link in
            NavigationStack {
                E2EEV2TrustedDevicesView(api: services.api, initialApprovalQR: link.id)
            }
        }
        .sheet(isPresented: $showE2EEIdentityReset) {
            NavigationStack {
                E2EEV2RecoveryResetView(api: services.api)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { showE2EEIdentityReset = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showNotificationSettings) {
            NavigationStack {
                NotificationSettingsView(userService: services.users)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("OK") { showNotificationSettings = false }
                        }
                    }
            }
        }
        .onAppear {
            consumeAntennaReportDeepLink()
            consumeSentinelleDeepLink()
            consumeShareDeepLink()
            consumeE2EEApprovalDeepLink()
            consumeE2EEApprovalQRDeepLink()
            consumeE2EEIdentityResetDeepLink()
            consumeNotificationSettingsDeepLink()
        }
        .onChangeCompat(of: router.openE2EEIdentityReset) { _, _ in consumeE2EEIdentityResetDeepLink() }
        .onChangeCompat(of: router.openNotificationSettings) { _, _ in consumeNotificationSettingsDeepLink() }
        .onChangeCompat(of: router.openSentinelleShareSlug) { _, _ in consumeShareDeepLink() }
        .onChangeCompat(of: router.openAntennaReportId) { _, _ in consumeAntennaReportDeepLink() }
        .onChangeCompat(of: router.openSentinelle) { _, _ in consumeSentinelleDeepLink() }
        .onChangeCompat(of: router.openE2EEDeviceApprovalId) { _, _ in consumeE2EEApprovalDeepLink() }
        .onChangeCompat(of: router.openE2EEApprovalQR) { _, _ in consumeE2EEApprovalQRDeepLink() }
        .task { await loadStats() }
        // À chaque retour sur le Profil : une mission réclamée ou une photo
        // validée entre-temps doit quitter « À faire ».
        .onAppear { Task { await loadOverview() } }
        .task { await refreshAndroidPresence() }
        .refreshable {
            await loadStats()
            await loadOverview()
        }
    }

    /// Consomme l'intention de deep link posée par le routeur (idempotent : on
    /// remet la valeur à `nil` une fois lue, comme `openSiteFromRouterIfNeeded`).
    /// Même contrat que ci-dessous : idempotent, l'intention est remise à zéro
    /// une fois lue.
    /// Même contrat : idempotent, l'intention est remise à zéro une fois lue.
    private func consumeShareDeepLink() {
        guard let slug = router.openSentinelleShareSlug else { return }
        router.openSentinelleShareSlug = nil
        deepLinkShare = SentinelleDeepLink(id: slug)
    }

    private func consumeSentinelleDeepLink() {
        guard router.openSentinelle else { return }
        let targetId = router.openSentinelleTargetId
        router.openSentinelle = false
        router.openSentinelleTargetId = nil
        deepLinkSentinelle = SentinelleDeepLink(id: targetId ?? "")
    }

    private func consumeAntennaReportDeepLink() {
        guard let id = router.openAntennaReportId else { return }
        router.openAntennaReportId = nil
        deepLinkReport = AntennaReportDeepLink(id: id)
    }

    private func consumeNotificationSettingsDeepLink() {
        guard router.openNotificationSettings else { return }
        router.openNotificationSettings = false
        showNotificationSettings = true
    }

    private func consumeE2EEApprovalDeepLink() {
        guard let id = router.openE2EEDeviceApprovalId else { return }
        router.openE2EEDeviceApprovalId = nil
        // Même règle que l'entrée des Réglages (E2E-03).
        guard E2EEV2RuntimeWriteGate.enabled else { return }
        deepLinkE2EEApproval = E2EEDeviceApprovalDeepLink(id: id)
    }

    private func consumeE2EEApprovalQRDeepLink() {
        guard let payload = router.openE2EEApprovalQR else { return }
        router.openE2EEApprovalQR = nil
        guard E2EEV2RuntimeWriteGate.enabled else { return }
        deepLinkE2EEApprovalQR = E2EEApprovalQRDeepLink(id: payload)
    }

    private func consumeE2EEIdentityResetDeepLink() {
        guard router.openE2EEIdentityReset else { return }
        router.openE2EEIdentityReset = false
        guard E2EEV2RuntimeWriteGate.enabled else { return }
        showE2EEIdentityReset = true
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
                    .lineLimit(user.name == nil ? 1 : nil)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("profile.displayName")
                Text(user.handle.flatMap { $0.isEmpty ? nil : "@\($0)" } ?? "Ajoute un nom d’utilisateur")
                    .font(SQFont.body(14, .medium))
                    .foregroundStyle((user.handle?.isEmpty ?? true) ? SQColor.labelSecondary : SQColor.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.sm) {
                    statCell(label: "Points", value: stats.totalPoints.map { $0.formatted() } ?? "—", accent: true)
                    Divider().overlay(SQColor.separator)
                    statCell(label: "Tests", value: stats.totalSpeedtests.map { $0.formatted() } ?? "—")
                    if let validations = stats.totalValidations {
                        Divider().overlay(SQColor.separator)
                        statCell(label: "Validations", value: validations.formatted())
                    }
                }
            } else {
                HStack(spacing: 0) {
                    statCell(label: "Points", value: stats.totalPoints.map { $0.formatted() } ?? "—", accent: true)
                    statDivider
                    statCell(label: "Tests", value: stats.totalSpeedtests.map { $0.formatted() } ?? "—")
                    if let validations = stats.totalValidations {
                        statDivider
                        statCell(label: "Validations", value: validations.formatted())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.lg)
        .sqCardBackground()
    }

    private func statCell(label: String, value: String, accent: Bool = false) -> some View {
        VStack(spacing: SQSpace.xxs) {
            Text(value)
                .font(SQFont.display(22, .bold))
                .monospacedDigit()
                .foregroundStyle(accent ? SQColor.brandRed : SQColor.label)
                .contentTransition(.numericText())
                .accessibilityIdentifier("profile.stat.value")
            // Encre pleine : `labelSecondary` sous 13 pt perd environ 23 % de
            // contraste au rendu (anti-crénelage) et passait sous 4,5:1 (TRX-12).
            // La hiérarchie reste portée par la taille du chiffre.
            Text(LocalizedStringKey(label))
                .font(SQFont.body(12.5, relativeTo: .caption))
                .foregroundStyle(SQColor.label)
                .accessibilityIdentifier("profile.stat.label")
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
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text("Niveau \(level)")
                            .font(SQFont.body(12.5, .medium))
                            .foregroundStyle(SQColor.label)
                            .accessibilityIdentifier("profile.progression.level")
                        Text("\(inLevel.formatted()) / \(goal.formatted()) pts")
                            .font(SQFont.body(12.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                            .accessibilityIdentifier("profile.progression.points")
                    }
                } else {
                    HStack {
                        Text("Niveau \(level)")
                            .font(SQFont.body(12.5, .medium))
                            .foregroundStyle(SQColor.label)
                            .accessibilityIdentifier("profile.progression.level")
                        Spacer()
                        Text("\(inLevel.formatted()) / \(goal.formatted()) pts")
                            .font(SQFont.body(12.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                            .accessibilityIdentifier("profile.progression.points")
                    }
                }
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
            .accessibilityHidden(true)
        }
        .padding(.vertical, SQSpace.lg)
        .padding(.horizontal, SQSpace.lg + 2)
        .sqCardBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Progression · Niveau \(level)")
        .accessibilityValue("\(inLevel) sur \(goal) points · \(Int(progress * 100)) %")
    }

    // MARK: - Menu

    // MARK: - Menu
    //
    // Le menu ne garde QUE ce qui relève du profil : ce que l'utilisateur a
    // produit, et son compte. Le reste a rejoint l'onglet où on le cherche —
    // Carte ANFR et Statistiques ANFR dans Carte, Amis / Notifications /
    // Appels / Préférences du fil dans Communauté — et la progression est
    // remontée en tuiles sous l'en-tête, à côté du niveau qu'elle prolonge.
    // Dix-neuf entrées à plat ne se lisaient plus.

    private var menuCard: some View {
        VStack(spacing: SQSpace.lg) {
            // Remontés des Réglages (MES-21, TRX-22) : Sentinelle, l'une des
            // rares fonctions Premium utilisées, était à cinq niveaux.
            menuSection("Mes suivis") {
                NavigationLink {
                    SentinelleView(service: services.sentinelle)
                } label: {
                    menuRow(title: "Sentinelle", icon: "wifi.router")
                }
                menuSeparator
                NavigationLink {
                    FavoriteAntennasView(favorites: services.favoriteAntennas) { favorite in
                        router.route(toSite: favorite.siteId)
                    }
                } label: {
                    menuRow(title: "Antennes suivies", icon: "star.fill")
                }
            }

            let todos = overview?.todos ?? []
            if !todos.isEmpty {
                menuSection("À faire") {
                    ForEach(Array(todos.enumerated()), id: \.offset) { index, todo in
                        if index > 0 { menuSeparator }
                        todoLink(todo)
                    }
                }
            }

            menuSection("Mes contributions") {
                NavigationLink {
                    MyMeasurementsView(service: services.sessions)
                } label: {
                    menuRow(title: "Mes mesures", icon: "mappin.and.ellipse")
                }
                menuSeparator
                NavigationLink {
                    PhotosView(service: services.photos)
                } label: {
                    menuRow(title: "Photos", icon: "photo.stack")
                }
                menuSeparator
                NavigationLink {
                    AntennaReportsListView(service: services.antennaReports)
                } label: {
                    menuRow(title: "Mes signalements d'antenne", icon: "exclamationmark.bubble")
                }
                menuSeparator
                NavigationLink {
                    CommunityOutagesListView(service: services.communityOutages, markets: services.markets)
                } label: {
                    menuRow(title: "Pannes signalées", icon: "exclamationmark.triangle.fill")
                }
                menuSeparator
                // Territoires : plus en tuile sous le niveau (décision du 29/09).
                NavigationLink {
                    TerritoriesView(service: services.gamification)
                } label: {
                    menuRow(title: "Territoires", icon: "square.grid.3x3.fill")
                }
            }

            // Écrans nourris par l'app Android : affichés seulement si le compte
            // a de telles données, sinon une ligne dit ce qu'ils apportent.
            menuSection("Avancé") {
                if androidPresence.showsAndroidScreens {
                    NavigationLink {
                        SessionsListView(service: services.sessions)
                    } label: {
                        menuRow(title: "Mes enregistrements de trajet", icon: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    menuSeparator
                    NavigationLink {
                        RadioLogsView(
                            service: services.radioLogs,
                            antennas: services.antennas,
                            networkPath: services.networkPath
                        )
                    } label: {
                        menuRow(title: "Logs antennes", icon: "antenna.radiowaves.left.and.right")
                    }
                    menuSeparator
                    NavigationLink {
                        MyIdentificationsView(service: services.identify)
                    } label: {
                        menuRow(title: "Mes identifications", icon: "checkmark.seal")
                    }
                } else {
                    androidHint
                }
            }

            menuSection("Compte") {
                NavigationLink {
                    PaywallView(store: services.entitlements, entryPoint: .profile)
                } label: {
                    menuRow(title: "Abonnements", icon: "creditcard.fill")
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
                menuSeparator
                NavigationLink {
                    SQGlossaryView()
                } label: {
                    menuRow(title: "Aide et glossaire", icon: "questionmark.circle")
                }
                .accessibilityIdentifier("profile.glossary")
            }
        }
    }

    /// Sans données Android : ce que l'app Android ajoute, plutôt que trois
    /// écrans vides.
    private var androidHint: some View {
        HStack(alignment: .top, spacing: SQSpace.md + 1) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Avec l’app Android")
                    .font(.body.weight(.medium))
                    .foregroundStyle(SQColor.label)
                Text("Elle enregistre tes trajets, tient un journal des antennes captées et aide à les identifier. Ces écrans apparaissent ici dès qu’elle a envoyé des données.")
                    .font(.footnote)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md + 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.android.hint")
    }

    /// Vérifie, au besoin, si le compte a des données Android (trajets,
    /// identifications, journal radio local).
    private func refreshAndroidPresence() async {
        guard !AppEnvironment.usesDemoData else { return }
        let sessions = services.sessions
        let identify = services.identify
        let radioLogs = services.radioLogs
        await androidPresence.refresh(
            sessionsTotal: {
                guard let page = try? await sessions.sessions(offset: 0, limit: 1) else { return nil }
                return page.pagination?.total ?? page.sessions.count
            },
            identifications: { (try? await identify.mine(includeRelated: false))?.count },
            hasLocalLogs: { !radioLogs.cachedSnapshot().entries.isEmpty }
        )
    }

    /// Une section du menu : intertitre discret + carte. L'intertitre est en
    /// casse normale — la DA « Crème & Terre cuite » proscrit les micro-labels
    /// majuscules tracés (cf. `sqKicker`).
    @ViewBuilder
    private func menuSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(LocalizedStringKey(title))
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.leading, SQSpace.xs)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .sqCardBackground()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Progression : les trois écrans de jeu, en tuiles sous l'en-tête plutôt
    /// qu'en lignes de menu. Ils prolongent le niveau et les points déjà
    /// affichés au-dessus — les ranger vingt lignes plus bas les coupait de
    /// leur contexte.
    private var progressionTiles: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.md) { progressionTileContent }
            } else {
                HStack(spacing: SQSpace.md) { progressionTileContent }
            }
        }
    }

    @ViewBuilder
    private var progressionTileContent: some View {
        progressionTile("Récompenses", icon: "rosette") {
            GamificationView(service: services.gamification)
        }
        progressionTile("Classements", icon: "trophy.fill") {
            LeaderboardsView(service: services.leaderboards, gamification: services.gamification, user: user)
        }
    }

    private func progressionTile<Destination: View>(
        _ title: String,
        icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(spacing: SQSpace.sm) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(width: 40, height: 40)
                    .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(SQFont.body(12.5, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.progression.tile.label.\(title)")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.md)
            .sqCardBackground(cornerRadius: SQRadius.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityIdentifier("profile.progression.tile.\(title)")
    }

    private var menuSeparator: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(height: 1)
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? SQSpace.lg : 65)
            .accessibilityHidden(true)
    }

    private func menuRow(title: String, icon: String) -> some View {
        HStack(spacing: SQSpace.md + 1) {
            // En très grand texte, l'icône cède sa place au titre : « Sentinelle »
            // se coupait en « Senti-/nelle » (tour AX5, 30/09).
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
                    .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            }
            Text(LocalizedStringKey(title))
                .font(.body.weight(.medium))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("profile.menu.title")
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.primary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md + 2)
        .contentShape(Rectangle())
    }

    /// Une ligne « À faire », vers l'écran où la régler.
    @ViewBuilder
    private func todoLink(_ todo: UserOverview.Todo) -> some View {
        switch todo {
        case .claimMissions(let count, let rewardXp):
            NavigationLink {
                GamificationView(service: services.gamification)
            } label: {
                menuRow(title: String(localized: "Missions à réclamer : \(count) (+\(rewardXp) pts)"), icon: "gift.fill")
            }
            .accessibilityIdentifier("profile.todo.missions")
        case .photosInReview(let count):
            NavigationLink {
                PhotosView(service: services.photos)
            } label: {
                menuRow(title: String(localized: "Photos en cours de vérification : \(count)"), icon: "hourglass")
            }
            .accessibilityIdentifier("profile.todo.photos")
        case .identificationConflicts(let count):
            NavigationLink {
                MyIdentificationsView(service: services.identify)
            } label: {
                menuRow(title: String(localized: "Identifications en conflit : \(count)"), icon: "exclamationmark.triangle")
            }
            .accessibilityIdentifier("profile.todo.identifications")
        }
    }

    // MARK: - Données

    private func loadOverview() async {
        // Un échec laisse simplement la section absente : rien d'autre n'en dépend.
        if let value = try? await UserOverviewService(api: services.api).overview() {
            overview = value
        }
    }

    private func loadStats() async {
        // Démonstration : pas d'appel réseau avec la session factice, qui
        // affichait « Stats indisponibles — Session expirée » dans les captures.
        if AppEnvironment.usesDemoData {
            stats = UserStats(totalSpeedtests: 128, totalPhotos: 14, totalValidations: 37,
                              totalCoverageSessions: 6, totalPoints: 4250, level: 12)
            statsError = nil
            progression = .demo
            return
        }
        // Progression (niveau / points / palier) : même source de données que
        // GamificationView (service existant) ; en cas d'échec, la carte de
        // progression est simplement omise.
        async let profileTask = services.gamification.profile()
        do {
            stats = try await services.users.stats()
            statsError = nil
        } catch {
            statsError = error.userFacingMessage
        }
        progression = try? await profileTask
    }
}

private struct EmailVerificationRequestReceipt: Decodable {
    let alreadyVerified: Bool
    let sent: Bool
}

/// Une adresse non confirmée n'empêche pas de mesurer. Les actions publiques
/// restent gardées côté serveur ; cette carte donne une issue native à ce 403.
private struct EmailVerificationCard: View {
    let userID: String
    let email: String
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @State private var isSending = false
    @State private var isRefreshing = false
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Label("Confirme ton adresse e-mail", systemImage: "envelope.fill")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text("Ouvre le lien reçu pour publier et contacter la communauté. La carte et les tests restent disponibles.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(email)
                .font(SQType.caption)
                .foregroundStyle(SQColor.label)
                .textSelection(.enabled)

            Button {
                Task { await resend() }
            } label: {
                Group {
                    if isSending { ProgressView() } else { Text("Renvoyer le lien") }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(SQColor.brandRed)
            .disabled(isSending || isRefreshing)
            .accessibilityIdentifier("profile.emailVerification.resend")

            Button { Task { await refresh() } } label: {
                Text("J’ai confirmé")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(SQColor.brandRed)
                .disabled(isSending || isRefreshing)
                .accessibilityIdentifier("profile.emailVerification.refresh")

            if let feedback {
                Text(feedback)
                    .font(SQType.caption)
                    .foregroundStyle(feedbackIsError ? SQColor.dangerInk : SQColor.label)
                    .accessibilityIdentifier("profile.emailVerification.feedback")
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
    }

    private var isCurrentAccount: Bool {
        guard case .authenticated(let current) = session.state else { return false }
        return current.id == userID
    }

    private func resend() async {
        guard !isSending, isCurrentAccount else { return }
        isSending = true
        defer { isSending = false }
        do {
            let receipt: EmailVerificationRequestReceipt = try await services.api.requestJSON(
                "/api/auth/verify-email/request", body: [String: String]()
            )
            guard isCurrentAccount else { return }
            if receipt.alreadyVerified {
                await session.refreshUser()
                feedback = String(localized: "Adresse déjà confirmée.")
            } else if receipt.sent {
                feedback = String(localized: "Lien envoyé. Vérifie ta boîte e-mail.")
            } else {
                feedback = String(localized: "Envoi non confirmé. Réessaie.")
            }
            feedbackIsError = !receipt.alreadyVerified && !receipt.sent
        } catch let error as APIError where error.isCancellation {
            return
        } catch {
            guard isCurrentAccount else { return }
            feedback = error.userFacingMessage
            feedbackIsError = true
        }
    }

    private func refresh() async {
        guard !isRefreshing, isCurrentAccount else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await session.refreshUser()
        guard isCurrentAccount else { return }
        feedback = String(localized: "Confirmation encore en attente. Ouvre le lien reçu puis actualise.")
        feedbackIsError = false
    }
}
