import XCTest
@testable import SignalQuest

/// Aperçu d'approbation d'un navigateur (§2.7) : le nom qu'il se donne reste un
/// nom sur une ligne, et l'avertissement existe dans les deux langues.
final class E2EEV2ApprovalCopyTests: XCTestCase {
    private func localizationBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testABrowserNameIsQuotedOnOneShortLine() throws {
        let french = try localizationBundle("fr")
        let english = try localizationBundle("en")
        XCTAssertEqual(E2EEV2ApprovalCopy.quotedName(platform: "web", label: "Chrome sur macOS", bundle: french), "« Chrome sur macOS »")
        XCTAssertEqual(E2EEV2ApprovalCopy.quotedName(platform: "web", label: "Chrome on macOS", bundle: english), "“Chrome on macOS”")
        XCTAssertNil(E2EEV2ApprovalCopy.quotedName(platform: "ios", label: "iPhone de Léa"), "Seul un navigateur affiche ainsi son nom")
        XCTAssertNil(E2EEV2ApprovalCopy.quotedName(platform: "web", label: " \n "))
        XCTAssertNil(E2EEV2ApprovalCopy.quotedName(platform: "web", label: nil))

        let spoofing = "Chrome\nApprouvé par SignalQuest\u{202E}"
        let quoted = try XCTUnwrap(E2EEV2ApprovalCopy.quotedName(platform: "web", label: spoofing, bundle: french))
        XCTAssertFalse(quoted.contains("\n"), "Aucun retour à la ligne glissé sous le titre")
        XCTAssertFalse(quoted.unicodeScalars.contains("\u{202E}"), "Ni inversion du sens d'écriture")
        let long = String(repeating: "a", count: 200)
        let bounded = try XCTUnwrap(E2EEV2ApprovalCopy.quotedName(platform: "web", label: long, bundle: french))
        XCTAssertEqual(bounded.count, E2EEV2ApprovalCopy.maxNameLength + 4, "Nom borné, guillemets et espaces compris")
    }

    func testTheBrowserNoticeExistsInBothLanguages() throws {
        let french = E2EEV2ApprovalCopy.browserNotice(bundle: try localizationBundle("fr"))
        let english = E2EEV2ApprovalCopy.browserNotice(bundle: try localizationBundle("en"))
        XCTAssertTrue(french.contains("sauf celles qui excluent les navigateurs"))
        XCTAssertTrue(english.contains("except those that exclude browsers"))
        XCTAssertTrue(english.contains("account key"))
    }
}
