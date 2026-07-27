import XCTest
@testable import SignalQuest

/// Le kill-switch de version est la seule fonctionnalité de l'app capable de la
/// rendre volontairement inutilisable. Une erreur de comparaison, une politique
/// incohérente ou un numéro de build illisible ne doivent JAMAIS aboutir à un
/// blocage : c'est le sens de la quasi-totalité de ces tests.
final class VersionPolicyTests: XCTestCase {

    private func policy(
        min: Int = 1,
        recommended: Int = 1,
        block: String? = "Mets à jour",
        warn: String? = "Une nouvelle version est disponible",
        store: URL? = URL(string: "https://apps.apple.com/app/id000")
    ) -> AppVersionPolicy {
        AppVersionPolicy(
            minVersionCode: min, recommendedVersionCode: recommended,
            warnMessage: warn, blockMessage: block, storeURL: store
        )
    }

    // MARK: - Verdicts nominaux

    func testBuildBelowMinimumIsBlocked() {
        let state = VersionPolicyService.evaluate(policy: policy(min: 10, recommended: 12), currentBuild: 9)
        XCTAssertTrue(state.blocksApp)
        guard case .updateRequired(let message, let url) = state else { return XCTFail("Attendu updateRequired") }
        XCTAssertEqual(message, "Mets à jour")
        XCTAssertNotNil(url)
    }

    func testBuildBetweenMinimumAndRecommendedOnlyWarns() {
        let state = VersionPolicyService.evaluate(policy: policy(min: 10, recommended: 12), currentBuild: 11)
        XCTAssertFalse(state.blocksApp, "Une recommandation ne doit jamais bloquer")
        guard case .updateRecommended(let message, _) = state else { return XCTFail("Attendu updateRecommended") }
        XCTAssertEqual(message, "Une nouvelle version est disponible")
    }

    func testBuildAtOrAboveRecommendedIsUpToDate() {
        XCTAssertEqual(VersionPolicyService.evaluate(policy: policy(min: 10, recommended: 12), currentBuild: 12), .upToDate)
        XCTAssertEqual(VersionPolicyService.evaluate(policy: policy(min: 10, recommended: 12), currentBuild: 99), .upToDate)
    }

    /// Frontière exacte : un build ÉGAL au minimum n'est pas obsolète.
    func testBuildEqualToMinimumIsNotBlocked() {
        let state = VersionPolicyService.evaluate(policy: policy(min: 10, recommended: 10), currentBuild: 10)
        XCTAssertFalse(state.blocksApp)
        XCTAssertEqual(state, .upToDate)
    }

    // MARK: - Garde-fous : aucune politique douteuse ne doit bloquer

    func testIncoherentPolicyIsIgnored() {
        // Minimum au-dessus du recommandé : configuration manifestement erronée.
        XCTAssertEqual(
            VersionPolicyService.evaluate(policy: policy(min: 50, recommended: 10), currentBuild: 1),
            .unknown,
            "Une politique incohérente ne doit pas bloquer l'app"
        )
    }

    func testNonPositiveVersionCodesAreIgnored() {
        XCTAssertEqual(VersionPolicyService.evaluate(policy: policy(min: 0, recommended: 0), currentBuild: 1), .unknown)
        XCTAssertEqual(VersionPolicyService.evaluate(policy: policy(min: -5, recommended: 10), currentBuild: 1), .unknown)
    }

    /// La politique par défaut du backend (min = recommandé = 1) ne doit bloquer
    /// personne : c'est ce qui est servi tant qu'aucune ligne n'existe en base.
    func testBackendFallbackPolicyBlocksNobody() {
        for build in [1, 2, 42] {
            XCTAssertEqual(
                VersionPolicyService.evaluate(policy: policy(min: 1, recommended: 1), currentBuild: build),
                .upToDate
            )
        }
    }

    // MARK: - Lecture du numéro de build

    func testBuildNumberParsing() {
        XCTAssertEqual(VersionPolicyService.parseBuildNumber("12"), 12)
        // Schéma parfois utilisé en TestFlight : on garde la composante majeure.
        XCTAssertEqual(VersionPolicyService.parseBuildNumber("12.3"), 12)
        XCTAssertEqual(VersionPolicyService.parseBuildNumber("  7 "), 7)
    }

    /// Un build illisible doit rendre tout blocage IMPOSSIBLE : un défaut de
    /// configuration ne doit pas mettre l'app hors service.
    func testUnparsableBuildNumberYieldsNil() {
        XCTAssertNil(VersionPolicyService.parseBuildNumber(nil))
        XCTAssertNil(VersionPolicyService.parseBuildNumber(""))
        XCTAssertNil(VersionPolicyService.parseBuildNumber("   "))
        XCTAssertNil(VersionPolicyService.parseBuildNumber("beta"))
        XCTAssertNil(VersionPolicyService.parseBuildNumber("v1"))
    }

    // MARK: - Décodage du contrat backend

    func testDecodesBackendPayload() throws {
        let json = """
        {
          "platform": "ios",
          "minVersionCode": 8,
          "recommendedVersionCode": 12,
          "warnMessage": "Nouvelle version dispo",
          "blockMessage": "Version trop ancienne",
          "storeUrl": "https://apps.apple.com/app/id123",
          "updatedAt": "2026-07-01T10:00:00.000Z"
        }
        """
        let decoded = try JSONDecoder.signalQuest.decode(AppVersionPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.minVersionCode, 8)
        XCTAssertEqual(decoded.recommendedVersionCode, 12)
        XCTAssertEqual(decoded.blockMessage, "Version trop ancienne")
        XCTAssertEqual(decoded.storeURL?.absoluteString, "https://apps.apple.com/app/id123")
    }

    /// Le repli iOS du backend renvoie `storeUrl: null` et des messages nuls :
    /// le décodage doit l'absorber sans lever.
    func testDecodesNullableFields() throws {
        let json = """
        { "platform": "ios", "minVersionCode": 1, "recommendedVersionCode": 1,
          "warnMessage": null, "blockMessage": null, "storeUrl": null, "updatedAt": null }
        """
        let decoded = try JSONDecoder.signalQuest.decode(AppVersionPolicy.self, from: Data(json.utf8))
        XCTAssertNil(decoded.storeURL)
        XCTAssertNil(decoded.blockMessage)
        XCTAssertEqual(VersionPolicyService.evaluate(policy: decoded, currentBuild: 1), .upToDate)
    }

    /// Une réponse tronquée ne doit pas faire échouer le décodage — l'app
    /// resterait alors sur `.unknown`, ce qui est le comportement voulu.
    func testDecodesPayloadWithMissingKeys() throws {
        let decoded = try JSONDecoder.signalQuest.decode(AppVersionPolicy.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.minVersionCode, 1)
        XCTAssertEqual(decoded.recommendedVersionCode, 1)
        XCTAssertEqual(VersionPolicyService.evaluate(policy: decoded, currentBuild: 1), .upToDate)
    }

    func testOnlyUpdateRequiredBlocksTheApp() {
        XCTAssertFalse(VersionPolicyState.unknown.blocksApp)
        XCTAssertFalse(VersionPolicyState.upToDate.blocksApp)
        XCTAssertFalse(VersionPolicyState.updateRecommended(message: nil, storeURL: nil).blocksApp)
        XCTAssertTrue(VersionPolicyState.updateRequired(message: nil, storeURL: nil).blocksApp)
    }
}
