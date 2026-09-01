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
    /// `true` only when the backend returned the strict v2 call descriptor.
    /// A required marker without that descriptor is rejected while decoding.
    let e2eeRequired: Bool
    let e2ee: E2EEV2CallSessionDescriptor?

    enum CodingKeys: String, CodingKey {
        case id, callId, mode, type, callType, conversationId, createdAt, startedAt, endedAt, participants
        case otherParticipants, caller, callerName, conversation, conversationTitle, isGroup
        case liveKitToken, token, liveKitUrl, wsUrl, liveKitRoom, roomName, status, pending
        case e2eeRequired, e2ee
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
        isGroup: Bool = false,
        e2eeRequired: Bool = false,
        e2ee: E2EEV2CallSessionDescriptor? = nil
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
        self.e2eeRequired = e2eeRequired
        self.e2ee = e2ee
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

        let requiredMarker = try c.decodeIfPresent(Bool.self, forKey: .e2eeRequired)
        let descriptorValue = try c.decodeIfPresent(JSONValue.self, forKey: .e2ee)
        let descriptor: E2EEV2CallSessionDescriptor?
        if let descriptorValue {
            guard let parsed = E2EEV2CallBridge.parseDescriptor(descriptorValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .e2ee,
                    in: c,
                    debugDescription: "Invalid E2EE v2 call descriptor"
                )
            }
            descriptor = parsed
        } else {
            descriptor = nil
        }
        if requiredMarker == true && descriptor == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .e2ee,
                in: c,
                debugDescription: "E2EE v2 call descriptor is required"
            )
        }
        if requiredMarker == false && descriptor != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .e2eeRequired,
                in: c,
                debugDescription: "Unexpected E2EE v2 call descriptor"
            )
        }
        e2eeRequired = requiredMarker ?? (descriptor != nil)
        e2ee = descriptor
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

enum CallsServiceError: LocalizedError, Equatable {
    case e2eeUnavailable(String)
    case invalidE2EEResponse

    var errorDescription: String? {
        switch self {
        case .e2eeUnavailable:
            return "L’appel chiffré de bout en bout n’est pas disponible sur cet appareil."
        case .invalidE2EEResponse:
            return "La vérification du chiffrement de l’appel a échoué."
        }
    }
}

/// Exact JSON bytes signed by the E2EE v2 device identity. The same bytes are
/// sent once, without transparent retry, and the response must bind the exact
/// local epoch before LiveKit receives any key material.
enum CallE2EEV2Wire {
    static func initiateBody(
        conversationId: String,
        type: String,
        context: E2EEV2CallEpochContext
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "conversationId": conversationId,
                "type": type,
                "e2ee": context.jsonObject,
            ],
            options: [.sortedKeys]
        )
    }

    static func answerBody(callId: String, context: E2EEV2CallEpochContext) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "callId": callId,
                "e2ee": context.jsonObject,
            ],
            options: [.sortedKeys]
        )
    }

    static func decodeBoundSession(
        _ data: Data,
        expectedContext: E2EEV2CallEpochContext,
        expectedCallId: String? = nil
    ) throws -> CallSession {
        let session = try JSONDecoder.signalQuest.decode(CallSession.self, from: data)
        guard expectedCallId.map({ $0 == session.id }) ?? true,
              let descriptor = session.e2ee,
              session.e2eeRequired,
              descriptor.version == expectedContext.version,
              descriptor.provider == expectedContext.provider,
              descriptor.epochId == expectedContext.epochId,
              descriptor.epochNumber == expectedContext.epochNumber,
              descriptor.keyCommitmentB64 == expectedContext.keyCommitmentB64,
              descriptor.keyId == expectedContext.epochId else {
            throw CallsServiceError.invalidE2EEResponse
        }
        return session
    }
}

/// DTO de cache disque de l'historique des appels (stale-while-revalidate). N'inclut
/// PAS les jetons LiveKit éphémères (inutiles au journal, et périssables).
struct CachedCallSession: Codable {
    let id: String
    let mode: String?
    let conversationId: String?
    let createdAt: Date?
    let endedAt: Date?
    let participants: [String]?
    let status: String?
    let isPending: Bool?
    let displayName: String?
    let isGroup: Bool

    init(_ c: CallSession) {
        id = c.id; mode = c.mode; conversationId = c.conversationId
        createdAt = c.createdAt; endedAt = c.endedAt; participants = c.participants
        status = c.status; isPending = c.isPending; displayName = c.displayName; isGroup = c.isGroup
    }

    var session: CallSession {
        CallSession(
            id: id, mode: mode, conversationId: conversationId, createdAt: createdAt,
            endedAt: endedAt, participants: participants, liveKitToken: nil, liveKitUrl: nil,
            liveKitRoom: nil, status: status, isPending: isPending, displayName: displayName, isGroup: isGroup
        )
    }
}

protocol CallsServicing: Sendable {
    func initiate(
        conversationId: String,
        mode: String,
        e2ee: E2EEV2CallEpochContext?
    ) async throws -> CallSession
    func answer(
        callId: String,
        e2ee: E2EEV2CallEpochContext?
    ) async throws -> CallSession
    func reject(callId: String) async throws
    func end(callId: String) async throws
    func pending() async throws -> [CallSession]
    func history() async throws -> [CallSession]
    /// Page d'historique (pagination). Écrit la 1re page en cache disque.
    func history(page: Int, limit: Int) async throws -> [CallSession]
    /// Dernière page mémorisée (affichage instantané avant le rafraîchissement réseau).
    func cachedHistory() async -> [CallSession]
    /// Efface (masque « pour moi ») TOUT l'historique d'appels côté serveur + vide le
    /// cache disque local. L'autre participant conserve l'appel.
    func clearHistory() async throws
    /// Masque « pour moi » un appel précis (l'autre participant le garde).
    func deleteEntry(callId: String) async throws
}

extension CallsServicing {
    func initiate(conversationId: String, mode: String) async throws -> CallSession {
        try await initiate(conversationId: conversationId, mode: mode, e2ee: nil)
    }

    func answer(callId: String) async throws -> CallSession {
        try await answer(callId: callId, e2ee: nil)
    }

    func history(page: Int, limit: Int) async throws -> [CallSession] { try await history() }
    func cachedHistory() async -> [CallSession] { [] }
}

final class CallsService: CallsServicing {
    private let api: APIClient
    private let cache: DiskCache
    private let e2eeTransport: E2EEV2APITransport
    private var historyCacheKey: String { "history-\(LocalAccountScope.storageNamespace)" }

    init(
        api: APIClient,
        cache: DiskCache = DiskCache(folderName: "SignalQuestCallsHistory"),
        e2eeTransport: E2EEV2APITransport? = nil
    ) {
        self.api = api
        self.cache = cache
        self.e2eeTransport = e2eeTransport ?? E2EEV2APITransport(api: api)
    }

    func initiate(
        conversationId: String,
        mode: String,
        e2ee: E2EEV2CallEpochContext?
    ) async throws -> CallSession {
        let type = mode.uppercased() == "VIDEO" || mode.lowercased() == "video" ? "VIDEO" : "AUDIO"
        if let e2ee {
            let body = try CallE2EEV2Wire.initiateBody(
                conversationId: conversationId,
                type: type,
                context: e2ee
            )
            let data = try await executeE2EECall(path: "/api/calls/initiate", body: body)
            return try CallE2EEV2Wire.decodeBoundSession(data, expectedContext: e2ee)
        }
        let session: CallSession = try await api.requestJSON(
            "/api/calls/initiate",
            body: CallInitiateRequest(conversationId: conversationId, type: type)
        )
        guard !session.e2eeRequired, session.e2ee == nil else {
            throw CallsServiceError.invalidE2EEResponse
        }
        return session
    }

    func answer(callId: String, e2ee: E2EEV2CallEpochContext?) async throws -> CallSession {
        if let e2ee {
            let body = try CallE2EEV2Wire.answerBody(callId: callId, context: e2ee)
            let data = try await executeE2EECall(path: "/api/calls/answer", body: body)
            return try CallE2EEV2Wire.decodeBoundSession(
                data,
                expectedContext: e2ee,
                expectedCallId: callId
            )
        }
        let session: CallSession = try await api.requestJSON("/api/calls/answer", body: ["callId": callId])
        guard !session.e2eeRequired, session.e2ee == nil else {
            throw CallsServiceError.invalidE2EEResponse
        }
        return session
    }

    private func executeE2EECall(path: String, body: Data) async throws -> Data {
        let owner = LocalAccountScope.currentOwnerScopeId
        switch await e2eeTransport.postJSON(
            path: path,
            body: body,
            expectedOwnerScopeId: owner,
            capabilitySet: .calls
        ) {
        case .success(let value, _, _):
            return value
        case .failure(let failure):
            throw CallsServiceError.e2eeUnavailable(failure.message)
        }
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
        try await history(page: 1, limit: 20)
    }

    func history(page: Int, limit: Int) async throws -> [CallSession] {
        struct Response: Decodable { let calls: [CallSession]?; let items: [CallSession]? }
        let r: Response = try await api.request(
            APIEndpoint(path: "/api/calls/history", query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]),
            as: Response.self
        )
        let calls = r.calls ?? r.items ?? []
        if page == 1 {
            // 1re page mémorisée pour un affichage instantané à la prochaine ouverture.
            try? await cache.write(calls.map(CachedCallSession.init), for: historyCacheKey)
        }
        return calls
    }

    func cachedHistory() async -> [CallSession] {
        guard let cached = try? await cache.read([CachedCallSession].self, for: historyCacheKey) else { return [] }
        return cached.map(\.session)
    }

    func clearHistory() async throws {
        try await api.request(APIEndpoint(path: "/api/calls/history", method: .delete))
        await cache.remove(historyCacheKey)
    }

    func deleteEntry(callId: String) async throws {
        try await api.request(APIEndpoint(path: "/api/calls/\(callId)", method: .delete))
        // Le cache ne contient que la 1re page : on l'invalide pour éviter de réafficher
        // l'appel supprimé avant le prochain fetch réseau.
        await cache.remove(historyCacheKey)
    }
}

private extension KeyedDecodingContainer where Key == CallSession.CodingKeys {
    func decodeLossyParticipants(forKey key: Key) throws -> [String]? {
        guard contains(key) else { return nil }
        if let values = try? decodeIfPresent([[String: String]].self, forKey: key) {
            let names = values.compactMap { $0["name"] ?? $0["email"] ?? $0["id"] ?? $0["userId"] }
            // Renvoyer nil (et non []) en cas d'échec/vide : un [] non-nil stoppait le
            // repli `?? otherParticipants` et perdait tous les noms (CALL-DEC-A).
            return names.isEmpty ? nil : names
        }
        return nil
    }
}
