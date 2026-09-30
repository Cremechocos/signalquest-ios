import SwiftUI
import CoreLocation

/// Accueil « Crème & Terre cuite » : salutation, état réseau en direct,
/// grille 2×2 d'actions (Tester en tuile accent), données communautaires
/// AUTOUR DE LA POSITION (pouls + dernières mesures proches) et dernière
/// mesure, locale ou du compte. Le feed social reste dans Communauté.
struct SignalQuestHomeView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let user: AuthUser?

    @State private var latestMeasurement: SpeedtestRunResult?
    @State private var networkStatus: NetworkPathStatus = .unknown
    /// Données communautaires autour de la position (nil/vides = section masquée).
    @State private var pulse: NetworkPulse?
    @State private var nearbyMeasures: [AndroidSpeedtestMarker] = []
    @State private var userLocation: CLLocation?
    /// Verdict de qualité réseau (opérateur identifié, données communautaires) qui pilote
    /// la pastille d'état. `nil` = pas encore chargé ou zone sans mesures.
    @State private var networkQuality: NearbyNetworkQuality?
    /// Sheet expliquant la source et le calcul du verdict réseau.
    @State private var showQualityDetail = false
    /// Comparaison des opérateurs au tap sur une tuile du pouls (métrique choisie).
    @State private var comparisonMetric: NearbyOperatorMetric = .download
    @State private var showOperatorComparison = false
    /// Horodatage du dernier rafraîchissement réel de « Autour de toi » (throttle
    /// des refetch pouls/mesures à chaque foreground/retour d'onglet — PERF-HOME-01).
    @State private var lastNearbyRefreshAt: Date = .distantPast
    /// Panne signalée à proximité, la plus grave d'abord. `nil` = rien à signaler.
    ///
    /// C'est le seul chemin de découverte qui ne demande rien à personne : sans lui, une panne se
    /// trouve en ouvrant la carte, en allumant le bon filtre et en visant le bon pylône — soit
    /// trois gestes que quelqu'un dont le réseau vient de tomber ne fera pas.
    @State private var nearbyOutage: CommunityOutage?
    /// Liste des pannes ouverte depuis la tuile « Pannes ».
    @State private var showOutages = false
    /// Dernier test du compte côté serveur : l'historique local est vide après une
    /// réinstallation ou sur un nouvel iPhone, et ne voit pas les tests faits sur
    /// Android (UI-06, UI-12).
    @State private var accountLatest: SocialShareableSpeedtest?
    @State private var lastAccountRefreshAt: Date = .distantPast
    /// Suit l'autorisation de localisation pour afficher, ou retirer, l'invitation
    /// à l'activer (TRX-19). `nil` tant que le service ne l'a pas encore publiée.
    @State private var locationStatus: CLAuthorizationStatus?

    private var gridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ]
    }

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
                outageBanner
                actionsGrid
                locationPrompt
                nearbySection
                latestMeasurementSection
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
            // Sans animation sur le conteneur, la transition du bandeau ne serait jamais jouée :
            // il apparaîtrait d'un coup au milieu de l'écran. `sqAnimation` se tait de lui-même
            // sous « Réduire les animations ».
            .sqAnimation(SQMotion.standard, value: nearbyOutage?.id)
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
        .navigationDestination(isPresented: $showOutages) {
            CommunityOutagesListView(service: services.communityOutages, markets: services.markets)
        }
        .onReceive(services.location.$authorizationStatus) { status in
            let previous = locationStatus
            locationStatus = status
            // Autorisation tout juste accordée : « Autour de toi » se remplit sans
            // attendre le prochain retour sur l'onglet. La première valeur reçue
            // n'est pas un changement : `.task` charge déjà l'écran.
            if let previous, !Self.isAuthorized(previous), Self.isAuthorized(status) {
                Task { await refreshNearby(forceFresh: true) }
            }
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    private var firstName: String {
        user?.name?.split(separator: " ").first.map(String.init) ?? (user == nil ? "SignalQuest" : String(localized: "à toi"))
    }

    // MARK: Header — avatar + salutation + cloche

    private var header: some View {
        HStack(spacing: SQSpace.md + 2) {
            // Le nom est annoncé juste à droite ; relire aussi l'image produit
            // un élément sans description utile dans VoiceOver.
            if let user {
                SQAvatar(url: user.avatarUrl, name: user.name ?? "SignalQuest", size: 54)
                    .accessibilityHidden(true)
            } else {
                // Invité : le logo, pas un faux avatar « S ».
                Image("SQLogoMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(user == nil ? String(localized: "Bienvenue sur") : String(localized: "Bonjour,"))
                    .font(SQFont.body(14))
                    .foregroundStyle(SQColor.labelSecondary)
                Text(firstName)
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    // Aux plus grandes tailles, « SignalQuest » se coupait en
                    // « SignalQu / est » : le nom rétrécit plutôt (UI-16).
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            Spacer()
            if user != nil { NavigationLink {
                NotificationsCenterView(service: services.notifications, badge: services)
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .background(SQColor.surface, in: Circle())
                    .sqShadowSoft()
                    .overlay(alignment: .topTrailing) {
                        if services.unreadNotifications > 0 {
                            Text(services.unreadNotifications > 99 ? "99+" : "\(services.unreadNotifications)")
                                .font(SQFont.body(11, relativeTo: .caption))
                                .fontWeight(.bold)
                                .foregroundStyle(SQColor.onAccent)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(SQColor.brandRed, in: Capsule())
                                .offset(x: 4, y: -4)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Notifications")
            .accessibilityValue(services.unreadNotifications > 0 ? Text(services.unreadNotifications, format: .number) : Text(""))
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Bandeau « panne à proximité »

    /// Juste sous l'état du réseau, avant les actions : quand le réseau ne marche pas, la
    /// question suivante est « est-ce moi ou est-ce l'antenne ? », et c'est ce bandeau qui y
    /// répond. Plus bas, il serait lu après avoir été contourné.
    ///
    /// Il PROPOSE, il n'envoie rien : signaler automatiquement ferait de la carte une carte de
    /// bruit, et « quelqu'un a constaté » ne voudrait plus rien dire.
    @ViewBuilder
    private var outageBanner: some View {
        if let outage = nearbyOutage {
            let tint = OutageTint.of(outage.severity)
            Button {
                Haptics.selection()
                router.route(toCommunityOutage: outage)
            } label: {
                HStack(spacing: SQSpace.md) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        // L'encre, pas la teinte : le pictogramme est posé sur un conteneur de sa
                        // propre couleur, où la teinte de base tombe sous le 3:1 de WCAG 1.4.11
                        // en apparence sombre.
                        .foregroundStyle(OutageTint.inkOf(outage.severity))
                        .frame(width: 46, height: 46)
                        .background(tint.opacity(0.13), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(outageBannerTitle(outage))
                            .font(SQFont.body(15, .semibold))
                            .foregroundStyle(SQColor.label)
                        Text(outageBannerSubtitle(outage))
                            .font(SQFont.body(13))
                            .foregroundStyle(SQColor.labelSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                }
                .padding(SQSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqCardBackground()
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel(Text("\(outageBannerTitle(outage)). \(outageBannerSubtitle(outage))"))
            .accessibilityHint("Ouvre la panne sur la carte")
            // L'ARRIVÉE de l'information mérite une transition — c'est un changement, pas un
            // état. Rien ne bouge ensuite, et `sqAnimation` se tait sous Réduire les animations.
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// « Panne signalée sur ce secteur » — jamais « votre réseau est en panne » : la panne est
    /// celle d'un opérateur sur un pylône, pas forcément la nôtre.
    private func outageBannerTitle(_ outage: CommunityOutage) -> String {
        outage.state == .confirmed
            ? String(localized: "Panne confirmée près de toi")
            : String(localized: "Panne signalée près de toi")
    }

    private func outageBannerSubtitle(_ outage: CommunityOutage) -> String {
        let place = outage.address ?? outage.siteName ?? outage.targetId
        let what = outage.severity == .degraded
            ? String(localized: "Service dégradé")
            : String(localized: "Plus aucun service")
        return place.isEmpty ? what : "\(what) · \(place)"
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
                Text(LocalizedStringKey(networkTitle))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                    .accessibilityIdentifier("home.network.title")
                Text(LocalizedStringKey(networkSubtitle))
                    .font(.subheadline)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SQSpace.sm)
            if let networkBadge {
                // Texte à l'encre, couleur portée par le point : teinté sur sa propre
                // teinte à 14 %, le texte tombait vers 2:1 en jaune et vert clair (TRX-04).
                HStack(spacing: 6) {
                    Circle()
                        .fill(networkTint)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(LocalizedStringKey(networkBadge))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SQColor.label)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(networkTintSoft, in: Capsule(style: .continuous))
            }
            // Indice discret que la carte est cliquable (verdict explicable).
            if networkQuality != nil {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SQColor.labelTertiary)
            }
        }
        .padding(.vertical, SQSpace.lg + 2)
        .padding(.horizontal, SQSpace.xl)
        .sqCardBackground()
    }

    private var isOnline: Bool { services.networkPath.isOnline }

    // Priorité du verdict affiché : hors-ligne → mode données réduites (contrainte
    // système réelle) → qualité communautaire de l'opérateur identifié → état neutre en
    // attendant les données. On n'annonce plus « au top » par défaut : le libellé
    // vert ne s'affiche que si les mesures de la zone le confirment.

    private var networkTitle: String {
        guard isOnline else { return String(localized: "Hors connexion") }
        if networkStatus.isConstrained { return String(localized: "Réseau limité") }
        if let quality = networkQuality { return quality.level.homeNetworkTitle }
        return String(localized: "Connecté")
    }

    private var networkSubtitle: String {
        guard isOnline else { return String(localized: "Vérifie ta connexion") }
        // Verdict dispo (hors mode données réduites) : opérateur + provenance + débit
        // médian communautaire. Le détail RSRP vit dans la sheet explicative
        // (peu lisible en un coup d'œil sur la pastille).
        if !networkStatus.isConstrained, let quality = networkQuality {
            // La provenance de l'opérateur (« IP/ASN », « SIM ») n'a rien à faire
            // sur cette ligne : la feuille explicative la détaille (MES-35).
            if let mbps = quality.medianDownloadMbps {
                return "\(quality.operatorLabel) · \(SQUnits.throughput(mbps: Double(mbps)))"
            }
            return "\(quality.operatorLabel) · " + String(localized: "\(quality.sampleCount) mesures")
        }
        switch networkStatus.connection {
        case .cellular:
            // « 5G » suffit en un coup d'œil : la nuance NSA/SA, sans explication
            // possible sur cette ligne, reste aux écrans de mesure (TRX-28).
            let tech = networkStatus.cellularTechnology.map {
                $0 == .fiveGNSA || $0 == .fiveGSA ? "5G" : $0.displayName
            }
            return [String(localized: "Cellulaire"), tech, networkStatus.operatorName]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        case .other: return String(localized: "Connexion inconnue")
        }
    }

    /// Seul le verdict mérite une pastille : « Hors connexion · Coupé » ou
    /// « Connecté · En ligne » répétaient le titre.
    private var networkBadge: String? {
        guard isOnline, !networkStatus.isConstrained else { return nil }
        return networkQuality?.level.title
    }

    private var networkTint: Color {
        guard isOnline else { return SQColor.danger }
        if networkStatus.isConstrained { return SQColor.warning }
        if let quality = networkQuality { return quality.level.swiftUIColor }
        return SQColor.label
    }

    private var networkTintSoft: Color {
        guard isOnline else { return SQColor.dangerSoft }
        if networkStatus.isConstrained { return SQColor.warningSoft }
        if let quality = networkQuality { return quality.level.swiftUIColor.opacity(0.14) }
        return SQColor.surfaceMuted
    }

    // MARK: Grille 2×2 d'actions

    /// « Tester » reste la tuile principale ; les trois autres mènent là où la barre
    /// d'onglets ne va pas en un geste. Carte et Communauté la doublaient (UI-06).
    private var actionsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 14) {
            actionTile(
                identifier: "speedtest",
                title: "Tester",
                subtitle: "Débit & latence",
                systemImage: "speedometer",
                accented: true
            ) { router.selectedTab = .speed }

            actionTile(
                identifier: "driveTest",
                title: "Drive Test",
                subtitle: "Tests pendant un trajet",
                systemImage: "location.north.line.fill"
            ) {
                // Même chemin que le raccourci Siri : l'onglet Tester ouvre le Drive Test.
                router.selectedTab = .speed
                router.pendingDriveTest = true
            }

            actionTile(
                identifier: "outages",
                title: "Pannes",
                subtitle: "Signalées par la communauté",
                systemImage: "exclamationmark.triangle"
            ) { showOutages = true }

            actionTile(
                identifier: "messages",
                title: "Messages",
                subtitle: messagesSubtitle,
                systemImage: "bubble.left.and.bubble.right",
                badgeCount: user == nil ? 0 : services.unreadConversations
            ) { router.route(toConversation: nil) }
        }
    }

    private var messagesSubtitle: String {
        guard user != nil else { return String(localized: "Connexion requise") }
        let unread = services.unreadConversations
        if unread <= 0 { return String(localized: "Conversations") }
        return unread == 1 ? String(localized: "1 non lu") : String(localized: "\(unread) non lus")
    }

    private func actionTile(
        identifier: String,
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
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: SQSpace.sm + 2))
                : AnyLayout(HStackLayout(alignment: .center, spacing: SQSpace.sm + 2))
            layout {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accented ? SQColor.onAccent : SQColor.brandRed)
                        .frame(width: 36, height: 36)
                        .background(
                            accented ? AnyShapeStyle(SQColor.onAccent.opacity(0.18)) : AnyShapeStyle(SQColor.accentSoft),
                            in: Circle()
                        )
                    if badgeCount > 0 {
                        Text("\(min(badgeCount, 99))")
                            .font(SQFont.body(11, .bold))
                            .foregroundStyle(SQColor.onAccent)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(SQColor.brandRed, in: Circle())
                            .offset(x: 6, y: -4)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(SQFont.body(16, .bold, relativeTo: .headline))
                        .foregroundStyle(accented ? SQColor.onAccent : Color.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.85)
                        .accessibilityIdentifier("home.action.title.\(identifier)")
                    Text(LocalizedStringKey(subtitle))
                        .font(SQFont.body(12, .semibold, relativeTo: .footnote))
                        // Pas d'alpha sur brique : à 12,5 pt il faut 4,5:1, que
                        // `onAccent` n'atteint qu'à α ≈ 0,92 — indiscernable du
                        // plein. La hiérarchie tient déjà par la taille (16,5
                        // semi-gras contre 12,5 normal).
                        .foregroundStyle(accented ? SQColor.onAccent : Color.primary)
                        // Trois lignes : en texte XXL, « Signalées par la communauté »
                        // se coupait (tour du 30/09).
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.action.subtitle.\(identifier)")
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 72,
                alignment: .leading
            )
            .padding(dynamicTypeSize.isAccessibilitySize ? SQSpace.lg : SQSpace.md)
            .background(
                accented ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface),
                in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
            )
            .overlay {
                // En « Noir intense », seul ce liseré détache les tuiles du fond (TRX-09).
                if !accented {
                    RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                        .strokeBorder(SQOledPalette.cardStroke, lineWidth: 1)
                }
            }
            .modifier(HomeTileShadow())
            .contentShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        // Les DEUX morceaux passent par le catalogue : composer les `String`
        // bruts produisait « Communauté. Fil, stories, entraide » à VoiceOver
        // dans une app par ailleurs anglaise.
        .accessibilityLabel(
            Text(LocalizedStringKey(title)) + Text(". ") + Text(LocalizedStringKey(subtitle))
        )
        // Ancre STABLE pour les tests UI et pour la localisation à venir : le
        // libellé visible change avec la DA et la langue, pas l'identifiant.
        .accessibilityIdentifier("home.action.\(identifier)")
    }

    // MARK: Invitation à la localisation

    /// Sans position, « Autour de toi » restait masqué sans rien proposer (TRX-19).
    /// La demande système ne part que sur ce bouton, jamais d'elle-même (UXP-01) ;
    /// refusée, elle ne reviendrait plus : le bouton ouvre alors les Réglages.
    /// Réservée aux membres : pour un invité, le pouls et les mesures récentes
    /// répondent 401, la carte promettrait ce qui n'arrivera pas.
    @ViewBuilder
    private var locationPrompt: some View {
        let status = locationStatus ?? services.location.authorizationStatus
        let nearbyIsEmpty = pulse?.hasData != true && nearbyMeasures.isEmpty
        if user != nil, nearbyIsEmpty, status == .notDetermined || status == .denied {
            HStack(alignment: .top, spacing: SQSpace.md) {
                Image(systemName: status == .denied ? "location.slash" : "location")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .frame(width: 40, height: 40)
                    .background(SQColor.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Le réseau autour de toi")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                        .sqHeader()
                    Text(status == .denied
                         ? "La localisation est désactivée pour SignalQuest. Active-la dans les Réglages pour voir les mesures et les pannes à moins d’un kilomètre."
                         : "Autorise la localisation pour voir les mesures, les pannes et l’opérateur le plus rapide à moins d’un kilomètre.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Haptics.selection()
                        if status == .denied {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        } else {
                            services.location.requestWhenInUse()
                        }
                    } label: {
                        Text(status == .denied ? "Ouvrir les Réglages" : "Activer la localisation")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.accentInk)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.location.enable")
                }
                Spacer(minLength: 0)
            }
            .padding(SQSpace.lg)
            .sqCardBackground()
        }
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
                .sqCardBackground()
            }
        }
    }

    /// Agrégat de zone (pouls réseau) : 3 mini-tuiles RSRP / débit médian / meilleur op.
    /// Tappable vers la comparaison des opérateurs dès qu'au moins deux sont mesurés.
    private func pulseRow(_ pulse: NetworkPulse) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: SQSpace.sm) { pulseTiles(pulse) }
            } else {
                // Tuiles de même hauteur, même quand un libellé passe sur deux lignes.
                HStack(spacing: SQSpace.sm + 2) { pulseTiles(pulse) }
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Le verdict en mots d'abord, la mesure brute ensuite : « -97 dBm » ou
    /// « meilleur op. » ne disaient rien à un débutant (MES-20). Le point reprend
    /// la couleur de l'échelle commune ; le texte reste à l'encre.
    @ViewBuilder
    private func pulseTiles(_ pulse: NetworkPulse) -> some View {
        if let rsrp = pulse.avgRsrpDbm {
            let signal = SQQualityScale.Signal(rsrp: Double(rsrp))
            pulseTileButton(value: signal.label, caption: String(localized: "Signal · \(rsrp) dBm"),
                            dot: signal.color, metric: .signal, term: .rsrp)
        }
        if let median = pulse.medianDownloadMbps {
            let tier = SQQualityScale.Throughput(mbps: Double(median))
            pulseTileButton(value: SQUnits.throughput(mbps: Double(median)),
                            caption: String(localized: "Réception typique"),
                            dot: tier.color, metric: .download, term: .download)
        }
        if let best = pulse.bestOperator, !best.isEmpty {
            pulseTileButton(value: best, caption: String(localized: "Le plus rapide"), metric: .download)
        }
    }

    /// Tuile du pouls, cliquable vers la comparaison des opérateurs sur sa métrique
    /// (signal → signal, réception et opérateur le plus rapide → débit). Le ⓘ est
    /// posé par-dessus la tuile, pas dedans : un bouton dans un bouton ne répond pas.
    private func pulseTileButton(value: String, caption: String, dot: Color? = nil,
                                 metric: NearbyOperatorMetric, term: SQTerm? = nil) -> some View {
        Button {
            guard userLocation != nil else { return }
            Haptics.selection()
            comparisonMetric = metric
            showOperatorComparison = true
        } label: {
            pulseTile(value: value, caption: caption, dot: dot)
        }
        .buttonStyle(.plain)
        .disabled(userLocation == nil)
        .accessibilityLabel(Text(verbatim: "\(caption) : \(value)"))
        .accessibilityHint(Text("Compare les opérateurs autour de toi"))
        .overlay(alignment: .topTrailing) {
            if let term {
                SQInfoButton(term: term)
                    .padding(SQSpace.xs)
            }
        }
    }

    private func pulseTile(value: String, caption: String, dot: Color?) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(SQFont.display(17, .bold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("home.pulse.value")
            }
            Text(caption)
                .font(SQType.micro)
                // À l'encre : le gris secondaire (5,2:1 sur la tuile) tombait sous
                // 4,5:1 une fois rendu à 12 pt. La hiérarchie tient par la taille.
                .foregroundStyle(SQColor.label)
                // Trois tuiles se partagent la largeur : à Dynamic Type élevé,
                // le libellé ne tenait plus et se tronquait silencieusement
                // (relevé par `performAccessibilityAudit`). La valeur avait déjà
                // son repli, pas le libellé.
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("home.pulse.unit")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bande haute réservée au ⓘ posé dans le coin : sans elle, il chevauchait
        // une valeur longue (« 120 Mbit/s »).
        .padding(.top, SQSpace.lg + 2)
        .padding(.bottom, SQSpace.sm + 2)
        .padding(.horizontal, SQSpace.xs)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// Une mesure communautaire proche : techno teintée, débit, contexte, distance.
    private func nearbyMeasureRow(_ measure: AndroidSpeedtestMarker) -> some View {
        Button {
            Haptics.selection()
            router.selectedTab = .map
        } label: {
            HStack(spacing: SQSpace.md) {
                // Texte à l'encre sur une teinte douce, couleur de la techno portée
                // par l'anneau : en blanc sur la teinte pleine, « 4G » restait sous
                // 4,5:1 (3,7:1 sur le bleu), comme la pastille du verdict (TRX-04).
                let tint = TechAccent.color(for: measure.tech)
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    Circle().strokeBorder(tint, lineWidth: 2)
                    if let label = Self.techShortLabel(measure.tech) {
                        Text(LocalizedStringKey(label))
                            .font(SQFont.body(13, .bold))
                            .foregroundStyle(SQColor.label)
                    } else {
                        // Techno inconnue (ex. « CELLULAR » brut) : icône antenne.
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SQColor.label)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(verbatim: SQUnits.throughput(mbps: measure.downloadMbps))
                            .font(SQFont.body(15, .semibold))
                            .foregroundStyle(SQColor.label)
                        if let ping = measure.pingMs {
                            Text(verbatim: "· \(SQUnits.milliseconds(ping))")
                                .font(SQFont.body(13))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    // Encre et retour à la ligne : en gris sur une ligne, le contexte
                    // manquait de contraste et se coupait aux grandes tailles.
                    Text(nearbyContext(for: measure))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.nearby.context")
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

    private static func techShortLabel(_ tech: String?) -> String? { TechAccent.shortLabel(for: tech) }

    /// « Orange · il y a 2 h · à 450 m » — ce qui est connu, dans cet ordre.
    private func nearbyContext(for measure: AndroidSpeedtestMarker) -> String {
        var parts: [String] = []
        if let op = measure.`operator`, !op.isEmpty { parts.append(op) }
        if let date = measure.timestamp {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        if let location = userLocation {
            let distance = location.distance(from: CLLocation(latitude: measure.lat, longitude: measure.lng))
            parts.append(String(localized: "à \(SignalFormatters.meters(distance))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Dernière mesure

    /// Ce que montre la carte « Dernière mesure », quelle que soit sa source.
    private struct DisplayedMeasurement {
        let date: Date?
        let downloadMbps: Double
        let latencyMs: Double?
        let technology: String?
    }

    /// Le test le plus récent entre l'historique local, le plus détaillé, et le
    /// compte, qui voit aussi les tests d'un autre appareil ou d'avant une
    /// réinstallation (UI-06, UI-12).
    private var displayedMeasurement: DisplayedMeasurement? {
        let local = latestMeasurement.map {
            DisplayedMeasurement(date: $0.createdAt, downloadMbps: $0.downloadAverageMbps,
                                 latencyMs: $0.pingMinMs ?? $0.pingMs, technology: measurementTech($0))
        }
        let account = accountLatest.flatMap { test -> DisplayedMeasurement? in
            guard let download = test.downloadAverageMbps else { return nil }
            return DisplayedMeasurement(date: test.timestamp, downloadMbps: download,
                                        latencyMs: test.ping, technology: Self.techShortLabel(test.networkType))
        }
        guard let account else { return local }
        guard let local, let localDate = local.date else { return account }
        // Le même test, envoyé au serveur, revient avec quelques secondes d'écart :
        // le local, plus détaillé, garde la priorité à égalité.
        if let accountDate = account.date, accountDate > localDate.addingTimeInterval(60) { return account }
        return local
    }

    @ViewBuilder
    private var latestMeasurementSection: some View {
        if let measurement = displayedMeasurement {
            Button {
                Haptics.selection()
                router.selectedTab = .speed
            } label: {
                HStack(spacing: SQSpace.md) {
                    VStack(alignment: .leading, spacing: 1) {
                        Group {
                            if let date = measurement.date {
                                // Relative, comme « Autour de toi » : la date complète
                                // avec l'année passait sur deux lignes.
                                Text("Dernière mesure · \(date.formatted(.relative(presentation: .named)))")
                            } else {
                                Text("Dernière mesure")
                            }
                        }
                        .font(SQFont.body(13.5))
                        .foregroundStyle(SQColor.labelSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(verbatim: SQUnits.throughputValue(mbps: measurement.downloadMbps))
                                .font(SQFont.display(30, .bold))
                                .foregroundStyle(SQColor.label)
                            Text(verbatim: SQUnits.throughputUnit(mbps: measurement.downloadMbps))
                                .font(SQFont.body(15, .medium))
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Spacer()
                    if let latency = measurement.latencyMs {
                        Text(verbatim: SQUnits.milliseconds(latency))
                            .font(SQFont.body(13, .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(SQColor.label)
                            .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
                    }
                    if let tech = measurement.technology {
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
                .sqCardBackground()
                .contentShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Dernière mesure : \(Int(measurement.downloadMbps)) mégabits par seconde. Ouvre le Speedtest.")
            .accessibilityIdentifier("home.latestMeasurement")
        } else {
            EmptyStateView(
                title: "Aucune mesure pour l’instant",
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
        async let account: Void = refreshAccountLatest(forceFresh: forceFresh)
        await refreshNearby(forceFresh: forceFresh)
        await account
    }

    /// Dernier test du compte. Silencieux : hors ligne ou en erreur, l'historique
    /// local suffit. Même retenue que « Autour de toi » : `refresh()` repart à
    /// chaque retour au premier plan.
    private func refreshAccountLatest(forceFresh: Bool) async {
        guard user != nil else { return }
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

    /// Charge le pouls réseau, les dernières mesures communautaires et le verdict
    /// de qualité (opérateur identifié) autour de la position. Best-effort : sans
    /// position ou sans données, la section reste masquée et la pastille retombe
    /// sur un état neutre (jamais d'erreur affichée sur l'Accueil).
    /// `forceFresh` (pull-to-refresh) contourne le cache de tuiles.
    private func refreshNearby(forceFresh: Bool) async {
        if AppEnvironment.usesDemoData {
            applyDemoNearby()
            return
        }
        // Throttle : refresh() est relancé à CHAQUE foreground + retour d'onglet.
        // Sans garde, pouls et mesures récentes repartaient sur le réseau à chaque
        // fois. On tolère 20 s entre deux rafraîchissements réels (PERF-HOME-01).
        if !forceFresh, Date().timeIntervalSince(lastNearbyRefreshAt) < 20 { return }
        // Ne JAMAIS déclencher le prompt système de localisation depuis l'Accueil
        // (même garde que le feed) : sinon il tombe hors contexte au premier
        // lancement et court-circuite le LocationPrimingSheet du speedtest (UXP-01).
        // On n'interroge la position que si l'autorisation est déjà accordée ou
        // qu'un fix est déjà connu.
        let status = services.location.authorizationStatus
        let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        guard authorized || services.location.lastLocation != nil else { return }
        guard let location = await services.location.currentLocation(timeoutSeconds: 6) else { return }
        userLocation = location
        lastNearbyRefreshAt = Date()
        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        // Pull-to-refresh : tuiles fraîches forcées (bypass du cache disque d'1 h) ;
        // sinon on tolère jusqu'à 90 s de cache pour ne pas marteler l'API.
        let maxAge: TimeInterval = forceFresh ? 0 : 90
        let isCellular = services.networkPath.status.connection == .cellular
        let simPlmn = services.networkPath.simPLMN().plmn

        // Pouls recadré sur le même rayon que le reste (1 km), tous opérateurs.
        async let pulseTask: NetworkPulse? = try? services.feed.networkPulse(
            latitude: lat, longitude: lng, radiusMeters: Self.nearbyRadiusMeters
        )
        // Liste = les plus RÉCENTS (le snapshot social porte des timestamps fiables,
        // contrairement aux tuiles carto). Comparaison = tuiles (volume sur 30 j).
        async let recentTask: [AndroidSpeedtestMarker] = recentNearbySpeedtests(latitude: lat, longitude: lng)
        async let tilesTask: [AndroidSpeedtestMarker] = nearbySpeedtests(latitude: lat, longitude: lng, around: location, maxAge: maxAge)
        async let qualityTask: NearbyNetworkQuality? = services.nearbyQuality.verdict(
            latitude: lat, longitude: lng, isCellular: isCellular, simPlmn: simPlmn, maxAge: maxAge
        )
        async let outageTask: CommunityOutage? = nearestOutage(around: location)

        pulse = await pulseTask
        nearbyOutage = await outageTask
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

    /// Démo (`--demo-data`, tours de captures) : « Autour de toi » rempli sans
    /// réseau, avec le pouls de démo du fil (Lyon) et trois mesures proches.
    private func applyDemoNearby() {
        let now = Date()
        userLocation = CLLocation(latitude: 45.764, longitude: 4.8357)
        pulse = .demo
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

    /// La panne signalée la plus pertinente autour de la position, ou `nil`.
    ///
    /// Rayon volontairement plus large que le kilomètre de « Autour de toi » (≈2,5 km) : une
    /// coupure porte sur une CELLULE, pas sur un pâté de maisons, et on peut très bien être servi
    /// par un pylône situé à deux kilomètres. Tous opérateurs confondus — on n'affiche pas moins
    /// que ce que la personne peut constater, et son opérateur réel n'est pas toujours connu
    /// (Wi-Fi, VPN, double SIM).
    ///
    /// Priorité : la plus grave d'abord, puis la mieux établie. Le bandeau n'en montre qu'UNE :
    /// en empiler trois ferait de l'accueil un tableau de bord d'incidents, ce qu'il n'est pas.
    /// Best-effort et silencieux : sans réseau ni marché, le bandeau ne s'affiche simplement pas.
    private func nearestOutage(around location: CLLocation) async -> CommunityOutage? {
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        guard let market = await services.markets.marketForLocation(
            latitude: latitude,
            longitude: longitude
        )?.code else { return nil }
        let halfSpanLat = Self.outageHalfSpanLat
        let halfSpanLng = halfSpanLat / max(cos(latitude * .pi / 180), 0.01)
        let bounds = MapBounds(
            north: latitude + halfSpanLat,
            south: latitude - halfSpanLat,
            east: longitude + halfSpanLng,
            west: longitude - halfSpanLng
        )
        let outages = (try? await services.communityOutages.outages(
            in: bounds, marketCode: market, operatorKey: "ALL"
        )) ?? []
        return outages
            .filter(\.state.isVisible)
            .max { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity == .degraded }
                return (lhs.state == .confirmed ? 1 : 0) < (rhs.state == .confirmed ? 1 : 0)
            }
    }

    /// Demi-fenêtre du bandeau de panne, en degrés de latitude : ≈2,5 km.
    private static let outageHalfSpanLat = 0.0225

    /// Tous les speedtests communautaires à ≤ 1 km RÉELS de la position (la maille
    /// des tuiles déborde largement, d'où le filtrage par distance).
    private func nearbySpeedtests(latitude: Double, longitude: Double, around location: CLLocation, maxAge: TimeInterval) async -> [AndroidSpeedtestMarker] {
        guard let market = await services.markets.marketForLocation(
            latitude: latitude,
            longitude: longitude
        )?.code else { return [] }
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
    func body(content: Content) -> some View {
        content.sqShadowSoft()
    }
}
