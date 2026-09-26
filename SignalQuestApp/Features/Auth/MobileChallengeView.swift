import SwiftUI
@preconcurrency import WebKit

private struct MobileChallengePresentation: ViewModifier {
    @ObservedObject var presenter: MobileChallengePresenter
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { presenter.attempt }, set: { if $0 == nil { presenter.cancel() } }),
                      onDismiss: presenter.didDismiss) { attempt in
            MobileChallengeSheet(attempt: attempt) { presenter.complete(id: attempt.id, result: $0) }
        }
    }
}

extension View {
    func mobileChallenge(using presenter: MobileChallengePresenter) -> some View {
        modifier(MobileChallengePresentation(presenter: presenter))
    }
}

struct MobileChallengeSheet: View {
    let attempt: MobileChallengeAttempt
    let onCompletion: (Result<MobileChallengeProof, MobileChallengeError>) -> Void

    var body: some View {
        NavigationStack {
            MobileChallengeWebView(attempt: attempt, onCompletion: onCompletion)
                .navigationTitle("Vérification")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annuler") { onCompletion(.failure(.cancelled)) }
                            .accessibilityIdentifier("auth.challenge.cancel")
                    }
                }
        }
        .interactiveDismissDisabled()
    }
}

struct MobileChallengeWebView: UIViewRepresentable {
    let attempt: MobileChallengeAttempt
    let onCompletion: (Result<MobileChallengeProof, MobileChallengeError>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(attempt: attempt, onCompletion: onCompletion) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Persistance requise par Turnstile, stable entre ses tentatives. Les
        // credentials API/Keychain ne sont jamais copiés vers WebKit.
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: MobileChallengeAttempt.handlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.accessibilityIdentifier = "auth.challenge.web"
        context.coordinator.start(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { coordinator.invalidate() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private enum Configuration: String { case enabled, disabled }
        private let attempt: MobileChallengeAttempt
        private let onCompletion: (Result<MobileChallengeProof, MobileChallengeError>) -> Void
        private weak var webView: WKWebView?
        private var configuration: Configuration?
        private var finished = false
        private var timeout: Task<Void, Never>?

        init(attempt: MobileChallengeAttempt,
             onCompletion: @escaping (Result<MobileChallengeProof, MobileChallengeError>) -> Void) {
            self.attempt = attempt
            self.onCompletion = onCompletion
        }

        func start(_ webView: WKWebView) {
            self.webView = webView
            armTimeout(seconds: 40)
            // URL publique sans identité, mot de passe, token ni User-Agent API.
            webView.load(URLRequest(url: attempt.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }

        func invalidate() {
            finish(.failure(.cancelled))
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: MobileChallengeAttempt.handlerName)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard !finished, let frame = navigationAction.targetFrame else {
                decisionHandler(.cancel)
                return
            }
            let allowed = frame.isMainFrame
                ? attempt.isMainDocument(navigationAction.request.url)
                : attempt.allowsSubframe(navigationAction.request.url)
            if !allowed && frame.isMainFrame { finish(.failure(.invalidResponse)) }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            guard !finished else { decisionHandler(.cancel); return }
            guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
            guard let http = navigationResponse.response as? HTTPURLResponse,
                  http.statusCode == 200, attempt.isMainDocument(http.url),
                  http.mimeType?.lowercased() == "text/html",
                  let raw = http.value(forHTTPHeaderField: "X-SQ-Challenge-State"),
                  let value = Configuration(rawValue: raw) else {
                finish(.failure(.unavailable))
                decisionHandler(.cancel)
                return
            }
            configuration = value
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, message.name == MobileChallengeAttempt.handlerName,
                  message.frameInfo.isMainFrame, attempt.isMainDocument(message.frameInfo.request.url),
                  attempt.acceptsOrigin(scheme: message.frameInfo.securityOrigin.protocol,
                                        host: message.frameInfo.securityOrigin.host, port: message.frameInfo.securityOrigin.port),
                  let configuration, let payload = MobileChallengeMessage.decode(message.body, for: attempt) else { return }
            switch payload.event {
            case .ready:
                armTimeout(seconds: 240)
            case .token:
                guard configuration == .enabled, let token = payload.token else {
                    finish(.failure(.invalidResponse)); return
                }
                finish(.success(MobileChallengeProof(action: attempt.action, token: token)))
            case .disabled:
                guard configuration == .disabled else { finish(.failure(.invalidResponse)); return }
                finish(.success(MobileChallengeProof(action: attempt.action, token: nil)))
            case .expired:
                finish(.failure(.expired))
            case .cancelled:
                finish(.failure(.cancelled))
            case .error, .timeout:
                finish(.failure(.unavailable))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(.unavailable))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(.failure(.unavailable))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(.unavailable)) }

        private func armTimeout(seconds: UInt64) {
            timeout?.cancel()
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                self?.finish(.failure(.unavailable))
            }
        }

        private func finish(_ result: Result<MobileChallengeProof, MobileChallengeError>) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            timeout = nil
            onCompletion(result)
        }
    }
}

@MainActor
final class MobileChallengePresenter: ObservableObject {
    @Published private(set) var attempt: MobileChallengeAttempt?
    @Published private(set) var isDismissing = false
    private var continuation: CheckedContinuation<MobileChallengeProof, Error>?

    var isBusy: Bool { attempt != nil || isDismissing }

    func request(origin: URL, action: MobileChallengeAction, language: String, theme: String) async throws -> MobileChallengeProof {
        try Task.checkCancellation()
        guard !isBusy else { throw MobileChallengeError.unavailable }
        let request = try MobileChallengeAttempt(origin: origin, action: action, language: language, theme: theme)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.attempt = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id: request.id, result: .failure(.cancelled)) }
        }
    }

    func complete(id: UUID, result: Result<MobileChallengeProof, MobileChallengeError>) {
        guard attempt?.id == id, let continuation else { return }
        self.continuation = nil
        isDismissing = true
        attempt = nil
        switch result {
        case .success(let proof): continuation.resume(returning: proof)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    func cancel() {
        if let id = attempt?.id { complete(id: id, result: .failure(.cancelled)) }
    }

    func didDismiss() { isDismissing = false }
}
