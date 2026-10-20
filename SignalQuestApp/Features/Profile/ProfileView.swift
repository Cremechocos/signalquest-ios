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

/// Profil Halo : en-tête compact (photo, nom, @, « Modifier »), points, tests,
/// validations et niveau sur une carte, tuiles Récompenses / Classements avec
/// ce qui t'attend, sections en petites capitales, déconnexion en ligne rouge
/// et version en pied. Header custom scrollable (pas de titre nav système).
struct ProfileView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var versionPolicy: VersionPolicyService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    let user: AuthUser
    /// Écrans nourris par l'app Android, montrés seulement avec des données.
    @StateObject private var androidPresence: AndroidDataPresence
    @State private var showEdit = false
    /// Écran poussé depuis le Profil (une ligne du menu, une tuile, « À faire »).
    @State private var pushed: ProfileDestination?

    /// Note l'écran demandé pour la sonde de gel (iOS 16), avant tout rendu.
    private func push(_ destination: ProfileDestination) {
        MainThreadHangProbe.mark("profile.push.\(destination)")
        pushed = destination
    }
    /// Choix du @pseudo depuis l'en-tête quand le compte n'en a pas encore.
    @State private var showHandleSheet = false
    @State private var stats: UserStats?
    @State private var statsError: String?
    @State private var progression: GamificationProfile?
    /// « À faire » de l'espace personnel (plan 3, vague 2).
    @State private var overview: UserOverview?
    /// Rang de la semaine parmi les amis, sous la tuile Classements (même
    /// source que le module « Ta semaine » de l'Accueil).
    @State private var weekRank: Int?
    /// Signalements « Bugs et idées » où l'équipe a bougé depuis la dernière lecture.
    @State private var unseenBugReplies = 0
    /// Fil de signalement à ouvrir en sheet (tap sur une notification
    /// `antenna_report_reply`), résolu depuis `router.openAntennaReportId`.
    @State private var deepLinkReport: AntennaReportDeepLink?
    /// Signalement « Bugs et idées » à ouvrir en sheet (notification `bug_*`).
    @State private var deepLinkBug: AntennaReportDeepLink?
    @State private var deepLinkScreen: AppRouter.ProfileScreen?
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
    /// Messages que la déconnexion supprimerait de l'appareil, relevés à l'ouverture de la confirmation.
    @State private var unsentMessages = 0
    /// `logout()` enchaîne plusieurs appels réseau : sans état d'attente, l'action semblait ignorée et pouvait être relancée.
    @State private var isLoggingOut = false

    init(user: AuthUser) {
        self.user = user
        _androidPresence = StateObject(wrappedValue: AndroidDataPresence(ownerScope: "user:\(user.id)"))
    }

    var body: some View {
        let _ = SQRenderProbe.hit("profile")
        ScrollView {
            VStack(spacing: SQSpace.md) {
                profileHeader
                    .sqFadeUp()
                if user.isEmailVerificationPending {
                    EmailVerificationCard(userID: user.id, email: user.email)
                }
                if stats != nil || levelProgress != nil {
                    // Points, tests, validations et niveau sur une seule carte.
                    statsCard(stats, progress: levelProgress)
                        .sqFadeUp()
                } else if let statsError {
                    ErrorStateView(title: "Stats indisponibles", message: statsError) {
                        Task { await loadStats() }
                    }
                        .sqFadeUp()
                }

                // Récompenses et Classements : juste sous le niveau et les
                // points auxquels ils se rapportent.
                progressionTiles

                // Pas de sqFadeUp sur le menu : plus haut que le viewport, la
                // scrollTransition ne l'amène jamais à l'identité → il resterait
                // estompé en permanence tant qu'on ne scrolle pas.
                menuCard

                logoutCard

                Text(verbatim: Self.versionLine)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("profile.version")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        // Push par état, comme Accueil et Communauté : sous iOS 16.7, tout
        // NavigationLink du Profil (par valeur comme par closure) gelait l'app,
        // alors que les boutons à feuille et les pushes programmatiques des
        // autres onglets répondaient.
        .profileDestinationCompat($pushed) { shown in
            let _ = SQRenderProbe.hit("profile.destination")
            destination(for: shown)
                .onAppear { MainThreadHangProbe.mark("profile.shown.\(shown)") }
        }
        // Directement sur le ScrollView (avant le ZStack de signalQuestBackground).
        .sqDockAutoMinimize()
        .toolbar(.hidden, for: .navigationBar)
        .signalQuestBackground()
        .sheet(isPresented: $showEdit) {
            EditProfileView(user: user)
        }
        .sheet(isPresented: $showHandleSheet) {
            ChooseHandleSheet(onSuccess: { _ in Task { await session.refreshUser() } })
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
        .sheet(item: $deepLinkBug) { link in
            NavigationStack {
                // Un administrateur suit tous les bugs depuis l'espace Admin : la vue de
                // l'auteur ne distingue pas les notes internes, que le serveur lui sert aussi.
                if case .authenticated(let user) = session.state, user.role == "admin" {
                    AdminBugDetailView(service: services.adminBugs, bugId: link.id,
                                       onClose: { deepLinkBug = nil })
                } else {
                    BugReportDetailView(service: services.bugReports, reportId: link.id,
                                        onClose: { deepLinkBug = nil })
                }
            }
        }
        // Notification sans fiche précise : l'écran du Profil qui en parle.
        .sheet(item: $deepLinkScreen) { screen in
            NavigationStack {
                switch screen {
                case .photos: PhotosView(service: services.photos)
                case .progression: GamificationView(service: services.gamification)
                case .sessions: SessionsListView(service: services.sessions)
                case .subscription: PaywallView(store: services.entitlements, entryPoint: .profile)
                }
            }
        }
        // Sentinelle vit dans les réglages, eux-mêmes sous l'onglet Profil : une
        // sheet évite d'avoir à dérouler cette pile pour arriver à la box.
        .sheet(item: $deepLinkSentinelle) { link in
            NavigationStack {
                SentinelleView(service: services.sentinelle, initialTargetId: link.targetId)
                    // Ouverte par un lien : sans « Fermer », seul le glissement en
                    // sortait (AF-PROF-03).
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { deepLinkSentinelle = nil }
                        }
                    }
            }
        }
        .sheet(item: $deepLinkShare) { link in
            NavigationStack {
                // La page Sentinelle habituelle, avec le jeton : l'écran dédié
                // a été retiré, son contenu a sa place dans la liste.
                SentinelleView(service: services.sentinelle, initialShareSlug: link.id)
                    // Ouverte par un lien : sans « Fermer », seul le glissement en
                    // sortait (AF-PROF-03).
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { deepLinkShare = nil }
                        }
                    }
            }
        }
        .sheet(item: $deepLinkE2EEApproval) { link in
            NavigationStack {
                E2EEV2TrustedDevicesView(api: services.api, initialApprovalId: link.id)
                    // Ouverte par un lien : sans « Fermer », seul le glissement en
                    // sortait (AF-PROF-03).
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { deepLinkE2EEApproval = nil }
                        }
                    }
            }
        }
        .sheet(item: $deepLinkE2EEApprovalQR) { link in
            NavigationStack {
                E2EEV2TrustedDevicesView(api: services.api, initialApprovalQR: link.id)
                    // Ouverte par un lien : sans « Fermer », seul le glissement en
                    // sortait (AF-PROF-03).
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { deepLinkE2EEApprovalQR = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showE2EEIdentityReset) {
            NavigationStack {
                // Ni « OK » ni glissement tant que la clé affichée n'est pas
                // sauvegardée (AF-PROF-01).
                E2EEV2RecoveryResetView(api: services.api) { showE2EEIdentityReset = false }
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
            consumeBugDeepLink()
            consumeScreenDeepLink()
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
        .onChangeCompat(of: router.openBugId) { _, _ in consumeBugDeepLink() }
        .onChangeCompat(of: router.openProfileScreen) { _, _ in consumeScreenDeepLink() }
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

    private func consumeBugDeepLink() {
        guard let id = router.openBugId else { return }
        router.openBugId = nil
        deepLinkBug = AntennaReportDeepLink(id: id)
    }

    private func consumeScreenDeepLink() {
        guard let screen = router.openProfileScreen else { return }
        router.openProfileScreen = nil
        deepLinkScreen = screen
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

    /// Photo, nom et @ sur une ligne, « Modifier » à droite. En très grand
    /// texte, les trois s'empilent pour que le nom garde toute la largeur.
    private var profileHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.md))
            : AnyLayout(HStackLayout(alignment: .center, spacing: SQSpace.md2))
        return layout {
            SQAvatar(url: user.avatarUrl, name: user.displayName, size: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(user.displayName)
                    .font(SQFont.display(22, .bold, relativeTo: .title2))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(user.name == nil ? 1 : 2)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("profile.displayName")
                    .sqHeader()
                if let handle = user.handle, !handle.isEmpty {
                    Text("@\(handle)")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Button {
                        showHandleSheet = true
                    } label: {
                        Text("Ajoute un nom d’utilisateur")
                            .font(SQType.callout(.semibold))
                            .foregroundStyle(SQColor.accentInk)
                            .multilineTextAlignment(.leading)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.chooseHandle")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showEdit = true
            } label: {
                Label("Modifier", systemImage: "pencil")
                    .font(SQType.callout(.bold))
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, SQSpace.md2)
                    .frame(minHeight: 36)
                    .background(SQColor.surface, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).stroke(SQColor.separator, lineWidth: 1))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Modifier le profil")
            .accessibilityIdentifier("profile.edit")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SQSpace.xs)
    }

    // MARK: - Stats et niveau

    /// Niveau et avancement dans le palier courant, quand le serveur les donne.
    private var levelProgress: (level: Int, fraction: Double, remaining: Int)? {
        guard let progression, let level = progression.level,
              let fraction = progression.levelFraction,
              let remaining = progression.pointsRemaining else { return nil }
        // Même lecture que la jauge de GamificationView : avancement et restant
        // viennent du serveur.
        return (level, fraction, remaining)
    }

    private func statsCard(_ stats: UserStats?, progress: (level: Int, fraction: Double, remaining: Int)?) -> some View {
        VStack(spacing: SQSpace.md) {
            if let stats {
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
            }
            if let progress {
                if stats != nil {
                    Rectangle().fill(SQColor.separator).frame(height: 1).accessibilityHidden(true)
                }
                progressionRows(level: progress.level, fraction: progress.fraction, remaining: progress.remaining)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(SQSpace.lg)
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

    private func progressionRows(level: Int, fraction: Double, remaining: Int) -> some View {
        let progress = fraction
        let levelText = Text("Niveau \(level)")
            .font(SQType.callout(.bold))
            .foregroundStyle(SQColor.label)
        let pointsText = Text("Encore \(remaining.formatted()) pts")
            .font(SQType.callout)
            .monospacedDigit()
            .foregroundStyle(SQColor.label)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    levelText.accessibilityIdentifier("profile.progression.level")
                    pointsText.accessibilityIdentifier("profile.progression.points")
                }
            } else {
                HStack {
                    levelText.accessibilityIdentifier("profile.progression.level")
                    Spacer()
                    pointsText.accessibilityIdentifier("profile.progression.points")
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(SQColor.surfaceMuted)
                    if progress > 0 {
                        Capsule(style: .continuous)
                            .fill(SQColor.brandRed)
                            .frame(width: max(8, proxy.size.width * progress))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Progression · Niveau \(level)")
        .accessibilityValue("Encore \(remaining) points · \(Int(progress * 100)) %")
    }

    // MARK: - Menu
    //
    // Le menu ne garde QUE ce qui relève du profil : ce que l'utilisateur a
    // produit, et son compte. Le reste a rejoint l'onglet où on le cherche —
    // Carte ANFR et Statistiques ANFR dans Carte, Amis / Notifications /
    // Appels / Préférences du fil dans Communauté — et la progression est
    // remontée en tuiles sous l'en-tête, à côté du niveau qu'elle prolonge.

    private var menuCard: some View {
        VStack(spacing: SQSpace.lg) {
            let todos = overview?.todos ?? []
            if !todos.isEmpty {
                menuSection("À faire") {
                    ForEach(Array(todos.enumerated()), id: \.offset) { index, todo in
                        if index > 0 { menuSeparator }
                        todoLink(todo)
                    }
                }
            }

            // Remontés des Réglages (MES-21, TRX-22) : Sentinelle, l'une des
            // rares fonctions Premium utilisées, était à cinq niveaux.
            menuSection("Suivis") {
                Button { push(ProfileDestination.favorites) } label: {
                    FavoriteCountMenuRow(favorites: services.favoriteAntennas)
                }
                menuSeparator
                Button { push(ProfileDestination.sentinelle) } label: {
                    menuRow(title: "Sentinelle", icon: "wifi.router")
                }
            }

            menuSection("Contributions") {
                Button { push(ProfileDestination.measurements) } label: {
                    menuRow(title: "Mes mesures", icon: "mappin.and.ellipse")
                }
                menuSeparator
                Button { push(ProfileDestination.photos) } label: {
                    menuRow(title: "Photos", icon: "photo.stack")
                }
                menuSeparator
                Button { push(ProfileDestination.antennaReports) } label: {
                    menuRow(title: "Signalements d’antenne", icon: "exclamationmark.bubble")
                }
                menuSeparator
                Button { push(ProfileDestination.outages) } label: {
                    menuRow(title: "Pannes signalées", icon: "exclamationmark.triangle")
                }
                menuSeparator
                // Territoires : plus en tuile sous le niveau (décision du 29/09).
                Button { push(ProfileDestination.territories) } label: {
                    menuRow(title: "Territoires", icon: "square.grid.3x3")
                }
            }

            // Écrans nourris par l'app Android : affichés seulement si le compte
            // a de telles données, sinon une ligne dit ce qu'ils apportent.
            menuSection("Avec l’app Android") {
                if androidPresence.showsAndroidScreens {
                    Button { push(ProfileDestination.sessions) } label: {
                        menuRow(title: "Enregistrements de trajet", icon: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    menuSeparator
                    Button { push(ProfileDestination.radioLogs) } label: {
                        menuRow(title: "Logs antennes", icon: "antenna.radiowaves.left.and.right")
                    }
                    menuSeparator
                    Button { push(ProfileDestination.identifications) } label: {
                        menuRow(title: "Mes identifications", icon: "checkmark.seal")
                    }
                } else {
                    androidHint
                }
            }

            menuSection("Compte") {
                // Mise à jour facultative : une rangée discrète, sans bloquer l'app.
                if case .updateRecommended(_, let storeURL) = versionPolicy.state,
                   let updateURL = ForcedUpdateView.resolvedUpdateURL(storeURL: storeURL) {
                    Button { openURL(updateURL) } label: {
                        menuRow(title: "Mise à jour recommandée", icon: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isLink)
                    .accessibilityIdentifier("profile.updateRecommended")
                    menuSeparator
                }
                Button { push(ProfileDestination.settings) } label: {
                    menuRow(title: "Réglages", icon: "gearshape")
                }
                menuSeparator
                Button { push(ProfileDestination.privacy) } label: {
                    menuRow(title: "Confidentialité", icon: "hand.raised")
                }
                menuSeparator
                Button { push(ProfileDestination.subscription) } label: {
                    SubscriptionMenuRow(store: services.entitlements)
                }
                menuSeparator
                Button { push(ProfileDestination.glossary) } label: {
                    menuRow(title: "Aide et glossaire", icon: "questionmark.circle")
                }
                .accessibilityIdentifier("profile.glossary")
                menuSeparator
                Button { push(ProfileDestination.bugs) } label: {
                    menuRow(title: "Bugs et idées", icon: "ladybug",
                            subtitle: String(localized: "Signaler un problème, proposer une amélioration"),
                            badge: unseenBugReplies > 0 ? unseenBugReplies.formatted() : nil)
                }
                .accessibilityIdentifier("profile.bugs")
                // Réservé aux administrateurs ; le serveur refuse de toute façon les autres comptes.
                if case .authenticated(let user) = session.state, user.role == "admin" {
                    menuSeparator
                    Button { push(ProfileDestination.adminBugs) } label: {
                        menuRow(title: "Admin · bugs et retours", icon: "wrench.and.screwdriver",
                                subtitle: String(localized: "Trier et répondre à tous les signalements"))
                    }
                    .accessibilityIdentifier("profile.admin")
                }
            }
        }
    }

    /// « Se déconnecter » : une ligne rouge dans sa carte, toujours confirmée.
    private var logoutCard: some View {
        Button {
            Task {
                unsentMessages = await services.unsentMessageCount()
                confirmLogout = true
            }
        } label: {
            HStack(spacing: SQSpace.md) {
                if !dynamicTypeSize.isAccessibilitySize {
                    ProfileMenuIcon(systemImage: "rectangle.portrait.and.arrow.right",
                                    tint: SQColor.dangerInk, fill: SQColor.dangerSoft)
                }
                Text("Se déconnecter")
                    .font(SQFont.body(16, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.dangerInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLoggingOut {
                    ProgressView()
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoggingOut)
        .sqCardBackground()
        .accessibilityIdentifier("profile.logout")
        .confirmationDialog("Te déconnecter ?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) {
                guard !isLoggingOut else { return }
                isLoggingOut = true
                Task {
                    await session.logout()
                    isLoggingOut = false
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            if unsentMessages > 0 {
                Text("Il reste \(unsentMessages) messages non envoyés : ils seront supprimés de cet iPhone si tu te déconnectes. Annule pour leur laisser le temps de partir.")
            } else {
                Text("Tu pourras te reconnecter à tout moment avec ton compte.")
            }
        }
    }

    /// « SignalQuest 1.0 (169) », comme dans les réglages d'iOS.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "SignalQuest \(version) (\(build))"
    }

    /// Sans données Android : ce que l'app Android ajoute, plutôt que trois
    /// écrans vides. Le titre de la section dit déjà « Avec l’app Android ».
    private var androidHint: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            if !dynamicTypeSize.isAccessibilitySize {
                ProfileMenuIcon(systemImage: "iphone.gen3.radiowaves.left.and.right")
            }
            Text("Elle enregistre tes trajets, tient un journal des antennes captées et aide à les identifier. Ces écrans apparaissent ici dès qu’elle a envoyé des données.")
                .font(SQType.callout)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md)
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

    /// Une section du menu : surtitre Halo en petites capitales + carte.
    @ViewBuilder
    private func menuSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(LocalizedStringKey(title))
                .sqKicker()
                .padding(.leading, SQSpace.xs)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .sqCardBackground()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Progression : les écrans de jeu, en tuiles sous les points. Chaque
    /// tuile dit ce qui t'attend, quand on le sait.
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
        progressionTile("Récompenses", icon: "rosette", subtitle: missionsSubtitle, destination: .rewards)
        progressionTile("Classements", icon: "trophy", subtitle: weekRank.map { String(localized: "\($0)e de tes amis") },
                        destination: .leaderboards)
    }

    private var missionsSubtitle: String? {
        for todo in overview?.todos ?? [] {
            if case .claimMissions(let count, _) = todo, count > 0 {
                return String(localized: "\(count) missions à réclamer")
            }
        }
        return nil
    }

    private func progressionTile(
        _ title: String,
        icon: String,
        subtitle: String?,
        destination: ProfileDestination
    ) -> some View {
        Button { push(destination) } label: {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                ProfileMenuIcon(systemImage: icon, tint: SQColor.accentInk, fill: SQColor.accentSoft)
                    .padding(.bottom, SQSpace.xs)
                Text(LocalizedStringKey(title))
                    .font(SQFont.body(15, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.progression.tile.label.\(title)")
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(SQSpace.md)
            .sqCardBackground(cornerRadius: SQRadius.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityValue(subtitle.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("profile.progression.tile.\(title)")
    }

    private var menuSeparator: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(height: 1)
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? SQSpace.lg : ProfileMenuRow.separatorInset)
            .accessibilityHidden(true)
    }

    /// `subtitle` : précision sous le titre ; `badge` : compteur en pastille à
    /// droite, pour que le titre ne porte jamais le chiffre sur une 2e ligne.
    private func menuRow(title: String, icon: String, subtitle: String? = nil, badge: String? = nil) -> some View {
        ProfileMenuRow(title: title, icon: icon, subtitle: subtitle, badge: badge)
    }

    /// Une ligne « À faire », vers l'écran où la régler.
    @ViewBuilder
    private func todoLink(_ todo: UserOverview.Todo) -> some View {
        switch todo {
        case .claimMissions(let count, let rewardXp):
            Button { push(ProfileDestination.rewards) } label: {
                ProfileMenuRow(title: "Missions à réclamer", icon: "gift", subtitle: String(localized: "+\(rewardXp) pts"),
                               badge: count.formatted(), accentIcon: true)
            }
            .accessibilityIdentifier("profile.todo.missions")
        case .photosInReview(let count):
            Button { push(ProfileDestination.pendingPhotos) } label: {
                ProfileMenuRow(title: "Photos en vérification", icon: "hourglass", badge: count.formatted(), accentIcon: true)
            }
            .accessibilityIdentifier("profile.todo.photos")
        case .identificationConflicts(let count):
            Button { push(ProfileDestination.identifications) } label: {
                ProfileMenuRow(title: "Identifications en conflit", icon: "exclamationmark.triangle", badge: count.formatted(),
                               accentIcon: true)
            }
            .accessibilityIdentifier("profile.todo.identifications")
        }
    }

    @ViewBuilder
    private func destination(for destination: ProfileDestination) -> some View {
        switch destination {
        case .favorites:
            FavoriteAntennasView(favorites: services.favoriteAntennas) { favorite in
                router.route(toSite: favorite.siteId, market: favorite.market)
            }
        case .sentinelle: SentinelleView(service: services.sentinelle)
        case .measurements: MyMeasurementsView(service: services.sessions)
        case .photos: PhotosView(service: services.photos)
        case .pendingPhotos: PhotosView(service: services.photos, initialFilter: .pending)
        case .antennaReports: AntennaReportsListView(service: services.antennaReports)
        case .outages: CommunityOutagesListView(service: services.communityOutages, markets: services.markets)
        case .territories: TerritoriesView(service: services.gamification, markets: services.markets)
        case .sessions: SessionsListView(service: services.sessions)
        case .radioLogs:
            RadioLogsView(service: services.radioLogs, antennas: services.antennas, networkPath: services.networkPath)
        case .identifications: MyIdentificationsView(service: services.identify)
        case .settings: SettingsView(userService: services.users, authService: services.auth)
        case .privacy: PrivacySettingsView(service: services.privacy)
        case .subscription: PaywallView(store: services.entitlements, entryPoint: .profile)
        case .glossary: SQGlossaryView()
        case .bugs: BugReportsListView()
        case .adminBugs: AdminBugsView(service: services.adminBugs)
        case .rewards: GamificationView(service: services.gamification)
        case .leaderboards: LeaderboardsView(service: services.leaderboards, gamification: services.gamification, user: user)
        }
    }

    // MARK: - Données

    private func loadOverview() async {
        // Un échec laisse simplement la section absente : rien d'autre n'en dépend.
        if let value = try? await UserOverviewService(api: services.api).overview() {
            overview = value
        }
        if let reports = try? await services.bugReports.myReports() {
            unseenBugReplies = BugReportsSeenStore.unseenCount(in: reports)
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
            weekRank = 3
            return
        }
        async let weekTask = try? await services.leaderboards.pointsLeaderboard(period: "week", scope: "friends")
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
        // Un rang n'a de sens qu'à plusieurs : seul, la tuile reste sans sous-titre.
        if let week = await weekTask, week.entries.count > 1 {
            weekRank = week.currentUserRank ?? week.entries.first { $0.userId == user.id }?.rank
        }
    }
}

private extension View {
    /// Sous iOS 16, les écrans du Profil s'ouvrent en feuille (décision du
    /// 20/10). Les y pousser figeait l'app sur un iPhone 8 en 16.7, même après
    /// le passage au push par état : chien de garde 0x8BADF00D, fil principal
    /// pris dans une mise à jour de SwiftUI sans aucune de nos frames (pile
    /// MetricKit de la 177). Les feuilles du Profil, elles, n'ont jamais gelé.
    /// Le bouton retour des en-têtes (`dismiss`) ferme alors la feuille ; « Fermer »
    /// sert aux écrans qui gardent la barre de navigation.
    @ViewBuilder
    func profileDestinationCompat<Destination: View>(
        _ item: Binding<ProfileDestination?>,
        @ViewBuilder destination: @escaping (ProfileDestination) -> Destination
    ) -> some View {
        if #available(iOS 17.0, *) {
            navigationDestinationItemCompat(item, destination: destination)
        } else {
            sheet(isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            )) {
                if let value = item.wrappedValue {
                    NavigationStack {
                        destination(value)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Fermer") { item.wrappedValue = nil }
                                }
                            }
                    }
                    .id(value)
                }
            }
        }
    }
}

/// Écrans ouverts depuis le Profil, poussés par `pushed`.
private enum ProfileDestination: Hashable {
    case favorites, sentinelle, measurements, photos, pendingPhotos, antennaReports, outages, territories
    case sessions, radioLogs, identifications
    case settings, privacy, subscription, glossary, bugs, adminBugs
    case rewards, leaderboards
}

/// Petite icône de ligne Halo : glyphe dans un carré arrondi de 30 pt.
struct ProfileMenuIcon: View {
    let systemImage: String
    var tint: Color = SQColor.labelSecondary
    var fill: Color = SQColor.surfaceMuted

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Ligne du menu Profil : icône, titre (et sous-titre), valeur ou pastille,
/// chevron. Le titre reste aligné à gauche même sur deux lignes.
struct ProfileMenuRow: View {
    /// Retrait du filet : marge + icône + espacement, pour s'aligner sur le titre.
    static let separatorInset: CGFloat = SQSpace.lg + 30 + SQSpace.md
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let icon: String
    var subtitle: String?
    var value: String?
    var badge: String?
    var accentIcon = false

    var body: some View {
        HStack(spacing: SQSpace.md) {
            // En très grand texte, l'icône cède sa place au titre : « Sentinelle »
            // se coupait en « Senti-/nelle » (tour AX5, 30/09).
            if !dynamicTypeSize.isAccessibilitySize {
                ProfileMenuIcon(systemImage: icon,
                                tint: accentIcon ? SQColor.accentInk : SQColor.labelSecondary,
                                fill: accentIcon ? SQColor.accentSoft : SQColor.surfaceMuted)
            }
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(LocalizedStringKey(title))
                    .font(SQFont.body(16, .semibold, relativeTo: .body))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile.menu.title")
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("profile.menu.subtitle")
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(verbatim: value)
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("profile.menu.value")
            }
            if let badge {
                Text(verbatim: badge)
                    .font(SQType.caption(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.onAccent)
                    .padding(.horizontal, SQSpace.xs2)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(SQColor.brandRed, in: Capsule(style: .continuous))
                    .accessibilityIdentifier("profile.menu.badge")
            }
            Image(systemName: "chevron.right")
                .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.sm2)
        .frame(minHeight: subtitle == nil ? 52 : 58)
        .contentShape(Rectangle())
    }
}

/// « Antennes suivies » avec leur nombre, tenu à jour par le service.
private struct FavoriteCountMenuRow: View {
    @ObservedObject var favorites: FavoriteAntennasService

    var body: some View {
        ProfileMenuRow(title: "Antennes suivies", icon: "star",
                       value: favorites.hasLoaded ? favorites.favorites.count.formatted() : nil)
    }
}

/// « Abonnements » avec la formule, seulement quand le serveur l'a confirmée.
private struct SubscriptionMenuRow: View {
    @ObservedObject var store: EntitlementsStore

    var body: some View {
        ProfileMenuRow(title: "Abonnements", icon: "creditcard",
                       value: store.serverState.snapshot?.tier.displayName)
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

            GradientButton(String(localized: "Renvoyer le lien"), isBusy: isSending, style: .accent) {
                Task { await resend() }
            }
            .disabled(isSending || isRefreshing)
            .accessibilityIdentifier("profile.emailVerification.resend")

            GradientButton(String(localized: "J’ai confirmé"), style: .secondary) {
                Task { await refresh() }
            }
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
        // `refreshUser()` avale l'échec : on appelle la variante qui le remonte,
        // pour ne pas répondre « encore en attente » faute de réseau.
        let auth = services.auth
        let account = LocalAccountScope.sessionSnapshot()
        let generation = auth.credentialSessionID()
        do {
            try await session.refreshUser(expectedUserID: userID, isCurrent: {
                LocalAccountScope.sessionSnapshot() == account && auth.credentialSessionID() == generation
            }, fetchUser: { try await auth.me() })
        } catch {
            guard !error.isCancellation, isCurrentAccount else { return }
            feedback = String(localized: "Actualisation impossible. Vérifie ta connexion puis réessaie.")
            feedbackIsError = true
            return
        }
        guard isCurrentAccount else { return }
        feedback = String(localized: "Confirmation encore en attente. Ouvre le lien reçu puis actualise.")
        feedbackIsError = false
    }
}
