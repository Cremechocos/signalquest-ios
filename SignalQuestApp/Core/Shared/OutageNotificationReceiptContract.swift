import Foundation

struct OutageNotificationReceiptPayload: Codable, Equatable, Sendable {
    let state: String
    let receiptToken: String

    static func parse(_ info: [AnyHashable: Any], state: String) -> (id: String, payload: Self)? {
        guard (info["type"] as? String)?.lowercased() == "community_outage",
              state == "received" || state == "opened",
              let rawID = info["outageNotificationId"] as? String,
              !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let token = info["outageNotificationReceiptToken"] as? String,
              token.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return (rawID, .init(state: state, receiptToken: token))
    }
}
