import Foundation

enum MobileChallengeAction: String, Codable, Sendable {
    case signup
    case passwordReset = "password-reset"
}

enum MobileChallengeError: Error, LocalizedError, Equatable, Sendable {
    case invalidOrigin, unavailable, invalidResponse, expired, cancelled, alreadyUsed

    var errorDescription: String? {
        switch self {
        case .invalidOrigin, .unavailable, .invalidResponse:
            return String(localized: "La vérification n’a pas pu aboutir. Réessaie sans modifier ta saisie.")
        case .expired, .alreadyUsed:
            return String(localized: "La vérification a expiré. Recommence-la pour continuer.")
        case .cancelled:
            return String(localized: "Vérification annulée. Ta saisie est conservée.")
        }
    }
}

struct MobileChallengeAttempt: Identifiable, Equatable, Sendable {
    static let path = "/api/auth/mobile-challenge"
    static let handlerName = "signalquestMobileChallenge"
    let id: UUID
    let action: MobileChallengeAction
    let url: URL

    init(origin: URL, action: MobileChallengeAction, language: String, theme: String,
         id: UUID = UUID()) throws {
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", ["light", "dark", "auto"].contains(theme) else {
            throw MobileChallengeError.invalidOrigin
        }
        parts.path = Self.path
        parts.queryItems = [
            URLQueryItem(name: "action", value: action.rawValue),
            URLQueryItem(name: "attempt", value: id.uuidString.lowercased()),
            URLQueryItem(name: "lang", value: language == "fr" ? "fr" : "en"),
            URLQueryItem(name: "theme", value: theme),
        ]
        guard let url = parts.url else { throw MobileChallengeError.invalidOrigin }
        self.id = id
        self.action = action
        self.url = url
    }

    func isMainDocument(_ candidate: URL?) -> Bool { candidate == url }

    func allowsSubframe(_ candidate: URL?) -> Bool {
        guard let candidate else { return false }
        if ["about:blank", "about:srcdoc"].contains(candidate.absoluteString) { return true }
        guard candidate.scheme?.lowercased() == "https", candidate.user == nil, candidate.password == nil else { return false }
        return Self.sameOrigin(candidate, url)
            || (candidate.host?.lowercased() == "challenges.cloudflare.com" && (candidate.port ?? 443) == 443)
    }

    func acceptsOrigin(scheme: String, host: String, port: Int) -> Bool {
        scheme.lowercased() == "https" && host.lowercased() == url.host?.lowercased()
            && (port == 0 ? 443 : port) == (url.port ?? 443)
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased() && (a.port ?? 443) == (b.port ?? 443)
    }
}

/// Résultat du navigateur, pas une preuve humaine : Siteverify reste l'autorité.
/// Une référence partagée rend la consommation unique même entre deux tâches.
final class MobileChallengeProof: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let action: MobileChallengeAction
    private let issuedAt: Date
    private let lock = NSLock()
    private var token: String?
    private var consumed = false

    init(action: MobileChallengeAction, token: String?, issuedAt: Date = Date()) {
        self.action = action
        self.token = token
        self.issuedAt = issuedAt
    }

    func consume(for expected: MobileChallengeAction, now: Date = Date()) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !consumed else { throw MobileChallengeError.alreadyUsed }
        consumed = true
        let value = token
        token = nil
        guard expected == action else { throw MobileChallengeError.invalidResponse }
        guard now >= issuedAt, now.timeIntervalSince(issuedAt) < 300 else { throw MobileChallengeError.expired }
        return value
    }

    var description: String { "MobileChallengeProof(redacted)" }
    var debugDescription: String { description }
}

/// Protocole fermé partagé avec la page backend. Le délégué WK vérifie aussi
/// la frame, le document et son statut HTTP avant de décoder ces données.
struct MobileChallengeMessage: Decodable, Equatable {
    enum Event: String, Decodable { case ready, token, disabled, error, expired, timeout, cancelled }
    let version: Int
    let action: MobileChallengeAction
    let attempt: UUID
    let event: Event
    let token: String?
    let reason: String?

    static func decode(_ body: Any, for expected: MobileChallengeAttempt) -> Self? {
        guard let fields = body as? [String: Any],
              Set(fields.keys).isSubset(of: ["version", "action", "attempt", "event", "token", "reason"]),
              JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields), data.count <= 16_384,
              let message = try? JSONDecoder().decode(Self.self, from: data),
              message.version == 1, message.action == expected.action, message.attempt == expected.id else { return nil }
        if message.event == .token {
            guard let token = message.token, !token.isEmpty, token.utf16.count <= 2048,
                  token.trimmingCharacters(in: .whitespacesAndNewlines) == token, message.reason == nil else { return nil }
        } else if message.token != nil { return nil }
        if let reason = message.reason, reason.utf16.count > 64 { return nil }
        return message
    }
}
