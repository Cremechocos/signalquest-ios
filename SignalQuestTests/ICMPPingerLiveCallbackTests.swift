import XCTest
@testable import SignalQuest

/// Le rappel `onSample` d'`ICMPPinger` est-il réellement appelé PENDANT la série ?
///
/// La distinction est tout l'objet du correctif : avant, la série n'était rendue
/// qu'à la fin, et l'écran restait vide plusieurs secondes. Un test sur la seule
/// sélection des valeurs ne l'aurait pas vu — il faut exercer le pinger.
///
/// Cible : la boucle locale. Elle répond toujours, sans dépendre du réseau ni du
/// DNS, et rend le test rapide et déterministe. Si l'ICMP n'est pas disponible
/// dans l'environnement d'exécution, le test s'ABSTIENT plutôt que d'échouer :
/// il vérifie un câblage, pas la joignabilité d'un hôte.
final class ICMPPingerLiveCallbackTests: XCTestCase {

    func testOnSampleFiresDuringTheSeriesNotOnlyAtTheEnd() async throws {
        let pinger = ICMPPinger(host: "127.0.0.1", timeout: 1)

        // Chaque appel est horodaté : c'est l'écart entre le PREMIER rappel et la
        // fin de la série qui prouve qu'on n'a pas tout reçu d'un coup.
        let recorder = CallbackRecorder()
        let started = Date()
        let samples = try await pinger.ping(
            count: 4,
            intervalMs: 120,
            onSample: { running in recorder.record(count: running.count) }
        )
        let totalElapsed = Date().timeIntervalSince(started)

        try XCTSkipIf(samples.isEmpty, "ICMP indisponible ici — câblage non exerçable")

        let calls = recorder.snapshot()
        XCTAssertEqual(calls.count, samples.count,
                       "un rappel par écho reçu")
        XCTAssertEqual(calls.map(\.count), Array(1...samples.count),
                       "la série passée doit s'allonger d'un écho à chaque appel")

        // Le cœur : le premier rappel arrive NETTEMENT avant la fin.
        if samples.count >= 2, totalElapsed > 0.05 {
            let firstCallAt = calls[0].elapsed
            XCTAssertLessThan(
                firstCallAt, totalElapsed * 0.8,
                "le 1er rappel doit précéder la fin de la série — sinon on est revenu au comportement d'origine"
            )
        }
    }

    /// Enregistreur simple : le rappel est `@Sendable`, il lui faut un état protégé.
    private final class CallbackRecorder: @unchecked Sendable {
        struct Call { let count: Int; let elapsed: TimeInterval }
        private let lock = NSLock()
        private let origin = Date()
        private var calls: [Call] = []

        func record(count: Int) {
            lock.lock()
            calls.append(Call(count: count, elapsed: Date().timeIntervalSince(origin)))
            lock.unlock()
        }

        func snapshot() -> [Call] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }
}
