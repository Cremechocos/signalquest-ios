import SwiftUI
import UIKit
import XCTest
@testable import SignalQuest

/// TRX-39 : une écriture dans UserDefaults recalcule-t-elle une vue qui observe
/// une AUTRE clé par @AppStorage ? Banc de mesure : compte les évaluations de
/// `body` d'une sonde hébergée dans une fenêtre, avec une clé à point et une
/// clé sans point. Mesuré le 01/10 : 5 écritures, 5 recalculs avec le point,
/// aucun sans. D'où les clés observées sans point (`SQObservedDefaultsKeys`).
@MainActor
final class AppStorageObservationTests: XCTestCase {
    private final class Count { var value = 0 }

    private struct DottedProbe: View {
        @AppStorage("sq.trx39.dotted") private var flag = false
        let count: Count
        var body: some View {
            count.value += 1
            return Text(flag ? "1" : "0")
        }
    }

    private struct PlainProbe: View {
        @AppStorage("sqTrx39Plain") private var flag = false
        let count: Count
        var body: some View {
            count.value += 1
            return Text(flag ? "1" : "0")
        }
    }

    override func tearDown() {
        for key in ["sq.trx39.dotted", "sqTrx39Plain", "sqTrx39Other"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    /// Évaluations de `body` provoquées par cinq écritures d'une autre clé.
    private func rendersCausedByOtherWrites<V: View>(_ view: (Count) -> V) -> Int {
        let count = Count()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let host = UIHostingController(rootView: view(count))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = count.value
        for index in 0..<5 {
            UserDefaults.standard.set(index, forKey: "sqTrx39Other")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let caused = count.value - before
        window.isHidden = true
        return caused
    }

    func testWritesToAnotherKeyAndTheViewsThatObserveAppStorage() {
        let dotted = rendersCausedByOtherWrites { DottedProbe(count: $0) }
        let plain = rendersCausedByOtherWrites { PlainProbe(count: $0) }
        // Mesure consignée dans le journal du test ; l'assertion ne garde que
        // ce qui doit tenir quelle que soit l'explication : une clé sans point
        // ne se recalcule pas pour l'écriture d'une autre clé.
        print("TRX39 dotted=\(dotted) plain=\(plain)")
        XCTAssertEqual(plain, 0, "Une clé sans point ne devrait pas réagir aux autres écritures")
    }
}
