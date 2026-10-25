import XCTest
@testable import SignalQuest

/// Lecteur du journal auto contre l'API locale (phase 2a du serveur), chargée
/// par `scripts/e2ee-auto/dev-seed-log.ts` avec la chaîne de référence des
/// vecteurs. Ne tourne qu'à la demande, et seulement contre la boucle locale :
/// `TEST_RUNNER_SQ_E2EE_AUTO_LOCAL_API=http://127.0.0.1:<port>` et
/// `TEST_RUNNER_SQ_E2EE_AUTO_LOCAL_COOKIE_FILE=<fichier du cookie de test>`.
final class E2EEAutoLogLocalIntegrationTests: XCTestCase {
    private struct Local {
        let base: URL
        let cookie: String
    }

    private func local() throws -> Local {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["SQ_E2EE_AUTO_LOCAL_API"], let base = URL(string: raw) else {
            throw XCTSkip("API locale non fournie (SQ_E2EE_AUTO_LOCAL_API)")
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(base.host ?? "") else {
            throw XCTSkip("adresse hors boucle locale refusée")
        }
        let path = try XCTUnwrap(environment["SQ_E2EE_AUTO_LOCAL_COOKIE_FILE"], "fichier du cookie de test")
        let cookie = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return Local(base: base, cookie: cookie)
    }

    private static func get(_ local: Local, path: String, query: [URLQueryItem]) async throws -> (Data, HTTPURLResponse) {
        var components = try XCTUnwrap(URLComponents(url: local.base.appendingPathComponent(path), resolvingAgainstBaseURL: false))
        components.queryItems = query
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.setValue("auth_token=\(local.cookie)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private struct Status: Error { let code: Int }

    private func makeReader(_ local: Local, store: E2EEAutoLogStore) throws -> E2EEAutoLogReader {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/log-head-v2.json")
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return E2EEAutoLogReader(
            ownerScopeId: "user:local-qa", pinnedLogKeyB64: try XCTUnwrap(vectors["pinnedLogKeyB64"] as? String),
            nextLogKeysB64: try XCTUnwrap(vectors["pinnedNextLogKeysB64"] as? [String]), store: store,
            fetchLinks: { after in
                let (data, response) = try await Self.get(local, path: "/api/e2ee/auto/log/links", query: [.init(name: "after", value: String(after))])
                guard response.statusCode == 200 else { throw Status(code: response.statusCode) }
                return (data, E2EEV2APITransport.httpDate(response.value(forHTTPHeaderField: "Date")))
            },
            fetchAccount: { userId, after, upTo in
                let (data, response) = try await Self.get(
                    local, path: "/api/e2ee/auto/log/accounts/\(userId)",
                    query: [.init(name: "after", value: String(after)), .init(name: "upTo", value: String(upTo))]
                )
                if response.statusCode == 404 { return nil }
                guard response.statusCode == 200 else { throw Status(code: response.statusCode) }
                return data
            }
        )
    }

    func testReadsSeededLocalLog() async throws {
        let local = try local()
        let store = E2EEAutoLogStore(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("e2ee-auto-local-\(UUID().uuidString)"),
            keyStore: InMemoryTokenStore(), anchorStore: InMemoryTokenStore()
        )
        let reader = try makeReader(local, store: store)
        let status = try await reader.refreshLinks()
        guard case .current(let head) = status else { return XCTFail("tête fraîche attendue : \(status)") }
        XCTAssertEqual(head.seq, 16)
        let offset = await reader.clockOffsetMs
        XCTAssertNotNil(offset, "en-tête Date")

        let alice = try await reader.account("user_alice_00000000001")
        XCTAssertEqual(try XCTUnwrap(alice).get().lastSeq, 16)
        let bob = try await reader.account("user_bob_0000000000002")
        XCTAssertEqual(try XCTUnwrap(bob).get().lastSeq, 15)
        let unknown = try await reader.account("user_nobody_0000000009")
        XCTAssertNil(unknown, "404 identique pour un compte non servi")

        // Relecture incrémentale depuis la tête gardée.
        let again = try await makeReader(local, store: store).refreshLinks()
        XCTAssertEqual(again, status)
        XCTAssertNil(try store.anchor(ownerScopeId: "user:local-qa")?.alert)
    }
}
