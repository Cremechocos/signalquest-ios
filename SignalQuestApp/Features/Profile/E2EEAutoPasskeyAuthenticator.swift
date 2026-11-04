import AuthenticationServices
import CryptoKit
import UIKit

/// Feuille système des passkeys pour E2EE-AUTO §5.5 : la passkey est créée sur un
/// défi local et ne sert qu'à l'extension WebAuthn `prf` (jamais `hmac-secret`).
/// Le serveur ne voit ni la clé publique ni la sortie PRF.
@MainActor
final class E2EEAutoPasskeyAuthenticator: NSObject {
    /// Valable pour l'apex et `www` ; déclaré dans l'apple-app-site-association (`webcredentials`).
    nonisolated static let relyingPartyId = "signalquest.fr"

    enum Failure: Error, Equatable {
        case cancelled
        /// Le gestionnaire de passkeys ne prend pas en charge `prf` : rien n'est proposé.
        case prfUnsupported
        case failed
    }

    struct Output: Equatable {
        /// Identifiant brut, en `b64url` sans bourrage (`{credentialId}`).
        let credentialId: String
        let prfOutput: Data
    }

    /// iOS 18 au moins (§5.5).
    nonisolated static var isAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

    /// Crée une passkey et lit sa sortie PRF pour `salt` : à la création si le
    /// gestionnaire l'évalue déjà, sinon par une assertion aussitôt après.
    func create(userName: String, userHandle: Data, salt: Data) async throws -> Output {
        guard #available(iOS 18.0, *) else { throw Failure.prfUnsupported }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingPartyId)
        let request = provider.createCredentialRegistrationRequest(challenge: Self.challenge(), name: userName, userID: userHandle)
        request.prf = .inputValues(.init(saltInput1: salt))
        let authorization = try await perform(request)
        guard let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw Failure.failed
        }
        guard let prf = registration.prf, prf.isSupported else { throw Failure.prfUnsupported }
        let credentialId = registration.credentialID.base64URLEncodedNoPadding()
        if let first = prf.first { return Output(credentialId: credentialId, prfOutput: Self.bytes(first)) }
        return try await assert([(registration.credentialID, salt)])
    }

    /// Assertion PRF sur les passkeys listées, chacune avec son propre `prfSalt`.
    func assert(_ credentials: [(credentialId: Data, salt: Data)]) async throws -> Output {
        guard #available(iOS 18.0, *) else { throw Failure.prfUnsupported }
        guard !credentials.isEmpty else { throw Failure.failed }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingPartyId)
        let request = provider.createCredentialAssertionRequest(challenge: Self.challenge())
        request.allowedCredentials = credentials.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.credentialId) }
        var inputs: [Data: ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues] = [:]
        for credential in credentials { inputs[credential.credentialId] = .init(saltInput1: credential.salt) }
        request.prf = .perCredentialInputValues(inputs)
        let authorization = try await perform(request)
        guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { throw Failure.failed }
        guard let prf = assertion.prf else { throw Failure.prfUnsupported }
        return Output(credentialId: assertion.credentialID.base64URLEncodedNoPadding(), prfOutput: Self.bytes(prf.first))
    }

    /// Identifiant WebAuthn de l'utilisateur, stable par compte et sans donnée personnelle.
    nonisolated static func userHandle(userId: String) -> Data {
        Data(SHA256.hash(data: Data("SQ-E2EE-AUTO-PASSKEY-USER\n1\n\(userId)".utf8)))
    }

    /// `{credentialId}` du serveur vers les octets bruts de la feuille système.
    nonisolated static func rawCredentialId(_ value: String) -> Data? {
        guard E2EEAutoHistory.isPasskeyCredentialId(value) else { return nil }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        guard continuation == nil else { throw Failure.failed }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private static func challenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private static func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(with: result)
    }
}

extension E2EEAutoPasskeyAuthenticator: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated { finish(.success(authorization)) }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        MainActor.assumeIsolated { finish(.failure(cancelled ? Failure.cancelled : Failure.failed)) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
