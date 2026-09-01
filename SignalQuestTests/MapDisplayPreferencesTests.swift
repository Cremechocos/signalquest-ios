import XCTest
@testable import SignalQuest

/// Anciennes préférences basemap : aucun chemin ne doit réactiver CARTO.
final class MapBackdropMigrationTests: XCTestCase {
    func testLegacyCartoResolvesToNativeAppleEvenBeforeMigration() {
        XCTAssertEqual(MapBackdrop.resolve("carto"), .applePlan)
        XCTAssertEqual(MapBackdrop.carto.mapKitKind, .applePlan)
        XCTAssertFalse(MapBackdrop.carto.usesThirdPartyTiles)
        XCTAssertEqual(MapBackdrop.carto.label, MapBackdrop.applePlan.label)
    }

    func testOnlySupportedChoicesAreOfferedAndUnknownValuesAreSafe() {
        XCTAssertEqual(MapBackdrop.allCases, [.applePlan, .osm, .topo, .satellite])
        XCTAssertEqual(MapBackdrop.resolve(nil), .applePlan)
        XCTAssertEqual(MapBackdrop.resolve("future-provider"), .applePlan)
        for choice in MapBackdrop.allCases {
            XCTAssertEqual(MapBackdrop.resolve(choice.rawValue), choice)
        }
    }

    func testMigrationIsIdempotentAndPreservesUnrelatedPreferences() throws {
        let suite = "SignalQuest.MapBackdropTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("carto", forKey: MapBackdrop.storageKey)
        defaults.set("sentinel", forKey: "unrelated-setting")
        MapBackdrop.migrateLegacyPreference(in: defaults)
        MapBackdrop.migrateLegacyPreference(in: defaults)
        XCTAssertEqual(defaults.string(forKey: MapBackdrop.storageKey), "applePlan")
        XCTAssertEqual(MapBackdrop.current(in: defaults), .applePlan)
        XCTAssertEqual(defaults.string(forKey: "unrelated-setting"), "sentinel")
    }

    func testMigrationDoesNotOverwriteAnExplicitSupportedChoice() throws {
        let suite = "SignalQuest.MapBackdropTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for choice in MapBackdrop.allCases {
            defaults.set(choice.rawValue, forKey: MapBackdrop.storageKey)
            MapBackdrop.migrateLegacyPreference(in: defaults)
            XCTAssertEqual(defaults.string(forKey: MapBackdrop.storageKey), choice.rawValue)
        }
    }
}

/// Réglages d'affichage de la carte : croisement des bandes et style d'azimut.
/// Tous deux persistent entre deux lancements, et leur valeur par défaut doit
/// reproduire le comportement d'avant — sinon la carte changerait toute seule
/// pour les utilisateurs existants.
final class MapDisplayPreferencesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MapBandMatchStore.reset()
        MapAzimuthStyleStore.reset()
    }

    override func tearDown() {
        MapBandMatchStore.reset()
        MapAzimuthStyleStore.reset()
        super.tearDown()
    }

    // MARK: Croisement des bandes

    func testBandMatchDefaultsToTheHistoricalBehaviour() {
        XCTAssertEqual(MapBandMatchStore.last(), .any)
    }

    func testBandMatchRoundTrips() {
        for mode in BandMatchMode.allCases {
            MapBandMatchStore.save(mode)
            XCTAssertEqual(MapBandMatchStore.last(), mode)
        }
    }

    /// La valeur brute part telle quelle en `?bandMatch=` : la changer casserait
    /// le contrat avec le backend, qui attend ces trois jetons exacts.
    func testBandMatchRawValuesMatchTheApiContract() {
        XCTAssertEqual(BandMatchMode.any.rawValue, "any")
        XCTAssertEqual(BandMatchMode.all.rawValue, "all")
        XCTAssertEqual(BandMatchMode.only.rawValue, "only")
    }

    /// Une valeur écrite par une version future (ou corrompue) ne doit pas
    /// planter ni bloquer la carte : on retombe sur le défaut.
    func testUnknownStoredBandMatchFallsBackToAny() {
        UserDefaults.standard.set("quelque-chose", forKey: MapBandMatchStore.key)
        XCTAssertEqual(MapBandMatchStore.last(), .any)
    }

    // MARK: Style d'azimut

    /// Les traits sont le défaut : ils restent lisibles en zone dense, et ce sont
    /// eux qui portent la couleur par opérateur sur un support partagé.
    func testAzimuthStyleDefaultsToLines() {
        XCTAssertEqual(MapAzimuthStyleStore.last(), .lines)
    }

    func testAzimuthStyleRoundTrips() {
        for style in AzimuthStyle.allCases {
            MapAzimuthStyleStore.save(style)
            XCTAssertEqual(MapAzimuthStyleStore.last(), style)
        }
    }

    func testUnknownStoredAzimuthStyleFallsBackToTheDefault() {
        UserDefaults.standard.set("fleches", forKey: MapAzimuthStyleStore.key)
        XCTAssertEqual(MapAzimuthStyleStore.last(), .lines)
    }

    /// Trois styles proposés, dont « aucun » : le quatrième (flèches) a été
    /// écarté, ce test évite qu'il revienne par inadvertance.
    func testThreeAzimuthStylesAreOffered() {
        XCTAssertEqual(AzimuthStyle.allCases, [.lobes, .lines, .hidden])
    }
}

/// Dégagement des contenus flottants posés sur une carte plein écran.
///
/// Ces contenus (légende, notice, panneau de contrôle) sont dans un `ZStack`
/// avec une carte qui fait `ignoresSafeArea()` : ils retombent donc au bas
/// PHYSIQUE de l'écran, là où le dock flottant les recouvre. Le
/// `sqDockSafeArea()` posé sur l'onglet ne les atteint pas.
final class DockFloatingInsetTests: XCTestCase {

    /// Le dégagement doit couvrir toute la hauteur du dock, sinon le contenu
    /// passe dessous — c'est le retour testeur qui a motivé la constante.
    func testFloatingInsetClearsTheWholeDock() {
        let inset = SQDock.floatingContentInset
        if SQDock.usesLegacyDock {
            XCTAssertGreaterThanOrEqual(inset, SQDock.clearance,
                                        "le dock custom se superpose : il faut réserver toute sa hauteur")
        } else if #available(iOS 26.0, *) {
            // Barre native : la safe area est déjà décalée, un simple souffle suffit.
            XCTAssertGreaterThan(inset, 0)
            XCTAssertLessThan(inset, SQDock.clearance)
        } else {
            XCTAssertGreaterThanOrEqual(inset, SQDock.clearance)
        }
    }

    /// Les vues combinent l'inset avec leur propre marge d'habillage. Avec la
    /// barre native l'inset VAUT `SQSpace.lg` : une soustraction nue donnerait
    /// alors zéro — acceptable — mais une marge plus grande donnerait un padding
    /// négatif, qui retire de l'espace. Le helper doit borner à zéro.
    func testCombinedInsetNeverGoesNegative() {
        XCTAssertGreaterThanOrEqual(SQDock.floatingContentInset(subtracting: SQSpace.lg), 0)
        XCTAssertGreaterThanOrEqual(SQDock.floatingContentInset(subtracting: SQSpace.md), 0)
        // Cas extrême : une marge bien plus grande que l'inset.
        XCTAssertEqual(SQDock.floatingContentInset(subtracting: 500), 0)
    }

    /// Avec le dock custom, le dégagement combiné doit rester substantiel :
    /// c'est lui qui empêche la légende de passer sous la capsule flottante.
    func testLegacyDockKeepsARealClearanceAfterSubtraction() throws {
        try XCTSkipUnless(SQDock.usesLegacyDock, "cas du dock custom uniquement")
        XCTAssertGreaterThanOrEqual(SQDock.floatingContentInset(subtracting: SQSpace.lg), SQDock.clearance - SQSpace.lg)
    }
}
