import Foundation
import XCTest
@testable import SignalQuest

/// Lot 3c : chaque terme expliqué par un ⓘ l'est aussi en anglais, et le
/// glossaire reste cohérent (familles non vides, renvois qui mènent ailleurs).
final class GlossaryTests: XCTestCase {
    /// Lit le fichier compilé plutôt que `String(localized:)`, qui suit la
    /// langue du processus : ce test tourne dans la passe française.
    private func compiledStrings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
            subdirectory: "\(language).lproj"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
    }

    func testEveryTermIsTranslatedInEnglish() throws {
        let english = try compiledStrings("en")
        for term in SQTerm.allCases {
            let entry = term.entry
            var keys = [entry.title, entry.definition] + entry.scale.flatMap { [$0.0, $0.1] }
            if let example = entry.example { keys.append(example) }
            for key in keys {
                XCTAssertNotNil(english[key], "\(term.rawValue) : « \(key) » n’a pas de traduction anglaise")
            }
        }
        for group in SQGlossaryGroup.allCases {
            XCTAssertNotNil(english[group.title], "Famille « \(group.title) » sans traduction anglaise")
        }
        XCTAssertEqual(english["Aide et glossaire"], "Help and glossary")
    }

    func testGlossaryStaysConsistent() {
        for group in SQGlossaryGroup.allCases {
            XCTAssertFalse(SQTerm.allCases.filter { $0.group == group }.isEmpty, "\(group.rawValue) est vide")
        }
        for term in SQTerm.allCases {
            XCTAssertFalse(term.related.contains(term), "\(term.rawValue) renvoie vers lui-même")
            XCTAssertEqual(term.entry.related, term.related)
        }
        XCTAssertEqual(Set(SQTerm.allCases.map(\.entry.title)).count, SQTerm.allCases.count,
            "Deux termes portent le même titre")
    }
}
