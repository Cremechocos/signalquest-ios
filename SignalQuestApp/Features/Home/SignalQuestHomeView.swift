import SwiftUI
import CoreLocation

/// Accueil Halo modulable : une suite de modules que chaque compte choisit, range et
/// dimensionne (« Modifier l'accueil »). Par défaut, la communauté passe devant : pannes
/// proches, ce qui bouge sur le réseau, le fil et la semaine.
///
/// « Mon réseau » ne montre que ce qu'iOS sait vraiment : le type de connexion, la
/// génération et l'opérateur, signalé comme estimé. Aucune valeur radio ici ; l'avis de la
/// communauté tient en une ligne et s'explique dans « D'où vient ce verdict ».
struct SignalQuestHomeView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let user: AuthUser?

    @State private var layout = HomeLayoutStore.layout()
    @State private var showEditor = false

    @State private var latestMeasurement: SpeedtestRunResult?
    @State private var networkStatus: NetworkPathStatus = .unknown
    /// `nil` = pas encore chargées ; vide = rien d'assez récent à moins d'un kilomètre.
    @State private var nearbyMeasures: [AndroidSpeedtestMarker]?
    @State private var userLocation: CLLocation?
    /// Verdict de qualité réseau (opérateur identifié, données communautaires).
    /// `nil` = pas encore chargé ou zone sans mesures : la ligne du verdict se tait.
    @State private var networkQuality: NearbyNetworkQuality?
    @State private var showQualityDetail = false
    @State private var comparisonMetric: NearbyOperatorMetric = .download
    @State private var showOperatorComparison = false
    /// Horodatage du dernier rafraîchissement réel des données de zone (throttle des
    /// refetch à chaque retour au premier plan ou sur l'onglet — PERF-HOME-01).
    @State private var lastNearbyRefreshAt: Date = .distantPast
    /// Pannes ouvertes à moins de 5 km, la plus proche d'abord. `nil` = pas encore chargées.
    @State private var nearbyOutages: [CommunityOutage]?
    @State private var showOutages = false
    /// Échecs des modules de zone : sans eux, un fix de position manqué ou une requête en erreur
    /// laisserait le squelette affiché indéfiniment. Remis à faux à chaque nouvelle tentative.
    @State private var locationFixFailed = false
    @State private var outagesFailed = false
    @State private var evolutionsFailed = false
    /// Sites prévus ou en cours d'activation à moins de 5 km. `nil` = pas encore chargés.
    @State private var evolutions: [PlannedSiteLive]?
    @State private var lastEvolutionsRefreshAt: Date = .distantPast
    @State private var operatorStats: [OperatorMetricStat]?
    @State private var marketEntry: MarketRegistryEntry?
    /// Dernier test du compte côté serveur : l'historique local est vide après une
    /// réinstallation ou sur un nouvel iPhone, et ne voit pas les tests faits sur
    /// Android (UI-06, UI-12).
    @State private var accountLatest: SocialShareableSpeedtest?
    @State private var lastAccountRefreshAt: Date = .distantPast
    @State private var stories: [SocialStory] = []
    @State private var trending: [TrendingHashtag] = []
    @State private var week: WeekSummary?
    @State private var showLeaderboards = false
    @State private var liveFriends: [SocialFriendLive]?
    @State private var lastSocialRefreshAt: Date = .distantPast
    /// Suit l'autorisation de localisation pour proposer de l'activer (TRX-19).
    /// `nil` tant que le service ne l'a pas encore publiée.
    @State private var locationStatus: CLAuthorizationStatus?
    @State private var showSignup = false
    /// Zone hors des marchés du registre : les modules de zone le disent au lieu d'un « rien à signaler ».
    @State private var marketUncovered = false

    /// La semaine du compte dans le classement de ses amis.
    struct WeekSummary: Equatable {
        let points: Int?
        let rank: Int?
        let friendsCount: Int
    }

    /// Rayon des mesures, du verdict et de la comparaison (1 km).
    private static let nearbyRadiusMeters = 1000
    /// Demi-fenêtre englobant le cercle de 1 km (le filtrage distance affine ensuite).
    private static let nearbyHalfSpanLat = 0.011
    private static let nearbyHalfSpanLng = 0.016
    /// Rayon des pannes et des évolutions : une coupure porte sur une CELLULE, et on peut être
    /// servi par un pylône à plusieurs kilomètres.
    private static let wideRadiusMeters = 5000.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                if user == nil {
                    guestContent
                } else {
                    modulesContent
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
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
        .onChangeCompat(of: user?.id) { _, _ in
            // Inscription réussie depuis l'Accueil invité : la feuille n'a plus lieu d'être.
            if user != nil { showSignup = false }
            layout = HomeLayoutStore.layout()
            Task { await refresh(forceFresh: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: HomeLayoutStore.didChange)) { _ in
            layout = HomeLayoutStore.layout()
        }
        .onReceive(services.location.$authorizationStatus) { status in
            let previous = locationStatus
            locationStatus = status
            // Autorisation tout juste accordée : les modules de zone se remplissent sans
            // attendre le prochain retour sur l'onglet. La première valeur reçue n'est pas
            // un changement : `.task` charge déjà l'écran.
            if let previous, !Self.isAuthorized(previous), Self.isAuthorized(status) {
                Task { await refreshNearby(forceFresh: true) }
            }
        }
        .navigationDestination(isPresented: $showOutages) {
            CommunityOutagesListView(service: services.communityOutages, markets: services.markets)
        }
        .navigationDestination(isPresented: $showLeaderboards) {
            if let user {
                LeaderboardsView(service: services.leaderboards, gamification: services.gamification, user: user)
            }
        }
        .sheet(isPresented: $showEditor) {
            HomeLayoutEditor(initial: layout) { edited in
                HomeLayoutStore.save(edited)
                layout = edited.reconciled()
                Task { await refresh(forceFresh: true) }
            }
        }
        .sheet(isPresented: $showQualityDetail) {
            if let quality = networkQuality {
                NearbyNetworkQualityDetailSheet(quality: quality)
            }
        }
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
        .sheet(isPresented: $showSignup) {
            NavigationStack { SignupView() }
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    private var currentLocationStatus: CLAuthorizationStatus {
        locationStatus ?? services.location.authorizationStatus
    }

    /// Sans position et sans autorisation : les modules de zone le disent au lieu de rester vides.
    private var needsLocation: Bool {
        userLocation == nil && (currentLocationStatus == .notDetermined || currentLocationStatus == .denied
                                || locationRestricted)
    }

    /// Contrôle parental ou gestion de l'appareil : l'utilisateur ne peut pas l'accorder lui-même.
    private var locationRestricted: Bool { currentLocationStatus == .restricted }

    /// Message d'un module de zone sans position ; la restriction n'a pas de réglage à ouvrir.
    private func locationNeededMessage(_ text: LocalizedStringKey) -> some View {
        moduleMessage(locationRestricted ? "La localisation est restreinte sur cet appareil." : text)
    }

    private var firstName: String? {
        user?.name?.split(separator: " ").first.map(String.init)
    }

    /// Sans prénom, la salutation reste complète plutôt que « Bonjour, à toi ».
    private var greeting: Text {
        if let firstName { return Text("Bonjour, \(firstName)") }
        return Text("Bonjour")
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .bottom, spacing: SQSpace.md) {
            if user == nil {
                // Invité : le logo, pas un faux avatar « S ».
                Image("SQLogoMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if user == nil {
                    Text("Bienvenue sur").sqKicker()
                    Text(verbatim: "SignalQuest")
                        .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                } else {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).sqKicker()
                    greeting
                        .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(SQColor.label)
                        // Aux grandes tailles, le prénom rétrécit plutôt que de se couper (UI-16) ;
                        // aux tailles d'accessibilité, il passe à la ligne à pleine taille : le
                        // réduire annulerait le réglage qu'on vient de choisir.
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.6)
                        .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.greeting")
            Spacer(minLength: 0)
            if user != nil { notificationsButton }
        }
        .padding(.top, SQSpace.xs)
    }

    private var notificationsButton: some View {
        NavigationLink {
            NotificationsCenterView(service: services.notifications, badge: services)
        } label: {
            Image(systemName: "bell")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.surface, in: Circle())
                .sqShadowSoft()
                .overlay(alignment: .topTrailing) {
                    if services.unreadNotifications > 0 {
                        SQCountBadge(count: services.unreadNotifications)
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Notifications")
        .accessibilityValue(services.unreadNotifications > 0 ? Text(services.unreadNotifications, format: .number) : Text(""))
        .accessibilityIdentifier("home.notifications")
    }

    // MARK: Modules

    @ViewBuilder
    private var modulesContent: some View {
        let rows = layout.rows(pairingSmall: !dynamicTypeSize.isAccessibilitySize)
        if rows.isEmpty {
            moduleCard {
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Ton accueil est vide")
                        .font(SQType.stateTitle)
                        .foregroundStyle(SQColor.label)
                    Text("Ajoute les modules qui t’intéressent : ton réseau, les pannes proches, la communauté…")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        ForEach(rows, id: \.first?.id) { row in
            if row.count == 2 {
                // Deux « Petit » côte à côte, de même hauteur.
                HStack(alignment: .top, spacing: SQSpace.md) {
                    module(row[0]).frame(maxHeight: .infinity)
                    module(row[1]).frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let entry = row.first {
                module(entry)
            }
        }
        editButton
    }

    @ViewBuilder
    private func module(_ entry: HomeModuleEntry) -> some View {
        Group {
            switch entry.module {
            case .network: networkModule
            case .outages: outagesModule
            case .latestTest: latestTestModule(size: entry.size)
            case .week: weekModule(size: entry.size)
            case .evolutions: evolutionsModule
            case .community: communityModule
            case .followedSites:
                HomeFollowedSitesModule(favorites: services.favoriteAntennas, registry: marketEntry)
            case .operators: operatorsModule
            case .nearbyMeasures: nearbyMeasuresModule
            case .liveFriends: liveFriendsModule
            case .shortcuts: shortcutsModule
            }
        }
        // L'appui long ouvre le menu natif du module : l'entrée en édition, sa taille, son retrait.
        .contextMenu {
            Button {
                showEditor = true
            } label: {
                Label("Modifier l’accueil", systemImage: "pencil")
            }
            if entry.module.supportedSizes.count > 1 {
                Button {
                    updateLayout { $0.toggleSize(entry.module) }
                } label: {
                    Label(entry.size == .small ? "Passer en Large" : "Passer en Petit",
                          systemImage: entry.size == .small ? "rectangle" : "square.split.2x1")
                }
            }
            Button(role: .destructive) {
                updateLayout { $0.remove(entry.module) }
            } label: {
                Label("Retirer de l’accueil", systemImage: "minus.circle")
            }
        }
    }

    private func updateLayout(_ change: (inout HomeLayout) -> Void) {
        var edited = layout
        change(&edited)
        HomeLayoutStore.save(edited)
        layout = edited.reconciled()
    }

    private var editButton: some View {
        Button {
            Haptics.selection()
            showEditor = true
        } label: {
            Label("Modifier l’accueil", systemImage: "pencil")
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.lg)
                .frame(minHeight: 44)
                .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
                .overlay { Capsule(style: .continuous).strokeBorder(SQColor.separator, lineWidth: 1) }
        }
        .buttonStyle(SQPressButtonStyle(scale: 0.97))
        .frame(maxWidth: .infinity)
        .padding(.top, SQSpace.xs)
        .accessibilityIdentifier("home.editLayout")
    }

    /// Carte Halo d'un module : surface blanche, 16 pt de marge, contenu aligné à gauche.
    private func moduleCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) { content() }
            .padding(SQSpace.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sqCardBackground()
    }

    /// Surtitre d'un module : icône, nom en capitales, et ce qui se range à droite.
    private func moduleHeader<Trailing: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SQColor.ink2)
                .accessibilityHidden(true)
            Text(title).sqKicker()
                .foregroundStyle(SQColor.ink2)
                .sqHeader()
            Spacer(minLength: SQSpace.sm)
            trailing()
        }
    }

    private func distanceText(to latitude: Double?, _ longitude: Double?) -> String? {
        guard let latitude, let longitude, let userLocation else { return nil }
        return SQUnits.distance(meters: userLocation.distance(from: CLLocation(latitude: latitude, longitude: longitude)))
    }

    private func operatorLabel(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return MarketRegistryEntry.operatorLabel(key, in: marketEntry)
    }

    private func opBar(_ name: String?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(SQBrand.operatorColor(name))
            .frame(width: 4, height: height)
            .accessibilityHidden(true)
    }

    private func chevron() -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SQColor.labelTertiary)
            .accessibilityHidden(true)
    }

    /// Message d'un module sans donnée : une ligne, à l'encre secondaire.
    private func moduleMessage(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(SQType.callout)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Module de zone dont le chargement a échoué : une ligne sobre et, tant qu'on peut
    /// relancer, un bouton pour réessayer (jamais un squelette qui ne finit pas).
    private func moduleFailure() -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            moduleMessage("Indisponible pour l’instant")
            Button {
                Haptics.selection()
                Task { await refreshNearby(forceFresh: true) }
            } label: {
                Text("Réessayer")
                    .font(SQType.callout(.bold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func loadingRows(_ count: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: SQSpace.md) {
                    Circle().fill(SQColor.skeleton).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: 180, height: 10, radius: 5)
                        SkeletonBlock(width: 120, height: 8, radius: 4)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chargement…")
    }

    // MARK: Mon réseau

    private var isOnline: Bool { services.networkPath.isOnline }

    /// L'opérateur n'a de sens qu'en cellulaire ; il reste « estimé » (IP/ASN ou SIM).
    private var cellularOperator: String? {
        guard networkStatus.connection == .cellular else { return nil }
        return networkQuality?.operatorLabel ?? networkStatus.operatorName
    }

    /// « 5G » suffit en un coup d'œil : la nuance NSA/SA reste aux écrans de mesure (TRX-28).
    private var generation: String? {
        networkStatus.cellularTechnology.map { $0 == .fiveGNSA || $0 == .fiveGSA ? "5G" : $0.displayName }
    }

    private var networkTitle: String {
        guard isOnline else { return String(localized: "Hors connexion") }
        if networkStatus.isConstrained { return String(localized: "Réseau limité") }
        switch networkStatus.connection {
        case .cellular: return cellularOperator ?? String(localized: "Cellulaire")
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        case .other: return String(localized: "Connecté")
        }
    }

    private var networkSubtitle: String {
        guard isOnline else { return String(localized: "Vérifie ta connexion") }
        if networkStatus.isConstrained { return String(localized: "Mode données réduites activé") }
        switch networkStatus.connection {
        case .cellular:
            switch (generation, cellularOperator) {
            case let (tech?, _?): return String(localized: "Connecté en \(tech) · opérateur estimé")
            case let (tech?, nil): return String(localized: "Connecté en \(tech)")
            case (nil, _?): return String(localized: "Connecté · opérateur estimé")
            case (nil, nil): return String(localized: "Connecté")
            }
        case .wifi, .wired: return String(localized: "Connecté")
        case .other: return String(localized: "Connexion inconnue")
        }
    }

    private var networkModule: some View {
        moduleCard {
            HStack(spacing: SQSpace.md) {
                networkSquare
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        if let cellularOperator, isOnline, !networkStatus.isConstrained {
                            opBar(cellularOperator, height: 16)
                        }
                        Text(verbatim: networkTitle)
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                            .lineLimit(2)
                            .accessibilityIdentifier("home.network.title")
                    }
                    Text(verbatim: networkSubtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.network.subtitle")
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize { testButton }
            }
            if dynamicTypeSize.isAccessibilitySize { testButton }
            if !isOnline {
                Text("Disponible au retour du réseau. Le verdict et les mesures autour de toi reviendront d’eux-mêmes.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if user == nil {
                Text("Le test fonctionne sans compte.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
            } else if needsLocation {
                locationTile
            } else if let quality = networkQuality, quality.level != .unknown, !networkStatus.isConstrained {
                Divider().overlay(SQColor.separator)
                verdictRow(quality)
            }
        }
    }

    @ViewBuilder
    private var networkSquare: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if !isOnline {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SQColor.dangerInk)
                    .frame(width: 48, height: 48)
                    .background(SQColor.dangerSoft, in: shape)
            } else if networkStatus.isConstrained {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(OutageTint.degradedInk)
                    .frame(width: 48, height: 48)
                    .background(SQColor.warningSoft, in: shape)
            } else if networkStatus.connection == .cellular, let generation {
                Text(verbatim: generation)
                    .font(SQFont.display(15, .bold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 48, height: 48)
                    .sqSurface(SQColor.chip, in: shape)
            } else {
                Image(systemName: networkStatus.connection == .cellular ? "antenna.radiowaves.left.and.right"
                      : networkStatus.connection == .wired ? "cable.connector" : "wifi")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 48, height: 48)
                    .sqSurface(SQColor.chip, in: shape)
            }
        }
        .accessibilityHidden(true)
    }

    /// « Tester », l'action principale de l'accueil : pilule d'encre, grisée hors connexion.
    private var testButton: some View {
        Button {
            Haptics.medium()
            router.selectedTab = .speed
        } label: {
            Label("Tester", systemImage: "speedometer")
                .font(SQType.button)
                .foregroundStyle(SQColor.onInk)
                .padding(.horizontal, SQSpace.lg)
                .frame(minHeight: 44)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                .background(SQColor.label, in: Capsule(style: .continuous))
                .opacity(isOnline ? 1 : 0.46)
        }
        .buttonStyle(SQPressButtonStyle(scale: 0.97))
        .disabled(!isOnline)
        .accessibilityLabel("Tester mon débit")
        // Ancre STABLE des tests UI : le libellé change avec la langue, pas l'identifiant.
        .accessibilityIdentifier("home.action.speedtest")
    }

    private func verdictTitle(_ level: CoverageQualityBand) -> String {
        switch level {
        case .excellent: return String(localized: "Réseau au top ici")
        case .good: return String(localized: "Bon réseau ici")
        case .fair: return String(localized: "Réseau correct ici")
        case .weak: return String(localized: "Réseau faible ici")
        case .poor: return String(localized: "Réseau très faible ici")
        case .noService: return String(localized: "Sans réseau constaté ici")
        case .unknown: return String(localized: "Réseau")
        }
    }

    /// L'avis de la communauté, en une ligne, avec sa source. Le détail (signal, débit, règle)
    /// vit dans « D'où vient ce verdict ».
    private func verdictRow(_ quality: NearbyNetworkQuality) -> some View {
        // Hors cellulaire, l'opérateur n'est pas celui de la connexion : on le nomme.
        let count = String(localized: "selon \(quality.sampleCount) mesures de la communauté")
        let source = networkStatus.connection == .cellular
            ? count
            : String(localized: "pour \(quality.operatorLabel)") + ", " + count
        return Button {
            Haptics.selection()
            showQualityDetail = true
        } label: {
            HStack(spacing: SQSpace.sm) {
                Circle()
                    .fill(quality.level.swiftUIColor)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                (Text(verbatim: verdictTitle(quality.level)).font(SQType.callout(.bold)).foregroundColor(SQColor.label)
                 + Text(verbatim: " " + source).font(SQType.callout).foregroundColor(SQColor.ink2))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.network.verdict.text")
                Spacer(minLength: 0)
                chevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(verdictTitle(quality.level)), \(source)"))
        .accessibilityHint("Comprendre d’où vient ce verdict")
        .accessibilityIdentifier("home.network.verdict")
    }

    /// Sans position, les modules de zone ne peuvent rien montrer : on le dit, avec le geste
    /// qui le règle. La demande système ne part que sur ce bouton, jamais d'elle-même (UXP-01) ;
    /// refusée, elle ne reviendrait plus : le bouton ouvre alors les Réglages.
    private var locationTile: some View {
        let denied = currentLocationStatus == .denied
        let restricted = locationRestricted
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: denied || restricted ? "location.slash" : "location")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SQColor.ink2)
                    .accessibilityHidden(true)
                Text("Le réseau autour de toi")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
            }
            Text(restricted
                 ? "La localisation est restreinte sur cet appareil (contrôle parental ou gestion de l’appareil) : SignalQuest ne peut pas l’utiliser."
                 : denied
                 ? "La localisation est désactivée pour SignalQuest. Active-la dans les Réglages pour voir le verdict, les pannes et les mesures autour de toi."
                 : "Autorise la localisation pour voir le verdict, les pannes et l’opérateur le plus rapide autour de toi.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !restricted {
                GradientButton(denied ? "Ouvrir les Réglages" : "Activer la localisation", style: .secondary) {
                    if denied {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } else {
                        services.location.requestWhenInUse()
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("home.location.enable")
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    // MARK: Pannes près de toi

    private var outagesModule: some View {
        moduleCard {
            moduleHeader("Pannes près de toi", systemImage: "exclamationmark.triangle") {
                Text(verbatim: SQUnits.distanceCompact(meters: Self.wideRadiusMeters))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
            }
            if let outages = nearbyOutages {
                if marketUncovered {
                    moduleMessage("SignalQuest ne couvre pas encore cette zone.")
                } else if outages.isEmpty {
                    HStack(spacing: SQSpace.sm2) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(OutageTint.resolvedInk)
                            .accessibilityHidden(true)
                        Text("Aucune panne signalée autour de toi")
                            .font(SQType.callout(.semibold))
                            .foregroundStyle(SQColor.label)
                    }
                } else {
                    ForEach(outages.prefix(2)) { outage in
                        outageRow(outage)
                    }
                    if outages.count > 2 {
                        Button {
                            showOutages = true
                        } label: {
                            Text("Voir les \(outages.count) pannes")
                                .font(SQType.callout(.bold))
                                .foregroundStyle(SQColor.accentInk)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if needsLocation {
                locationNeededMessage("Active la localisation pour voir les pannes autour de toi.")
            } else if locationFixFailed || outagesFailed {
                moduleFailure()
            } else {
                loadingRows()
            }
        }
        .accessibilityIdentifier("home.module.outages")
    }

    /// Plein si la panne est confirmée, évidé tant qu'elle n'est que signalée ; rouge sans
    /// service, ambre en service dégradé.
    private func outageRow(_ outage: CommunityOutage) -> some View {
        let confirmed = outage.state == .confirmed
        let tint = OutageTint.of(outage.severity)
        let what = outage.severity == .degraded
            ? String(localized: "service dégradé")
            : String(localized: "aucun service")
        let title = [operatorLabel(outage.operatorKey), what].compactMap { $0 }.joined(separator: " · ")
        let state = confirmed
            ? String(localized: "confirmée")
            : SignalFormatters.date(outage.startedAt, includingTime: true, relative: true)
                .map { String(localized: "signalée \($0)") } ?? String(localized: "signalée")
        let place = outage.address ?? outage.siteName
        let subtitle = [place, distanceText(to: outage.latitude, outage.longitude), state]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return Button {
            Haptics.selection()
            router.route(toCommunityOutage: outage)
        } label: {
            HStack(spacing: SQSpace.md) {
                ZStack {
                    if confirmed {
                        Circle().fill(tint)
                    } else {
                        Circle().strokeBorder(tint, lineWidth: 2.5)
                    }
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(confirmed ? SQColor.surface : OutageTint.inkOf(outage.severity))
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: subtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                chevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre la panne sur la carte")
    }

    // MARK: Ton test

    /// Ce que montre « Ton test », quelle que soit sa source.
    private struct DisplayedMeasurement {
        let date: Date?
        let downloadMbps: Double
        let latencyMs: Double?
        let technology: String?
        let operatorName: String?
    }

    /// Le test le plus récent entre l'historique local, le plus détaillé, et le
    /// compte, qui voit aussi les tests d'un autre appareil ou d'avant une
    /// réinstallation (UI-06, UI-12).
    private var displayedMeasurement: DisplayedMeasurement? {
        let local = latestMeasurement.map {
            DisplayedMeasurement(date: $0.createdAt, downloadMbps: $0.downloadAverageMbps,
                                 latencyMs: $0.primaryPingMs, technology: measurementTech($0),
                                 operatorName: $0.networkOperatorName)
        }
        let account = accountLatest.flatMap { test -> DisplayedMeasurement? in
            guard let download = test.downloadAverageMbps else { return nil }
            return DisplayedMeasurement(date: test.timestamp, downloadMbps: download, latencyMs: test.ping,
                                        technology: TechAccent.shortLabel(for: test.networkType),
                                        operatorName: test.mobileOperator)
        }
        guard let account else { return local }
        guard let local, let localDate = local.date else { return account }
        // Le même test, envoyé au serveur, revient avec quelques secondes d'écart :
        // le local, plus détaillé, garde la priorité à égalité.
        if let accountDate = account.date, accountDate > localDate.addingTimeInterval(60) { return account }
        return local
    }

    /// Capsule techno du dernier test : « 5G » / « 4G » / « Wi-Fi ».
    private func measurementTech(_ measurement: SpeedtestRunResult) -> String? {
        if let tech = measurement.cellularTechnology?.displayName {
            return tech.hasPrefix("5G") ? "5G" : tech
        }
        switch measurement.connectionType {
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        default: return nil
        }
    }

    /// Grand chiffre Halo : valeur 26/800 et unité grise.
    private func bigValue(_ value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: value)
                .font(SQFont.display(26, .bold, relativeTo: .title))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let unit {
                Text(verbatim: unit)
                    .font(SQType.caption(.semibold))
                    .foregroundStyle(SQColor.ink2)
            }
        }
    }

    private func latestTestModule(size: HomeModuleSize) -> some View {
        Button {
            Haptics.selection()
            router.selectedTab = .speed
        } label: {
            moduleCard {
                moduleHeader(size == .small ? "Ton test" : "Ton dernier test", systemImage: "speedometer")
                if let measurement = displayedMeasurement {
                    let line = [
                        [measurement.technology, measurement.operatorName].compactMap { $0 }.joined(separator: " "),
                        measurement.date.map { $0.formatted(.relative(presentation: .named)) },
                    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    HStack(alignment: .firstTextBaseline) {
                        // Un débit nul est un test sans mesure : « — », pas « 0,0 Mbit/s ».
                        if measurement.downloadMbps > 0 {
                            bigValue(SQUnits.throughputValue(mbps: measurement.downloadMbps),
                                     unit: SQUnits.throughputUnit(mbps: measurement.downloadMbps))
                        } else {
                            bigValue("—", unit: nil)
                        }
                        if size == .large, let latency = measurement.latencyMs {
                            Spacer(minLength: SQSpace.sm)
                            Text(verbatim: SQUnits.milliseconds(latency))
                                .font(SQType.caption(.semibold))
                                .foregroundStyle(SQColor.label)
                                .padding(.horizontal, SQSpace.sm2)
                                .padding(.vertical, SQSpace.xs)
                                .sqSurface(SQColor.chip, in: Capsule(style: .continuous))
                        }
                    }
                    Text(verbatim: line)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    bigValue("—", unit: nil)
                    Text("Lance un premier test pour créer ton repère.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre le Speedtest")
        .accessibilityIdentifier("home.latestMeasurement")
    }

    // MARK: Ta semaine

    private func weekModule(size: HomeModuleSize) -> some View {
        Button {
            Haptics.selection()
            showLeaderboards = true
        } label: {
            moduleCard {
                moduleHeader("Ta semaine", systemImage: "trophy")
                bigValue(week?.points.map { $0.formatted(.number) } ?? "—", unit: String(localized: "pts"))
                Text(verbatim: weekLine)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre les classements")
        .accessibilityIdentifier("home.module.week")
    }

    private var weekLine: String {
        guard let week else { return String(localized: "Classement de tes amis") }
        if let rank = week.rank, week.friendsCount > 1 {
            return String(localized: "\(rank)e de tes amis")
        }
        return String(localized: "Invite des amis pour te comparer")
    }

    // MARK: Ça bouge près de toi

    private var evolutionsModule: some View {
        moduleCard {
            moduleHeader("Ça bouge près de toi", systemImage: "sparkles")
            if let sites = evolutions {
                if marketUncovered {
                    moduleMessage("SignalQuest ne couvre pas encore cette zone.")
                } else if sites.isEmpty {
                    moduleMessage("Rien de nouveau déclaré autour de toi pour l’instant.")
                } else {
                    ForEach(sites.prefix(3), id: \.id) { site in
                        evolutionRow(site)
                    }
                }
            } else if needsLocation {
                locationNeededMessage("Active la localisation pour voir les sites qui évoluent autour de toi.")
            } else if locationFixFailed || evolutionsFailed {
                moduleFailure()
            } else {
                loadingRows()
            }
        }
        .accessibilityIdentifier("home.module.evolutions")
    }

    private func evolutionRow(_ site: PlannedSiteLive) -> some View {
        let name = operatorLabel(site.operator) ?? String(localized: "Opérateur")
        let pending = site.activation?.pendingTechnologies ?? []
        let upgrade = site.activation?.status == .upgradePending ? Self.highestGeneration(pending) : nil
        let title = upgrade.map { String(localized: "\(name) passe en \($0)") }
            ?? String(localized: "Nouveau site \(name)")
        let status: String = {
            switch site.activation?.status {
            case .upgradePending: return String(localized: "activation déclarée")
            case .declared: return String(localized: "déclaré à l’ANFR")
            default: return String(localized: "prévu par l’opérateur")
            }
        }()
        let subtitle = [site.commune, distanceText(to: site.lat, site.lon), status]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return Button {
            Haptics.selection()
            if let lat = site.lat, let lon = site.lon {
                router.pendingMapFocus = Coordinates(latitude: lat, longitude: lon)
                router.pendingMapLayer = .planned
            }
            router.selectedTab = .map
        } label: {
            HStack(spacing: SQSpace.md) {
                Group {
                    if let upgrade {
                        TechBadge(text: upgrade, color: TechAccent.color(for: upgrade))
                    } else {
                        Text("Prévu")
                            .font(SQType.chip)
                            .foregroundStyle(SQColor.chipInk)
                            .padding(.horizontal, SQSpace.sm2)
                            .padding(.vertical, SQSpace.xs2)
                            .sqSurface(SQColor.chip, in: Capsule(style: .continuous))
                    }
                }
                .fixedSize()
                // Même colonne pour « 5G » et « Prévu » : les titres restent alignés.
                .frame(minWidth: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: subtitle)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.evolution.subtitle")
                }
                Spacer(minLength: 0)
                chevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Montre le site sur la carte")
    }

    /// La génération la plus récente parmi des jetons comme « 4G », « 5G ».
    static func highestGeneration(_ technologies: [String]) -> String? {
        // « 5G 3500 » ou « 2G/3G » : seuls les chiffres collés à un « G » sont une génération.
        technologies
            .flatMap { token -> [Int] in
                var found: [Int] = []
                var rest = token.uppercased()[...]
                while let range = rest.range(of: #"\d{1,2}G"#, options: .regularExpression) {
                    if let generation = Int(rest[range].dropLast()) { found.append(generation) }
                    rest = rest[range.upperBound...]
                }
                return found
            }
            .max()
            .map { "\($0)G" }
    }

    // MARK: Communauté

    /// Une bulle par membre : sa story la plus récente, cerclée tant qu'il en reste à voir.
    private var storyAuthors: [(story: SocialStory, viewed: Bool)] {
        let hidden = HiddenStoryAuthorsStore.hiddenIds()
        var order: [String] = []
        var byAuthor: [String: (story: SocialStory, viewed: Bool)] = [:]
        for story in stories where story.isMine != true && !hidden.contains(story.author.id) {
            let viewed = story.viewedByMe == true
            if let existing = byAuthor[story.author.id] {
                byAuthor[story.author.id] = (existing.story, existing.viewed && viewed)
            } else {
                order.append(story.author.id)
                byAuthor[story.author.id] = (story, viewed)
            }
        }
        return order.compactMap { byAuthor[$0] }.sorted { !$0.viewed && $1.viewed }
    }

    private var communityModule: some View {
        moduleCard {
            moduleHeader("Communauté", systemImage: "person.2") {
                Button {
                    Haptics.selection()
                    router.selectedTab = .community
                } label: {
                    HStack(spacing: SQSpace.xs) {
                        Text("Le fil").font(SQType.caption(.bold)).foregroundStyle(SQColor.ink2)
                        chevron()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ouvrir le fil")
            }
            .padding(.vertical, -SQSpace.sm)
            let authors = storyAuthors
            if !authors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: SQSpace.sm) {
                        ForEach(authors.prefix(10), id: \.story.id) { item in
                            Button {
                                Haptics.light()
                                router.selectedTab = .community
                            } label: {
                                StoryBubble(story: item.story, viewed: item.viewed)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Story de \(item.story.author.displayName)")
                            .accessibilityValue(item.viewed ? "Déjà vue" : "Pas encore vue")
                            .accessibilityHint("Ouvre le fil")
                        }
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            if !trending.isEmpty {
                Button {
                    Haptics.selection()
                    router.selectedTab = .community
                } label: {
                    // Autant de tendances que la largeur en tient, jamais une coupée.
                    ViewThatFits(in: .horizontal) {
                        trendingRow(3)
                        trendingRow(2)
                        trendingRow(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Ouvre le fil")
            }
            if authors.isEmpty && trending.isEmpty {
                moduleMessage("Les mesures, pannes et photos partagées par la communauté se retrouvent dans le fil.")
            }
        }
        .accessibilityIdentifier("home.module.community")
    }

    private func trendingRow(_ count: Int) -> some View {
        HStack(spacing: SQSpace.xs2) {
            Text("Tendances")
                .font(SQType.caption(.semibold))
                .foregroundStyle(SQColor.ink2)
                .fixedSize()
            ForEach(trending.prefix(count)) { tag in
                Text(verbatim: tag.tag.hasPrefix("#") ? tag.tag : "#\(tag.tag)")
                    .font(SQType.chip)
                    .foregroundStyle(SQColor.chipInk)
                    .fixedSize()
                    .padding(.horizontal, SQSpace.sm2)
                    .padding(.vertical, SQSpace.xs2)
                    .sqSurface(SQColor.chip, in: Capsule(style: .continuous))
            }
        }
    }

    // MARK: Opérateurs ici

    private var operatorsModule: some View {
        moduleCard {
            moduleHeader("Opérateurs ici", systemImage: "chart.bar") {
                Text(verbatim: SQUnits.distanceCompact(meters: Double(Self.nearbyRadiusMeters)))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
            }
            if let stats = operatorStats {
                if stats.isEmpty {
                    moduleMessage("Pas encore assez de mesures autour de toi pour comparer les opérateurs.")
                } else {
                    Button {
                        Haptics.selection()
                        comparisonMetric = .download
                        showOperatorComparison = true
                    } label: {
                        VStack(spacing: SQSpace.sm2) {
                            let best = Double(stats.map(\.value).max() ?? 1)
                            ForEach(stats.prefix(4)) { stat in
                                HStack(spacing: SQSpace.sm) {
                                    opBar(stat.operatorName, height: 20)
                                    Text(verbatim: stat.operatorName)
                                        .font(SQType.callout(.semibold))
                                        .foregroundStyle(SQColor.label)
                                        .frame(width: 92, alignment: .leading)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    GeometryReader { proxy in
                                        Capsule()
                                            .fill(SQColor.label.opacity(0.75))
                                            .frame(width: max(6, proxy.size.width * Double(stat.value) / max(best, 1)), height: 6)
                                            .frame(maxHeight: .infinity, alignment: .center)
                                    }
                                    .frame(height: 20)
                                    .accessibilityHidden(true)
                                    Text(verbatim: SQUnits.throughput(mbps: Double(stat.value)))
                                        .font(SQType.caption(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(SQColor.label)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            HStack {
                                Text("Débit médian · comparer en détail")
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.ink2)
                                Spacer(minLength: 0)
                                chevron()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Compare les opérateurs autour de toi")
                }
            } else if needsLocation {
                locationNeededMessage("Active la localisation pour comparer les opérateurs autour de toi.")
            } else if locationFixFailed {
                moduleFailure()
            } else {
                loadingRows(3)
            }
        }
        .accessibilityIdentifier("home.module.operators")
    }

    // MARK: Mesures autour de toi

    private var nearbyMeasuresModule: some View {
        moduleCard {
            moduleHeader("Mesures autour de toi", systemImage: "mappin.and.ellipse")
            if let measures = nearbyMeasures {
                if measures.isEmpty {
                    moduleMessage("Aucune mesure récente à moins d’un kilomètre.")
                } else {
                    ForEach(measures) { measure in
                        nearbyMeasureRow(measure)
                    }
                }
            } else if needsLocation {
                locationNeededMessage("Active la localisation pour voir les mesures autour de toi.")
            } else if locationFixFailed {
                moduleFailure()
            } else {
                loadingRows()
            }
        }
        .accessibilityIdentifier("home.module.nearbyMeasures")
    }

    /// Une mesure communautaire proche : techno, débit, contexte, distance.
    private func nearbyMeasureRow(_ measure: AndroidSpeedtestMarker) -> some View {
        Button {
            Haptics.selection()
            router.pendingMapFocus = Coordinates(latitude: measure.lat, longitude: measure.lng)
            router.pendingMapLayer = .speedtest
            router.selectedTab = .map
        } label: {
            HStack(spacing: SQSpace.md) {
                // Texte à l'encre sur une teinte douce, couleur de la techno portée par
                // l'anneau : en blanc sur la teinte pleine, « 4G » restait sous 4,5:1 (TRX-04).
                let tint = TechAccent.color(for: measure.tech)
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    Circle().strokeBorder(tint, lineWidth: 2)
                    if let label = TechAccent.shortLabel(for: measure.tech) {
                        Text(LocalizedStringKey(label))
                            .font(SQFont.body(13, .bold))
                            .foregroundStyle(SQColor.label)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SQColor.label)
                    }
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: SQUnits.throughput(mbps: measure.downloadMbps)
                         + (measure.pingMs.map { " · \(SQUnits.milliseconds($0))" } ?? ""))
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                    Text(verbatim: nearbyContext(for: measure))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.nearby.context")
                }
                Spacer(minLength: 0)
                chevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Montre la mesure sur la carte")
    }

    /// « Orange · il y a 2 h · à 450 m » — ce qui est connu, dans cet ordre.
    private func nearbyContext(for measure: AndroidSpeedtestMarker) -> String {
        var parts: [String] = []
        if let op = measure.`operator`, !op.isEmpty { parts.append(op) }
        if let date = measure.timestamp {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        if let distance = distanceText(to: measure.lat, measure.lng) {
            parts.append(String(localized: "à \(distance)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Amis en direct

    private var liveFriendsModule: some View {
        moduleCard {
            moduleHeader("Amis en direct", systemImage: "location.circle")
            if let friends = liveFriends {
                let located = friends.filter { $0.location != nil }
                if located.isEmpty {
                    moduleMessage("Aucun ami ne partage sa position en ce moment.")
                } else {
                    ForEach(located.prefix(3)) { friend in
                        Button {
                            Haptics.selection()
                            if let location = friend.location {
                                router.pendingMapFocus = Coordinates(latitude: location.lat, longitude: location.lng)
                            }
                            router.selectedTab = .map
                        } label: {
                            HStack(spacing: SQSpace.md) {
                                SQAvatar(url: friend.avatarUrl, name: friend.name ?? "?", size: 38)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: friend.name ?? String(localized: "Ami"))
                                        .font(SQType.callout(.bold))
                                        .foregroundStyle(SQColor.label)
                                    Text(verbatim: [
                                        distanceText(to: friend.location?.lat, friend.location?.lng).map { String(localized: "à \($0)") },
                                        friend.location?.updatedAt.map { $0.formatted(.relative(presentation: .named)) },
                                    ].compactMap { $0 }.joined(separator: " · "))
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.ink2)
                                }
                                Spacer(minLength: 0)
                                chevron()
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Montre sa position sur la carte")
                    }
                }
            } else {
                loadingRows()
            }
        }
        .accessibilityIdentifier("home.module.liveFriends")
    }

    // MARK: Raccourcis

    private var shortcutsModule: some View {
        moduleCard {
            moduleHeader("Raccourcis", systemImage: "square.grid.2x2")
            let columns = dynamicTypeSize.isAccessibilitySize
                ? [GridItem(.flexible())]
                : [GridItem(.flexible(), spacing: SQSpace.sm), GridItem(.flexible(), spacing: SQSpace.sm)]
            LazyVGrid(columns: columns, spacing: SQSpace.sm) {
                shortcut("driveTest", title: "Drive Test", systemImage: "location.north.line") {
                    router.selectedTab = .speed
                    router.pendingDriveTest = true
                }
                shortcut("outages", title: "Pannes", systemImage: "exclamationmark.triangle") { showOutages = true }
                shortcut("messages", title: "Messages", systemImage: "bubble.left.and.bubble.right",
                         badge: services.unreadConversations) { router.route(toConversation: nil) }
                shortcut("leaderboards", title: "Classements", systemImage: "trophy") { showLeaderboards = true }
            }
        }
    }

    private func shortcut(
        _ identifier: String,
        title: LocalizedStringKey,
        systemImage: String,
        badge: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: SQSpace.sm) {
                SQIconPastille(systemImage: systemImage, size: 34)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 { SQCountBadge(count: badge).offset(x: 6, y: -4) }
                    }
                Text(title)
                    .font(SQType.callout(.bold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(SQSpace.sm2)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityValue(badge > 0 ? Text("\(badge) non lus") : Text(""))
        .accessibilityIdentifier("home.action.\(identifier)")
    }

    // MARK: Invité

    /// Pour un invité : son réseau avec Tester (le test marche sans compte), ce que la
    /// communauté apporte, et les modules des membres estompés, sans fausses données.
    @ViewBuilder
    private var guestContent: some View {
        networkModule
        moduleCard {
            moduleHeader("La communauté autour de toi", systemImage: "person.2")
            Text("Pannes proches, sites qui évoluent, le fil et les classements : crée un compte pour les voir ici.")
                .font(SQType.callout)
                .foregroundStyle(SQColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SQSpace.sm) {
                GradientButton("Créer un compte") { showSignup = true }
                    .accessibilityIdentifier("home.guest.signup")
                GradientButton("Se connecter", style: .secondary) { router.selectedTab = .profile }
                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
                    .accessibilityIdentifier("home.guest.login")
            }
        }
        moduleCard {
            moduleHeader("Pannes près de toi", systemImage: "exclamationmark.triangle") {
                Image(systemName: "lock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            loadingRows()
                .opacity(0.55)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pannes près de toi, réservé aux membres")
    }

    // MARK: Chargement

    private func refresh(forceFresh: Bool = false) async {
        services.networkPath.refreshNow()
        networkStatus = services.networkPath.status
        latestMeasurement = await services.speedtest.history().first
        guard user != nil else { return }
        async let account: Void = refreshAccountLatest(forceFresh: forceFresh)
        async let social: Void = refreshSocial(forceFresh: forceFresh)
        await refreshNearby(forceFresh: forceFresh)
        await account
        await social
    }

    private func has(_ module: HomeModule) -> Bool {
        layout.entries.contains { $0.module == module }
    }

    /// Dernier test du compte. Silencieux : hors ligne ou en erreur, l'historique
    /// local suffit.
    private func refreshAccountLatest(forceFresh: Bool) async {
        guard user != nil, has(.latestTest) else { return }
        if AppEnvironment.usesDemoData {
            accountLatest = SocialShareableSpeedtest(
                id: "demo", downloadSpeed: 214.6, uploadSpeed: 48.2, ping: 18,
                networkType: "5G", mobileOperator: "Orange", timestamp: Date().addingTimeInterval(-3_600))
            return
        }
        if !forceFresh, Date().timeIntervalSince(lastAccountRefreshAt) < 60 { return }
        lastAccountRefreshAt = Date()
        if let latest = try? await services.feed.myLatestSpeedtest() {
            accountLatest = latest
        }
    }

    /// Stories, tendances, semaine et amis en direct : seulement pour les modules affichés.
    private func refreshSocial(forceFresh: Bool) async {
        guard let user else { return }
        if AppEnvironment.usesDemoData {
            stories = HomeDemoData.stories
            trending = [TrendingHashtag(tag: "5G", postCount: 42), TrendingHashtag(tag: "Lyon", postCount: 17),
                        TrendingHashtag(tag: "panne", postCount: 9)]
            week = WeekSummary(points: 1_240, rank: 3, friendsCount: 8)
            liveFriends = []
            return
        }
        if !forceFresh, Date().timeIntervalSince(lastSocialRefreshAt) < 60 { return }
        lastSocialRefreshAt = Date()
        let wantsCommunity = has(.community)
        let wantsWeek = has(.week)
        let wantsFriends = has(.liveFriends)
        async let storiesTask: [SocialStory]? = wantsCommunity ? try? await services.stories.list() : nil
        async let trendingTask: [TrendingHashtag]? = wantsCommunity ? try? await services.feed.trendingHashtags() : nil
        async let weekTask: PointsLeaderboardResult? = wantsWeek
            ? try? await services.leaderboards.pointsLeaderboard(period: "week", scope: "friends") : nil
        async let friendsTask: [SocialFriendLive]? = wantsFriends ? try? await services.map.friendsSnapshot() : nil
        if let value = await storiesTask { stories = value }
        if let value = await trendingTask { trending = value }
        if let result = await weekTask {
            let mine = result.entries.first { $0.userId == user.id }
            week = WeekSummary(points: mine?.periodPoints ?? mine?.points ?? (mine == nil ? nil : 0),
                               rank: result.currentUserRank ?? mine?.rank,
                               friendsCount: result.entries.count)
        }
        if wantsFriends { liveFriends = await friendsTask ?? liveFriends ?? [] }
    }

    /// Charge le verdict, les pannes, les évolutions et les mesures autour de la position.
    /// Best-effort : sans position ou sans données, chaque module le dit sobrement (jamais
    /// d'erreur affichée sur l'Accueil). `forceFresh` (pull-to-refresh) contourne les caches.
    private func refreshNearby(forceFresh: Bool) async {
        guard user != nil else { return }
        if AppEnvironment.usesDemoData {
            applyDemoNearby()
            marketEntry = await services.markets.marketForLocation(latitude: 45.764, longitude: 4.8357)
            return
        }
        if !forceFresh, Date().timeIntervalSince(lastNearbyRefreshAt) < 20 { return }
        // Ne JAMAIS déclencher le prompt système de localisation depuis l'Accueil (UXP-01) :
        // on n'interroge la position que si l'autorisation est déjà accordée ou qu'un fix
        // est déjà connu.
        let status = services.location.authorizationStatus
        guard Self.isAuthorized(status) || services.location.lastLocation != nil else { return }
        locationFixFailed = false
        guard let location = await services.location.currentLocation(timeoutSeconds: 6) else {
            locationFixFailed = true
            return
        }
        userLocation = location
        lastNearbyRefreshAt = Date()
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        let maxAge: TimeInterval = forceFresh ? 0 : 90
        let isCellular = services.networkPath.status.connection == .cellular
        let simPlmn = services.networkPath.simPLMN().plmn
        let market = await services.markets.marketForLocation(latitude: lat, longitude: lng)
        marketEntry = market
        marketUncovered = market == nil

        let wantsNetwork = has(.network)
        let wantsMeasures = has(.nearbyMeasures)
        let wantsOperators = has(.operators)
        let wantsOutages = has(.outages)
        let wantsEvolutions = has(.evolutions)
            && (forceFresh || evolutions == nil || Date().timeIntervalSince(lastEvolutionsRefreshAt) > 600)

        async let qualityTask: NearbyNetworkQuality? = wantsNetwork
            ? await services.nearbyQuality.verdict(latitude: lat, longitude: lng, isCellular: isCellular,
                                                   simPlmn: simPlmn, maxAge: maxAge)
            : nil
        async let recentTask: [AndroidSpeedtestMarker]? = wantsMeasures
            ? await recentNearbySpeedtests(latitude: lat, longitude: lng) : nil
        async let rankingTask: [OperatorMetricStat]? = wantsOperators
            ? try? await services.nearbyQuality.loadOperatorRanking(metric: .download, latitude: lat, longitude: lng, maxAge: maxAge)
            : nil
        async let outagesTask: [CommunityOutage]? = wantsOutages
            ? await nearbyOutageList(around: location, market: market?.code) : nil
        async let evolutionsTask: [PlannedSiteLive]? = wantsEvolutions
            ? await nearbyEvolutions(around: location, market: market?.code) : nil

        if wantsNetwork { networkQuality = await qualityTask }
        if let recent = await recentTask { nearbyMeasures = recent }
        // Comme les pannes : un échec garde ce que le module montrait ; à vide, il se dit sans données.
        if wantsOperators { operatorStats = await rankingTask ?? operatorStats ?? [] }
        let outages = await outagesTask
        if let outages { nearbyOutages = outages }
        outagesFailed = wantsOutages && outages == nil && nearbyOutages == nil
        let sites = await evolutionsTask
        if let sites {
            evolutions = sites
            lastEvolutionsRefreshAt = Date()
        }
        evolutionsFailed = wantsEvolutions && sites == nil && evolutions == nil
    }

    /// Démo (`--demo-data`, tours de captures) : modules de zone remplis sans réseau, à Lyon.
    private func applyDemoNearby() {
        let now = Date()
        userLocation = CLLocation(latitude: 45.764, longitude: 4.8357)
        networkQuality = NearbyNetworkQuality(
            level: .good, signalBand: .good, speedBand: .excellent, medianRsrpDbm: -85, medianDownloadMbps: 120,
            operatorLabel: "Orange", operatorKey: "ORANGE", operatorSource: .ipAsn, sampleCount: 42, radiusMeters: 1000)
        nearbyOutages = HomeDemoData.outages
        evolutions = HomeDemoData.evolutions
        operatorStats = [
            OperatorMetricStat(operatorName: "Orange", value: 214, sampleCount: 18, detail: nil),
            OperatorMetricStat(operatorName: "SFR", value: 132, sampleCount: 11, detail: nil),
            OperatorMetricStat(operatorName: "Free Mobile", value: 96, sampleCount: 9, detail: nil),
            OperatorMetricStat(operatorName: "Bouygues", value: 71, sampleCount: 7, detail: nil),
        ]
        nearbyMeasures = [
            AndroidSpeedtestMarker(id: "demo-1", lat: 45.7652, lng: 4.8371, downloadMbps: 312.4, uploadMbps: 54.1,
                                   pingMs: 17, tech: "5G", band: 78, frequency: nil,
                                   timestamp: now.addingTimeInterval(-1_200), operator: "Orange"),
            AndroidSpeedtestMarker(id: "demo-2", lat: 45.7629, lng: 4.8331, downloadMbps: 86.7, uploadMbps: 21.3,
                                   pingMs: 26, tech: "4G", band: 3, frequency: nil,
                                   timestamp: now.addingTimeInterval(-5_400), operator: "SFR"),
            AndroidSpeedtestMarker(id: "demo-3", lat: 45.7668, lng: 4.8322, downloadMbps: 8.4, uploadMbps: 2.2,
                                   pingMs: 61, tech: "4G", band: 20, frequency: nil,
                                   timestamp: now.addingTimeInterval(-14_400), operator: "Free"),
        ]
    }

    /// Fenêtre englobant le cercle de `wideRadiusMeters` autour de la position.
    private static func wideBounds(around location: CLLocation) -> MapBounds {
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let halfSpanLat = wideRadiusMeters / 111_000
        let halfSpanLng = halfSpanLat / max(cos(latitude * .pi / 180), 0.01)
        return MapBounds(north: latitude + halfSpanLat, south: latitude - halfSpanLat,
                         east: longitude + halfSpanLng, west: longitude - halfSpanLng)
    }

    /// Les pannes ouvertes à moins de 5 km, tous opérateurs confondus, la plus proche d'abord.
    /// `nil` en cas d'échec : le module garde ce qu'il montrait.
    private func nearbyOutageList(around location: CLLocation, market: String?) async -> [CommunityOutage]? {
        guard let market else { return [] }
        guard let outages = try? await services.communityOutages.outages(
            in: Self.wideBounds(around: location), marketCode: market, operatorKey: "ALL"
        ) else { return nil }
        return outages
            .filter(\.state.isVisible)
            .map { ($0, location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.1 <= Self.wideRadiusMeters }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Sites prévus, déclarés ou en cours d'activation à moins de 5 km, le plus proche d'abord.
    /// Les sites déjà actifs n'ont rien de neuf à annoncer.
    private func nearbyEvolutions(around location: CLLocation, market: String?) async -> [PlannedSiteLive]? {
        guard let market else { return [] }
        guard let result = try? await services.map.plannedSitesLayer(
            market: market, operatorName: "ALL", territory: nil, bands: []
        ) else { return nil }
        return result.sites
            .filter { $0.activation?.status != .active }
            .compactMap { site -> (PlannedSiteLive, Double)? in
                guard let lat = site.lat, let lon = site.lon else { return nil }
                return (site, location.distance(from: CLLocation(latitude: lat, longitude: lon)))
            }
            .filter { $0.1 <= Self.wideRadiusMeters }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Les 3 speedtests communautaires les PLUS RÉCENTS à ≤ 1 km, via l'endpoint dédié ;
    /// repli sur les plus proches des tuiles si l'endpoint n'a rien renvoyé.
    private func recentNearbySpeedtests(latitude: Double, longitude: Double) async -> [AndroidSpeedtestMarker] {
        let recent = (try? await services.feed.nearbyRecentSpeedtests(
            latitude: latitude, longitude: longitude, radiusMeters: Self.nearbyRadiusMeters, limit: 3
        )) ?? []
        if !recent.isEmpty { return Array(recent.prefix(3)) }
        guard let market = await services.markets.marketForLocation(latitude: latitude, longitude: longitude)?.code else { return [] }
        let bounds = MapBounds(
            north: latitude + Self.nearbyHalfSpanLat, south: latitude - Self.nearbyHalfSpanLat,
            east: longitude + Self.nearbyHalfSpanLng, west: longitude - Self.nearbyHalfSpanLng
        )
        guard let tiles = try? await services.map.speedtestTiles(
            bounds: bounds, zoom: 14, market: market, operatorName: "ALL", days: 30, bands: [], maxAge: 90
        ) else { return [] }
        let center = CLLocation(latitude: latitude, longitude: longitude)
        return tiles
            .flatMap(\.markers)
            .map { ($0, center.distance(from: CLLocation(latitude: $0.lat, longitude: $0.lng))) }
            .filter { $0.1 <= Double(Self.nearbyRadiusMeters) }
            .sorted { $0.1 < $1.1 }
            .prefix(3)
            .map(\.0)
    }
}

/// « Antennes suivies » : observe le service des favoris, et lit l'état de chaque site
/// (panne ouverte ou non) dans les pannes de la communauté.
private struct HomeFollowedSitesModule: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @ObservedObject var favorites: FavoriteAntennasService
    let registry: MarketRegistryEntry?
    /// `true` = panne ouverte, `false` = rien de signalé ; absent = inconnu (on ne dit rien).
    @State private var hasOutage: [String: Bool] = [:]

    private var shown: [FavoriteAntenna] { Array(favorites.favorites.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "star.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SQColor.ink2)
                    .accessibilityHidden(true)
                Text("Antennes suivies").sqKicker()
                    .foregroundStyle(SQColor.ink2)
                    .sqHeader()
                Spacer(minLength: SQSpace.sm)
                if !favorites.favorites.isEmpty {
                    Text(favorites.favorites.count, format: .number)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                }
            }
            if favorites.favorites.isEmpty {
                Button {
                    router.selectedTab = .map
                } label: {
                    Text(favorites.hasLoaded
                         ? "Touche l’étoile d’une fiche antenne pour la suivre et la retrouver ici."
                         : favorites.isLoading
                            ? "Chargement des antennes suivies…"
                            : "Antennes suivies indisponibles pour l’instant.")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(shown) { favorite in
                    row(favorite)
                }
                if favorites.favorites.count > shown.count {
                    NavigationLink {
                        FavoriteAntennasView(favorites: favorites) { router.route(toSite: $0.siteId, market: $0.market) }
                    } label: {
                        Text("Voir les \(favorites.favorites.count) antennes")
                            .font(SQType.callout(.bold))
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sqCardBackground()
        .accessibilityIdentifier("home.module.followedSites")
        .task { if !favorites.hasLoaded { await favorites.load() } }
        .task(id: shown.map(\.id)) { await loadStatuses() }
    }

    private func row(_ favorite: FavoriteAntenna) -> some View {
        let operatorName = favorite.operator.flatMap { $0.isEmpty ? nil : $0 }
            .map { MarketRegistryEntry.operatorLabel($0, in: registry) }
        let distance: String? = {
            guard let latitude = favorite.latitude, let longitude = favorite.longitude,
                  let here = services.location.cachedLocation() else { return nil }
            return SQUnits.distance(meters: here.distance(from: CLLocation(latitude: latitude, longitude: longitude)))
        }()
        return Button {
            Haptics.selection()
            router.route(toSite: favorite.siteId, market: favorite.market)
        } label: {
            HStack(spacing: SQSpace.sm2) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SQBrand.operatorColor(operatorName))
                    .frame(width: 4, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(favorite.displayName)
                        .font(SQType.callout(.bold))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    Text(verbatim: [operatorName, distance].compactMap { $0 }.joined(separator: " · "))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.ink2)
                }
                Spacer(minLength: 0)
                if let outage = hasOutage[favorite.id] {
                    Text(outage ? "Panne" : "En service")
                        .font(SQType.chip)
                        .foregroundStyle(outage ? SQColor.dangerInk : OutageTint.resolvedInk)
                        .padding(.horizontal, SQSpace.sm2)
                        .padding(.vertical, SQSpace.xs)
                        .background(outage ? SQColor.dangerSoft : SQColor.successSoft, in: Capsule(style: .continuous))
                        .fixedSize()
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre la fiche du site")
    }

    private func loadStatuses() async {
        for favorite in shown {
            guard let outages = try? await services.communityOutages.outages(
                forSiteId: favorite.siteId, targetKind: "anfr", marketCode: favorite.market, operatorKey: "ALL"
            ) else { continue }
            hasOutage[favorite.id] = outages.contains { $0.state.isVisible }
        }
    }
}

/// Données de démonstration (`--demo-data`, tours de captures) : chaque module rempli, à Lyon.
private enum HomeDemoData {
    private static func decode<T: Decodable>(_ json: String) -> [T] {
        (try? JSONDecoder().decode([T].self, from: Data(json.utf8))) ?? []
    }

    static let outages: [CommunityOutage] = decode(#"""
    [{"id":"demo-o1","targetKind":"anfr","targetId":"demo-1","marketCode":"FR","operatorKey":"BOUYGUES",
      "latitude":45.7605,"longitude":4.8590,"address":"Gare de la Part-Dieu","state":"confirmed","severity":"down"},
     {"id":"demo-o2","targetKind":"anfr","targetId":"demo-2","marketCode":"FR","operatorKey":"SFR",
      "latitude":45.7790,"longitude":4.8270,"address":"Croix-Rousse","state":"reported","severity":"degraded"}]
    """#)

    static let evolutions: [PlannedSiteLive] = decode(#"""
    [{"operator":"ORANGE","lat":45.7670,"lon":4.8420,"commune":"Lyon 1er","plannedKey":"demo-p1",
      "technologies":["4G","5G"],"activation":{"status":"upgrade_pending","pendingTechnologies":["5G"]}},
     {"operator":"FREE","lat":45.7520,"lon":4.8300,"commune":"Lyon 2e","plannedKey":"demo-p2",
      "technologies":["4G","5G"],"activation":{"status":"declared","plannedTechnologies":["4G","5G"]}}]
    """#)

    static let stories: [SocialStory] = decode(#"""
    [{"id":"demo-s1","author":{"id":"demo-a1","name":"Camille"},"viewedByMe":false},
     {"id":"demo-s2","author":{"id":"demo-a2","name":"Marc"},"viewedByMe":false},
     {"id":"demo-s3","author":{"id":"demo-a3","name":"Léa"},"viewedByMe":false},
     {"id":"demo-s4","author":{"id":"demo-a4","name":"Julien"},"viewedByMe":true},
     {"id":"demo-s5","author":{"id":"demo-a5","name":"Inès"},"viewedByMe":true}]
    """#)
}

// MARK: - Modifier l'accueil

/// Édition de l'accueil : une liste simple plutôt qu'une page qui tremble. « Sur ton accueil »
/// porte les modules actifs (retirer, taille, déplacer) ; « À ajouter », les autres. Rien
/// n'est enregistré avant « Terminé ».
struct HomeLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HomeLayout
    @State private var showPresets = false
    @State private var confirmReset = false
    let onSave: (HomeLayout) -> Void

    init(initial: HomeLayout, onSave: @escaping (HomeLayout) -> Void) {
        _draft = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                Section {
                    ForEach(draft.entries) { entry in
                        activeRow(entry)
                            .listRowBackground(SQColor.surface)
                            .listRowSeparatorTint(SQColor.separator)
                    }
                    .onMove { source, destination in
                        draft.move(fromOffsets: source, toOffset: destination)
                    }
                    .deleteDisabled(true)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Sur ton accueil").sqKicker()
                        Spacer(minLength: SQSpace.sm)
                        Text("Glisse ≡ pour déplacer")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.ink2)
                    }
                    .textCase(nil)
                } footer: {
                    if draft.entries.isEmpty {
                        Text("Aucun module : ajoute-en un ci-dessous.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.ink2)
                    }
                }

                if !draft.available.isEmpty {
                    Section {
                        ForEach(draft.available) { module in
                            availableRow(module)
                                .listRowBackground(SQColor.surface)
                                .listRowSeparatorTint(SQColor.separator)
                        }
                        .deleteDisabled(true)
                        .moveDisabled(true)
                    } header: {
                        Text("À ajouter").sqKicker().textCase(nil)
                    }
                }

                Section {
                    HStack(spacing: SQSpace.sm) {
                        GradientButton("Préréglages", style: .secondary) { showPresets = true }
                            .accessibilityIdentifier("home.editor.presets")
                        GradientButton("Réinitialiser", style: .ghost) { confirmReset = true }
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("home.editor.reset")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // L'édition native n'apporte que les poignées de déplacement : retirer et ajouter
            // passent par les pastilles − et +, en un seul geste.
            .environment(\.editMode, .constant(.active))
            .sqAnimation(SQMotion.standard, value: draft)
        }
        .sqSheet(background: SQColor.bg)
        .sheet(isPresented: $showPresets) {
            HomeLayoutPresetsSheet(current: draft.matchingPreset) { preset in
                draft = .preset(preset)
            }
        }
        .confirmationDialog("Revenir à l’accueil par défaut ?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Réinitialiser", role: .destructive) { draft = .default }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L’ordre, les tailles et les modules reprennent le préréglage Communauté.")
        }
        .interactiveDismissDisabled(draft != HomeLayoutStore.layout())
    }

    private var header: some View {
        HStack {
            Button("Annuler") { dismiss() }
                .font(SQType.body(.semibold))
                .foregroundStyle(SQColor.ink2)
                .frame(minHeight: 44)
                .accessibilityIdentifier("home.editor.cancel")
            Spacer(minLength: SQSpace.sm)
            Text("Modifier l’accueil")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .sqHeader()
            Spacer(minLength: SQSpace.sm)
            Button {
                Haptics.medium()
                onSave(draft)
                dismiss()
            } label: {
                Text("Terminé")
                    .font(SQType.button)
                    .foregroundStyle(SQColor.onInk)
                    .padding(.horizontal, SQSpace.lg)
                    .frame(minHeight: 38)
                    .background(SQColor.label, in: Capsule(style: .continuous))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle(scale: 0.97))
            .accessibilityIdentifier("home.editor.done")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.md)
        .padding(.bottom, SQSpace.xs)
    }

    private func moduleTile(_ module: HomeModule) -> some View {
        Image(systemName: module.systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(SQColor.ink2)
            .frame(width: 34, height: 34)
            .sqSurface(SQColor.chip, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }

    private func roundSign(_ systemImage: String, fill: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(SQColor.surface)
            .frame(width: 24, height: 24)
            .background(fill, in: Circle())
    }

    private func activeRow(_ entry: HomeModuleEntry) -> some View {
        let index = draft.entries.firstIndex(of: entry) ?? 0
        let canResize = entry.module.supportedSizes.count > 1
        return HStack(spacing: SQSpace.sm2) {
            Button {
                Haptics.selection()
                draft.remove(entry.module)
            } label: {
                roundSign("minus", fill: SQColor.danger)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retirer \(entry.module.title)")
            .accessibilityIdentifier("home.editor.remove.\(entry.module.rawValue)")
            .padding(.leading, -SQSpace.sm2)
            moduleTile(entry.module)
            Text(verbatim: entry.module.title)
                .font(SQType.callout(.bold))
                .foregroundStyle(SQColor.label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Haptics.selection()
                draft.toggleSize(entry.module)
            } label: {
                Text(verbatim: entry.size.title)
                    .font(SQType.chip)
                    .foregroundStyle(canResize ? SQColor.chipInk : SQColor.labelSecondary)
                    .padding(.horizontal, SQSpace.sm2)
                    .frame(minHeight: 26)
                    .sqSurface(SQColor.chip, in: Capsule(style: .continuous))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canResize)
            .accessibilityLabel("Taille")
            .accessibilityValue(Text(verbatim: entry.size.title))
            .accessibilityHint(canResize ? "Passe de Petit à Large" : "Ce module n’existe qu’en Large")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Monter") { draft.move(entry.module, by: -1) }
        .accessibilityAction(named: "Descendre") { draft.move(entry.module, by: 1) }
        .accessibilityAction(named: "Retirer") { draft.remove(entry.module) }
        .accessibilityValue(Text("Position \(index + 1) sur \(draft.entries.count)"))
    }

    private func availableRow(_ module: HomeModule) -> some View {
        Button {
            Haptics.selection()
            draft.add(module)
        } label: {
            HStack(spacing: SQSpace.sm2) {
                roundSign("plus", fill: SQColor.success)
                    .frame(width: 44, height: 44)
                    .padding(.leading, -SQSpace.sm2)
                moduleTile(module)
                Text(verbatim: module.title)
                    .font(SQType.callout(.bold))
                    .foregroundStyle(SQColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ajouter \(module.title)")
        .accessibilityIdentifier("home.editor.add.\(module.rawValue)")
    }
}

/// Les préréglages, comme ceux du tableau de bord Android : ils remplacent l'ordre et les
/// tailles, puis tout reste ajustable.
private struct HomeLayoutPresetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: HomeLayout.Preset?
    let onPick: (HomeLayout.Preset) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Modifier l’accueil").sqKicker()
                        Text("Préréglages")
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                    }
                    Spacer(minLength: SQSpace.sm)
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "home.presets.close") { dismiss() }
                }
                ForEach(HomeLayout.Preset.allCases) { preset in
                    let selected = preset == current
                    Button {
                        Haptics.selection()
                        onPick(preset)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: SQSpace.md) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: preset.title)
                                    .font(SQType.heading)
                                    .foregroundStyle(SQColor.label)
                                Text(verbatim: preset.summary)
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(SQColor.accentInk)
                            }
                        }
                        .padding(SQSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? SQColor.accentSoft : SQColor.surfaceMuted,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(SQColor.brandRed, lineWidth: 1.5)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("home.presets.\(preset.rawValue)")
                }
                Text("Un préréglage remplace l’ordre et les tailles ; tu peux ensuite tout ajuster.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SQSpace.lg)
        }
        .presentationDetents([.medium, .large])
        .sqSheet()
    }
}

// MARK: - Modules de l'accueil

/// Un module de l'accueil. Chacun dit une seule chose ; l'ordre, la taille et la présence
/// se règlent dans « Modifier l'accueil », comme le tableau de bord Radio d'Android.
enum HomeModule: String, CaseIterable, Identifiable, Sendable {
    case network, outages, latestTest, week, evolutions, community, followedSites
    case operators, nearbyMeasures, liveFriends, shortcuts

    var id: String { rawValue }

    /// Nom dans la liste d'édition (clé du catalogue).
    var title: String {
        switch self {
        case .network: return String(localized: "Mon réseau")
        case .outages: return String(localized: "Pannes près de toi")
        case .latestTest: return String(localized: "Ton dernier test")
        case .week: return String(localized: "Ta semaine")
        case .evolutions: return String(localized: "Ça bouge près de toi")
        case .community: return String(localized: "Communauté")
        case .followedSites: return String(localized: "Antennes suivies")
        case .operators: return String(localized: "Opérateurs ici")
        case .nearbyMeasures: return String(localized: "Mesures autour de toi")
        case .liveFriends: return String(localized: "Amis en direct")
        case .shortcuts: return String(localized: "Raccourcis")
        }
    }

    var systemImage: String {
        switch self {
        case .network: return "cellularbars"
        case .outages: return "exclamationmark.triangle"
        case .latestTest: return "speedometer"
        case .week: return "trophy"
        case .evolutions: return "sparkles"
        case .community: return "person.2"
        case .followedSites: return "star.fill"
        case .operators: return "chart.bar"
        case .nearbyMeasures: return "mappin.and.ellipse"
        case .liveFriends: return "location.circle"
        case .shortcuts: return "square.grid.2x2"
        }
    }

    /// Seuls les modules qui tiennent en un chiffre et une ligne existent en « Petit ».
    var supportedSizes: [HomeModuleSize] {
        switch self {
        case .latestTest, .week: return [.small, .large]
        default: return [.large]
        }
    }
}

/// Les deux tailles des widgets iOS : deux « Petit » côte à côte, ou une pleine largeur.
enum HomeModuleSize: String, Codable, Sendable {
    case small, large

    var title: String {
        self == .small ? String(localized: "Petit") : String(localized: "Large")
    }
}

struct HomeModuleEntry: Equatable, Identifiable, Sendable {
    var module: HomeModule
    var size: HomeModuleSize
    var id: String { module.rawValue }
}

/// L'accueil d'un compte : les modules affichés, dans l'ordre, avec leur taille.
struct HomeLayout: Equatable, Sendable {
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case community, field, essential
        var id: String { rawValue }

        var title: String {
            switch self {
            case .community: return String(localized: "Communauté")
            case .field: return String(localized: "Terrain")
            case .essential: return String(localized: "Essentiel")
            }
        }

        var summary: String {
            switch self {
            case .community:
                return String(localized: "Mon réseau, pannes, ton test, ta semaine, ce qui bouge, la communauté et tes antennes. Par défaut.")
            case .field:
                return String(localized: "Mon réseau, pannes, ce qui bouge, opérateurs ici, mesures autour de toi et antennes suivies.")
            case .essential:
                return String(localized: "Mon réseau, pannes et ton dernier test. Rien d’autre.")
            }
        }
    }

    static let schemaVersion = 1
    var entries: [HomeModuleEntry]

    static let `default` = preset(.community)

    static func preset(_ preset: Preset) -> HomeLayout {
        switch preset {
        case .community:
            return HomeLayout(entries: [
                .init(module: .network, size: .large), .init(module: .outages, size: .large),
                .init(module: .latestTest, size: .small), .init(module: .week, size: .small),
                .init(module: .evolutions, size: .large), .init(module: .community, size: .large),
                .init(module: .followedSites, size: .large),
            ])
        case .field:
            return HomeLayout(entries: [
                .init(module: .network, size: .large), .init(module: .outages, size: .large),
                .init(module: .evolutions, size: .large), .init(module: .operators, size: .large),
                .init(module: .nearbyMeasures, size: .large), .init(module: .followedSites, size: .large),
            ])
        case .essential:
            return HomeLayout(entries: [
                .init(module: .network, size: .large), .init(module: .outages, size: .large),
                .init(module: .latestTest, size: .large),
            ])
        }
    }

    /// Le préréglage dont l'accueil est la copie exacte, s'il y en a un.
    var matchingPreset: Preset? {
        Preset.allCases.first { HomeLayout.preset($0) == self }
    }

    /// Les modules qu'on peut encore ajouter, dans l'ordre du catalogue.
    var available: [HomeModule] {
        HomeModule.allCases.filter { module in !entries.contains { $0.module == module } }
    }

    /// Un module au plus une fois, et toujours dans une taille qu'il sait prendre.
    func reconciled() -> HomeLayout {
        var seen = Set<HomeModule>()
        let cleaned = entries.compactMap { entry -> HomeModuleEntry? in
            guard seen.insert(entry.module).inserted else { return nil }
            let size = entry.module.supportedSizes.contains(entry.size) ? entry.size : .large
            return HomeModuleEntry(module: entry.module, size: size)
        }
        return HomeLayout(entries: cleaned)
    }

    mutating func remove(_ module: HomeModule) {
        entries.removeAll { $0.module == module }
    }

    mutating func add(_ module: HomeModule) {
        guard !entries.contains(where: { $0.module == module }) else { return }
        entries.append(HomeModuleEntry(module: module, size: module.supportedSizes.contains(.large) ? .large : .small))
    }

    /// Passe de « Petit » à « Large » et inversement, quand le module sait le faire.
    mutating func toggleSize(_ module: HomeModule) {
        guard let index = entries.firstIndex(where: { $0.module == module }),
              module.supportedSizes.count > 1 else { return }
        entries[index].size = entries[index].size == .small ? .large : .small
    }

    /// Monte (`offset` négatif) ou descend un module, sans sortir de la liste.
    mutating func move(_ module: HomeModule, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.module == module }) else { return }
        let target = min(max(index + offset, 0), entries.count - 1)
        guard target != index else { return }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: target)
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Même règle que `Array.move(fromOffsets:toOffset:)` de SwiftUI, sans dépendre de lui ici.
        let moving = source.sorted().map { entries[$0] }
        let before = source.filter { $0 < destination }.count
        entries = entries.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        entries.insert(contentsOf: moving, at: destination - before)
    }

    /// Les rangées affichées : deux « Petit » consécutifs partagent une rangée ; un « Petit »
    /// seul, ou tous aux grandes tailles de texte, prend la pleine largeur.
    func rows(pairingSmall: Bool) -> [[HomeModuleEntry]] {
        var rows: [[HomeModuleEntry]] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            if pairingSmall, entry.size == .small, index + 1 < entries.count, entries[index + 1].size == .small {
                rows.append([entry, entries[index + 1]])
                index += 2
            } else {
                rows.append([entry])
                index += 1
            }
        }
        return rows
    }
}

extension HomeLayout: Codable {
    private enum CodingKeys: String, CodingKey { case version, entries }
    /// Lu champ par champ : un module ajouté par une version plus récente, puis relu par
    /// celle-ci, est ignoré au lieu de faire perdre tout l'accueil.
    private struct StoredEntry: Codable {
        let module: String
        let size: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([StoredEntry].self, forKey: .entries)
        entries = stored.compactMap { item in
            guard let module = HomeModule(rawValue: item.module) else { return nil }
            return HomeModuleEntry(module: module, size: HomeModuleSize(rawValue: item.size) ?? .large)
        }
        self = reconciled()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(entries.map { StoredEntry(module: $0.module.rawValue, size: $0.size.rawValue) }, forKey: .entries)
    }
}

/// L'accueil de chaque compte, gardé sur l'appareil. Rien ne part au serveur, comme les
/// préférences du tableau de bord d'Android.
enum HomeLayoutStore {
    static let didChange = Notification.Name("SignalQuest.HomeLayoutDidChange")
    private static let prefix = "SignalQuest.HomeLayout.v1"

    private static func key(_ ownerScopeId: String) -> String {
        "\(prefix).\(LocalAccountScope.storageNamespace(for: ownerScopeId))"
    }

    static func layout(
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) -> HomeLayout {
        guard let data = defaults.data(forKey: key(ownerScopeId)),
              let layout = try? JSONDecoder().decode(HomeLayout.self, from: data) else { return .default }
        return layout
    }

    static func save(
        _ layout: HomeLayout,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) {
        let cleaned = layout.reconciled()
        if cleaned == .default {
            defaults.removeObject(forKey: key(ownerScopeId))
        } else if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: key(ownerScopeId))
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
