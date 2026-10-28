import XCTest
@testable import SignalQuest

/// PRIVACY-DPV v1 : vecteur `contracts/social/default-post-visibility-v1.json`,
/// copié à l'octet depuis le serveur (2bf37ef49).
@MainActor
final class DefaultPostVisibilityTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/social/default-post-visibility-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func settings(_ extra: String) throws -> SocialPrivacy {
        let json = """
        {"shareLiveLocationWithFriends":false,"shareRadioDataWithFriends":false,"shareSessionsWithFriends":false,
         "sharePhotosOnFriendMap":false,"lastSeenVisibility":"friends","messageRequestPolicy":"friends_only"\(extra)}
        """
        return try JSONDecoder.signalQuest.decode(SocialPrivacy.self, from: Data(json.utf8))
    }

    /// §9 : les textes sont ceux du vecteur, à l'octet, dans les trois formes.
    func testTextsMatchTheVectorByteForByte() throws {
        let texts = try XCTUnwrap(try vector()["texts"] as? [String: Any])
        let entries = try XCTUnwrap(texts["entries"] as? [String: [String: String]])
        XCTAssertEqual(Set(entries.keys), Set(DefaultPostVisibilityText.entries.keys))
        for (key, forms) in entries {
            for form in DefaultPostVisibilityText.Form.allCases {
                XCTAssertEqual(DefaultPostVisibilityText.text(key, form: form), forms[form.rawValue], "\(key) \(form.rawValue)")
            }
        }
        for value in DefaultPostVisibility.allCases {
            XCTAssertNotNil(entries["audience.\(value.rawValue)"])
        }
    }

    /// §3 : la réponse `include=posts` donne la valeur effective et « à demander ».
    func testServedCasesDecodeToTheEffectiveValueAndPending() throws {
        let served = try XCTUnwrap(try vector()["served"] as? [String: Any])
        let cases = try XCTUnwrap(served["cases"] as? [[String: Any]])
        for item in cases {
            let raw = try XCTUnwrap(item["defaultPostVisibility"] as? String)
            let pending = try XCTUnwrap(item["defaultPostVisibilityPending"] as? Bool)
            let value = try settings(",\"defaultPostVisibility\":\"\(raw)\",\"defaultPostVisibilityPending\":\(pending)")
            XCTAssertEqual(value.defaultPostVisibility?.rawValue, raw, "\(item["name"] ?? "")")
            XCTAssertEqual(value.defaultPostVisibilityPending, pending)
        }
        let official = try XCTUnwrap(served["officialAccount"] as? [String: Any])
        XCTAssertEqual(official["defaultPostVisibilityPending"] as? Bool, false, "Le compte officiel n'a jamais de page")
    }

    /// Ancien serveur, ou valeur illisible : ni page, ni lien (§6).
    func testMissingOrUnknownValueMeansUnsupportedAndNeverPending() throws {
        let old = try settings("")
        XCTAssertNil(old.defaultPostVisibility)
        XCTAssertNil(old.defaultPostVisibilityPending)
        let unknown = try settings(",\"defaultPostVisibility\":\"Private\",\"defaultPostVisibilityPending\":true")
        XCTAssertNil(unknown.defaultPostVisibility)
        XCTAssertNil(unknown.defaultPostVisibilityPending, "Jamais de page sur une valeur mal lue")

        let store = DefaultPostVisibilityStore()
        store.record(unknown, owner: "user:a")
        XCTAssertTrue(store.isUnsupported(owner: "user:a"))
        XCTAssertNil(store.state(owner: "user:a"))
        XCTAssertEqual(store.composerPrefill(owner: "user:a"), .friends)
    }

    /// §4, §6, §7 : le corps du PATCH. Sans la case, seulement la valeur : c'est
    /// aussi, au champ près, le geste de fermeture de la page.
    func testPatchBodiesFollowTheVector() throws {
        func encoded(_ patch: DefaultPostVisibilityPatch) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(patch)) as? NSDictionary)
        }
        XCTAssertEqual(try encoded(DefaultPostVisibilityPatch(defaultPostVisibility: .privateOnly)),
                       ["defaultPostVisibility": "private"])
        XCTAssertEqual(try encoded(DefaultPostVisibilityPatch(defaultPostVisibility: .privateOnly, applyToExistingPosts: true)),
                       ["defaultPostVisibility": "private", "applyToExistingPosts": true])
        let patch = try XCTUnwrap(try vector()["patch"] as? [String: Any])
        let accepted = try XCTUnwrap(patch["cases"] as? [[String: Any]]).filter { $0["status"] as? Int == 200 }
        for item in accepted {
            let body = try XCTUnwrap(item["body"] as? [String: Any])
            let value = try XCTUnwrap(DefaultPostVisibility(rawValue: try XCTUnwrap(body["defaultPostVisibility"] as? String)))
            let apply = body["applyToExistingPosts"] as? Bool == true
            var expected = body
            if body["applyToExistingPosts"] as? Bool == false { expected["applyToExistingPosts"] = nil }
            XCTAssertEqual(try encoded(DefaultPostVisibilityPatch(defaultPostVisibility: value, applyToExistingPosts: apply ? true : nil)),
                           expected as NSDictionary)
        }
    }

    /// §7 : `appliedToExistingPosts` est lu à la racine, à côté de `settings`.
    func testAppliedCountIsReadAtTheRootOfTheResponse() throws {
        let base = """
        {"shareLiveLocationWithFriends":false,"shareRadioDataWithFriends":false,"shareSessionsWithFriends":false,
         "sharePhotosOnFriendMap":false,"lastSeenVisibility":"none","messageRequestPolicy":"everyone",
         "defaultPostVisibility":"private","defaultPostVisibilityPending":false}
        """
        let applied = try JSONDecoder.signalQuest.decode(PrivacySettingsResponse.self,
            from: Data(#"{"settings":\#(base),"appliedToExistingPosts":4}"#.utf8))
        XCTAssertEqual(applied.appliedToExistingPosts, 4)
        XCTAssertEqual(applied.settings.defaultPostVisibility, .privateOnly)
        XCTAssertEqual(applied.settings.defaultPostVisibilityPending, false)
        let none = try JSONDecoder.signalQuest.decode(PrivacySettingsResponse.self, from: Data(#"{"settings":\#(base)}"#.utf8))
        XCTAssertNil(none.appliedToExistingPosts)
    }

    /// §7 : un 503 a sa phrase, et n'est jamais rejoué tout seul.
    func testApplyTimeoutHasItsTextAndIsNotRetriedAutomatically() throws {
        let timeout = try XCTUnwrap(try vector()["applyToExistingPosts"] as? [String: Any])["timeout"] as? [String: Any]
        let headers = try XCTUnwrap(timeout?["headers"] as? [String: String])
        let retryAfter = try XCTUnwrap(Int(try XCTUnwrap(headers["Retry-After"])))
        XCTAssertNil(APIClient.throttleDelaySeconds(retryAfter: retryAfter, attempt: 0),
                     "Retry-After: 5 dépasse le plafond de rejeu automatique")
        let error = APIError.http(status: 503, code: "PRIVACY_APPLY_RETRY", message: "", requestId: nil, retryAfter: retryAfter)
        XCTAssertEqual(DefaultPostVisibilityText.failureMessage(error), DefaultPostVisibilityText.text("error.applyRetry"))
        XCTAssertNotEqual(DefaultPostVisibilityText.failureMessage(APIError.http(status: 400, code: "PRIVACY_SETTING_INVALID",
            message: "", requestId: nil, retryAfter: nil)), DefaultPostVisibilityText.text("error.applyRetry"))
    }

    /// §7, §9 : la case est masquée avec « Automatique », et sa phrase remplace
    /// celle des publications gardées.
    func testExistingPostsNoteFollowsTheCheckbox() {
        XCTAssertFalse(DefaultPostVisibilitySheet.applyToExistingPostsByDefault, "Décochée à chaque ouverture")
        XCTAssertFalse(DefaultPostVisibility.auto.allowsApplyingToExistingPosts)
        XCTAssertEqual(DefaultPostVisibility.auto.existingPostsNote(applying: true), DefaultPostVisibilityText.text("note.existingKept"))
        for value in [DefaultPostVisibility.publicWorld, .friends, .privateOnly] {
            XCTAssertEqual(value.existingPostsNote(applying: false), DefaultPostVisibilityText.text("note.existingKept"))
            XCTAssertEqual(value.existingPostsNote(applying: true), DefaultPostVisibilityText.text("note.existingApplied.\(value.rawValue)"))
        }
    }

    /// §8 : le composer part de la valeur effective ; « Automatique » vaut amis.
    func testComposerPrefillFollowsTheEffectiveValue() throws {
        XCTAssertEqual(DefaultPostVisibility.auto.composerVisibility, .friends)
        XCTAssertEqual(DefaultPostVisibility.publicWorld.composerVisibility, .publicWorld)
        XCTAssertEqual(DefaultPostVisibility.friends.composerVisibility, .friends)
        XCTAssertEqual(DefaultPostVisibility.privateOnly.composerVisibility, .privateOnly)

        let store = DefaultPostVisibilityStore()
        XCTAssertEqual(store.composerPrefill(owner: "user:a"), .friends, "Rien de chargé : amis")
        store.record(try settings(",\"defaultPostVisibility\":\"private\",\"defaultPostVisibilityPending\":false"), owner: "user:a")
        XCTAssertEqual(store.composerPrefill(owner: "user:a"), .privateOnly)
        XCTAssertEqual(store.composerPrefill(owner: "user:b"), .friends, "Le réglage d'un compte ne sert pas à un autre")
        XCTAssertFalse(store.isUnsupported(owner: "user:a"))
    }

    /// §6 : un seul GET frais par lancement et par compte.
    func testLaunchCheckHappensOncePerAccount() {
        let store = DefaultPostVisibilityStore()
        XCTAssertTrue(store.needsLaunchCheck(owner: "user:a"))
        store.markLaunchChecked(owner: "user:a")
        XCTAssertFalse(store.needsLaunchCheck(owner: "user:a"))
        XCTAssertTrue(store.needsLaunchCheck(owner: "user:b"))
    }
}
