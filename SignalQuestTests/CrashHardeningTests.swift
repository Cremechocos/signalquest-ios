import XCTest
@testable import SignalQuest

/// Non-régression sur cinq traps identifiés par analyse statique. Chaque test
/// échouerait — ou ferait crasher le runner — sur le code d'avant le correctif.
final class CrashHardeningTests: XCTestCase {

    // MARK: - MapBounds : conversions Int(...) sur NaN / infini

    /// `Int(Double.nan)` **trappe** (ce n'est pas un dépassement rattrapable).
    /// MapKit peut livrer un span NaN pendant une transition de caméra, et ces
    /// bornes alimentaient directement la clé de cache de `MapSnapshotService`.
    func testMapBoundsRejectsNonFiniteValues() {
        let finite = MapBounds(north: 48.9, south: 48.8, east: 2.4, west: 2.3)
        XCTAssertTrue(finite.isFinite)

        let cases: [(String, MapBounds)] = [
            ("north NaN", MapBounds(north: .nan, south: 48.8, east: 2.4, west: 2.3)),
            ("south NaN", MapBounds(north: 48.9, south: .nan, east: 2.4, west: 2.3)),
            ("east +inf", MapBounds(north: 48.9, south: 48.8, east: .infinity, west: 2.3)),
            ("west -inf", MapBounds(north: 48.9, south: 48.8, east: 2.4, west: -.infinity))
        ]
        for (label, bounds) in cases {
            XCTAssertFalse(bounds.isFinite, "\(label) doit être rejeté")
        }
    }

    /// Le snapshot doit refuser une région dégénérée AVANT de construire sa clé
    /// de cache, et le signaler comme une annulation — il n'y a rien à charger,
    /// ce n'est pas une erreur à montrer à l'utilisateur.
    func testSnapshotRejectsNonFiniteBoundsAsCancellation() async {
        let service = MapSnapshotService(api: APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore())))
        let bounds = MapBounds(north: .nan, south: 48.8, east: 2.4, west: 2.3)
        do {
            _ = try await service.snapshot(bounds: bounds, zoom: 12, lightweight: true)
            XCTFail("Une région non finie doit être rejetée")
        } catch {
            XCTAssertTrue(error.isCancellation, "Attendu .cancelled, obtenu \(error)")
        }
    }

    /// Bornes finies mais zoom NaN : c'est `Int(zoom)` qui trappe.
    func testSnapshotRejectsNonFiniteZoom() async {
        let service = MapSnapshotService(api: APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore())))
        let bounds = MapBounds(north: 48.9, south: 48.8, east: 2.4, west: 2.3)
        do {
            _ = try await service.snapshot(bounds: bounds, zoom: .nan, lightweight: true)
            XCTFail("Un zoom non fini doit être rejeté")
        } catch {
            XCTAssertTrue(error.isCancellation, "Attendu .cancelled, obtenu \(error)")
        }
    }

    // MARK: - decodeLossyArray : lossy réel, pas tout-ou-rien

    private struct Holder: Decodable {
        let values: [Int]
        let names: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            values = c.decodeLossyArray([Int].self, forKey: .values)
            names = c.decodeLossyArray([String].self, forKey: .names)
        }
        enum CodingKeys: String, CodingKey { case values, names }
    }

    /// Le comportement historique (`(try? decode([T].self)) ?? []`) vidait le
    /// tableau ENTIER dès qu'un élément était mal typé : une valeur inattendue
    /// ajoutée côté serveur faisait disparaître toute la liste des opérateurs,
    /// des bandes ou des clusters d'une tuile de carte.
    func testLossyArrayKeepsValidElements() throws {
        let json = #"{"values":[1,"deux",3],"names":["a",42,"c"]}"#
        let holder = try JSONDecoder().decode(Holder.self, from: Data(json.utf8))
        XCTAssertEqual(holder.values, [1, 3], "L'élément invalide doit être ignoré, pas vider le tableau")
        XCTAssertEqual(holder.names, ["a", "c"])
    }

    func testLossyArrayHandlesFullyInvalidAndMissingKeys() throws {
        let allInvalid = try JSONDecoder().decode(Holder.self, from: Data(#"{"values":["x"],"names":[1]}"#.utf8))
        XCTAssertEqual(allInvalid.values, [])
        XCTAssertEqual(allInvalid.names, [])

        let missing = try JSONDecoder().decode(Holder.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.values, [])

        // Valeur non-tableau : ne doit ni throw ni boucler.
        let notAnArray = try JSONDecoder().decode(Holder.self, from: Data(#"{"values":"nope","names":null}"#.utf8))
        XCTAssertEqual(notAnArray.values, [])
        XCTAssertEqual(notAnArray.names, [])
    }

    /// `decodeLossyElementArray` est conservé comme alias : les deux doivent
    /// désormais se comporter à l'identique.
    func testLossyElementArrayIsAnAlias() throws {
        struct Both: Decodable {
            let a: [Int]
            let b: [Int]
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                a = c.decodeLossyArray([Int].self, forKey: .v)
                b = c.decodeLossyElementArray([Int].self, forKey: .v)
            }
            enum CodingKeys: String, CodingKey { case v }
        }
        let decoded = try JSONDecoder().decode(Both.self, from: Data(#"{"v":[1,"x",2]}"#.utf8))
        XCTAssertEqual(decoded.a, decoded.b)
        XCTAssertEqual(decoded.a, [1, 2])
    }

    // MARK: - SpeedtestLiveSampler : accès concurrent

    /// L'état était muté sans synchronisation alors que `observe` est appelé
    /// depuis les callbacks `NWConnection`. Deux `append`/`removeFirst`
    /// concurrents sur un `Array` Swift corrompent le buffer. À exécuter sous
    /// Thread Sanitizer pour que la détection soit fiable ; sans TSan, ce test
    /// vérifie au moins l'absence de crash et la cohérence du résultat.
    func testLiveSamplerSurvivesConcurrentObservations() {
        let sampler = SpeedtestLiveSampler(windowMs: 500, smoothing: 0.3)
        let iterations = 500
        let queues = (0..<4).map { DispatchQueue(label: "sampler.\($0)") }
        let group = DispatchGroup()

        for (index, queue) in queues.enumerated() {
            group.enter()
            queue.async {
                for i in 0..<iterations {
                    _ = sampler.observe(
                        totalBytes: (i + 1) * 1_000 * (index + 1),
                        elapsedMs: Double(i) * 10
                    )
                }
                group.leave()
            }
        }

        let finished = group.wait(timeout: .now() + 30)
        XCTAssertEqual(finished, .success, "Les observations concurrentes doivent se terminer")
        XCTAssertTrue(sampler.lastInstantMbps.isFinite, "Le débit instantané doit rester exploitable")
        XCTAssertGreaterThanOrEqual(sampler.lastInstantMbps, 0)
    }

    /// Le lissage exponentiel doit rester correct après l'introduction du verrou.
    func testLiveSamplerSmoothingIsUnchanged() {
        let sampler = SpeedtestLiveSampler(windowMs: 1_000, smoothing: 0.5)
        XCTAssertEqual(sampler.observe(totalBytes: 0, elapsedMs: 0), 0, accuracy: 0.0001)
        // 1 000 000 octets en 1 000 ms = 8 Mbit/s ; première valeur = pas de lissage.
        XCTAssertEqual(sampler.observe(totalBytes: 1_000_000, elapsedMs: 1_000), 8, accuracy: 0.01)
    }
}
