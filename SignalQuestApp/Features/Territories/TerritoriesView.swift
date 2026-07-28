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
                legend
            }
            .padding(SQSpace.lg)
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
    /// Au-delà de ce span, la grille n'a plus de sens à l'écran : les cellules
    /// font moins d'un pixel. On ne charge RIEN plutôt que de faire travailler
    /// le serveur pour un rendu illisible.
    @Published private(set) var isZoomedOut = false

    static let maxSpanDegrees: Double = 1.2

    private let service: GamificationServicing
    private let marketCode: String?
    private let operatorKey: String?
    private var reloadTask: Task<Void, Never>?

    init(service: GamificationServicing, marketCode: String?, operatorKey: String?) {
        self.service = service
        self.marketCode = marketCode
        self.operatorKey = operatorKey
    }

    deinit { reloadTask?.cancel() }

    func regionChanged(_ region: MKCoordinateRegion, span: MKCoordinateSpan) {
        let tooWide = max(span.latitudeDelta, span.longitudeDelta) > Self.maxSpanDegrees
        isZoomedOut = tooWide
        guard !tooWide else {
            reloadTask?.cancel()
            return
        }
        // Débounce 400 ms : un déplacement de carte émet des dizaines
        // d'événements de région, et chacun déclencherait une agrégation SQL.
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.load(region: region, span: span)
        }
    }

    private func load(region: MKCoordinateRegion, span: MKCoordinateSpan) async {
        isLoading = true
        defer { isLoading = false }
        let south = region.center.latitude - span.latitudeDelta / 2
        let north = region.center.latitude + span.latitudeDelta / 2
        let west = region.center.longitude - span.longitudeDelta / 2
        let east = region.center.longitude + span.longitudeDelta / 2
        do {
            grid = try await service.territories(
                south: south, west: west, north: north, east: east,
                marketCode: marketCode, operatorKey: operatorKey
            )
        } catch {
            // Silencieux : la carte reste utilisable avec la grille précédente,
            // et un bandeau d'erreur par déplacement serait insupportable.
            if !error.isCancellation { grid = grid }
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
        // milliers de polygones. Comparer les clés évite de le recréer quand
        // seule la région a bougé sans changer la grille.
        let keys = cells.map(\.cellKey).joined(separator: ",").hashValue
        guard keys != context.coordinator.lastCellsHash else { return }
        context.coordinator.lastCellsHash = keys
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

    func makeCoordinator() -> Coordinator { Coordinator(onRegionChange: onRegionChange) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let onRegionChange: (MKCoordinateRegion, MKCoordinateSpan) -> Void
        var lastCellsHash: Int?

        init(onRegionChange: @escaping (MKCoordinateRegion, MKCoordinateSpan) -> Void) {
            self.onRegionChange = onRegionChange
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
