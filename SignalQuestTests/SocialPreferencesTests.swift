import XCTest
@testable import SignalQuest

/// Le serveur indexe les hashtags sous leur forme NUE. Une normalisation
/// approximative crée des entrées distinctes pour le même tag, et l'utilisateur
/// voit « #5G » et « 5g » côte à côte sans comprendre pourquoi.
final class SocialPreferencesTests: XCTestCase {

    func testHashtagNormalisationMatchesTheServerForm() {
        XCTAssertEqual("#5G".normalizedHashtag, "5g")
        XCTAssertEqual("  #Fibre ".normalizedHashtag, "fibre")
        XCTAssertEqual("RESEAU".normalizedHashtag, "reseau")
        XCTAssertEqual("##double".normalizedHashtag, "double")
    }

    /// Toutes les écritures d'un même tag doivent converger : c'est ce qui
    /// empêche les doublons côté serveur.
    func testAllSpellingsOfATagConverge() {
        let forms = ["5g", "5G", "#5g", "#5G", " #5G "]
        XCTAssertEqual(Set(forms.map(\.normalizedHashtag)).count, 1)
    }

    /// L'affichage remet le `#` que le stockage n'a pas.
    func testDisplayAddsTheHashWithoutDoublingIt() {
        XCTAssertEqual(FollowedHashtag(hashtag: "5g", notifyOnNew: false, createdAt: nil).displayTag, "#5g")
        XCTAssertEqual(FollowedHashtag(hashtag: "#5g", notifyOnNew: false, createdAt: nil).displayTag, "#5g")
    }

    /// Une liste absente vaut liste vide : l'écran de réglages ne doit pas se
    /// vider parce que le serveur a omis un champ.
    func testMissingListsDecodeAsEmpty() throws {
        let mutes = try JSONDecoder().decode(SocialMutes.self, from: Data(#"{"words":[{"pattern":"spam"}]}"#.utf8))
        XCTAssertTrue(mutes.hashtags.isEmpty)
        XCTAssertEqual(mutes.words.count, 1)
        XCTAssertFalse(mutes.isEmpty)
    }

    func testFullInventoryDecodes() throws {
        let json = """
        {"hashtags":[{"hashtag":"5g","createdAt":"2026-07-20T10:00:00Z"}],
         "words":[{"pattern":"promo","createdAt":"2026-07-21T10:00:00Z"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let mutes = try decoder.decode(SocialMutes.self, from: Data(json.utf8))
        XCTAssertEqual(mutes.hashtags.first?.displayTag, "#5g")
        XCTAssertEqual(mutes.words.first?.pattern, "promo")
    }

    /// Un tag vide ne doit rien envoyer : le serveur répondrait 404 sur une
    /// route dont le segment est vide.
    func testEmptyTagNormalisesToEmptyAndIsRejectedUpstream() {
        XCTAssertTrue("#".normalizedHashtag.isEmpty)
        XCTAssertTrue("   ".normalizedHashtag.isEmpty)
    }
}
