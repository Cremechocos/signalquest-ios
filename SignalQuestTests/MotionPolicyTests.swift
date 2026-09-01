import SwiftUI
import XCTest
@testable import SignalQuest

/// Verrouille la règle d'accessibilité : une boucle n'existe que dans le
/// helper central, qui refuse de la construire sous Reduce Motion.
final class MotionPolicyTests: XCTestCase {
    func testRepeatingMotionIsNotConstructedWhenMotionIsReduced() {
        XCTAssertNil(
            SQMotion.repeating(
                .linear(duration: 1),
                reduceMotion: true
            )
        )
    }

    func testRepeatingMotionIsNotConstructedForAnInactiveSurface() {
        XCTAssertNil(
            SQMotion.repeating(
                .linear(duration: 1),
                active: false,
                reduceMotion: false
            )
        )
    }

    func testRepeatingMotionRemainsAvailableForAnActiveSurface() {
        XCTAssertNotNil(
            SQMotion.repeating(
                .linear(duration: 1),
                active: true,
                reduceMotion: false
            )
        )
    }

    func testNoProductionViewBypassesTheRepeatingMotionGate() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("SignalQuestApp", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        )

        var offenders: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift", url.lastPathComponent != "SQMotion.swift" else {
                continue
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains(".repeatForever(") {
                offenders.append(url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""))
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Les boucles doivent passer par SQMotion.repeating : \(offenders.sorted())"
        )
    }
}
