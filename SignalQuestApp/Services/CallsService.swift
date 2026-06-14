import Foundation

struct CallSession: Decodable, Identifiable, Equatable {
    let id: String
    let mode: String?            // "audio" | "video"
    let conversationId: String?
    let createdAt: Date?
    let endedAt: Date?
    let participants: [String]?
    let liveKitToken: String?
    let liveKitUrl: URL?
    let liveKitRoom: String?
    let status: String?          // pending | ringing | accepted | rejected | ended

    enum CodingKeys: String, CodingKey {
        case id, callId, mode, type, conversationId, createdAt, startedAt, endedAt, participants
        case liveKitToken, token, liveKitUrl, wsUrl, liveKitRoom, roomName, status
    }

    init(
        id: String,
        mode: String?,
        conversationId: String?,
        createdAt: Date?,
        endedAt: Date?,
        participants: [String]?,
        liveKitToken: String?,
        liveKitUrl: URL?,
        liveKitRoom: String?,
        status: String?
    ) {
        self.id = id
        self.mode = mode
        self.conversationId = conversationId
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.participants = participants
        self.liveKitToken = liveKitToken
        self.liveKitUrl = liveKitUrl
        self.liveKitRoom = liveKitRoom
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id))
            ?? (try? c.decode(String.self, forKey: .callId))
            ?? UUID().uuidString
        let rawMode = (try? c.decodeIfPresent(String.self, forKey: .mode))
            ?? (try? c.decodeIfPresent(String.self, forKey: .type))
        mode = rawMode?.lowercased()
        conversationId = try? c.decodeIfPresent(String.self, forKey: .conversationId)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt))
            ?? (try? c.decodeIfPresent(Date.self, forKey: .startedAt))
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
        participants = (try? c.decodeIfPresent([String].self, forKey: .participants))
            ?? (try? c.decodeLossyParticipants(forKey: .participants))
        liveKitToken = (try? c.decodeIfPresent(String.self, forKey: .liveKitToken))
            ?? (try? c.decodeIfPresent(String.self, forKey: .token))
        liveKitUrl = (try? c.decodeIfPresent(URL.self, forKey: .liveKitUrl))
            ?? (try? c.decodeIfPresent(URL.self, forKey: .wsUrl))
        liveKitRoom = (try? c.decodeIfPresent(String.self, forKey: .liveKitRoom))
            ?? (try? c.decodeIfPresent(String.self, forKey: .roomName))
        status = (try? c.decodeIfPresent(String.self, forKey: .status))?.lowercased()
    }
}

struct CallInitiateRequest: Codable {
    let conversationId: String
    let type: String
}

protocol CallsServicing: Sendable {
    func initiate(conversationId: String, mode: String) async throws -> CallSession
    func answer(callId: String) async throws -> CallSession
    func reject(callId: String) async throws
    func end(callId: String) async throws
    func pending() async throws -> [CallSession]
    func history() async throws -> [CallSession]
}

final class CallsService: CallsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func initiate(conversationId: String, mode: String) async throws -> CallSession {
        let type = mode.uppercased() == "VIDEO" || mode.lowercased() == "video" ? "VIDEO" : "AUDIO"
        return try await api.requestJSON(
            "/api/calls/initiate",
            body: CallInitiateRequest(conversationId: conversationId, type: type)
        )
    }

    func answer(callId: String) async throws -> CallSession {
        try await api.requestJSON("/api/calls/answer", body: ["callId": callId])
    }

    func reject(callId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON("/api/calls/reject", body: ["callId": callId])
    }

    func end(callId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON("/api/calls/end", body: ["callId": callId])
    }

    func pending() async throws -> [CallSession] {
        struct Response: Decodable { let calls: [CallSession]?; let items: [CallSession]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/calls/pending"), as: Response.self)
        return r.calls ?? r.items ?? []
    }

    func history() async throws -> [CallSession] {
        struct Response: Decodable { let calls: [CallSession]?; let items: [CallSession]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/calls/history"), as: Response.self)
        return r.calls ?? r.items ?? []
    }
}

private extension KeyedDecodingContainer where Key == CallSession.CodingKeys {
    func decodeLossyParticipants(forKey key: Key) throws -> [String] {
        if let values = try? decodeIfPresent([[String: String]].self, forKey: key) {
            return values.compactMap { $0["name"] ?? $0["email"] ?? $0["id"] ?? $0["userId"] }
        }
        return []
    }
}
