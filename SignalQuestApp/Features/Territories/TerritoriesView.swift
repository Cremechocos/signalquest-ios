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

    @StateObject private var model: TerritoriesViewModel
    @Environment(\.dismiss) private var dismiss

    init(service: GamificationServicing, marketCode: String? = nil, operatorKey: String? = nil) {
        self.service = service
        self.marketCode = marketCode
        self.operatorKey = operatorKey
        _model = StateObject(wrappedValue: TerritoriesViewModel(
            service: service, marketCode: marketCode, operatorKey: operatorKey
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TerritoryMapView(
                cells: model.grid?.cells ?? [],
                onRegionChange: { region, span in model.regionChanged(region, span: span) }
            )
            .ignoresSafeArea()

            VStack(spacing: SQSpace.sm) {
                if model.isZoomedOut {
                    // Message HONNÊTE : on ne prétend pas afficher une grille
                    // complète, on explique pourquoi elle ne l'est pas.
                    notice("Zoome pour voir les territoires", icon: "plus.magnifyingglass")
                } else if model.grid?.truncated == true {
                    notice("Zone trop large : certains territoires ne sont pas affichés", icon: "exclamationmark.triangle")
                }
                if let errorMessage = model.errorMessage {
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.dangerInk)
                        if model.grid != nil {
                            Text("Dernier état connu conservé.")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        GradientButton("Réessayer", isBusy: model.isLoading, style: .secondary) {
                            Task { await model.retry() }
                        }
                    }
                    .padding(SQSpace.md)
                    .background(SQColor.surfaceGlass, in: RoundedRectangle(cornerRadius: SQRadius.md))
                    .accessibilityIdentifier("territories.loadError")
                } else if !model.isZoomedOut, model.grid?.cells.isEmpty == true, !model.isLoading {
                    notice("Aucun territoire dans cette zone", icon: "square.grid.3x3")
                }
                legend
            }
            .padding(SQSpace.lg)
            // La carte ignore la safe area et le dock flotte par-dessus : sans ce
            // dégagement, notice et légende passent DESSOUS et deviennent
            // illisibles (retour testeur TestFlight, 4 août 2026).
            .padding(.bottom, SQDock.floatingContentInset(subtracting: SQSpace.lg))
        }
        .overlay(alignment: .top) {
            if model.isLoading {
                ProgressView()
                    .tint(SQColor.brandRed)
                    .padding(SQSpace.md)
                    .background(SQColor.surfaceGlass, in: Capsule())
                    .padding(.top, SQSpace.lg)
            }
        }
        .navigationTitle("Territoires")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func notice(_ text: String, icon: String) -> some View {
        HStack(spacing: SQSpace.xs + 1) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(LocalizedStringKey(text))
                .font(SQFont.body(13, .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(SQColor.label)
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .background(SQColor.surfaceGlass, in: Capsule(style: .continuous))
        .sqShadowSoft()
    }

    private var legend: some View {
        let statuses: [TerritoryCell.Status] = [.virgin, .observed, .reliable, .complete]
        return HStack(spacing: SQSpace.md) {
            ForEach(statuses, id: \.self) { status in
                let sample = TerritoryCell(
                    cellKey: "", status: status,
                    bounds: .init(north: 0, south: 0, east: 0, west: 0),
                    pointsCount: 0, userCount: 0, trustScore: 0,
                    lastObservedAt: nil, mine: false
                )
                HStack(spacing: SQSpace.xs) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(sample.fillColor))
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(SQColor.label.opacity(0.15), lineWidth: 0.5)
                        )
                    Text(LocalizedStringKey(sample.statusLabel))
                        .font(SQFont.body(11))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // Chaque entrée annoncée d'un bloc : la pastille seule ne dit
                // rien à VoiceOver.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(LocalizedStringKey(sample.statusLabel))
            }
        }
        .foregroundStyle(SQColor.labelSecondary)
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .background(SQColor.surfaceGlass, in: Capsule(style: .continuous))
        .sqShadowSoft()
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
    let onRegionChange: (MKCoordinateRegion, MKCoordinateSpan) -> Void

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
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Un overlay UNIQUE : on le remplace en bloc plutôt que d'ajouter des
        // milliers de polygones. La clé seule ne suffit pas : une même cellule
        // peut changer de statut, de propriétaire ou de couleur avec le thème.
        let identity = TerritoryRenderIdentity(
            cells: cells,
            colorScheme: context.environment.colorScheme,
            contrast: context.environment.colorSchemeContrast
        )
        context.coordinator.render(cells: cells, identity: identity, on: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onRegionChange: onRegionChange) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let onRegionChange: (MKCoordinateRegion, MKCoordinateSpan) -> Void
        var lastIdentity: TerritoryRenderIdentity?

        init(onRegionChange: @escaping (MKCoordinateRegion, MKCoordinateSpan) -> Void) {
            self.onRegionChange = onRegionChange
        }

        func render(cells: [TerritoryCell], identity: TerritoryRenderIdentity, on map: MKMapView) {
            guard identity != lastIdentity else { return }
            lastIdentity = identity
            map.removeOverlays(map.overlays)
            guard !cells.isEmpty else { return }
            let overlay = TerritoryOverlay(cells: cells.map {
                TerritoryOverlay.Cell(
                    rect: $0.mapRect,
                    fill: $0.fillColor.cgColor,
                    stroke: $0.strokeColor.cgColor,
                    mine: $0.mine
                )
            })
            map.addOverlay(overlay, level: .aboveRoads)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onRegionChange(mapView.region, mapView.region.span)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast

    init(cells: [TerritoryCell], colorScheme: ColorScheme, contrast: ColorSchemeContrast) {
        self.cells = cells.map { Cell(key: $0.cellKey, status: $0.status, bounds: $0.bounds, mine: $0.mine) }
        self.colorScheme = colorScheme
        self.contrast = contrast
    }
}
