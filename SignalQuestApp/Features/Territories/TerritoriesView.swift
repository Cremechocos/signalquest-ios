import SwiftUI
import MapKit

/// Carte des territoires : grille de conquête sur la couverture communautaire.
///
/// Le backend agrège en SQL et complète les cellules vides — c'est ce qui rend
/// la « zone blanche » enfin représentable. Avant ce refactor, l'écran aurait
/// affiché une grille fausse au-delà du quartier.
struct TerritoriesView: View {
    let service: GamificationServicing
    var marketCode: String?
    var operatorKey: String?
    /// Registre des marchés : sert à ouvrir la carte sur le marché quand la position manque.
    var markets: MarketRegistryServicing?

    @StateObject private var model: TerritoriesViewModel
    @Environment(\.dismiss) private var dismiss
    /// Cellule touchée : retrouvée par sa clé dans la grille courante, elle
    /// disparaît d'elle-même quand la zone rechargée ne la contient plus.
    @State private var selectedCellKey: String?
    /// Suivi de position de la carte, piloté par le bouton de l'en-tête.
    @State private var trackingMode: MKUserTrackingMode = .none
    /// Centre du marché, utilisé tant que la position de l'utilisateur n'est pas connue.
    @State private var fallbackCenter: CLLocationCoordinate2D?
    @State private var locationDenied = false
    @State private var showsCellList = false

    private var selectedCell: TerritoryCell? {
        guard let selectedCellKey else { return nil }
        return model.grid?.cells.first { $0.cellKey == selectedCellKey }
    }

    init(service: GamificationServicing, marketCode: String? = nil, operatorKey: String? = nil,
         markets: MarketRegistryServicing? = nil) {
        self.service = service
        self.marketCode = marketCode
        self.operatorKey = operatorKey
        self.markets = markets
        _model = StateObject(wrappedValue: TerritoriesViewModel(
            service: service, marketCode: marketCode, operatorKey: operatorKey
        ))
    }

    var body: some View {
        TerritoryMapView(
            cells: model.grid?.cells ?? [],
            selectedCellKey: model.isZoomedOut ? nil : selectedCellKey,
            fallbackCenter: fallbackCenter,
            trackingMode: $trackingMode,
            onRegionChange: { region, span in model.regionChanged(region, span: span) },
            onSelectCell: { key in selectedCellKey = key }
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            VStack(spacing: SQSpace.sm) {
                mapHeader
                notices
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: SQSpace.sm) {
                if model.errorMessage != nil { errorCard }
                bottomCard
            }
            .padding(.horizontal, SQSpace.lg)
            // La carte ignore la safe area et le dock flotte par-dessus : sans ce
            // dégagement, la carte du bas passerait DESSOUS et deviendrait
            // illisible (retour testeur TestFlight, 4 août 2026).
            .padding(.bottom, SQDock.floatingContentInset(subtracting: SQSpace.md) + SQSpace.xl)
            .sqReadableWidth()
        }
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : UIKit coupe le balayage retour, rétabli ici.
        .sqKeepsSwipeBack()
        .navigationTitle("Territoires")
        .task { await loadFallbackCenter() }
        .onAppear { refreshLocationAuthorization() }
        .sheet(isPresented: $showsCellList) {
            TerritoryCellListSheet(
                cells: model.grid?.cells ?? [],
                reference: model.referenceCenter,
                selectedKey: selectedCellKey
            ) { key in
                selectedCellKey = key
                showsCellList = false
            }
        }
    }

    /// Sans position, la carte s'ouvre sur le centre du marché (France par défaut)
    /// plutôt que sur le monde entier.
    private func loadFallbackCenter() async {
        guard let markets else { return }
        let code = (marketCode?.isEmpty == false ? marketCode : nil) ?? "FR"
        if let entry = await markets.market(forCode: code),
           let latitude = entry.defaultCenterLatitude, let longitude = entry.defaultCenterLongitude,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
            fallbackCenter = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private func refreshLocationAuthorization() {
        let status = CLLocationManager().authorizationStatus
        locationDenied = status == .denied || status == .restricted
    }

    // MARK: En-tête et avis sur la carte

    private var mapHeader: some View {
        HStack(spacing: SQSpace.sm) {
            MapFloatingIconButton(systemImage: "chevron.left", label: "Retour", identifier: "territories.back") { dismiss() }
            MapFloatingTitle(title: "Territoires", identifier: "territories.title")
            Spacer(minLength: 0)
            MapFloatingIconButton(systemImage: trackingSymbol, label: "Recentrer sur ma position",
                                  identifier: "territories.userTracking",
                                  tint: trackingMode == .none ? SQColor.label : SQColor.accentInk) {
                // Même cycle que le bouton de suivi de Plans : position, puis cap, puis libre.
                switch trackingMode {
                case .none: trackingMode = .follow
                case .follow: trackingMode = .followWithHeading
                default: trackingMode = .none
                }
            }
            .accessibilityValue(trackingValue)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
    }

    private var trackingSymbol: String {
        switch trackingMode {
        case .follow: return "location.fill"
        case .followWithHeading: return "location.north.line.fill"
        default: return "location"
        }
    }

    private var trackingValue: Text {
        switch trackingMode {
        case .follow: return Text("Suit ma position")
        case .followWithHeading: return Text("Suit ma position et mon cap")
        default: return Text(verbatim: "")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if locationDenied, model.isZoomedOut || model.grid?.cells.isEmpty != false {
            locationSettingsButton
        }
        if model.isZoomedOut {
            // Message HONNÊTE : on ne prétend pas afficher une grille
            // complète, on explique pourquoi elle ne l'est pas.
            notice("Zoome pour voir les territoires", icon: "plus.magnifyingglass", tint: SQColor.label)
        } else if model.grid?.truncated == true {
            notice("Zone trop large : certains territoires ne sont pas affichés",
                   icon: "exclamationmark.triangle", tint: OutageTint.degradedInk)
        } else if model.errorMessage == nil, model.grid?.cells.isEmpty == true, !model.isLoading {
            notice("Aucun territoire dans cette zone", icon: "square.grid.3x3", tint: SQColor.label)
        } else if model.isLoading {
            SQSpinner()
                .tint(SQColor.brandRed)
                .padding(SQSpace.sm2)
                .sqSurface(SQColor.surface, in: Capsule())
                .sqShadowCard()
        } else if selectedCell == nil, model.grid?.cells.isEmpty == false {
            notice("Touche un carré pour voir son détail", icon: "info.circle", tint: SQColor.label)
        }
    }

    /// Localisation refusée : la carte reste sur le marché, et un lien mène aux Réglages.
    private var locationSettingsButton: some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: SQSpace.xs + 1) {
                Image(systemName: "location.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Activer la localisation")
                    .font(SQFont.body(13, .semibold))
                    .lineLimit(2)
            }
            .foregroundStyle(SQColor.accentInk)
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 44)
            .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
            .sqShadowCard()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityHint(Text("Ouvre les Réglages pour autoriser la position"))
        .accessibilityIdentifier("territories.enableLocation")
    }

    private func notice(_ text: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: SQSpace.xs + 1) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(SQFont.body(13, .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, SQSpace.md)
        .frame(minHeight: 36)
        .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowCard()
        .padding(.horizontal, SQSpace.lg)
        .accessibilityElement(children: .combine)
    }

    // MARK: Carte du bas : la zone ou le carré touché

    private var errorCard: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SQColor.dangerInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Territoires non chargés")
                    .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                Group {
                    if model.grid != nil {
                        Text("Le dernier état connu reste affiché.")
                    } else if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                    }
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            GradientButton("Réessayer", isBusy: model.isLoading, style: .secondary) {
                Task { await model.retry() }
            }
            .fixedSize()
        }
        .padding(SQSpace.md)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("territories.loadError")
    }

    @ViewBuilder
    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            if let selectedCell, !model.isZoomedOut {
                cellDetail(selectedCell)
            } else {
                zoneSummary
            }
            if showsLegend { legend }
        }
        .padding(SQSpace.md)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
    }

    /// Côté d'un carré, arrondi au kilomètre : la grille est en degrés, donc exact sur la
    /// latitude seulement. Le résumé le dit avec « environ ».
    private var cellSideKm: Int {
        max(1, Int(((model.grid?.cellSize ?? 0.02) * 111).rounded()))
    }

    private var zoneSummary: some View {
        HStack(alignment: .center, spacing: SQSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dans cette zone")
                    .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                Group {
                    if model.isZoomedOut {
                        Text("Zoome pour compter les carrés")
                    } else if let cells = model.grid?.cells {
                        Text("\(cells.count) carrés") + Text(verbatim: " · ")
                            + Text("environ \(cellSideKm) km de côté") + Text(verbatim: " · ")
                            + Text("\(cells.filter(\.mine).count) à toi")
                    }
                }
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if !model.isZoomedOut, model.grid?.cells.isEmpty == false {
                Button {
                    showsCellList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel(Text("Liste des carrés"))
                .accessibilityIdentifier("territories.cellList")
            }
            legendToggle
        }
        .accessibilityIdentifier("territories.summary")
    }

    /// Fiche d'une cellule touchée : ce que la grille charge déjà, enfin lisible.
    private func cellDetail(_ cell: TerritoryCell) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: SQSpace.sm) {
                swatch(for: cell.status)
                Text(cell.statusLabel)
                    .font(SQFont.body(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(SQColor.label)
                if cell.mine {
                    Text("Ma zone")
                        .font(SQFont.body(11, .bold, relativeTo: .caption2))
                        .foregroundStyle(SQColor.accentInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(SQColor.accentSoft, in: Capsule())
                }
                Spacer(minLength: SQSpace.sm)
                Button {
                    selectedCellKey = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(width: 32, height: 32)
                        .background(SQColor.chip, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel(Text("Fermer"))
                .accessibilityIdentifier("territories.cell.close")
            }
            SQFactRow(label: "Mesures", value: cell.pointsCount.formatted())
            SQFactRow(label: "Contributeurs", value: cell.userCount.formatted())
            SQFactRow(
                label: "Dernière mesure",
                value: cell.lastObservedAt.map { $0.formatted(.relative(presentation: .named)) }
                    ?? String(localized: "Jamais observée")
            )
            HStack {
                Spacer(minLength: 0)
                legendToggle
            }
            // La cible reste de 44 pt ; seul l'espace visible se resserre.
            .padding(.vertical, -SQSpace.sm)
        }
        .monospacedDigit()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("territories.cell")
    }

    // MARK: Légende

    /// Légende repliable : ouverte par défaut, elle se range pour libérer la carte.
    @State private var showsLegend = true

    private var legendToggle: some View {
        Button {
            Haptics.light()
            withAnimation(.snappy(duration: 0.2)) { showsLegend.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text("Légende")
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(showsLegend ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .font(SQFont.body(12, .semibold, relativeTo: .caption))
            .foregroundStyle(SQColor.labelSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(showsLegend ? Text("Masquer la légende") : Text("Afficher la légende"))
        .accessibilityIdentifier("territories.legendToggle")
    }

    /// Légende complète (SOC-39) : les cinq états dessinés sur la carte, dont
    /// « À rafraîchir », et le contour brique des zones où tu as contribué.
    private var legend: some View {
        let statuses: [TerritoryCell.Status] = [.virgin, .observed, .reliable, .complete, .stale]
        let counts = !model.isZoomedOut
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: legendColumnWidth), spacing: SQSpace.md, alignment: .leading)],
            alignment: .leading,
            spacing: SQSpace.sm
        ) {
            ForEach(statuses, id: \.self) { status in
                legendItem(Self.sample(status).statusLabel, count: counts ? model.grid?.count(of: status) : nil) {
                    swatch(for: status)
                }
            }
            legendItem(String(localized: "Mes zones"), count: counts ? model.grid?.cells.filter(\.mine).count : nil) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(SQColor.brandRed, lineWidth: 2.5)
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityIdentifier("territories.legend")
    }

    /// Largeur d'une entrée de légende, qui suit la taille du texte : à 104 pt
    /// fixes, « Zone inexplorée » se coupait en très grand texte.
    @ScaledMetric(relativeTo: .caption) private var legendColumnWidth: CGFloat = 132

    private static func sample(_ status: TerritoryCell.Status) -> TerritoryCell {
        TerritoryCell(
            cellKey: "", status: status,
            bounds: .init(north: 0, south: 0, east: 0, west: 0),
            pointsCount: 0, userCount: 0, trustScore: 0,
            lastObservedAt: nil, mine: false
        )
    }

    /// Pastille d'un statut, comme sur la carte : « Inexplorée » hachurée, les
    /// autres teintées de leur couleur.
    @ViewBuilder
    private func swatch(for status: TerritoryCell.Status) -> some View {
        if status == .virgin {
            SQHatchedSwatch(color: SQColor.labelTertiary)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            let tint = Color(Self.sample(status).strokeTint)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(Self.sample(status).fillColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(tint, lineWidth: 1)
                )
                .frame(width: 18, height: 18)
        }
    }

    private func legendItem<Swatch: View>(_ label: String, count: Int?, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(spacing: SQSpace.sm) {
            swatch()
            // 12 pt à l'encre pleine : le gris secondaire à 11 pt passait sous
            // le contraste rendu (TRX-12).
            Text(label)
                .font(SQFont.body(12, .medium, relativeTo: .caption))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let count {
                Text(count.formatted())
                    .font(SQFont.body(12, .bold, relativeTo: .caption))
                    .foregroundStyle(SQColor.label)
                    .monospacedDigit()
            }
        }
        // Chaque entrée annoncée d'un bloc : la pastille seule ne dit rien à
        // VoiceOver. La grille dessinée est muette : la légende en donne le
        // décompte pour la zone affichée (« Fiable, 9 carrés »).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(count.map { Text("\($0) carrés") } ?? Text(verbatim: ""))
    }
}

@MainActor
final class TerritoriesViewModel: ObservableObject {
    @Published private(set) var grid: TerritoryGrid?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// Au-delà de ce span, la grille n'a plus de sens à l'écran : les cellules
    /// font moins d'un pixel. On ne charge RIEN plutôt que de faire travailler
    /// le serveur pour un rendu illisible.
    @Published private(set) var isZoomedOut = false

    static let maxSpanDegrees: Double = 1.2

    private let fetch: @MainActor (MKCoordinateRegion, MKCoordinateSpan) async throws -> TerritoryGrid
    private var reloadTask: Task<Void, Never>?
    private var requestedRegion: (region: MKCoordinateRegion, span: MKCoordinateSpan)?
    private var requestGeneration = UUID()

    /// Centre de la zone chargée, repère des distances de la liste des carrés.
    var referenceCenter: CLLocationCoordinate2D? { requestedRegion?.region.center }

    init(service: GamificationServicing, marketCode: String?, operatorKey: String?) {
        fetch = { region, span in
            try await service.territories(
                south: region.center.latitude - span.latitudeDelta / 2,
                west: region.center.longitude - span.longitudeDelta / 2,
                north: region.center.latitude + span.latitudeDelta / 2,
                east: region.center.longitude + span.longitudeDelta / 2,
                marketCode: marketCode, operatorKey: operatorKey
            )
        }
    }

    init(fetch: @escaping @MainActor (MKCoordinateRegion, MKCoordinateSpan) async throws -> TerritoryGrid) {
        self.fetch = fetch
    }

    deinit { reloadTask?.cancel() }

    func regionChanged(_ region: MKCoordinateRegion, span: MKCoordinateSpan) {
        let tooWide = max(span.latitudeDelta, span.longitudeDelta) > Self.maxSpanDegrees
        isZoomedOut = tooWide
        requestGeneration = UUID()
        reloadTask?.cancel()
        isLoading = false
        guard !tooWide else {
            requestedRegion = nil
            grid = nil
            errorMessage = nil
            return
        }
        requestedRegion = (region, span)
        // Débounce 400 ms : un déplacement de carte émet des dizaines
        // d'événements de région, et chacun déclencherait une agrégation SQL.
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.load(region: region, span: span)
        }
    }

    func retry() async {
        guard let requestedRegion else { return }
        reloadTask?.cancel()
        await load(region: requestedRegion.region, span: requestedRegion.span)
    }

    func load(region: MKCoordinateRegion, span: MKCoordinateSpan) async {
        requestedRegion = (region, span)
        let generation = UUID()
        requestGeneration = generation
        isLoading = true
        defer { if requestGeneration == generation { isLoading = false } }
        do {
            let response = try await fetch(region, span)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            grid = response
            errorMessage = nil
        } catch {
            guard requestGeneration == generation, !Task.isCancelled, !error.isCancellation else { return }
            // Conserver la dernière grille, mais signaler explicitement qu'elle
            // n'est pas le résultat du viewport demandé.
            errorMessage = String(localized: "Impossible de charger les territoires. Réessaie.")
        }
    }
}

/// Pont MapKit. Repris de `MapKitMapView` : même moteur, même gestion du
/// `Coordinator`, un seul overlay remplacé à chaque grille.
struct TerritoryMapView: UIViewRepresentable {
    let cells: [TerritoryCell]
    /// Carré touché : entouré à l'encre sur la carte.
    var selectedCellKey: String?
    /// Centre du marché : la carte s'y ouvre tant que la position manque.
    var fallbackCenter: CLLocationCoordinate2D?
    @Binding var trackingMode: MKUserTrackingMode
    let onRegionChange: (MKCoordinateRegion, MKCoordinateSpan) -> Void
    var onSelectCell: (String?) -> Void = { _ in }

    /// Span d'ouverture sur la position : un quartier, bien sous le plafond
    /// `TerritoriesViewModel.maxSpanDegrees`.
    static let initialSpanDegrees: Double = 0.05
    /// Span d'ouverture sur le marché : large assez pour contenir des carrés, sous le plafond.
    static let fallbackSpanDegrees: Double = 0.5

    /// Le mode terrain change les encres de la grille sans changer clair/sombre : la lecture
    /// du réglage ici relance `updateUIView` quand il bascule.
    @AppStorage(SQFieldMode.storageKey) private var fieldMode = false

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        // Même configuration que la carte principale (`MapKitMapView.applyBackdrop`) :
        // relief à plat, POI masqués. VÉRIFIÉ par capture : cela ne change PAS la
        // palette d'Apple Plan (les deux cartes rendent le même vert/bleu vif) —
        // c'est un alignement de comportement, pas un correctif visuel. Le filtre
        // de POI passe par la configuration plutôt que par la propriété dépréciée
        // `MKMapView.pointOfInterestFilter`.
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        if let location = map.userLocation.location {
            context.coordinator.centerOnce(on: location.coordinate, in: map)
        }
        if let fallbackCenter {
            context.coordinator.centerOnFallback(fallbackCenter, in: map)
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.trackingMode = $trackingMode
        if let fallbackCenter {
            context.coordinator.centerOnFallback(fallbackCenter, in: map)
        }
        // Le bouton de suivi est dans l'en-tête SwiftUI : la carte suit son mode.
        if map.userTrackingMode != trackingMode {
            map.setUserTrackingMode(trackingMode, animated: true)
        }
        // Un overlay UNIQUE : on le remplace en bloc plutôt que d'ajouter des
        // milliers de polygones. La clé seule ne suffit pas : une même cellule
        // peut changer de statut, de propriétaire ou de couleur avec le thème.
        let identity = TerritoryRenderIdentity(
            cells: cells,
            selectedKey: selectedCellKey,
            colorScheme: context.environment.colorScheme,
            contrast: context.environment.colorSchemeContrast,
            fieldMode: fieldMode
        )
        context.coordinator.render(cells: cells, identity: identity, on: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onRegionChange: onRegionChange, onSelectCell: onSelectCell) }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        let onRegionChange: (MKCoordinateRegion, MKCoordinateSpan) -> Void
        let onSelectCell: (String?) -> Void
        var trackingMode: Binding<MKUserTrackingMode>?
        var lastIdentity: TerritoryRenderIdentity?
        private var cells: [TerritoryCell] = []
        private var hasCentered = false
        private var hasCenteredOnFallback = false
        /// Le geste de l'utilisateur sur la carte : on ne la déplace plus d'office ensuite.
        private var userMovedMap = false
        private var gridOverlay: TerritoryOverlay?
        private var selectionOverlay: TerritorySelectionOverlay?
        private var appliedSelection: (key: String, scheme: ColorScheme, contrast: ColorSchemeContrast)?

        init(onRegionChange: @escaping (MKCoordinateRegion, MKCoordinateSpan) -> Void,
             onSelectCell: @escaping (String?) -> Void = { _ in }) {
            self.onRegionChange = onRegionChange
            self.onSelectCell = onSelectCell
        }

        /// Premier affichage seulement : ensuite, la carte reste où
        /// l'utilisateur l'a menée.
        /// Sans position : le centre du marché, une seule fois, tant que la carte n'a pas bougé.
        func centerOnFallback(_ coordinate: CLLocationCoordinate2D, in map: MKMapView) {
            guard !hasCentered, !hasCenteredOnFallback, !userMovedMap,
                  map.userLocation.location == nil, CLLocationCoordinate2DIsValid(coordinate) else { return }
            hasCenteredOnFallback = true
            let span = MKCoordinateSpan(
                latitudeDelta: TerritoryMapView.fallbackSpanDegrees,
                longitudeDelta: TerritoryMapView.fallbackSpanDegrees
            )
            map.setRegion(MKCoordinateRegion(center: coordinate, span: span), animated: false)
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            let gestures = mapView.subviews.first?.gestureRecognizers ?? []
            if gestures.contains(where: { $0.state == .began || $0.state == .changed }) { userMovedMap = true }
        }

        func centerOnce(on coordinate: CLLocationCoordinate2D, in map: MKMapView) {
            guard !hasCentered, !userMovedMap, CLLocationCoordinate2DIsValid(coordinate) else { return }
            hasCentered = true
            let span = MKCoordinateSpan(
                latitudeDelta: TerritoryMapView.initialSpanDegrees,
                longitudeDelta: TerritoryMapView.initialSpanDegrees
            )
            map.setRegion(MKCoordinateRegion(center: coordinate, span: span), animated: false)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let location = userLocation.location else { return }
            centerOnce(on: location.coordinate, in: mapView)
        }

        /// Un geste sur la carte coupe le suivi : l'en-tête doit le refléter.
        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            guard let trackingMode, trackingMode.wrappedValue != mode else { return }
            DispatchQueue.main.async { trackingMode.wrappedValue = mode }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = MKMapPoint(map.convert(gesture.location(in: map), toCoordinateFrom: map))
            onSelectCell(cells.first { $0.mapRect.contains(point) }?.cellKey)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !(touch.view is UIControl)
        }

        func render(cells: [TerritoryCell], identity: TerritoryRenderIdentity, on map: MKMapView) {
            // Le carré touché a son propre overlay : l'identité de la grille l'ignore.
            var gridIdentity = identity
            gridIdentity.selectedKey = nil
            if gridIdentity != lastIdentity {
                lastIdentity = gridIdentity
                self.cells = cells
                if let gridOverlay { map.removeOverlay(gridOverlay) }
                gridOverlay = nil
                if !cells.isEmpty {
                    let overlay = TerritoryOverlay(cells: cells.map {
                        TerritoryOverlay.Cell(
                            rect: $0.mapRect,
                            fill: $0.fillColor.cgColor,
                            stroke: $0.strokeColor.cgColor,
                            mine: $0.mine,
                            hatch: $0.status == .virgin ? TerritoryCell.hatchColor.cgColor : nil
                        )
                    })
                    gridOverlay = overlay
                    map.addOverlay(overlay, level: .aboveRoads)
                }
                // La grille a été reposée : le liseré doit repasser au-dessus.
                clearSelection(on: map)
            }
            updateSelection(key: identity.selectedKey, identity: identity, on: map)
        }

        private func clearSelection(on map: MKMapView) {
            if let selectionOverlay { map.removeOverlay(selectionOverlay) }
            selectionOverlay = nil
            appliedSelection = nil
        }

        private func updateSelection(key: String?, identity: TerritoryRenderIdentity, on map: MKMapView) {
            guard let key, let cell = cells.first(where: { $0.cellKey == key }) else {
                clearSelection(on: map)
                return
            }
            if let appliedSelection, appliedSelection.key == key,
               appliedSelection.scheme == identity.colorScheme, appliedSelection.contrast == identity.contrast {
                return
            }
            clearSelection(on: map)
            let overlay = TerritorySelectionOverlay(
                cellKey: key, rect: cell.mapRect, ink: UIColor(SQColor.label).cgColor
            )
            selectionOverlay = overlay
            appliedSelection = (key, identity.colorScheme, identity.contrast)
            map.addOverlay(overlay, level: .aboveRoads)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onRegionChange(mapView.region, mapView.region.span)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let selection = overlay as? TerritorySelectionOverlay {
                return TerritorySelectionRenderer(overlay: selection)
            }
            guard let territory = overlay as? TerritoryOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }
            return TerritoryOverlayRenderer(overlay: territory)
        }
    }
}

struct TerritoryRenderIdentity: Equatable {
    struct Cell: Equatable {
        let key: String
        let status: TerritoryCell.Status
        let bounds: TerritoryCell.Bounds
        let mine: Bool
    }

    let cells: [Cell]
    var selectedKey: String?
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    /// Mode terrain : il change les encres sans changer clair/sombre.
    let fieldMode: Bool

    init(cells: [TerritoryCell], selectedKey: String? = nil, colorScheme: ColorScheme, contrast: ColorSchemeContrast,
         fieldMode: Bool = false) {
        self.cells = cells.map { Cell(key: $0.cellKey, status: $0.status, bounds: $0.bounds, mine: $0.mine) }
        self.selectedKey = selectedKey
        self.colorScheme = colorScheme
        self.contrast = contrast
        self.fieldMode = fieldMode
    }
}

// MARK: - Liste des carrés (alternative à la grille dessinée)

/// Les carrés de la zone affichée en liste : statut, mesures, dernière mesure, et leur position
/// par rapport au centre de la carte. La grille est un seul overlay muet pour VoiceOver ; cette
/// liste donne accès à chaque carré sans passer par un tap sur la carte.
struct TerritoryCellListSheet: View {
    let cells: [TerritoryCell]
    let reference: CLLocationCoordinate2D?
    let selectedKey: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var onlyMine = false

    /// Mes zones d'abord, puis du plus avancé au moins avancé, puis du plus proche du centre.
    static func ordered(_ cells: [TerritoryCell], reference: CLLocationCoordinate2D?, onlyMine: Bool) -> [TerritoryCell] {
        let rank: [TerritoryCell.Status: Int] = [.complete: 0, .reliable: 1, .observed: 2, .stale: 3, .virgin: 4]
        let filtered = onlyMine ? cells.filter(\.mine) : cells
        return filtered.sorted { lhs, rhs in
            if lhs.mine != rhs.mine { return lhs.mine }
            let l = rank[lhs.status] ?? 5, r = rank[rhs.status] ?? 5
            if l != r { return l < r }
            let ld = distanceMeters(lhs, from: reference), rd = distanceMeters(rhs, from: reference)
            if ld != rd { return ld < rd }
            return lhs.cellKey < rhs.cellKey
        }
    }

    static func distanceMeters(_ cell: TerritoryCell, from reference: CLLocationCoordinate2D?) -> Double {
        guard let reference else { return 0 }
        let center = CLLocation(
            latitude: (cell.bounds.north + cell.bounds.south) / 2,
            longitude: (cell.bounds.east + cell.bounds.west) / 2
        )
        return center.distance(from: CLLocation(latitude: reference.latitude, longitude: reference.longitude))
    }

    /// Huit points cardinaux, du carré vu depuis le centre de la zone.
    static func direction(of cell: TerritoryCell, from reference: CLLocationCoordinate2D) -> String {
        let dLat = (cell.bounds.north + cell.bounds.south) / 2 - reference.latitude
        let dLon = ((cell.bounds.east + cell.bounds.west) / 2 - reference.longitude) * cos(reference.latitude * .pi / 180)
        let degrees = (atan2(dLon, dLat) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let names = [
            String(localized: "nord"), String(localized: "nord-est"), String(localized: "est"),
            String(localized: "sud-est"), String(localized: "sud"), String(localized: "sud-ouest"),
            String(localized: "ouest"), String(localized: "nord-ouest"),
        ]
        return names[Int(((degrees + 22.5) / 45).rounded(.down)) % 8]
    }

    private func position(of cell: TerritoryCell) -> String? {
        guard let reference else { return nil }
        let meters = Self.distanceMeters(cell, from: reference)
        guard meters >= 100 else { return String(localized: "Au centre de la zone") }
        let distance = Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
        return String(format: String(localized: "À %1$@ au %2$@ du centre de la zone"),
                      distance, Self.direction(of: cell, from: reference))
    }

    var body: some View {
        let rows = Self.ordered(cells, reference: reference, onlyMine: onlyMine)
        NavigationStack {
            List {
                Section {
                    Toggle("Mes zones seulement", isOn: $onlyMine)
                        .accessibilityIdentifier("territories.cellList.onlyMine")
                }
                Section {
                    if rows.isEmpty {
                        Text("Aucun carré à afficher")
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    ForEach(rows) { cell in
                        Button { onSelect(cell.cellKey) } label: { row(cell) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(cell.cellKey == selectedKey ? .isSelected : [])
                    }
                }
            }
            .navigationTitle("Carrés de la zone")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("territories.cellList.sheet")
    }

    private func row(_ cell: TerritoryCell) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xxs) {
            HStack(spacing: SQSpace.xs) {
                Text(cell.statusLabel)
                    .font(SQFont.body(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                if cell.mine {
                    Text("Ma zone")
                        .font(SQFont.body(11, .bold, relativeTo: .caption2))
                        .foregroundStyle(SQColor.accentInk)
                }
            }
            Text("\(cell.pointsCount) mesures · \(cell.userCount) contributeurs")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            if let position = position(of: cell) {
                Text(position)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            if let last = cell.lastObservedAt {
                Text("Dernière mesure \(last.formatted(.relative(presentation: .named)))")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
