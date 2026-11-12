import XCTest
@testable import SignalQuest

/// Refus « réseau non pris en charge » : vecteur
/// `contracts/errors/supported-network-required-v1.json`, copié à l'octet depuis
/// le serveur (#800, f3064e43a).
final class SupportedNetworkRequiredTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/errors/supported-network-required-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ json: String) throws -> BackendErrorResponse {
        try JSONDecoder().decode(BackendErrorResponse.self, from: Data(json.utf8))
    }

    private func message(_ body: BackendErrorResponse) -> String {
        APIError.userFacingMessage(status: 403, code: body.appCode, serverMessage: body.error ?? "")
    }

    func testVectorFeaturesAreTheOnesTheAppNames() throws {
        let v = try vector()
        XCTAssertEqual(v["code"] as? String, BackendErrorResponse.supportedNetworkRequired)
        XCTAssertEqual(v["status"] as? Int, 403)
        let values = try XCTUnwrap((v["feature"] as? [String: Any])?["values"] as? [String])
        XCTAssertEqual(Set(values), BackendErrorResponse.supportedNetworkFeatures)
        for route in try XCTUnwrap(v["routes"] as? [String: String]).values {
            XCTAssertTrue(BackendErrorResponse.supportedNetworkFeatures.contains(route), route)
        }
    }

    /// Les libellés français du vecteur sont les clés du catalogue, mot pour mot.
    func testFrenchLabelsMatchTheVector() throws {
        let labels = try XCTUnwrap(try vector()["labels"] as? [String: Any])
        let generic = try XCTUnwrap(labels["generic"] as? [String: String])
        let live = try XCTUnwrap(labels["live_share"] as? [String: String])
        XCTAssertEqual(generic["fr-tu"], "Cette fonction demande une carte SIM d'un opérateur pris en charge.")
        XCTAssertEqual(generic["fr-vous"], generic["fr-tu"])
        XCTAssertEqual(live["fr-tu"], "Le partage en direct demande une carte SIM d'un opérateur pris en charge.")
        XCTAssertEqual(live["fr-vous"], live["fr-tu"])
    }

    func testServedExampleNamesLiveSharing() throws {
        let example = try XCTUnwrap(try vector()["example"] as? [String: Any])
        let body = try decode(String(decoding: JSONSerialization.data(withJSONObject: example), as: UTF8.self))
        XCTAssertEqual(body.appCode, "SUPPORTED_NETWORK_REQUIRED.LIVE_SHARE")
        XCTAssertEqual(message(body), String(localized: "Le partage en direct demande une carte SIM d'un opérateur pris en charge."))
    }

    func testEachFeatureHasItsOwnMessage() throws {
        var seen = Set<String>()
        for feature in BackendErrorResponse.supportedNetworkFeatures {
            let text = message(try decode(#"{"code":"SUPPORTED_NETWORK_REQUIRED","feature":"\#(feature)","error":"x"}"#))
            XCTAssertNotEqual(text, "x", feature)
            seen.insert(text)
        }
        XCTAssertEqual(seen.count, BackendErrorResponse.supportedNetworkFeatures.count)
    }

    /// Une fonction inconnue ou absente donne le message générique, jamais une erreur.
    func testUnknownOrMissingFeatureFallsBackToTheGenericMessage() throws {
        let generic = String(localized: "Cette fonction demande une carte SIM d'un opérateur pris en charge.")
        for json in [#"{"code":"SUPPORTED_NETWORK_REQUIRED","feature":"drive_test","error":"x"}"#,
                     #"{"code":"SUPPORTED_NETWORK_REQUIRED","error":"x"}"#] {
            let body = try decode(json)
            XCTAssertEqual(body.appCode, "SUPPORTED_NETWORK_REQUIRED")
            XCTAssertEqual(message(body), generic)
        }
    }

    /// OPERATOR_REQUIRED (FAV-1, 400) n'a rien à voir avec la SIM.
    func testOperatorRequiredIsNotASimRefusal() throws {
        let body = try decode(#"{"code":"OPERATOR_REQUIRED","feature":"live_share","error":"Précise l'opérateur."}"#)
        XCTAssertEqual(body.appCode, "OPERATOR_REQUIRED")
        XCTAssertFalse(APIError.userFacingMessage(status: 400, code: body.appCode, serverMessage: body.error ?? "").contains("SIM"))
    }
}

/// CONV-MEMBERSHIP r1 (#1219, servi le 12/11) : la cause d'un 403 « plus membre ».
final class ConversationMembershipLossTests: XCTestCase {
    private func loss(_ status: Int, _ json: String) throws -> ConversationMembershipLoss? {
        let body = try JSONDecoder().decode(BackendErrorResponse.self, from: Data(json.utf8))
        let error = APIError.http(status: status, code: body.appCode, message: body.error ?? "", requestId: nil, retryAfter: nil)
        return ConversationMembershipLoss(error: error)
    }

    func testEachServedCauseHasItsCase() throws {
        func forbidden(_ details: String) -> String { #"{"error":"Accès refusé","code":"FORBIDDEN","details":"# + details + "}" }
        XCTAssertEqual(try loss(403, forbidden(#"{"membership":"left"}"#)), .left)
        XCTAssertEqual(try loss(403, forbidden(#"{"membership":"removed"}"#)), .removed)
        XCTAssertEqual(try loss(403, forbidden(#"{"membership":"deleted_for_self","returnsOnNewMessage":true}"#)),
                       .deletedForSelf(returnsOnNewMessage: true))
        XCTAssertEqual(try loss(403, forbidden(#"{"membership":"deleted_for_self","returnsOnNewMessage":false}"#)),
                       .deletedForSelf(returnsOnNewMessage: false))
        XCTAssertEqual(try loss(403, forbidden(#"{"membership":"request_declined"}"#)), .requestDeclined)
        XCTAssertEqual(try loss(403, forbidden(#"{"membership":"not_member"}"#)), .notMember)
        // Une cause d'une version future : texte générique, jamais d'erreur.
        XCTAssertEqual(try loss(403, forbidden(#"{"membership":"archived_by_admin"}"#)), .notMember)
        XCTAssertEqual(try loss(404, #"{"error":"Conversation introuvable","code":"NOT_FOUND"}"#), .gone)
    }

    /// Les autres 403 (blocage, demande en attente, droits d'admin) gardent leur message.
    func testOtherForbiddenStayOrdinaryErrors() throws {
        XCTAssertNil(try loss(403, #"{"error":"Accès refusé","code":"FORBIDDEN"}"#))
        XCTAssertNil(try loss(403, #"{"error":"En attente","code":"MESSAGE_REQUEST_PENDING"}"#))
        XCTAssertNil(try loss(404, #"{"error":"Introuvable","code":"E2EE_CONVERSATION_NOT_FOUND"}"#))
    }

    func testTextsFollowAndroid() {
        XCTAssertEqual(ConversationMembershipLoss.left.title, "Tu as quitté cette conversation")
        XCTAssertEqual(ConversationMembershipLoss.removed.message, "Ton accès a été retiré : tu ne peux plus lire ni envoyer de messages ici.")
        XCTAssertEqual(ConversationMembershipLoss.deletedForSelf(returnsOnNewMessage: true).message,
                       "Elle reviendra dans ta liste au prochain message.")
        // Un groupe supprimé pour soi ne revient pas : pas de promesse.
        XCTAssertNil(ConversationMembershipLoss.deletedForSelf(returnsOnNewMessage: false).message)
        XCTAssertEqual(ConversationMembershipLoss.gone.title, "Cette conversation n’existe plus")
    }
}
