import Foundation

struct PasswordResetRequest: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id = UUID()
    let token: String
    var description: String { "PasswordResetRequest(redacted)" }
    var debugDescription: String { description }
}

enum PasswordResetLink {
    case unrelated, invalid, request(PasswordResetRequest)

    static func parse(_ url: URL, origin: URL) -> Self {
        guard let source = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let incoming = URLComponents(url: url, resolvingAgainstBaseURL: false),
              source.scheme?.lowercased() == "https", incoming.scheme?.lowercased() == "https",
              let host = source.host, !host.isEmpty, incoming.host?.lowercased() == host.lowercased(),
              (source.port ?? 443) == (incoming.port ?? 443),
              source.user == nil, source.password == nil, incoming.user == nil, incoming.password == nil,
              incoming.path == "/reset-password" else { return .unrelated }
        guard incoming.fragment == nil, let items = incoming.queryItems,
              items.count == 1, items[0].name == "token", let token = items[0].value,
              !token.isEmpty, token.utf16.count <= 2048,
              token.trimmingCharacters(in: .whitespacesAndNewlines) == token,
              token.rangeOfCharacter(from: .controlCharacters) == nil else { return .invalid }
        return .request(PasswordResetRequest(token: token))
    }
}
