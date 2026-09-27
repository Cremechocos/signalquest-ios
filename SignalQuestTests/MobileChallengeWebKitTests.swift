import XCTest
import SwiftUI
import WebKit
@testable import SignalQuest

/// Intégration WKWebView réelle. Serveurs HTTPS locaux et certificat de recette
/// requis sur le simulateur dédié ; aucune substitution de delegate ou de TLS.
@MainActor
final class MobileChallengeWebKitTests: XCTestCase {
    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard (env["SQ_WK_CHALLENGE_QA"] ?? env["TEST_RUNNER_SQ_WK_CHALLENGE_QA"]) == "1" else {
            throw XCTSkip("Recette WebKit HTTPS locale non demandée")
        }
    }

    func testRealBackendDisabledPageReturnsNoToken() async throws {
        let fixture = try Fixture(mode: 1)
        defer { fixture.close() }
        let proof = try await fixture.result().get()
        XCTAssertNil(try proof.consume(for: .signup))
        XCTAssertEqual(fixture.box.completions, 1)
    }

    func testHTTPFailureCannotBecomeDisabledConfiguration() async throws {
        let fixture = try Fixture(mode: 2)
        defer { fixture.close() }
        guard case .failure(.unavailable) = try await fixture.result() else { return XCTFail("A 503 must fail the check") }
    }

    func testSubframeCannotSupplyTheMainDocumentProof() async throws {
        let fixture = try Fixture(mode: 3)
        defer { fixture.close() }
        let proof = try await fixture.result().get()
        XCTAssertEqual(try proof.consume(for: .signup), "synthetic-main-token")
        XCTAssertEqual(fixture.box.completions, 1)
    }

    func testOldAttemptAndWrongActionMessagesCannotCompleteTheCheck() async throws {
        let fixture = try Fixture(mode: 4)
        defer { fixture.close() }
        let proof = try await fixture.result().get()
        XCTAssertEqual(try proof.consume(for: .signup), "synthetic-main-token")
    }

    func testMainDocumentRedirectIsRejected() async throws {
        let fixture = try Fixture(mode: 5)
        defer { fixture.close() }
        guard case .failure = try await fixture.result() else { return XCTFail("Unexpected main document must not provide a proof") }
    }

    func testMissingServerConfigurationHeaderIsNotAnExemption() async throws {
        let fixture = try Fixture(mode: 6)
        defer { fixture.close() }
        guard case .failure(.unavailable) = try await fixture.result() else { return XCTFail("Missing header must not bypass verification") }
    }

    func testRealCloudflareDummyWidgetAndSiteverifyCompleteOverHTTPS() async throws {
        let fixture = try Fixture(mode: 7, port: 4326)
        defer { fixture.close() }
        let proof = try await fixture.result(timeout: 60).get()
        print("SQ_WK provider proof received")
        let token = try XCTUnwrap(proof.consume(for: .signup))
        // This is Cloudflare's documented public dummy token, never a real key.
        XCTAssertTrue(token == "XXXX.DUMMY.TOKEN.XXXX", "Expected the public dummy token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let api = APIClient(config: AppConfig(appBaseURL: URL(string: "https://127.0.0.1:4326")!,
            apiBaseURL: URL(string: "https://127.0.0.1:4326")!, debugLogsEnabled: false),
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: URLSession(configuration: configuration))
        let response: SuccessResponse = try await api.requestJSONSingleAttempt("/qa/siteverify", body: ["token": token], authenticated: false)
        XCTAssertTrue(response.isAcknowledged, "The real shared server validator must accept the dummy widget token")
        print("SQ_WK Siteverify acknowledged=\(response.isAcknowledged)")
        if let web = fixture.webView {
            let screenshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? MobileChallengeError.unavailable) }
                }
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "turnstile-real-webkit-dummy-key"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private final class Box {
        var value: Result<MobileChallengeProof, MobileChallengeError>?
        var completions = 0
        func receive(_ result: Result<MobileChallengeProof, MobileChallengeError>) { completions += 1; value = result }
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let box = Box()
        private weak var previousKeyWindow: UIWindow?
        private var probe: NavigationProbe?

        init(mode: Int, port: Int = 4325) throws {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                throw XCTSkip("Une scène UIKit active est requise pour WebKit")
            }
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            let attempt = try MobileChallengeAttempt(origin: URL(string: "https://127.0.0.1:\(port)")!,
                action: .signup, language: "en", theme: "light",
                id: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(mode)")!)
            let box = self.box
            window.rootViewController = UIHostingController(rootView: MobileChallengeWebView(attempt: attempt, onCompletion: box.receive))
            window.makeKeyAndVisible()
        }

        var webView: WKWebView? {
            func find(_ view: UIView) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                for child in view.subviews { if let web = find(child) { return web } }
                return nil
            }
            return window.rootViewController.flatMap { find($0.view) }
        }

        func result(timeout: Int = 10) async throws -> Result<MobileChallengeProof, MobileChallengeError> {
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            while box.value == nil, ContinuousClock.now < deadline {
                if probe == nil, let web = webView,
                   let original = web.navigationDelegate as? MobileChallengeWebView.Coordinator {
                    let probe = NavigationProbe(original: original)
                    self.probe = probe
                    web.navigationDelegate = probe
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if box.value == nil {
                print("SQ_WK no completion: web=\(webView != nil) loading=\(webView?.isLoading ?? false) progress=\(webView?.estimatedProgress ?? -1) path=\(webView?.url?.path ?? "none") bounds=\(webView?.bounds.size ?? .zero)")
                print("SQ_WK navigation \(probe?.events ?? [])")
            }
            return try XCTUnwrap(box.value, "The real WebView must complete within the test deadline")
        }

        func close() {
            if let probe { probe.original.invalidate() }
            else { (webView?.navigationDelegate as? MobileChallengeWebView.Coordinator)?.invalidate() }
            window.isHidden = true
            window.rootViewController = nil
            if let previousKeyWindow, !previousKeyWindow.isHidden { previousKeyWindow.makeKey() }
        }
    }

    @MainActor
    private final class NavigationProbe: NSObject, WKNavigationDelegate {
        let original: MobileChallengeWebView.Coordinator
        var events: [String] = []
        init(original: MobileChallengeWebView.Coordinator) { self.original = original }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            events.append("action main=\(String(describing: navigationAction.targetFrame?.isMainFrame)) path=\(navigationAction.request.url?.path ?? "none")")
            original.webView(webView, decidePolicyFor: navigationAction) { policy in
                self.events.append("action policy=\(policy.rawValue)")
                decisionHandler(policy)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            let response = navigationResponse.response as? HTTPURLResponse
            events.append("response main=\(navigationResponse.isForMainFrame) status=\(response?.statusCode ?? -1) state=\(response?.value(forHTTPHeaderField: "X-SQ-Challenge-State") ?? "none")")
            original.webView(webView, decidePolicyFor: navigationResponse) { policy in
                self.events.append("response policy=\(policy.rawValue)")
                decisionHandler(policy)
            }
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { events.append("commit") }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { events.append("finish") }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            events.append("failure \((error as NSError).domain) \((error as NSError).code)")
            original.webView(webView, didFail: navigation, withError: error)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            events.append("provisional failure \((error as NSError).domain) \((error as NSError).code)")
            original.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            events.append("terminated")
            original.webViewWebContentProcessDidTerminate(webView)
        }
    }
}
