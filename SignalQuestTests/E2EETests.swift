import CryptoKit
import XCTest
@testable import SignalQuest

final class E2EETests: XCTestCase {
    func testV2AADBindsConversationContentTypeAndDevice() throws {
        let context = EncryptedMessageEnvelopeV2AAD(
            conversationId: "conversation-42",
            contentType: .poll,
            senderDeviceId: "device-ios-1",
            operationId: "poll-create-1"
        )
        let decoded = try JSONDecoder().decode(
            EncryptedMessageEnvelopeV2AAD.self,
            from: context.encoded()
        )

        XCTAssertEqual(decoded.cryptoVersion, 2)
        XCTAssertEqual(decoded.schema, "signalquest.encrypted-message")
        XCTAssertEqual(decoded.conversationId, "conversation-42")
        XCTAssertEqual(decoded.contentType, .poll)
        XCTAssertEqual(decoded.senderDeviceId, "device-ios-1")
        XCTAssertEqual(decoded.operationId, "poll-create-1")
    }

    func testAESGCMV1RoundtripPayloadShape() throws {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data("secret".utf8), using: key, nonce: nonce)
        var combined = Data(sealed.ciphertext)
        combined.append(sealed.tag)
        let payload = E2EEPayload(
            v: 1,
            ivB64: nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ciphertextB64: combined.base64EncodedString(),
            aadB64: nil
        )

        let data = try XCTUnwrap(Data(base64Encoded: payload.ciphertextB64))
        let iv = try XCTUnwrap(Data(base64Encoded: payload.ivB64))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data.prefix(data.count - 16), tag: data.suffix(16))
        let plain = try AES.GCM.open(box, using: key)
        XCTAssertEqual(String(data: plain, encoding: .utf8), "secret")
    }

    func testInvalidRSAJWKFailsGracefully() {
        XCTAssertThrowsError(try E2EEService.unwrapConversationKey(wrappedKeyB64: "bad", privateJwk: "{}"))
    }

    func testWipeLocalKeysClearsPrivateAndConversationKeys() async throws {
        let store = InMemoryTokenStore()
        try store.set("{\"kty\":\"RSA\"}", for: "privateJwk:current")
        try store.set("{\"kty\":\"RSA\"}", for: "privateJwk:u1")
        try store.set(Data(repeating: 7, count: 32).base64EncodedString(), for: "conversation:c1")
        let api = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()))
        let service = E2EEService(api: api, tokenStore: store)

        await service.wipeLocalKeys()

        XCTAssertNil(try store.string(for: "privateJwk:current"))
        XCTAssertNil(try store.string(for: "privateJwk:u1"))
        XCTAssertNil(try store.string(for: "conversation:c1"))
        let unlocked = await service.isUnlocked()
        XCTAssertFalse(unlocked)
    }

    /// Génère une clé via le flux complet (POST bootstrap mocké), puis vérifie
    /// que la clé publique JWK exportée sait wrapper une clé de conversation
    /// que la clé privée JWK stockée sait dé-wrapper — l'aller-retour exact
    /// utilisé entre participants iOS/Android/web.
    func testGeneratedKeyWrapUnwrapRoundTrip() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"ok\":true}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let store = InMemoryTokenStore()
        let api = APIClient(
            config: .test,
            cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()),
            session: URLSession(configuration: sessionConfig)
        )
        let service = E2EEService(api: api, tokenStore: store)

        try await service.generateAndRegisterKey(userId: "u1", password: "correct horse battery")

        let privateJwk = try XCTUnwrap(store.string(for: "privateJwk:current"))
        let privateObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(privateJwk.utf8)) as? [String: String])
        XCTAssertEqual(privateObj["kty"], "RSA")
        for field in ["n", "e", "d", "p", "q", "dp", "dq", "qi"] {
            XCTAssertNotNil(privateObj[field], "champ JWK manquant: \(field)")
            XCTAssertFalse(privateObj[field]!.contains("="), "padding base64url interdit: \(field)")
            XCTAssertFalse(privateObj[field]!.contains("+"), "alphabet base64url attendu: \(field)")
        }
        let publicJwk = "{\"kty\":\"RSA\",\"n\":\"\(privateObj["n"]!)\",\"e\":\"\(privateObj["e"]!)\"}"

        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let wrapped = try E2EEService.wrapConversationKey(rawKey: rawKey, publicJwk: publicJwk)
        XCTAssertFalse(wrapped.contains("="), "wrappedKeyB64 doit être sans padding")
        let unwrapped = try E2EEService.unwrapConversationKey(wrappedKeyB64: wrapped, privateJwk: privateJwk)
        XCTAssertEqual(unwrapped, rawKey)
    }

    /// La clé privée générée doit pouvoir être re-déverrouillée à partir des
    /// champs envoyés au serveur (PBKDF2 + AES-GCM), comme le ferait un autre
    /// appareil après GET /api/e2ee/bootstrap.
    func testGeneratedKeyBootstrapFieldsDecryptWithPassword() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"ok\":true}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let store = InMemoryTokenStore()
        let api = APIClient(
            config: .test,
            cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()),
            session: URLSession(configuration: sessionConfig)
        )
        let service = E2EEService(api: api, tokenStore: store)

        try await service.generateAndRegisterKey(userId: "u1", password: "s3cret-pass")

        let body = try XCTUnwrap(capturedBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let encryptedPrivateJwk = try XCTUnwrap(payload["encryptedPrivateJwk"] as? String)
        let kdfSaltB64 = try XCTUnwrap(payload["kdfSaltB64"] as? String)
        let iterations = try XCTUnwrap(payload["kdfIterations"] as? Int)
        XCTAssertEqual(iterations, 210_000)

        let decrypted = try E2EEService.decryptPrivateJWK(
            password: "s3cret-pass",
            encryptedPrivateJwkB64: encryptedPrivateJwk,
            kdfSaltB64: kdfSaltB64,
            iterations: iterations
        )
        let stored = try XCTUnwrap(store.string(for: "privateJwk:current"))
        XCTAssertEqual(decrypted, stored)
        let publicKeyJwk = try XCTUnwrap(payload["publicKeyJwk"] as? String)
        XCTAssertTrue(E2EEService.privateJwk(decrypted, matchesPublicJwk: publicKeyJwk))
    }

    /// E2EE-UX-03 — Un mot de passe erroné doit remonter `.wrongPassword`
    /// (message FR clair), PAS une CryptoKitError technique. Réutilise le même
    /// flux de génération que le test ci-dessus, puis tente un déchiffrement avec
    /// un mauvais mot de passe.
    func testWrongPasswordMapsToWrongPasswordError() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: 4096)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, Data("{\"ok\":true}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(
            config: .test,
            cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()),
            session: URLSession(configuration: sessionConfig)
        )
        let service = E2EEService(api: api, tokenStore: InMemoryTokenStore())
        try await service.generateAndRegisterKey(userId: "u1", password: "s3cret-pass")

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(capturedBody)) as? [String: Any])
        let encryptedPrivateJwk = try XCTUnwrap(payload["encryptedPrivateJwk"] as? String)
        let kdfSaltB64 = try XCTUnwrap(payload["kdfSaltB64"] as? String)
        let iterations = try XCTUnwrap(payload["kdfIterations"] as? Int)

        XCTAssertThrowsError(
            try E2EEService.decryptPrivateJWK(
                password: "mauvais-mot-de-passe",
                encryptedPrivateJwkB64: encryptedPrivateJwk,
                kdfSaltB64: kdfSaltB64,
                iterations: iterations
            )
        ) { error in
            XCTAssertEqual(error as? E2EEError, .wrongPassword)
        }
    }

    func testE2EECleartextSendBlockedWithoutKey() async {
        let conversation = MessageConversation(
            id: "c1",
            title: "Secure",
            isGroup: false,
            e2eeEnabled: true,
            groupPhotoUrl: nil,
            createdAt: nil,
            updatedAt: nil,
            lastMessageAt: nil,
            lastReadAt: nil,
            pinnedAt: nil,
            participants: [],
            lastMessage: nil
        )
        let service = MessagesService(api: APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore())))
        do {
            _ = try await service.sendText("hello", in: conversation, e2ee: nil)
            XCTFail("Expected locked E2EE error")
        } catch let error as E2EEError {
            XCTAssertEqual(error, .locked)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    /// Invariant E2EE (réception) : un message marqué chiffré mais SANS iv/ciphertext
    /// est malformé — `decryptText` doit lever `.decryptFailed` et ne JAMAIS retomber
    /// sur le `content` en clair. On fournit volontairement un `content` clair pour
    /// vérifier qu'il n'est jamais renvoyé.
    func testDecryptTextNeverFallsBackToCleartextOnMissingFields() async throws {
        let json = Data(#"{"id":"m1","conversationId":"c1","content":"hello-en-clair"}"#.utf8)
        let message = try JSONDecoder().decode(MessageItem.self, from: json)
        XCTAssertNil(message.e2eeIvB64)
        XCTAssertNil(message.e2eeCiphertextB64)

        let api = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()))
        let service = E2EEService(api: api, tokenStore: InMemoryTokenStore())
        do {
            _ = try await service.decryptText(conversationId: "c1", message: message)
            XCTFail("decryptText doit lever .decryptFailed, jamais renvoyer le clair")
        } catch let error as E2EEError {
            XCTAssertEqual(error, .decryptFailed)
        } catch {
            XCTFail("Erreur inattendue \(error)")
        }
    }
}
