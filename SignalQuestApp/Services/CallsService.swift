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
    /// Descripteur signé d'un appel chiffré (D.11, E.4), relayé tel quel par
    /// le serveur ; lu strictement, un descripteur mal formé fait échouer le
    /// décodage. Sa vérification (appareil, époque, nonce) revient à l'appelé.
    let e2eeV2: E2EEV2SignedCallDescriptor?
    /// Identité LiveKit annoncée (`<userId>.<deviceId>`), informative : aucune
    /// vérification ne s'y fie (E.4).
    let livekitIdentity: String?

    /// Un appel chiffré est celui qui porte un descripteur v2.
    var e2eeRequired: Bool { e2eeV2 != nil }

    enum CodingKeys: String, CodingKey {
        case id, callId, mode, type, callType, conversationId, createdAt, startedAt, endedAt, participants
        case otherParticipants, caller, callerName, conversation, conversationTitle, isGroup
        case liveKitToken, token, liveKitUrl, wsUrl, liveKitRoom, roomName, status, pending
        case e2eeRequired, e2eeV2, livekitIdentity
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
        e2eeV2: E2EEV2SignedCallDescriptor? = nil,
        livekitIdentity: String? = nil
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
        self.e2eeV2 = e2eeV2
        self.livekitIdentity = livekitIdentity
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

        // `e2eeV2` absent ou nul : appel non chiffré. Présent : lu strictement.
        let descriptorValue = try c.decodeIfPresent(JSONValue.self, forKey: .e2eeV2)
        if let descriptorValue, descriptorValue != .null {
            guard let parsed = E2EEV2SignedCallDescriptor.parse(descriptorValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .e2eeV2, in: c, debugDescription: "Invalid E2EE v2 call descriptor"
                )
            }
            e2eeV2 = parsed
        } else {
            e2eeV2 = nil
        }
        // Ancien marqueur : un appel annoncé chiffré sans descripteur n'est jamais
        // pris pour un appel en clair.
        if try c.decodeIfPresent(Bool.self, forKey: .e2eeRequired) == true, e2eeV2 == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .e2eeRequired, in: c, debugDescription: "E2EE v2 call descriptor is required"
            )
        }
        livekitIdentity = try? c.decodeIfPresent(String.self, forKey: .livekitIdentity)
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
    /// Refus du serveur à un appel chiffré, avec son code (E.0) :
    /// `E2EE_EPOCH_STALE`, `CALL_ID_TAKEN`, `CALL_PARTICIPANT_ALREADY_ANSWERED`…
    case refused(code: String)

    var errorDescription: String? {
        switch self {
        case .e2eeUnavailable(let reason) where reason == "e2ee-device-locked":
            // Spec §2.6 (v0.4.13) : verrouillé, la clé existe ; seul le déverrouillage manque.
            return String(localized: "Déverrouille ton appareil pour rejoindre l’appel chiffré.")
        case .e2eeUnavailable:
            return String(localized: "L’appel chiffré de bout en bout n’est pas disponible sur cet appareil.")
        case .invalidE2EEResponse:
            return String(localized: "La vérification du chiffrement de l’appel a échoué.")
        case .refused("CALL_PARTICIPANT_ALREADY_ANSWERED"), .refused("E2EE_CALL_DEVICE_NOT_ELIGIBLE"):
            return String(localized: "L’appel a déjà été pris sur un autre appareil.")
        case .refused("E2EE_CAPABILITY_MISSING"):
            return String(localized: "Un membre doit mettre à jour SignalQuest pour les appels chiffrés.")
        case .refused:
            return String(localized: "L’appel chiffré de bout en bout n’est pas disponible sur cet appareil.")
        }
    }
}

/// Corps et réponses d'un appel chiffré (E.4), envoyés en requête signée par
/// l'appareil, une seule fois et sans reprise transparente.
enum CallE2EEV2Wire {
    /// `{conversationId, type, callId, e2eeV2}`, exactement.
    static func initiateBody(conversationId: String, type: String, descriptor: E2EEV2SignedCallDescriptor) -> Data {
        E2EEV2CanonicalJSON.encode(.object([
            "conversationId": .string(conversationId),
            "type": .string(type),
            "callId": .string(descriptor.descriptor.callId),
            "e2eeV2": .object([
                "descriptor": .string(descriptor.signed.canonical),
                "signatureB64": .string(descriptor.signed.signatureB64),
                "callerDeviceId": .string(descriptor.callerDeviceId),
            ]),
        ]))
    }

    /// `{callId}`, rien de plus.
    static func answerBody(callId: String) -> Data {
        E2EEV2CanonicalJSON.encode(.object(["callId": .string(callId)]))
    }

    /// La réponse d'initiation porte l'appel demandé et, à l'octet, le
    /// descripteur signé ici.
    static func decodeInitiated(_ data: Data, sent: E2EEV2SignedCallDescriptor) throws -> CallSession {
        let session = try JSONDecoder.signalQuest.decode(CallSession.self, from: data)
        guard session.id == sent.descriptor.callId, session.e2eeV2 == sent else {
            throw CallsServiceError.invalidE2EEResponse
        }
        return session
    }

    /// La réponse à `answer` porte un descripteur pour cet appel ; l'appelé le
    /// compare à celui qu'il a vérifié avant de rejoindre.
    static func decodeAnswered(_ data: Data, callId: String) throws -> CallSession {
        let session = try JSONDecoder.signalQuest.decode(CallSession.self, from: data)
        guard session.id == callId, session.e2eeV2?.descriptor.callId == callId else {
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
        e2ee: E2EEV2SignedCallDescriptor?
    ) async throws -> CallSession
    /// `e2ee` : appel chiffré, réponse signée par l'appareil (E.4).
    func answer(
        callId: String,
        e2ee: Bool
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
        try await answer(callId: callId, e2ee: false)
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
        e2ee: E2EEV2SignedCallDescriptor?
    ) async throws -> CallSession {
        let type = mode.uppercased() == "VIDEO" || mode.lowercased() == "video" ? "VIDEO" : "AUDIO"
        if let e2ee {
            let body = CallE2EEV2Wire.initiateBody(conversationId: conversationId, type: type, descriptor: e2ee)
            let data = try await executeE2EECall(path: "/api/calls/initiate", body: body)
            return try CallE2EEV2Wire.decodeInitiated(data, sent: e2ee)
        }
        let session: CallSession = try await api.requestJSON(
            "/api/calls/initiate",
            body: CallInitiateRequest(conversationId: conversationId, type: type)
        )
        guard !session.e2eeRequired else {
            throw CallsServiceError.invalidE2EEResponse
        }
        return session
    }

    func answer(callId: String, e2ee: Bool) async throws -> CallSession {
        if e2ee {
            let data = try await executeE2EECall(path: "/api/calls/answer", body: CallE2EEV2Wire.answerBody(callId: callId))
            return try CallE2EEV2Wire.decodeAnswered(data, callId: callId)
        }
        let session: CallSession = try await api.requestJSON("/api/calls/answer", body: ["callId": callId])
        guard !session.e2eeRequired else {
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
        case .failure(let failure) where failure.statusCode != nil && failure.code != nil:
            throw CallsServiceError.refused(code: failure.code ?? "")
        case .failure(let failure):
            throw CallsServiceError.e2eeUnavailable(failure.message)
        }
    }

    func reject(callId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON("/api/calls/reject", body: ["callId": callId])
    }

    /// `/api/calls/leave`, comme Android et le web : `/api/calls/end` en est
    /// l'alias déprécié. Un second départ répond 200 (`alreadyClosed`).
    func end(callId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON("/api/calls/leave", body: ["callId": callId])
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
