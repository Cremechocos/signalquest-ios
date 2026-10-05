import CryptoKit
import Foundation

enum E2EEV2MembershipWriteResultV2: Sendable, Equatable {
    /// Changement accepté et ajouté à la chaîne gardée. Une rotation suit
    /// (§3.3) : membres ou réglage des navigateurs ont changé.
    case applied(changeNumber: Int)
    /// La chaîne locale est en retard sur le serveur : la relire, puis réessayer.
    case needsSync
    /// Les règles de D.4 refusent ce changement à ce compte.
    case notAllowed
    case failure(E2EEV2TransportFailure)
}

/// Changements d'appartenance après la genèse (D.4, E.2) : ajout ou retrait
/// d'un membre, départ, rôles, exclusion des navigateurs. Composé sur la tête
/// de la chaîne gardée, vérifié localement contre les mêmes règles que chez
/// les autres membres, puis envoyé en comparaison-échange sur son numéro. Le
/// changement signé est gardé avant l'envoi et renvoyé tel quel : un accusé
/// perdu ne fait jamais signer deux changements pour un même numéro.
final class E2EEV2MembershipWriterV2: @unchecked Sendable {
    enum Change: Equatable, Sendable {
        case add(userId: String)
        case remove(userId: String)
        case leave
        case promote(userId: String)
        case demote(userId: String)
        case excludeBrowsers(Bool)

        var action: String {
            switch self {
            case .add: return "ADD"
            case .remove: return "REMOVE"
            case .leave: return "LEAVE"
            case .promote: return "ROLE_ADMIN"
            case .demote: return "ROLE_MEMBER"
            case .excludeBrowsers(let on): return on ? "EXCLUDE_WEB_ON" : "EXCLUDE_WEB_OFF"
            }
        }

        func target(ownUserId: String) -> String {
            switch self {
            case .add(let userId), .remove(let userId), .promote(let userId), .demote(let userId): return userId
            case .leave: return ownUserId
            case .excludeBrowsers: return "-"
            }
        }
    }

    private let transport: E2EEV2APITransport
    private let identityStore: E2EEV2DeviceIdentityStore
    private let stateStore: E2EEV2ConversationStateStore
    private let expectedSession: LocalAccountSession?
    private let now: @Sendable () -> Date

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore(),
        expectedSession: LocalAccountSession? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identityStore = identityStore
        self.stateStore = stateStore
        self.expectedSession = expectedSession
        self.now = now
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
    }

    func submit(
        _ change: Change,
        conversationId: String,
        isGroup: Bool,
        expectedOwnerScopeId: String
    ) async -> E2EEV2MembershipWriteResultV2 {
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:"),
              E2EEV2Canonical.isOpaque(conversationId) else {
            return .failure(localError("invalid-e2ee-membership-scope"))
        }
        let ownerNamespace = session.ownerNamespace
        let ownUserId = String(expectedOwnerScopeId.dropFirst("user:".count))
        let device: E2EEV2DeviceDescriptor
        let ownKey: P256.Signing.PublicKey
        let chain: [E2EEV2SignedString]
        let head: E2EEV2MembershipState
        let genesisLength: Int
        var pending: E2EEV2SignedString?
        do {
            guard let loaded = try identityStore.load(ownerNamespace: ownerNamespace),
                  let keyData = Data(base64Encoded: loaded.publicSigningKeyB64),
                  let genesis = try stateStore.genesis(conversationId: conversationId, ownerNamespace: ownerNamespace)
            else { return .failure(localError("e2ee-membership-state-unavailable")) }
            device = loaded
            ownKey = try P256.Signing.PublicKey(x963Representation: keyData)
            genesisLength = genesis.membershipChangeNumber
            chain = try stateStore.membershipChain(conversationId: conversationId, ownerNamespace: ownerNamespace)
            // Chaîne gardée, déjà vérifiée : relue sans l'annuaire du jour.
            head = try E2EEV2MembershipChain.apply(
                chain, conversationId: conversationId, isGroup: isGroup, genesisLength: genesisLength,
                verifiedCount: chain.count
            ) { _, _ in nil }
            pending = try stateStore.pendingMembership(conversationId: conversationId, ownerNamespace: ownerNamespace)
        } catch {
            return .failure(localError("e2ee-membership-state-unavailable"))
        }

        // Un changement gardé passe avant tout autre. Si la chaîne l'a déjà
        // dépassé, il a été accepté (accusé perdu) ou battu par un autre au même
        // numéro : il ne repart jamais.
        if let known = pending {
            let number = E2EEV2Canonical.split(known.canonical, tag: E2EEV2MembershipChange.tag, version: "1", fieldCount: 10)
                .flatMap { E2EEV2Canonical.sequenceNumber($0[3]) }
            if number != head.changeNumber + 1 {
                try? stateStore.clearPendingMembership(conversationId: conversationId, ownerNamespace: ownerNamespace)
                pending = nil
                if let number, chain.contains(known) { return .applied(changeNumber: number) }
            }
        }

        let signed: E2EEV2SignedString
        if let known = pending {
            signed = known
        } else {
            let next = E2EEV2MembershipChange(
                conversationId: conversationId, changeNumber: head.changeNumber + 1, action: change.action,
                targetUserId: change.target(ownUserId: ownUserId), actorUserId: ownUserId, actorDeviceId: device.deviceId,
                previousChangeDigest: head.lastCanonical.map(E2EEV2MembershipChange.digest(of:)) ?? "-",
                createdAtMs: Int64(now().timeIntervalSince1970 * 1_000)
            )
            guard head.changeNumber < E2EEV2Canonical.maxSequenceNumber,
                  E2EEV2Canonical.isOpaque(device.deviceId) else { return .notAllowed }
            do {
                let signature = try identityStore.sign(canonicalRequest: Data(next.canonical.utf8), ownerNamespace: ownerNamespace)
                signed = E2EEV2SignedString(canonical: next.canonical, signatureB64: signature.base64EncodedString())
            } catch {
                return .failure(localError("e2ee-membership-signing-failed"))
            }
            // Les mêmes règles que chez les autres membres (D.4).
            do {
                _ = try E2EEV2MembershipChain.apply(
                    [signed], to: head, conversationId: conversationId, isGroup: isGroup, genesisLength: genesisLength,
                    verifiedCount: head.changeNumber
                ) { userId, deviceId in userId == ownUserId && deviceId == device.deviceId ? ownKey : nil }
            } catch {
                return .notAllowed
            }
            do {
                try stateStore.savePendingMembership(signed, conversationId: conversationId, ownerNamespace: ownerNamespace)
            } catch {
                return .failure(localError("e2ee-membership-storage-failed"))
            }
        }

        let body = E2EEV2CanonicalJSON.encode(E2EEV2MembershipChange.json(signed))
        switch await transport.bound(to: session).postJSON(
            path: "/api/e2ee/v2/conversations/\(conversationId)/membership", body: body,
            expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
        ) {
        case .failure(let error) where error.statusCode == 409 && error.code == "E2EE_MEMBERSHIP_STALE":
            return .needsSync
        case .failure(let error)
            where error.statusCode == 404 && error.code == "E2EE_CONVERSATION_NOT_FOUND" && pending != nil
                && E2EEV2Canonical.split(signed.canonical, tag: E2EEV2MembershipChange.tag, version: "1", fieldCount: 10)?[4]
                    == "LEAVE":
            // v0.4.16 : départ gardé et renvoyé après un reçu perdu ; l'appelant
            // n'est plus membre, le départ est tenu pour fait.
            guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }
            do {
                try stateStore.appendMembership([signed], conversationId: conversationId, ownerNamespace: ownerNamespace)
                try stateStore.clearPendingMembership(conversationId: conversationId, ownerNamespace: ownerNamespace)
            } catch {
                return .failure(localError("e2ee-membership-storage-failed"))
            }
            return .applied(changeNumber: head.changeNumber + 1)
        // Refus définitif d'un changement que le serveur ne prendra jamais (le
        // dernier admin qui part sans successeur, un membre sans v2) : il n'est
        // pas gardé, sinon il repartirait à la place du changement suivant.
        case .failure(let error) where error.statusCode == 409
            && ["E2EE_LAST_ADMIN_MUST_PROMOTE", "E2EE_UPDATE_REQUIRED"].contains(error.code ?? ""):
            try? stateStore.clearPendingMembership(conversationId: conversationId, ownerNamespace: ownerNamespace)
            return .failure(error)
        case .failure(let error):
            return .failure(error)
        case .success(let data, _, _):
            guard session.isCurrent else { return .failure(localError("e2ee-session-changed")) }
            let number = head.changeNumber + 1
            guard let root = (try? E2EEV2CanonicalJSON.parseStrict(data))?.objectValue, Set(root.keys) == ["changeNumber"],
                  root["changeNumber"]?.stringValue == String(number) else {
                return .failure(localError("invalid-e2ee-membership-response"))
            }
            do {
                try stateStore.appendMembership([signed], conversationId: conversationId, ownerNamespace: ownerNamespace)
                try stateStore.clearPendingMembership(conversationId: conversationId, ownerNamespace: ownerNamespace)
            } catch {
                return .failure(localError("e2ee-membership-storage-failed"))
            }
            return .applied(changeNumber: number)
        }
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
