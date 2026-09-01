import Foundation

enum OutageNotificationReceiptSender {
    struct Receipt: Sendable {
        let id: String
        let token: String
        let apiBaseURL: URL
    }

    private struct Body: Encodable {
        let state: String
        let receiptToken: String
    }

    static func parse(_ info: [AnyHashable: Any]) -> Receipt? {
        guard (info["type"] as? String)?.lowercased() == "community_outage",
              let id = info["outageNotificationId"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let token = info["outageNotificationReceiptToken"] as? String,
              token.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              let rawBase = Bundle.main.object(forInfoDictionaryKey: "SQ_API_BASE_URL") as? String,
              !rawBase.contains("$("),
              let base = URL(string: rawBase) else { return nil }
        return Receipt(id: id, token: token, apiBaseURL: base)
    }

    static func send(_ receipt: Receipt) async -> Bool {
        let url = receipt.apiBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("community-outages")
            .appendingPathComponent("notifications")
            .appendingPathComponent(receipt.id)
            .appendingPathComponent("receipt")
        var request = URLRequest(url: url, timeoutInterval: 1.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(
            Body(state: "received", receiptToken: receipt.token)
        )
        guard request.httpBody != nil else { return false }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.0
        configuration.timeoutIntervalForResource = 1.0
        do {
            let (_, response) = try await URLSession(configuration: configuration).data(for: request)
            return (response as? HTTPURLResponse).map { 200..<300 ~= $0.statusCode } ?? false
        } catch {
            return false
        }
    }
}
