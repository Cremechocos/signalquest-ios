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
    let isPending: Bool?
    let displayName: String?
    let isGroup: Bool

    enum CodingKeys: String, CodingKey {
        case id, callId, mode, type, callType, conversationId, createdAt, startedAt, endedAt, participants
        case otherParticipants, caller, callerName, conversation, conversationTitle, isGroup
        case liveKitToken, token, liveKitUrl, wsUrl, liveKitRoom, roomName, status, pending
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
        status: String?,
        isPending: Bool? = nil,
        displayName: String? = nil,
        isGroup: Bool = false
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
        self.isPending = isPending
        self.displayName = displayName
        self.isGroup = isGroup
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = (try? c.decode(String.self, forKey: .id))
            ?? (try? c.decode(String.self, forKey: .callId)),
              !decodedID.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.callId,
                .init(codingPath: decoder.codingPath, debugDescription: "A call requires id or callId")
            )
        }
        id = decodedID
        let rawMode = (try? c.decodeIfPresent(String.self, forKey: .mode))
            ?? (try? c.decodeIfPresent(String.self, forKey: .callType))
            ?? (try? c.decodeIfPresent(String.self, forKey: .type))
        mode = rawMode?.lowercased()
        conversationId = try? c.decodeIfPresent(String.self, forKey: .conversationId)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt))
            ?? (try? c.decodeIfPresent(Date.self, forKey: .startedAt))
        endedAt = try? c.decodeIfPresent(Date.self, forKey: .endedAt)
        let decodedParticipants = (try? c.decodeIfPresent([String].self, forKey: .participants))
            ?? (try? c.decodeLossyParticipants(forKey: .participants))
            ?? (try? c.decodeLossyParticipants(forKey: .otherParticipants))
        participants = decodedParticipants
        liveKitToken = (try? c.decodeIfPresent(String.self, forKey: .liveKitToken))
            ?? (try? c.decodeIfPresent(String.self, forKey: .token))
        liveKitUrl = (try? c.decodeIfPresent(URL.self, forKey: .liveKitUrl))
            ?? (try? c.decodeIfPresent(URL.self, forKey: .wsUrl))
        liveKitRoom = (try? c.decodeIfPresent(String.self, forKey: .liveKitRoom))
            ?? (try? c.decodeIfPresent(String.self, forKey: .roomName))
        status = (try? c.decodeIfPresent(String.self, forKey: .status))?.lowercased()
        isPending = try? c.decodeIfPresent(Bool.self, forKey: .pending)
        let callerName = try? c.decodeIfPresent(String.self, forKey: .callerName)
        let conversationTitle = try? c.decodeIfPresent(String.self, forKey: .conversationTitle)
        let caller = try? c.decodeIfPresent(CallDisplayEntity.self, forKey: .caller)
        let conversation = try? c.decodeIfPresent(CallConversationSummary.self, forKey: .conversation)
        displayName = conversationTitle
            ?? conversation?.title
            ?? callerName
            ?? caller?.name
            ?? decodedParticipants?.first
        isGroup = (try? c.decodeIfPresent(Bool.self, forKey: .isGroup))
            ?? conversation?.isGroup
            ?? false
    }
}

private struct CallDisplayEntity: Decodable {
    let name: String?
}

private struct CallConversationSummary: Decodable {
    let title: String?
    let isGroup: Bool?
}

/// `/api/calls/pending` currently returns one object (`pending`, `callId`, …),
/// whereas older clients expected `{ calls: [...] }`. Decode both shapes so a
/// contract migration cannot silently make incoming calls disappear.
struct PendingCallsResponse: Decodable, Equatable {
    let calls: [CallSession]

    private enum CodingKeys: String, CodingKey { case pending, calls, items }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let calls = try container.decodeIfPresent([CallSession].self, forKey: .calls) {
            self.calls = calls
            return
        }
        if let items = try container.decodeIfPresent([CallSession].self, forKey: .items) {
            calls = items
            return
        }
        guard try container.decodeIfPresent(Bool.self, forKey: .pending) == true else {
            calls = []
            return
        }
        calls = [try CallSession(from: decoder)]
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
        let response: PendingCallsResponse = try await api.request(
            APIEndpoint(path: "/api/calls/pending"),
            as: PendingCallsResponse.self
        )
        return response.calls
    }

    func history() async throws -> [CallSession] {
        struct Response: Decodable { let calls: [CallSession]?; let items: [CallSession]? }
        let r: Response = try await api.request(APIEndpoint(path: "/api/calls/history"), as: Response.self)
        return r.calls ?? r.items ?? []
    }
}

private extension KeyedDecodingContainer where Key == CallSession.CodingKeys {
    func decodeLossyParticipants(forKey key: Key) throws -> [String]? {
        guard contains(key) else { return nil }
        if let values = try? decodeIfPresent([[String: String]].self, forKey: key) {
            return values.compactMap { $0["name"] ?? $0["email"] ?? $0["id"] ?? $0["userId"] }
        }
        return []
    }
}
