import XCTest

/// Mesures de FLUIDITÉ objectives (build Release, appareil physique). UN SEUL bloc
/// `measure()` par méthode (contrainte XCTest) → une méthode par scénario. Les
/// résultats « measured […] » s'impriment dans la sortie de test + le .xcresult.
@MainActor
final class FluidityQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        let token = env["SQ_AUTH_TOKEN"] ?? ""
        if env["SQ_EXISTING_SESSION"] == "1" {
            // Rien : on garde la session déjà présente dans le Keychain (compte RÉEL
            // de l'utilisateur, déjà connecté). Aucune injection, aucun reset.
        } else if token.isEmpty {
            app.launchArguments += ["--mock-auth", "--reset-map"]
        } else {
            app.launchEnvironment["SQ_AUTH_TOKEN"] = token
            app.launchArguments += ["--reset-map"]
        }
        return app
    }

    private func dismissSystemAlert() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for l in ["Refuser", "Ne pas autoriser", "Don't Allow", "Autoriser", "Allow"] {
            let b = sb.buttons[l]
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }
    }

    private func measureOptions() -> XCTMeasureOptions {
        let opts = XCTMeasureOptions()
        opts.invocationOptions = [.manuallyStart, .manuallyStop]
        return opts
    }

    /// Temps de lancement à froid (Release).
    func testLaunchPerformance() {
        let app = configuredApp()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
            _ = app.tabBars.buttons["Feed"].waitForExistence(timeout: 25)
            app.terminate()
        }
    }

    /// Fluidité du scroll du Feed (écran d'accueil, anneaux de stories + cartes).
    func testFeedScrollHitches() {
        let app = configuredApp()
        app.launch()
        dismissSystemAlert()
        XCTAssertTrue(app.tabBars.buttons["Feed"].waitForExistence(timeout: 25))
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTCPUMetric(), XCTMemoryMetric()], options: measureOptions()) {
            startMeasuring()
            for _ in 0..<6 { app.swipeUp(velocity: .fast) }
            for _ in 0..<4 { app.swipeDown(velocity: .fast) }
            stopMeasuring()
        }
    }

    /// Pilote : ouvre la Carte et pan en boucle ~50 s (sans mesure). Sert de « driver »
    /// pour une capture externe `xctrace` (Animation Hitches) attachée à l'app pendant
    /// que MKMapView s'anime. Imprime TRACE_MAP_PANNING quand le pan démarre.
    func testMapDriveLong() {
        let app = configuredApp()
        app.launch()
        dismissSystemAlert()
        XCTAssertTrue(app.tabBars.buttons["Carte"].waitForExistence(timeout: 25))
        app.tabBars.buttons["Carte"].tap()
        Thread.sleep(forTimeInterval: 6)
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let left   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.45))
        let right  = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.45))
        let up     = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        NSLog("TRACE_MAP_PANNING")
        print("TRACE_MAP_PANNING")
        let deadline = Date().addingTimeInterval(50)
        while Date() < deadline {
            center.press(forDuration: 0.02, thenDragTo: left)
            center.press(forDuration: 0.02, thenDragTo: up)
            center.press(forDuration: 0.02, thenDragTo: right)
        }
    }

    /// Fluidité du pan/zoom de la Carte (écran le plus lourd : MapKit + overlays).
    func testMapPanHitches() {
        let app = configuredApp()
        app.launch()
        dismissSystemAlert()
        XCTAssertTrue(app.tabBars.buttons["Carte"].waitForExistence(timeout: 25))
        app.tabBars.buttons["Carte"].tap()
        Thread.sleep(forTimeInterval: 5)   // laisse la carte + antennes charger
        // Drags UNIQUEMENT dans la zone centrale (dy 0.30–0.55) : loin de la barre de
        // recherche (haut), de la barre d'onglets et des boutons (bas) → aucun tap
        // destructeur (déconnexion, filtres…). PERF-MAP fluidité.
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let left   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.45))
        let right  = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.45))
        let up     = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTCPUMetric()], options: measureOptions()) {
            startMeasuring()
            for _ in 0..<6 {
                center.press(forDuration: 0.02, thenDragTo: left)
                center.press(forDuration: 0.02, thenDragTo: up)
                center.press(forDuration: 0.02, thenDragTo: right)
            }
            stopMeasuring()
        }
    }
}
