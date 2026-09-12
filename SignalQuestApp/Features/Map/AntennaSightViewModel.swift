import Combine
import CoreLocation
import Foundation

/// Ce que la fiche antenne sait de la position de l'utilisateur : les mesures
/// géométriques immédiates, puis le profil de relief une fois le réseau revenu.
@MainActor
final class AntennaSightViewModel: ObservableObject {
    @Published private(set) var profile: [AntennaSightGeometry.ProfilePoint] = []
    @Published private(set) var verdict: AntennaSightGeometry.SightVerdict?
    @Published private(set) var isLoading = false
    /// Le profil a été demandé et a échoué (réseau, source indisponible) : on le
    /// dit, plutôt que de laisser un cadre vide qui ressemble à un chargement.
    @Published private(set) var failed = false

    private let terrain: TerrainServicing
    private var loadedKey: String?
    private(set) var displayKey: String?
    private var generation = UUID()
    /// Élévations et bâti déjà obtenus pour le trajet en cours.
    ///
    /// La fiche s'ouvre AVANT que le détail du site n'arrive : la hauteur
    /// d'antenne vaut alors 25 m par défaut, et le profil calculé avec cette
    /// valeur restait figé, puisque la clé de rechargement ne dépend que des
    /// coordonnées. La ligne de visée pointait donc 14 m trop bas jusqu'au
    /// prochain déplacement. Conserver les mesures permet de recalculer
    /// localement dès que la vraie hauteur arrive, sans rappeler le réseau.
    private var cachedElevations: [Double?] = []
    private var cachedBuildings: [Double?] = []
    private var cachedDistance: Double = 0
    /// Géométrie courante, relue à chaque construction plutôt que capturée.
    private var antennaHeight: Double = 25
    private var frequency: Double = 2100

    init(terrain: TerrainServicing) {
        self.terrain = terrain
    }

    /// Déclare la hauteur d'antenne et la fréquence à utiliser.
    ///
    /// Appelée à chaque fois que la vue en sait davantage — à l'ouverture avec ce
    /// que porte la tuile, puis quand le détail du site répond. La valeur est
    /// STOCKÉE et relue au moment de construire le profil : le calcul de relief
    /// en cours l'utilisera, même s'il a démarré avant. C'est ce qui manquait —
    /// la hauteur était capturée à l'appel, si bien qu'une réponse arrivée
    /// pendant le chargement du terrain ne changeait plus rien, et la ligne de
    /// visée restait fausse jusqu'à ce qu'on actualise à la main.
    func setGeometry(antennaHeightMeters: Double, frequencyMhz: Double) {
        guard antennaHeight != antennaHeightMeters || frequency != frequencyMhz else { return }
        antennaHeight = antennaHeightMeters
        frequency = frequencyMhz
        rebuildFromCache()
    }

    /// Reconstruit le profil sur les mesures déjà en main. Instantané : aucun
    /// appel réseau. Sans effet tant que le relief n'est pas arrivé — le calcul
    /// en cours reprendra alors la hauteur courante de lui-même.
    private func rebuildFromCache() {
        guard !cachedElevations.isEmpty, cachedDistance > 0 else { return }
        let points = AntennaSightGeometry.buildProfile(
            distanceMeters: cachedDistance,
            groundElevations: cachedElevations,
            clutterHeights: cachedBuildings,
            antennaHeightMeters: antennaHeight,
            frequencyMhz: frequency
        )
        guard !points.isEmpty else { return }
        profile = points
        verdict = AntennaSightGeometry.verdict(
            for: points,
            includesBuildings: cachedBuildings.contains { ($0 ?? 0) > 0 }
        )
    }

    /// Altitude du sol sous l'utilisateur et sous l'antenne, telles que lues dans
    /// le modèle de terrain — pas l'altitude GPS, bien moins fiable en vertical.
    var userGroundMeters: Double? { profile.first?.groundMeters }
    var antennaGroundMeters: Double? { profile.last?.groundMeters }

    static func permitsProfile(distanceMeters: Double) -> Bool {
        distanceMeters.isFinite && distanceMeters > 20 && distanceMeters <= 30_000
    }

    static func requestKey(user: CLLocationCoordinate2D, antenna: CLLocationCoordinate2D, contextKey: String = "") -> String {
        "\(contextKey)|\(user.latitude),\(user.longitude)→\(antenna.latitude),\(antenna.longitude)"
    }

    func load(
        user: CLLocationCoordinate2D,
        antenna: CLLocationCoordinate2D,
        distanceMeters: Double,
        contextKey: String = ""
    ) async {
        // Avant échantillonnage, cache et service : une ancienne réponse ou un
        // profil en cache ne doit jamais contourner la limite de distance.
        guard Self.permitsProfile(distanceMeters: distanceMeters),
              CLLocationCoordinate2DIsValid(user), CLLocationCoordinate2DIsValid(antenna) else {
            invalidate()
            return
        }
        guard !Task.isCancelled else { return }
        let key = Self.requestKey(user: user, antenna: antenna, contextKey: contextKey)
        guard key != loadedKey else { return }
        invalidate()
        let requestGeneration = generation
        loadedKey = key
        displayKey = key
        isLoading = true
        defer {
            if generation == requestGeneration {
                isLoading = false
                if Task.isCancelled { invalidate() }
            }
        }

        let path = AntennaSightGeometry.samplePath(from: user, to: antenna, distanceMeters: distanceMeters)

        // Les deux sources partent EN MÊME TEMPS : le relief vient de l'IGN,
        // rapide, le bâti d'Overpass, souvent bien plus lent. Les enchaîner
        // faisait attendre le profil entier au rythme du plus lent, alors que le
        // relief suffit à afficher quelque chose d'utile.
        async let elevationTask = terrain.elevations(for: path)
        async let buildingTask: [Double?]? = try? await terrain.buildingHeights(for: path)

        do {
            let elevations = try await elevationTask
            guard generation == requestGeneration, !Task.isCancelled else { return }
            cachedDistance = distanceMeters
            cachedElevations = elevations
            // `antennaHeight` est relue ICI, pas au démarrage : si le détail du
            // site a répondu pendant le chargement du relief, sa hauteur est
            // déjà prise en compte.
            let relief = AntennaSightGeometry.buildProfile(
                distanceMeters: distanceMeters,
                groundElevations: elevations,
                clutterHeights: [],
                antennaHeightMeters: antennaHeight,
                frequencyMhz: frequency
            )
            guard !relief.isEmpty else {
                failed = true
                loadedKey = nil
                return
            }
            // Premier rendu dès que le relief est là : l'utilisateur voit son
            // profil pendant qu'Overpass réfléchit encore.
            profile = relief
            verdict = AntennaSightGeometry.verdict(for: relief, includesBuildings: false)
            isLoading = false

            // Puis le bâti vient l'enrichir, sans jamais le remplacer par du vide.
            let buildings = await buildingTask
            guard generation == requestGeneration, !Task.isCancelled, let buildings else { return }
            cachedBuildings = buildings
            guard buildings.contains(where: { ($0 ?? 0) > 0 }) else { return }
            let enriched = AntennaSightGeometry.buildProfile(
                distanceMeters: distanceMeters,
                groundElevations: elevations,
                clutterHeights: buildings,
                antennaHeightMeters: antennaHeight,
                frequencyMhz: frequency
            )
            guard !enriched.isEmpty else { return }
            profile = enriched
            verdict = AntennaSightGeometry.verdict(for: enriched, includesBuildings: true)
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            failed = true
            // Un échec ne doit pas geler la vue sur cette clé : la prochaine
            // apparition de la fiche pourra réessayer.
            loadedKey = nil
        }
    }

    /// Valeurs copiées pour la présentation modale : l'annulation d'une tâche
    /// ou la disparition de sa vue source ne peuvent vider un profil ouvert.
    func snapshot() -> AntennaSightProfileSnapshot? {
        guard let displayKey, !profile.isEmpty else { return nil }
        return AntennaSightProfileSnapshot(requestKey: displayKey, profile: profile, verdict: verdict, distanceMeters: cachedDistance)
    }

    /// Force un recalcul, même position et même antenne — après un déplacement
    /// que le cache aurait considéré comme identique.
    func invalidate() {
        generation = UUID()
        displayKey = nil
        profile = []
        verdict = nil
        failed = false
        isLoading = false
        cachedDistance = 0
        loadedKey = nil
        cachedElevations = []
        cachedBuildings = []
    }
}


struct AntennaSightProfileSnapshot {
    let requestKey: String
    let profile: [AntennaSightGeometry.ProfilePoint]
    let verdict: AntennaSightGeometry.SightVerdict?
    let distanceMeters: Double
}
