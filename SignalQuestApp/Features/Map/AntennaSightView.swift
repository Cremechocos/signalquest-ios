import SwiftUI
import CoreLocation

/// Le bloc « depuis ta position » de la fiche antenne : distance, cap, secteur
/// qui couvre, angle d'élévation, et un aperçu du relief entre les deux points.
struct AntennaSightCard: View {
    let site: AntennaSite
    let details: AntennaDetails?
    /// Secteurs à utiliser tant que la fiche détaillée n'a pas répondu.
    ///
    /// C'est l'appelant qui les scope sur l'opérateur affiché : sur un support
    /// partagé, `site.azimuths` ne porte que ceux du premier opérateur fusionné,
    /// et la boussole désignait donc le lobe d'un autre le temps du chargement —
    /// c'est-à-dire à chaque bascule d'opérateur.
    let fallbackAzimuths: [Double]
    /// Le service est OBSERVÉ, pas seulement lu.
    ///
    /// `AppServices` ne republie pas les changements de `LocationService` : une
    /// vue qui se contentait de lire `services.location` ne se rafraîchissait
    /// donc jamais. La flèche de la boussole restait figée, et la distance
    /// gardait la valeur d'ouverture de la fiche même après un relevé GPS.
    @ObservedObject var location: LocationService
    let origin: AntennaSightOrigin
    let tint: Color
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: AntennaSightViewModel
    @State private var presentedProfile: AntennaProfilePresentation?
    @State private var gpsSnapshot = AntennaSightGPSSnapshot()
    @State private var originRevision = UUID()
    @State private var gpsWasInRange = false
    @State private var isRefreshing = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        site: AntennaSite,
        details: AntennaDetails?,
        fallbackAzimuths: [Double],
        location: LocationService,
        origin: AntennaSightOrigin = .device,
        tint: Color,
        terrain: TerrainServicing
    ) {
        self.site = site
        self.details = details
        self.fallbackAzimuths = fallbackAzimuths
        self.location = location
        self.origin = origin
        self.tint = tint
        _model = StateObject(wrappedValue: AntennaSightViewModel(terrain: terrain))
    }

    private var gpsPolicy: LocationFixPolicy {
        LocationFixPolicy(maxAge: LocationService.defaultMaxLocationAge, maximumAccuracy: nil)
    }

    private var currentGPS: CLLocation? { location.cachedLocation() }

    private var userLocation: CLLocation? {
        if origin.isDevice {
            guard currentGPS != nil, let fix = gpsSnapshot.location, location.isUsable(fix) else { return nil }
            return fix
        }
        guard let coordinate = origin.coordinate(deviceLocation: nil) else { return nil }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private var originTimestamp: Date? { origin.isDevice ? userLocation?.timestamp : nil }

    private var antennaCoordinate: CLLocationCoordinate2D? {
        if let core = details?.core, core.lat != 0 || core.lng != 0,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: core.lat, longitude: core.lng)) {
            return CLLocationCoordinate2D(latitude: core.lat, longitude: core.lng)
        }
        guard let latitude = site.latitude, let longitude = site.longitude, site.hasValidCoordinate else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var distanceMeters: Double? {
        guard let userLocation, let antenna = antennaCoordinate else { return nil }
        return userLocation.distance(from: CLLocation(latitude: antenna.latitude, longitude: antenna.longitude))
    }

    private var bearing: Double? {
        guard let userLocation, let antenna = antennaCoordinate else { return nil }
        return AntennaSectorGeometry.bearing(from: userLocation.coordinate, to: antenna)
    }

    /// Secteur du site le plus aligné sur l'utilisateur, et s'il le couvre.
    private var alignedSector: (azimuth: Double, offset: Double, inSector: Bool)? {
        guard let userLocation, let antenna = antennaCoordinate else { return nil }
        let azimuths = (details?.core?.azimuts ?? []).isEmpty ? fallbackAzimuths : (details?.core?.azimuts ?? [])
        return AntennaSectorGeometry.bestSector(antenna: antenna, azimuths: azimuths, user: userLocation.coordinate)
    }

    /// Hauteur de rayonnement, du plus précis au plus grossier. `site.height`
    /// vient de la tuile (`support_info.hauteur`) : il permet une première visée
    /// juste dès l'ouverture, sans attendre la réponse du détail.
    private var antennaHeightMeters: Double? {
        details?.core?.siteInfo.radiatingHeightMeters ?? site.height
    }

    /// Nature du support — connue elle aussi dès la tuile.
    private var supportLabel: String? {
        details?.core?.siteInfo.supportType ?? details?.core?.technical.supportType ?? site.supportNature
    }

    /// Différence de hauteur entre le sommet de l'antenne et les yeux de
    /// l'observateur, relief compris quand il est connu.
    private var deltaHeightMeters: Double? {
        guard let antennaHeightMeters else { return nil }
        let groundDelta: Double
        if hasCurrentProfile, let antennaGround = model.antennaGroundMeters, let userGround = model.userGroundMeters {
            groundDelta = antennaGround - userGround
        } else {
            groundDelta = 0
        }
        return antennaHeightMeters + groundDelta - AntennaSightGeometry.observerHeightMeters
    }

    private var elevationAngle: Double? {
        guard let distanceMeters, let deltaHeightMeters else { return nil }
        return AntennaSightGeometry.elevationAngle(distanceMeters: distanceMeters, deltaHeightMeters: deltaHeightMeters)
    }

    /// Fréquence la plus basse du site : c'est elle qui porte le plus loin, donc
    /// celle qui compte quand on cherche à savoir si le site atteint l'endroit
    /// où l'on est. C'est aussi le cas le plus exigeant en zone de Fresnel.
    private var frequencyMhz: Double {
        let labels = (details?.core?.frequencyBands ?? []).isEmpty
            ? site.radioSystems
            : (details?.core?.frequencyBands ?? [])
        let frequencies = labels.compactMap { label -> Double? in
            guard let range = label.range(of: #"\d{3,4}"#, options: .regularExpression) else { return nil }
            return Double(label[range])
        }
        return frequencies.min() ?? 2100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if case let .searchedAddress(_, _, title) = origin, !title.isEmpty {
                Text(title)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if let originTimestamp {
                Text("Position relevée à \(originTimestamp.formatted(date: .omitted, time: .standard))")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if let distanceMeters, let bearing {
                HStack(alignment: .center, spacing: SQSpace.lg) {
                    AntennaCompassDial(
                        bearing: bearing,
                        deviceHeading: origin.isDevice ? location.headingDegrees : nil,
                        sectorAzimuth: alignedSector?.azimuth,
                        tint: tint
                    )
                    .frame(width: 92, height: 92)
                    .animation(reduceMotion ? nil : SQMotion.standard, value: location.headingDegrees)

                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text(SQUnits.distance(meters: distanceMeters))
                            .accessibilityIdentifier("antenna.sight.distance")
                            .font(SQType.title)
                            .foregroundStyle(SQColor.label)
                        Text("cap \(Int(bearing.rounded()))° \(AntennaSightGeometry.cardinal(for: bearing))")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                        if let elevationAngle {
                            Text(elevationLabel(elevationAngle))
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if origin.isDevice { refreshButton }
                }
                sectorLine
                if permitsProfile && model.displayKey == sightTaskKey { terrainPreview }
            } else {
                unavailableLine
            }
        }
        .foregroundStyle(SQColor.label)
        .task(id: sightTaskKey) { await loadProfile() }
        // La fiche s'affiche avant que le détail du site n'arrive : quand la vraie
        // hauteur d'antenne se substitue à la valeur par défaut, le profil est
        // reprojeté sur les mesures déjà en main, sans nouvel appel réseau.
        .onChangeCompat(of: geometryKey) { _, _ in
            model.setGeometry(antennaHeightMeters: antennaHeightMeters ?? 25, frequencyMhz: frequencyMhz)
        }
        .onChangeCompat(of: sightTaskKey) { _, key in
            if presentedProfile?.requestKey != key { presentedProfile = nil }
        }
        .onChangeCompat(of: location.lastLocation) { _, _ in reconcileGPSOrigin() }
        .onChangeCompat(of: antennaKey) { _, _ in reconcileGPSOrigin() }
        .onChangeCompat(of: origin) { _, _ in
            originRevision = UUID()
            gpsSnapshot.clear()
            reconcileGPSOrigin(force: true)
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { reconcileGPSOrigin() }
        }
        .onAppear {
            reconcileGPSOrigin()
            location.startHeadingUpdates()
        }
        .onDisappear { location.stopHeadingUpdates() }
        .task(id: gpsExpiryTaskKey) { await expireGPSOrigin() }
        .sheet(item: $presentedProfile) { presentation in
            presentation.view
                .task(id: scenePhase) { await expirePresentation(presentation) }
        }
    }

    /// Le profil et ses paramètres sont copiés avant toute transition modale.
    private func presentProfile() {
        guard !isRefreshing, hasCurrentProfile, let snapshot = model.snapshot(), snapshot.requestKey == sightTaskKey else { return }
        presentedProfile = AntennaProfilePresentation(
            requestKey: snapshot.requestKey,
            expiresAt: origin.isDevice ? gpsSnapshot.expiresAt(maxAge: gpsPolicy.maxAge) : nil,
            view: AntennaProfileView(
                profile: snapshot.profile,
                verdict: snapshot.verdict,
                siteLabel: site.siteId ?? site.id,
                distanceMeters: snapshot.distanceMeters,
                antennaHeightMeters: antennaHeightMeters,
                heightIsEstimated: details?.core?.siteInfo.radiatingHeightIsEstimated ?? false,
                supportHeightMeters: details?.core?.siteInfo.supportHeightMeters
                    ?? details?.core?.siteInfo.pylonHeight
                    ?? site.height,
                supportLabel: supportLabel,
                antennaTypes: details?.core?.siteInfo.antennaTypes ?? [],
                tint: tint,
                frequencyMhz: frequencyMhz,
                originLabel: origin.label,
                isSearchedAddress: !origin.isDevice,
                originTimestamp: originTimestamp
            )
        )
    }

    private var antennaKey: String {
        guard let antenna = antennaCoordinate else { return "none" }
        return "\(site.id)|\(antenna.latitude),\(antenna.longitude)"
    }

    private var currentGPSDistance: Double? {
        guard let fix = currentGPS, let antenna = antennaCoordinate else { return nil }
        return fix.distance(from: CLLocation(latitude: antenna.latitude, longitude: antenna.longitude))
    }

    private func reconcileGPSOrigin(force: Bool = false) {
        guard origin.isDevice else {
            gpsSnapshot.clear()
            return
        }
        let inRange = currentGPSDistance.map { $0.isFinite && $0 <= 30_000 } ?? false
        gpsSnapshot.update(current: currentGPS, policy: gpsPolicy, now: Date(), force: force || (inRange && !gpsWasInRange))
        gpsWasInRange = inRange
    }

    private var gpsExpiryTaskKey: String {
        "\(origin.isDevice)|\(contextKey)|\(antennaKey)|\(scenePhase == .active)"
    }

    /// SwiftUI annule cette attente quand le relevé ou l'activité de scène
    /// change. À la réapparition et au retour actif, la politique est relue
    /// immédiatement ; aucune durée restante n'est transportée entre scènes.
    private func expireGPSOrigin() async {
        guard scenePhase == .active, origin.isDevice,
              let deadline = gpsSnapshot.expiresAt(maxAge: gpsPolicy.maxAge) else { return }
        do { try await waitUntil(deadline) } catch { return }
        guard !Task.isCancelled else { return }
        reconcileGPSOrigin()
    }

    /// La sheet a sa propre expiration si la présentation masque sa vue source.
    private func expirePresentation(_ presentation: AntennaProfilePresentation) async {
        guard scenePhase == .active, let deadline = presentation.expiresAt else { return }
        do { try await waitUntil(deadline) } catch { return }
        guard !Task.isCancelled, presentedProfile?.id == presentation.id else { return }
        presentedProfile = nil
        reconcileGPSOrigin()
    }

    private func waitUntil(_ deadline: Date) async throws {
        // L'horloge réelle reste la référence, y compris après une suspension.
        while deadline.timeIntervalSinceNow > 0 {
            let seconds = min(deadline.timeIntervalSinceNow, gpsPolicy.maxAge)
            if seconds <= 0 { break }
            try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded(.up)))
        }
        try Task.checkCancellation()
    }

    /// Redemande un point GPS et recalcule la visée depuis là.
    ///
    /// Utile dès qu'on se déplace pour chercher un dégagement : sans cela, la
    /// fiche garde la position d'ouverture, et le profil resterait celui d'un
    /// endroit qu'on vient de quitter.
    private var refreshButton: some View {
        Button {
            Haptics.light()
            Task { await refreshPosition() }
        } label: {
            Image(systemName: "location.circle")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(isRefreshing ? SQColor.labelTertiary : tint)
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(
                    SQMotion.repeating(
                        .linear(duration: 1),
                        autoreverses: false,
                        active: isRefreshing,
                        reduceMotion: reduceMotion
                    ),
                    value: isRefreshing
                )
                .frame(width: 34, height: 34)
                .background(SQColor.surfaceMuted, in: Circle())
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(isRefreshing)
        .accessibilityLabel("Actualiser ma position")
        .accessibilityHint("Recalcule la distance et le profil depuis l'endroit où tu es maintenant")
    }

    private func refreshPosition() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // `maxAge: 0` force un vrai relevé : le service renverrait sinon le fix
        // en cache, qui est précisément celui qu'on cherche à remplacer.
        let refreshed = await location.currentLocation(timeoutSeconds: 10, maxAge: 0)
        // Un timeout ne doit pas transformer le cache en nouveau relevé.
        // La politique normale peut toujours invalider une origine périmée.
        reconcileGPSOrigin(force: refreshed != nil)
    }

    /// Change dès que la hauteur d'antenne ou la bande de référence évoluent —
    /// typiquement quand le détail du site remplace ce que portait la tuile.
    private var geometryKey: String {
        "\(antennaHeightMeters ?? -1)|\(frequencyMhz)"
    }

    private var permitsProfile: Bool {
        guard let distanceMeters else { return false }
        if origin.isDevice {
            return AntennaSightGPSSnapshot.permitsProfile(snapshotDistance: distanceMeters, currentDistance: currentGPSDistance)
        }
        return AntennaSightViewModel.permitsProfile(distanceMeters: distanceMeters)
    }

    private var hasCurrentProfile: Bool {
        permitsProfile && model.displayKey == sightTaskKey && !model.profile.isEmpty
    }

    /// La révision ne contient ni titre ni adresse lisible. Le GPS stabilisé
    /// garde sa révision ; chaque changement de recherche en reçoit une autre.
    private var contextKey: String {
        let revision = origin.isDevice ? gpsSnapshot.revision : originRevision
        return "\(site.id)|\(revision)"
    }

    private var sightTaskKey: String {
        guard let userLocation, let antenna = antennaCoordinate else { return "none|\(contextKey)" }
        let key = AntennaSightViewModel.requestKey(user: userLocation.coordinate, antenna: antenna, contextKey: contextKey)
        // Même un déplacement GPS inférieur à 100 m peut franchir 30 km.
        return permitsProfile ? key : "excluded|\(key)"
    }

    private func loadProfile() async {
        guard permitsProfile, let userLocation, let antenna = antennaCoordinate, let distanceMeters else {
            model.invalidate()
            return
        }
        model.setGeometry(antennaHeightMeters: antennaHeightMeters ?? 25, frequencyMhz: frequencyMhz)
        await model.load(user: userLocation.coordinate, antenna: antenna, distanceMeters: distanceMeters, contextKey: contextKey)
    }

    private func elevationLabel(_ angle: Double) -> String {
        let rounded = (angle * 10).rounded() / 10
        if antennaHeightMeters == nil {
            return String(localized: "élévation \(formatted(rounded))° · hauteur inconnue")
        }
        if details?.core?.siteInfo.radiatingHeightIsEstimated == true {
            return String(localized: "élévation \(formatted(rounded))° · hauteur du support")
        }
        return String(localized: "élévation \(formatted(rounded))°")
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    @ViewBuilder
    private var sectorLine: some View {
        if let sector = alignedSector {
            HStack(spacing: SQSpace.xs + 2) {
                Image(systemName: sector.inSector ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(sector.inSector ? SQColor.success : SQColor.labelTertiary)
                Text(sector.inSector
                     ? String(localized: "Le point de départ est dans le lobe du secteur \(Int(sector.azimuth.rounded()))° (écart \(Int(sector.offset.rounded()))°)")
                     : String(localized: "Hors lobe — le secteur le plus proche pointe à \(Int(sector.azimuth.rounded()))° (écart \(Int(sector.offset.rounded()))°)"))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var terrainPreview: some View {
        if model.isLoading {
            HStack(spacing: SQSpace.sm) {
                ProgressView().tint(tint)
                Text("Lecture du relief…")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !model.profile.isEmpty {
            Button {
                Haptics.light()
                presentProfile()
            } label: {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    AntennaTerrainPreview(
                        profile: model.profile,
                        supportLabel: supportLabel,
                        supportHeightMeters: details?.core?.siteInfo.supportHeightMeters
                            ?? details?.core?.siteInfo.pylonHeight
                            ?? site.height
                            ?? antennaHeightMeters,
                        antennaHeightMeters: antennaHeightMeters,
                        tint: tint
                    )
                    .frame(height: 82)
                    if let verdict = model.verdict {
                        HStack(spacing: SQSpace.xs + 2) {
                            Image(systemName: verdictIcon(verdict.level))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(verdictColor(verdict.level))
                            Text(verdictLabel(verdict))
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SQColor.labelTertiary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint("Ouvre le profil d'altitude détaillé")
            .accessibilityIdentifier("antenna.profile.open")
            .disabled(isRefreshing)
        } else if model.failed {
            Text("Relief indisponible pour ce trajet.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelTertiary)
        }
    }

    private var unavailableLine: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "location.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SQColor.labelTertiary)
            Text(origin == .unresolved
                 ? String(localized: "Sélectionne une adresse dans les résultats ou efface la recherche pour utiliser ta position.")
                 : userLocation == nil
                    ? String(localized: "Position actuelle indisponible. Actualise la localisation pour situer ce site.")
                    : String(localized: "Ce site n'a pas de coordonnées exploitables."))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if origin.isDevice { refreshButton }
        }
    }

    private func verdictIcon(_ level: AntennaSightGeometry.SightVerdict.Level) -> String {
        switch level {
        case .clear: return "eye"
        case .grazing: return "eye.trianglebadge.exclamationmark"
        case .blocked: return "eye.slash"
        }
    }

    private func verdictColor(_ level: AntennaSightGeometry.SightVerdict.Level) -> Color {
        switch level {
        case .clear: return SQColor.success
        case .grazing: return SQColor.warning
        case .blocked: return SQColor.danger
        }
    }

    private func verdictLabel(_ verdict: AntennaSightGeometry.SightVerdict) -> String {
        let scope = verdict.includesBuildings
            ? String(localized: "relief et bâtiments")
            : String(localized: "relief seul")
        switch verdict.level {
        case .clear:
            return String(localized: "Vue dégagée jusqu'au site — \(scope)")
        case .grazing:
            guard let distance = verdict.obstacleDistanceMeters else {
                return String(localized: "Passage au ras d'un obstacle — \(scope)")
            }
            return String(localized: "Ça frôle un obstacle à \(SQUnits.distance(meters: distance)) — \(scope)")
        case .blocked:
            guard let distance = verdict.obstacleDistanceMeters else {
                return String(localized: "Un obstacle masque le site — \(scope)")
            }
            let overshoot = verdict.obstacleOvershootMeters.map { " (+\(Int($0.rounded())) m)" } ?? ""
            return String(localized: "Masqué à \(SQUnits.distance(meters: distance))\(overshoot) — \(scope)")
        }
    }
}

/// Cadran de visée : la flèche pointe l'antenne. Quand le cap du téléphone est
/// connu, le cadran tourne avec l'appareil — on vise physiquement le site au
/// lieu de convertir un relèvement en degrés dans sa tête.
struct AntennaCompassDial: View {
    let bearing: Double
    let deviceHeading: Double?
    let sectorAzimuth: Double?
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 2
            guard radius > 8 else { return }
            // Sans cap connu, le cadran reste nord en haut et la flèche donne le
            // relèvement absolu : moins direct, mais jamais faux.
            let rotation = deviceHeading ?? 0

            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(SQColor.surfaceMuted)
            )

            // Repère nord, qui tourne avec le cadran.
            let northAngle = (-rotation - 90) * .pi / 180
            context.draw(
                Text("N").font(SQFont.archivo(10, .bold)).foregroundColor(SQColor.labelSecondary),
                at: CGPoint(
                    x: center.x + cos(northAngle) * (radius - 9),
                    y: center.y + sin(northAngle) * (radius - 9)
                )
            )

            // Lobe du secteur qui couvre l'utilisateur, vu depuis sa position :
            // il pointe vers l'antenne, à l'opposé de l'azimut du secteur.
            if let sectorAzimuth {
                let halfBeam = AntennaSectorGeometry.defaultHalfBeamDegrees
                let facing = sectorAzimuth + 180 - rotation
                var wedge = Path()
                wedge.move(to: center)
                wedge.addArc(
                    center: center,
                    radius: radius - 4,
                    startAngle: .degrees(facing - 90 - halfBeam),
                    endAngle: .degrees(facing - 90 + halfBeam),
                    clockwise: false
                )
                wedge.closeSubpath()
                context.fill(wedge, with: .color(tint.opacity(0.16)))
            }

            // Flèche vers l'antenne.
            let angle = AntennaSightGeometry.dialAngle(bearing: bearing, deviceHeading: deviceHeading)
            var arrow = Path()
            let tip = point(from: center, angle: angle, distance: radius - 6)
            let left = point(from: center, angle: angle + 148, distance: radius * 0.42)
            let right = point(from: center, angle: angle - 148, distance: radius * 0.42)
            arrow.move(to: tip)
            arrow.addLine(to: left)
            arrow.addLine(to: center)
            arrow.addLine(to: right)
            arrow.closeSubpath()
            context.fill(arrow, with: .color(tint))

            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                with: .color(SQColor.surface)
            )
        }
        .accessibilityLabel(deviceHeading == nil
            ? String(localized: "Relèvement de l'antenne : \(Int(bearing.rounded())) degrés")
            : String(localized: "Boussole pointant l'antenne, relèvement \(Int(bearing.rounded())) degrés"))
    }

    /// Repère écran : 0° = nord = vers le haut, sens horaire.
    private func point(from center: CGPoint, angle: Double, distance: Double) -> CGPoint {
        let radians = (angle - 90) * .pi / 180
        return CGPoint(x: center.x + cos(radians) * distance, y: center.y + sin(radians) * distance)
    }
}

/// Aperçu compact du relief : la silhouette du terrain, le bâti, la ligne de
/// visée, et aux deux bouts l'observateur et le support. Assez pour voir d'un
/// coup d'œil si ça passe, et quoi on cherche à l'arrivée.
struct AntennaTerrainPreview: View {
    let profile: [AntennaSightGeometry.ProfilePoint]
    let supportLabel: String?
    let supportHeightMeters: Double?
    /// Hauteur de RAYONNEMENT, distincte de celle du support : c'est elle que
    /// vise la ligne. Les dessiner au sommet du support faisait pointer la visée
    /// à mi-hauteur du pylône, très loin des antennes.
    let antennaHeightMeters: Double?
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard profile.count > 1, let antennaGround = profile.last?.groundMeters else { return }
            let structureHeight = max(supportHeightMeters ?? 0, 1)
            var values = profile.flatMap { [$0.obstacleMeters, $0.sightLineMeters] }
            values.append(antennaGround + structureHeight)
            guard let minValue = values.min(), let maxValue = values.max() else { return }
            let span = max(maxValue - minValue, 1) * 1.05
            let total = max(profile.last?.distanceMeters ?? 1, 1)
            // Marge à droite pour que le support ne soit pas coupé par le bord.
            let plotWidth = size.width - 18

            func x(_ distance: Double) -> CGFloat { plotWidth * distance / total }
            func y(_ value: Double) -> CGFloat {
                size.height - (value - minValue) / span * (size.height - 8) - 4
            }
            func position(_ point: AntennaSightGeometry.ProfilePoint, value: Double) -> CGPoint {
                CGPoint(x: x(point.distanceMeters), y: y(value))
            }

            var ground = Path()
            ground.move(to: CGPoint(x: 0, y: size.height))
            for point in profile { ground.addLine(to: position(point, value: point.groundMeters)) }
            ground.addLine(to: CGPoint(x: x(total), y: size.height))
            ground.closeSubpath()
            context.fill(ground, with: .color(SQColor.labelSecondary.opacity(0.25)))

            if profile.contains(where: { $0.clutterMeters > 0 }) {
                var built = Path()
                built.move(to: CGPoint(x: 0, y: size.height))
                for point in profile { built.addLine(to: position(point, value: point.obstacleMeters)) }
                built.addLine(to: CGPoint(x: x(total), y: size.height))
                built.closeSubpath()
                context.fill(built, with: .color(SQColor.labelSecondary.opacity(0.18)))
            }

            var sight = Path()
            sight.move(to: position(profile[0], value: profile[0].sightLineMeters))
            for point in profile.dropFirst() { sight.addLine(to: position(point, value: point.sightLineMeters)) }
            context.stroke(sight, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))

            let groundY = y(antennaGround)
            let topY = y(antennaGround + structureHeight)
            let width = max(min((groundY - topY) * 0.34, 14), 7)
            let family = AntennaSupportSilhouette.family(for: supportLabel)
            let structure = AntennaSupportSilhouette.strokePath(
                family: family, baseX: x(total), baseY: groundY, topY: topY, width: width
            )
            context.stroke(structure, with: .color(tint), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

            // Les antennes à LEUR hauteur, sur le fût — c'est le point que vise
            // la ligne de visée, et les deux doivent se rejoindre à l'œil.
            let radiatingY = y(antennaGround + (antennaHeightMeters ?? structureHeight))
            let ratio = structureHeight > 0 ? (antennaHeightMeters ?? structureHeight) / structureHeight : 1
            let antennas = AntennaSupportSilhouette.antennaPath(
                antennaTypes: [],
                centerX: x(total),
                antennaY: radiatingY,
                width: AntennaSupportSilhouette.width(family: family, at: CGFloat(ratio), baseWidth: width)
            )
            context.fill(antennas.panels, with: .color(tint))
        }
        .accessibilityLabel("Aperçu du relief entre le point de départ et l'antenne")
    }
}
