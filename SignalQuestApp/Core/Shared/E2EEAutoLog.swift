import CryptoKit
import Foundation

/// Journal des appareils du chiffrement automatique (E2EE-AUTO), contrat
/// `docs/e2ee-auto-contract.md` v1, §2.3 et §3 : formats stricts, condensats,
/// charges signées, chaîne publique des maillons et journal d'un compte. Suit
/// la référence `packages/core/e2ee-auto-log.ts` ; en cas d'écart, les vecteurs
/// `contracts/e2ee-auto/` font foi.
enum E2EEAutoLog {
    static let none = "-"
    static let entryVersion = "2"
    static let linkVersion = "1"
    static let headVersion = "2"

    /// Ancienneté exigée d'un signataire (§3.2, §4.4) et âge accepté d'une tête,
    /// avec sa tolérance d'horloge de part et d'autre (§3.4).
    static let signerMinAgeMs: Int64 = 24 * 3_600_000
    static let headMaxAgeMs: Int64 = 24 * 3_600_000
    static let clockToleranceMs: Int64 = 10 * 60_000

    enum Platform: String, Sendable, Equatable {
        case ios, android, web
    }

    enum Op: String, Sendable, Equatable {
        case add = "ADD"
        case addPending = "ADD_PENDING"
        case activate = "ACTIVATE"
        case rotate = "ROTATE"
        case revoke = "REVOKE"
        case historyKey = "HISTORY_KEY"
        case mode = "MODE"
        case logKey = "LOG_KEY"
    }

    enum Mode: String, Sendable, Equatable {
        case strict = "STRICT"
        case normal = "NORMAL"
    }

    /// `USER` et `NOT_ME` sont signés par l'appareil qui révoque ; les autres
    /// sont posés par le serveur, sans signature, et affichés comme tels.
    enum RevokeReason: String, Sendable, Equatable {
        case user = "USER"
        case notMe = "NOT_ME"
        case emailNotMe = "EMAIL_NOT_ME"
        case inactive = "INACTIVE"
        case accountDeleted = "ACCOUNT_DELETED"
        case admin = "ADMIN"

        var isSigned: Bool { self == .user || self == .notMe }
    }

    // MARK: - Formats de champ (§2.3)

    /// Entier décimal ASCII sans signe ni zéro de tête, dans `range`.
    static func decimal(_ value: String, in range: ClosedRange<Int64>) -> Int64? {
        guard let number = E2EEV2Canonical.safeInteger(value), range.contains(number) else { return nil }
        return number
    }

    /// `b64` canonique : alphabet standard, remplissage présent, bits de queue
    /// nuls, vérifiés par réencodage (`QR==` est refusé).
    static func canonicalBase64(_ value: String) -> Data? {
        guard !value.isEmpty, let data = Data(base64Encoded: value), data.base64EncodedString() == value else { return nil }
        return data
    }

    /// Condensat `b64url` de 32 octets, canonique.
    static func isDigest(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              value.utf8.allSatisfy({ isBase64URLByte($0) }) else { return false }
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: standard), data.count == 32 else { return false }
        return data.base64URLEncodedNoPadding() == value
    }

    /// Clé publique P-256 : X9.63 non compressé de 65 octets, sur la courbe, en `b64` canonique.
    static func isPublicKey(_ value: String) -> Bool {
        E2EEV2Canonical.isX963PublicKey(value)
    }

    /// Signature en `b64` canonique ; la forme DER et le S bas sont vérifiés à la vérification.
    static func isSignature(_ value: String) -> Bool {
        guard let data = canonicalBase64(value) else { return false }
        return (8...72).contains(data.count)
    }

    static func digest(_ text: String) -> String {
        E2EEV2Canonical.sha256B64URL(Data(text.utf8))
    }

    /// Signature DER canonique à S bas (§2.3) sur les octets UTF-8 de `payload`.
    static func verify(publicKeyB64: String, payload: String, signatureB64: String) -> Bool {
        guard isSignature(signatureB64),
              let signature = Data(base64Encoded: signatureB64),
              let keyData = Data(base64Encoded: publicKeyB64),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData) else { return false }
        return E2EEV2LowS.verify(derSignature: signature, message: Data(payload.utf8), publicKey: key)
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }

    // MARK: - Charges signées (§3.1)

    /// Chaque charge porte `prevUserEntryHash` : une ancienne signature ne peut
    /// pas être rejouée sur un autre état du compte.
    enum Payload {
        static func activate(
            userId: String, prevUserEntryHash: String, approverDeviceId: String, deviceId: String,
            identityKeyB64: String, signingKeyB64: String, keyVersion: Int
        ) -> String {
            ["SQ-E2EE-AUTO-ACTIVATE", "1", userId, prevUserEntryHash, approverDeviceId, deviceId,
             identityKeyB64, signingKeyB64, String(keyVersion)].joined(separator: "\n")
        }

        static func rotate(userId: String, prevUserEntryHash: String, deviceId: String, newIdentityKeyB64: String, keyVersion: Int) -> String {
            ["SQ-E2EE-AUTO-ROTATE", "1", userId, prevUserEntryHash, deviceId, newIdentityKeyB64, String(keyVersion)]
                .joined(separator: "\n")
        }

        static func revoke(userId: String, prevUserEntryHash: String, revokerDeviceId: String, deviceId: String, reason: RevokeReason) -> String {
            ["SQ-E2EE-AUTO-REVOKE", "1", userId, prevUserEntryHash, revokerDeviceId, deviceId, reason.rawValue]
                .joined(separator: "\n")
        }

        static func historyKey(userId: String, prevUserEntryHash: String, signerDeviceId: String, previousHkPubB64: String?, hkPubB64: String) -> String {
            ["SQ-E2EE-AUTO-HISTORY-KEY", "1", userId, prevUserEntryHash, signerDeviceId, previousHkPubB64 ?? none, hkPubB64]
                .joined(separator: "\n")
        }

        static func mode(userId: String, prevUserEntryHash: String, signerDeviceId: String, mode: Mode) -> String {
            ["SQ-E2EE-AUTO-MODE", "1", userId, prevUserEntryHash, signerDeviceId, mode.rawValue].joined(separator: "\n")
        }

        static func logKey(seq: Int64, oldLogKeyId: String, newLogKeyB64: String) -> String {
            ["SQ-E2EE-AUTO-LOG-KEY", "1", String(seq), oldLogKeyId, newLogKeyB64].joined(separator: "\n")
        }
    }

    // MARK: - Entrée de compte (§3.1)

    struct Entry: Equatable, Sendable {
        let seq: Int64
        let userId: String
        let prevUserEntryHash: String
        let op: Op
        let deviceId: String
        let platform: String
        let identityKeyB64: String
        let signingKeyB64: String
        let keyVersion: String
        let detail: String
        let createdAtMs: Int64

        var canonical: String {
            ["SQ-E2EE-AUTO-LOG-ENTRY", entryVersion, String(seq), userId, prevUserEntryHash, op.rawValue, deviceId,
             platform, identityKeyB64, signingKeyB64, keyVersion, detail, String(createdAtMs)].joined(separator: "\n")
        }
    }

    enum Detail: Equatable, Sendable {
        case add(genesis: Bool)
        case addPending
        case activate(approverDeviceId: String, signatureB64: String)
        case rotate(signatureB64: String)
        case signedRevoke(reason: RevokeReason, revokerDeviceId: String, signatureB64: String)
        case serverRevoke(reason: RevokeReason)
        case historyKey(signerDeviceId: String, hkPubB64: String, signatureB64: String)
        case mode(signerDeviceId: String, mode: Mode, signatureB64: String)
        case logKey(newLogKeyB64: String, signatureB64: String)
    }

    /// Champs portés par chaque `op` ; les autres valent `-`.
    private struct Fields {
        let deviceId: Bool
        let platform: Bool
        let identityKey: Bool
        let signingKey: Bool
        let keyVersion: Bool
    }

    private static func fields(_ op: Op) -> Fields {
        switch op {
        case .add, .addPending, .activate:
            Fields(deviceId: true, platform: true, identityKey: true, signingKey: true, keyVersion: true)
        case .rotate:
            Fields(deviceId: true, platform: false, identityKey: true, signingKey: false, keyVersion: true)
        case .revoke:
            Fields(deviceId: true, platform: false, identityKey: false, signingKey: false, keyVersion: false)
        case .historyKey, .mode, .logKey:
            Fields(deviceId: false, platform: false, identityKey: false, signingKey: false, keyVersion: false)
        }
    }

    /// `detail` selon `op` ; `:` n'y sert que de séparateur, un champ de trop est refusé.
    static func parseDetail(_ op: Op, _ detail: String) -> Detail? {
        let parts = detail.components(separatedBy: ":")
        switch op {
        case .add:
            return detail == "GENESIS" ? .add(genesis: true) : detail == none ? .add(genesis: false) : nil
        case .addPending:
            return detail == none ? .addPending : nil
        case .activate:
            guard parts.count == 2, E2EEV2Canonical.isOpaque(parts[0]), isSignature(parts[1]) else { return nil }
            return .activate(approverDeviceId: parts[0], signatureB64: parts[1])
        case .rotate:
            guard parts.count == 1, isSignature(parts[0]) else { return nil }
            return .rotate(signatureB64: parts[0])
        case .revoke:
            if parts.count == 1, let reason = RevokeReason(rawValue: parts[0]), !reason.isSigned {
                return .serverRevoke(reason: reason)
            }
            guard parts.count == 3, let reason = RevokeReason(rawValue: parts[0]), reason.isSigned,
                  E2EEV2Canonical.isOpaque(parts[1]), isSignature(parts[2]) else { return nil }
            return .signedRevoke(reason: reason, revokerDeviceId: parts[1], signatureB64: parts[2])
        case .historyKey:
            guard parts.count == 3, E2EEV2Canonical.isOpaque(parts[0]), isPublicKey(parts[1]), isSignature(parts[2]) else { return nil }
            return .historyKey(signerDeviceId: parts[0], hkPubB64: parts[1], signatureB64: parts[2])
        case .mode:
            guard parts.count == 3, E2EEV2Canonical.isOpaque(parts[0]), let mode = Mode(rawValue: parts[1]),
                  isSignature(parts[2]) else { return nil }
            return .mode(signerDeviceId: parts[0], mode: mode, signatureB64: parts[2])
        case .logKey:
            guard parts.count == 2, isPublicKey(parts[0]), isSignature(parts[1]) else { return nil }
            return .logKey(newLogKeyB64: parts[0], signatureB64: parts[1])
        }
    }

    /// Lecture stricte d'une entrée : exactement 13 lignes, champs au format, `-`
    /// pour les champs sans objet, `detail` conforme à `op`. Ne vérifie ni
    /// chaînage ni signature.
    static func parseEntry(_ text: String) -> (entry: Entry, detail: Detail)? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 13, lines[0] == "SQ-E2EE-AUTO-LOG-ENTRY", lines[1] == entryVersion,
              let seq = decimal(lines[2], in: 1...E2EEV2Canonical.maxSafeInteger),
              let createdAtMs = decimal(lines[12], in: 0...E2EEV2Canonical.maxSafeInteger),
              let op = Op(rawValue: lines[5]) else { return nil }
        let userId = lines[3]
        let prevUserEntryHash = lines[4]
        if op == .logKey {
            guard userId == none, prevUserEntryHash == none else { return nil }
        } else {
            guard E2EEV2Canonical.isOpaque(userId), prevUserEntryHash == none || isDigest(prevUserEntryHash) else { return nil }
        }
        let expected = fields(op)
        func conforms(_ present: Bool, _ value: String, _ valid: (String) -> Bool) -> Bool {
            present ? valid(value) : value == none
        }
        guard conforms(expected.deviceId, lines[6], E2EEV2Canonical.isOpaque),
              conforms(expected.platform, lines[7], { Platform(rawValue: $0) != nil }),
              conforms(expected.identityKey, lines[8], isPublicKey),
              conforms(expected.signingKey, lines[9], isPublicKey),
              conforms(expected.keyVersion, lines[10], { E2EEV2Canonical.sequenceNumber($0) != nil }),
              let detail = parseDetail(op, lines[11]) else { return nil }
        let entry = Entry(
            seq: seq, userId: userId, prevUserEntryHash: prevUserEntryHash, op: op, deviceId: lines[6],
            platform: lines[7], identityKeyB64: lines[8], signingKeyB64: lines[9], keyVersion: lines[10],
            detail: lines[11], createdAtMs: createdAtMs
        )
        return (entry, detail)
    }

    // MARK: - Maillons, identifiant et étiquette de compte (§3.3)

    enum LinkKind: String, Sendable, Equatable {
        case account = "ACCOUNT"
        case entry = "ENTRY"
    }

    struct Link: Equatable, Sendable {
        let seq: Int64
        let prevLinkHash: String
        let kind: LinkKind
        let tag: String
        let hash: String
        let genesis: Bool

        /// Maillon d'une entrée `LOG_KEY`, la seule sans compte.
        var isLogKey: Bool { kind == .entry && tag == none }

        var canonical: String {
            ["SQ-E2EE-AUTO-LOG-LINK", linkVersion, String(seq), prevLinkHash, kind.rawValue, tag, hash, genesis ? "1" : "0"]
                .joined(separator: "\n")
        }
    }

    static let genesisHash = digest("SQ-E2EE-AUTO-LOG-GENESIS\n1")

    static func accountId(userId: String) -> String {
        digest("SQ-E2EE-AUTO-ACCOUNT-ID\n1\n\(userId)")
    }

    static func accountTag(userId: String, accountSaltB64: String) -> String {
        digest("SQ-E2EE-AUTO-ACCOUNT-TAG\n1\n\(userId)\n\(accountSaltB64)")
    }

    static func saltCommitment(accountSaltB64: String) -> String {
        digest("SQ-E2EE-AUTO-ACCOUNT-SALT\n1\n\(accountSaltB64)")
    }

    /// Sel de compte : 16 octets en `b64` canonique.
    static func isAccountSalt(_ value: String) -> Bool {
        canonicalBase64(value)?.count == 16
    }

    static func parseLink(_ text: String) -> Link? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 8, lines[0] == "SQ-E2EE-AUTO-LOG-LINK", lines[1] == linkVersion,
              let seq = decimal(lines[2], in: 1...E2EEV2Canonical.maxSafeInteger),
              isDigest(lines[3]),
              let kind = LinkKind(rawValue: lines[4]),
              isDigest(lines[5]) || (kind == .entry && lines[5] == none),
              isDigest(lines[6]),
              lines[7] == "0" || lines[7] == "1" else { return nil }
        return Link(seq: seq, prevLinkHash: lines[3], kind: kind, tag: lines[5], hash: lines[6], genesis: lines[7] == "1")
    }

    // MARK: - Tête signée (§3.4)

    struct Head: Equatable, Sendable {
        let seq: Int64
        let linkHash: String
        let logKeyId: String
        let createdAtMs: Int64
    }

    static func logKeyId(_ logKeyB64: String) -> String {
        E2EEV2Canonical.sha256B64URL(Data(base64Encoded: logKeyB64) ?? Data())
    }

    static func parseHead(_ text: String) -> Head? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 6, lines[0] == "SQ-E2EE-AUTO-LOG-HEAD", lines[1] == headVersion,
              let seq = decimal(lines[2], in: 0...E2EEV2Canonical.maxSafeInteger),
              let createdAtMs = decimal(lines[5], in: 0...E2EEV2Canonical.maxSafeInteger),
              isDigest(lines[3]), isDigest(lines[4]) else { return nil }
        return Head(seq: seq, linkHash: lines[3], logKeyId: lines[4], createdAtMs: createdAtMs)
    }

    enum HeadError: String, Error, Sendable {
        case format = "HEAD_FORMAT"
        case logKey = "HEAD_LOG_KEY"
        case signature = "HEAD_SIGNATURE"
    }

    enum HeadCheck: Equatable, Sendable {
        case ok(Head)
        /// « Journal pas à jour » : aucune alerte, aucun nouveau destinataire, nouvel essai.
        case stale(Head)
        case invalid(HeadError)
    }

    /// Tête signée par la clé du journal en vigueur : format, signature (DER, S
    /// bas), et âge à l'horloge de l'appareil, avec 10 min de tolérance de part
    /// et d'autre.
    static func checkHead(text: String, signatureB64: String, logKeyB64: String, nowMs: Int64) -> HeadCheck {
        guard let head = parseHead(text) else { return .invalid(.format) }
        guard head.logKeyId == logKeyId(logKeyB64) else { return .invalid(.logKey) }
        guard verify(publicKeyB64: logKeyB64, payload: text, signatureB64: signatureB64) else { return .invalid(.signature) }
        return isFresh(createdAtMs: head.createdAtMs, nowMs: nowMs) ? .ok(head) : .stale(head)
    }

    /// 24 h au plus, et pas plus de la tolérance dans le futur (§3.4).
    static func isFresh(createdAtMs: Int64, nowMs: Int64) -> Bool {
        nowMs - createdAtMs <= headMaxAgeMs + clockToleranceMs && createdAtMs - nowMs <= clockToleranceMs
    }

    // MARK: - Chaîne publique des maillons (§3.3, §3.5 points 1, 3 et 4)

    struct AccountLink: Equatable, Sendable {
        let seq: Int64
        let saltCommitment: String
    }

    struct ChainState: Equatable, Sendable {
        var seq: Int64
        var linkHash: String
        /// Un maillon `genesis = 0` hors `LOG_KEY` a été vu : plus aucun `genesis = 1` n'est admis.
        var genesisClosed: Bool
        /// `accountId` → maillon `ACCOUNT`, unique par compte.
        var accounts: [String: AccountLink]
        /// Clé du journal en vigueur à `seq`, après les entrées `LOG_KEY`.
        var logKeyB64: String
        /// Clés suivantes épinglées dans l'app, dans l'ordre : un `LOG_KEY` ne mène qu'à la première (§3.4).
        var nextLogKeysB64: [String]

        static func initial(pinnedLogKeyB64: String, nextLogKeysB64: [String] = []) -> ChainState {
            ChainState(
                seq: 0, linkHash: genesisHash, genesisClosed: false, accounts: [:],
                logKeyB64: pinnedLogKeyB64, nextLogKeysB64: nextLogKeysB64
            )
        }
    }

    enum ChainError: String, Error, Sendable {
        case linkFormat = "LINK_FORMAT"
        case linkSeq = "LINK_SEQ"
        case linkPrevHash = "LINK_PREV_HASH"
        case genesisAfterClose = "GENESIS_AFTER_CLOSE"
        case duplicateAccount = "DUPLICATE_ACCOUNT"
        case logKeyEntryMissing = "LOG_KEY_ENTRY_MISSING"
        case logKeyEntryInvalid = "LOG_KEY_ENTRY_INVALID"
        case logKeyNotPinned = "LOG_KEY_NOT_PINNED"
        case rollback = "ROLLBACK"
        case fork = "FORK"
        /// Alerte de la révision 13 : maillons enchaînés jusqu'à une tête
        /// vérifiée, mais contraires au §3.3. Traitée comme une fourche.
        case chainInvalid = "CHAIN_INVALID"
    }

    struct ChainFailure: Error, Equatable, Sendable {
        let error: ChainError
        let seq: Int64
    }

    /// Prolonge l'état gardé par une page de maillons, en ordre. `logKeyEntries` :
    /// les entrées complètes jointes aux maillons dont le `tag` vaut `-` (§3.5),
    /// par `seq`. Rend le nouvel état ou la première erreur, sans toucher à `state`.
    static func extendChain(_ state: ChainState, links: [String], logKeyEntries: [Int64: String]) -> Result<ChainState, ChainFailure> {
        let extended = extendChainPartially(state, links: links, logKeyEntries: logKeyEntries)
        if let failure = extended.failure { return .failure(failure) }
        return .success(extended.state)
    }

    /// Comme `extendChain`, mais rend aussi l'état au dernier maillon admis :
    /// la clé du journal en vigueur avant la faute juge la tête (révision 13).
    static func extendChainPartially(
        _ state: ChainState, links: [String], logKeyEntries: [Int64: String]
    ) -> (state: ChainState, failure: ChainFailure?) {
        var state = state
        for text in links {
            let expectedSeq = state.seq + 1
            guard let link = parseLink(text) else { return (state, ChainFailure(error: .linkFormat, seq: expectedSeq)) }
            guard link.seq == expectedSeq else { return (state, ChainFailure(error: .linkSeq, seq: link.seq)) }
            guard link.prevLinkHash == state.linkHash else { return (state, ChainFailure(error: .linkPrevHash, seq: link.seq)) }

            if link.genesis && (state.genesisClosed || link.isLogKey) {
                return (state, ChainFailure(error: .genesisAfterClose, seq: link.seq))
            }
            if !link.genesis && !link.isLogKey { state.genesisClosed = true }

            if link.kind == .account {
                guard state.accounts[link.tag] == nil else { return (state, ChainFailure(error: .duplicateAccount, seq: link.seq)) }
                state.accounts[link.tag] = AccountLink(seq: link.seq, saltCommitment: link.hash)
            } else if link.isLogKey {
                guard let entryText = logKeyEntries[link.seq] else {
                    return (state, ChainFailure(error: .logKeyEntryMissing, seq: link.seq))
                }
                guard let parsed = parseEntry(entryText), parsed.entry.op == .logKey, parsed.entry.seq == link.seq,
                      digest(entryText) == link.hash,
                      case let .logKey(newLogKeyB64, signatureB64) = parsed.detail,
                      verify(
                        publicKeyB64: state.logKeyB64,
                        payload: Payload.logKey(seq: link.seq, oldLogKeyId: logKeyId(state.logKeyB64), newLogKeyB64: newLogKeyB64),
                        signatureB64: signatureB64
                      ) else {
                    return (state, ChainFailure(error: .logKeyEntryInvalid, seq: link.seq))
                }
                // Une ancienne clé volée ne doit pas pouvoir en installer une autre (§3.4, v2).
                guard newLogKeyB64 == state.nextLogKeysB64.first else {
                    return (state, ChainFailure(error: .logKeyNotPinned, seq: link.seq))
                }
                state.logKeyB64 = newLogKeyB64
                state.nextLogKeysB64.removeFirst()
            }
            state.seq = link.seq
            state.linkHash = digest(text)
        }
        return (state, nil)
    }

    /// Chaînage lu avant le format (révision 13) : la 4ᵉ ligne du texte coupé
    /// sur `\n`, si c'est un condensat. nil rompt le chaînage : non concluant.
    static func chainedPrevLinkHash(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 4, isDigest(lines[3]) else { return nil }
        return lines[3]
    }

    enum HeadComparison: Equatable, Sendable {
        case match
        /// La tête annonce des maillons pas encore lus : page suivante.
        case ahead
        case failure(ChainError)
    }

    /// La tête vérifiée doit prolonger l'état gardé : un `seq` plus petit est un
    /// retour en arrière, le même `seq` avec un autre condensat une fourche.
    static func compare(head: Head, to state: ChainState) -> HeadComparison {
        if head.seq < state.seq { return .failure(.rollback) }
        if head.seq == state.seq { return head.linkHash == state.linkHash ? .match : .failure(.fork) }
        return .ahead
    }

    // MARK: - Journal d'un compte (§3.2, §3.5 points 4 à 6, §6)

    enum DeviceStatus: String, Sendable, Equatable {
        case active = "ACTIVE"
        case pending = "PENDING"
        case revoked = "REVOKED"
    }

    /// Clé d'accord d'un appareil : `sinceMs` = `createdAtMs` de l'`ADD` (version 1) ou du `ROTATE` (§7.1).
    struct IdentityKey: Equatable, Sendable {
        let keyVersion: Int
        let identityKeyB64: String
        let sinceMs: Int64
    }

    struct DeviceState: Equatable, Sendable {
        let deviceId: String
        let platform: Platform
        var identityKeyB64: String
        let signingKeyB64: String
        var keyVersion: Int
        var status: DeviceStatus
        /// `createdAtMs` de l'entrée `ADD` ou `ADD_PENDING` (heure d'approbation v2 pour `GENESIS`).
        let addedAtMs: Int64
        /// `createdAtMs` de l'`ADD`, ou de l'`ACTIVATE` après un `ADD_PENDING` : destinataire
        /// depuis (§7.1). nil = jamais activé (en attente, ou révoqué sans `ACTIVATE`).
        var activatedAtMs: Int64?
        let addEntryHash: String
        /// Clés d'accord successives, pour lire un manifeste face au journal (§7.1).
        var identityKeys: [IdentityKey]
        var revokeReason: RevokeReason?
        var revokeSeq: Int64?
        var revokedAtMs: Int64?
    }

    /// Une entrée `HISTORY_KEY` vérifiée : la chaîne de HK (§5.6) et les rotations s'y lisent.
    struct HistoryKeyRecord: Equatable, Sendable {
        let seq: Int64
        let entryHash: String
        let hkPubB64: String
        let previousHkPubB64: String?
        let signerDeviceId: String
        /// `addedAtMs` du signataire : l'ancienneté de 24 h se juge à `createdAtMs` de l'entrée.
        let signerAddedAtMs: Int64
        let createdAtMs: Int64
        /// `seq` du dernier `REVOKE` (hors `ACCOUNT_DELETED`) que cette HK remplace.
        let afterRevokeSeq: Int64?
    }

    struct AccountState: Equatable, Sendable {
        let userId: String
        let accountTag: String
        var devices: [String: DeviceState]
        var historyKeyPubB64: String?
        var historyKeyEntryHash: String?
        var historyKeys: [HistoryKeyRecord]
        /// `REVOKE` vu depuis la dernière HK : une rotation est due (§5.6).
        var rotationDueRevokeSeq: Int64?
        var mode: Mode
        var lastEntryHash: String?
        var lastSeq: Int64
        /// `seq` de chaque entrée du compte, croissants : `memberLogSeqs` n'en cite qu'un (§7.1).
        var entrySeqs: [Int64]

        init(userId: String, accountSaltB64: String) {
            self.userId = userId
            accountTag = E2EEAutoLog.accountTag(userId: userId, accountSaltB64: accountSaltB64)
            devices = [:]
            historyKeyPubB64 = nil
            historyKeyEntryHash = nil
            historyKeys = []
            rotationDueRevokeSeq = nil
            mode = .normal
            lastEntryHash = nil
            lastSeq = 0
            entrySeqs = []
        }

        /// Appareils à qui envelopper une époque (§4.2, §6) : actifs seulement, jamais `PENDING`.
        var activeDevices: [DeviceState] {
            devices.values.filter { $0.status == .active }.sorted { $0.deviceId < $1.deviceId }
        }
    }

    enum AccountError: String, Error, Sendable {
        case accountLinkMissing = "ACCOUNT_LINK_MISSING"
        /// Sel `null` alors que le maillon `ACCOUNT` du compte existe sous la tête :
        /// le serveur tait le compte entier (§3.5 point 5).
        case accountWithheld = "ACCOUNT_WITHHELD"
        case accountSalt = "ACCOUNT_SALT"
        case entryFormat = "ENTRY_FORMAT"
        case entryNotInChain = "ENTRY_NOT_IN_CHAIN"
        case entryMissing = "ENTRY_MISSING"
        case entryBeforeAccount = "ENTRY_BEFORE_ACCOUNT"
        case entryUser = "ENTRY_USER"
        case entryHash = "ENTRY_HASH"
        case entryChain = "ENTRY_CHAIN"
        case entryTime = "ENTRY_TIME"
        case genesisMismatch = "GENESIS_MISMATCH"
        case deviceExists = "DEVICE_EXISTS"
        case deviceUnknown = "DEVICE_UNKNOWN"
        case deviceState = "DEVICE_STATE"
        case strictAdd = "STRICT_ADD"
        case keyVersion = "KEY_VERSION"
        case signer = "SIGNER"
        case signerTooRecent = "SIGNER_TOO_RECENT"
        case signature = "SIGNATURE"
        case strictNeedsTwoDevices = "STRICT_NEEDS_TWO_DEVICES"
    }

    struct AccountFailure: Error, Equatable, Sendable {
        let error: AccountError
        let seq: Int64?

        /// Un maillon du compte sans son entrée (§3.5 point 5) : le seul échec
        /// d'un compte qui alerte (révision 13), les autres le rendent illisible sans alerte.
        var isMissingLink: Bool { error == .entryMissing || error == .accountWithheld }
    }

    /// Vérifie le journal complet d'un compte contre la chaîne publique déjà
    /// vérifiée (§3.5) : sel engagé par l'unique maillon `ACCOUNT`, aucun maillon
    /// du compte absent ni placé avant lui, condensats, chaînage
    /// `prevUserEntryHash`, heures, puis chaque entrée et sa signature. `links` :
    /// tous les maillons vérifiés de 1 à la tête, par `seq`.
    static func verifyAccount(
        userId: String, accountSaltB64: String, entries: [String], links: [Int64: String], chain: ChainState
    ) -> Result<AccountState, AccountFailure> {
        func fail(_ error: AccountError, _ seq: Int64? = nil) -> Result<AccountState, AccountFailure> {
            .failure(AccountFailure(error: error, seq: seq))
        }
        guard E2EEV2Canonical.isOpaque(userId), isAccountSalt(accountSaltB64) else { return fail(.accountSalt) }
        guard let account = chain.accounts[accountId(userId: userId)] else {
            // Sel sans maillon `ACCOUNT` : toléré sans entrée, sinon échec à la première (révision 6).
            return entries.isEmpty
                ? .success(AccountState(userId: userId, accountSaltB64: accountSaltB64))
                : fail(.accountLinkMissing, entries.first.flatMap(parseEntry)?.entry.seq)
        }
        guard account.saltCommitment == saltCommitment(accountSaltB64: accountSaltB64) else { return fail(.accountSalt, account.seq) }

        let tag = accountTag(userId: userId, accountSaltB64: accountSaltB64)
        var taggedSeqs: [Int64] = []
        for (seq, text) in links.sorted(by: { $0.key < $1.key }) {
            guard let link = parseLink(text), link.kind == .entry, link.tag == tag else { continue }
            if seq < account.seq { return fail(.entryBeforeAccount, seq) }
            taggedSeqs.append(seq)
        }
        taggedSeqs.sort()

        // §3.5 (v2) : les maillons du compte dans l'ordre des `seq` ; le premier contrôle
        // qui échoue fixe le `seq` fautif.
        var state = AccountState(userId: userId, accountSaltB64: accountSaltB64)
        var lastNonGenesisMs: Int64 = -1
        for index in 0..<max(taggedSeqs.count, entries.count) {
            let text = index < entries.count ? entries[index] : nil
            let parsed = text.flatMap(parseEntry)
            guard index < taggedSeqs.count else { return fail(.entryNotInChain, parsed?.entry.seq) }
            let expectedSeq = taggedSeqs[index]
            guard let text else { return fail(.entryMissing, expectedSeq) }
            guard let (entry, detail) = parsed else { return fail(.entryFormat, expectedSeq) }
            guard entry.seq == expectedSeq else {
                return entry.seq < expectedSeq ? fail(.entryNotInChain, entry.seq) : fail(.entryMissing, expectedSeq)
            }
            guard entry.userId == userId, entry.op != .logKey else { return fail(.entryUser, entry.seq) }
            let entryHash = digest(text)
            guard let linkText = links[entry.seq], let link = parseLink(linkText), link.hash == entryHash else {
                return fail(.entryHash, entry.seq)
            }
            guard entry.prevUserEntryHash == (state.lastEntryHash ?? none) else { return fail(.entryChain, entry.seq) }
            let isGenesis = detail == .add(genesis: true)
            guard link.genesis == isGenesis else { return fail(.genesisMismatch, entry.seq) }
            if !isGenesis {
                guard entry.createdAtMs >= lastNonGenesisMs else { return fail(.entryTime, entry.seq) }
                lastNonGenesisMs = entry.createdAtMs
            }
            if let error = apply(entry, detail: detail, entryHash: entryHash, to: &state) { return fail(error, entry.seq) }
            state.lastEntryHash = entryHash
            state.lastSeq = entry.seq
            state.entrySeqs.append(entry.seq)
        }
        return .success(state)
    }

    private static func activeSigner(_ state: AccountState, _ signerDeviceId: String, atMs: Int64, requireAge: Bool) -> Result<DeviceState, AccountError> {
        guard let signer = state.devices[signerDeviceId], signer.status == .active else { return .failure(.signer) }
        if requireAge && atMs - signer.addedAtMs < signerMinAgeMs { return .failure(.signerTooRecent) }
        return .success(signer)
    }

    /// Applique une entrée à l'état du compte, ou rend l'erreur sans rien appliquer.
    private static func apply(_ entry: Entry, detail: Detail, entryHash: String, to state: inout AccountState) -> AccountError? {
        let prev = entry.prevUserEntryHash
        switch detail {
        case .add, .addPending:
            guard state.devices[entry.deviceId] == nil else { return .deviceExists }
            if detail == .add(genesis: false) && state.mode == .strict { return .strictAdd }
            guard let platform = Platform(rawValue: entry.platform), let keyVersion = Int(entry.keyVersion) else { return .deviceState }
            state.devices[entry.deviceId] = DeviceState(
                deviceId: entry.deviceId, platform: platform, identityKeyB64: entry.identityKeyB64,
                signingKeyB64: entry.signingKeyB64, keyVersion: keyVersion,
                status: detail == .addPending ? .pending : .active, addedAtMs: entry.createdAtMs,
                activatedAtMs: detail == .addPending ? nil : entry.createdAtMs,
                addEntryHash: entryHash,
                identityKeys: [IdentityKey(keyVersion: keyVersion, identityKeyB64: entry.identityKeyB64, sinceMs: entry.createdAtMs)],
                revokeReason: nil, revokeSeq: nil, revokedAtMs: nil
            )
            return nil

        case let .activate(approverDeviceId, signatureB64):
            guard var device = state.devices[entry.deviceId] else { return .deviceUnknown }
            guard device.status == .pending, device.platform.rawValue == entry.platform,
                  device.identityKeyB64 == entry.identityKeyB64, device.signingKeyB64 == entry.signingKeyB64,
                  String(device.keyVersion) == entry.keyVersion else { return .deviceState }
            let approver: DeviceState
            switch activeSigner(state, approverDeviceId, atMs: entry.createdAtMs, requireAge: true) {
            case let .success(signer): approver = signer
            case let .failure(error): return error
            }
            let payload = Payload.activate(
                userId: entry.userId, prevUserEntryHash: prev, approverDeviceId: approverDeviceId, deviceId: entry.deviceId,
                identityKeyB64: entry.identityKeyB64, signingKeyB64: entry.signingKeyB64, keyVersion: device.keyVersion
            )
            guard verify(publicKeyB64: approver.signingKeyB64, payload: payload, signatureB64: signatureB64) else { return .signature }
            device.status = .active
            device.activatedAtMs = entry.createdAtMs
            state.devices[entry.deviceId] = device
            return nil

        case let .rotate(signatureB64):
            guard var device = state.devices[entry.deviceId] else { return .deviceUnknown }
            guard device.status != .revoked else { return .deviceState }
            guard let keyVersion = Int(entry.keyVersion), keyVersion == device.keyVersion + 1 else { return .keyVersion }
            let payload = Payload.rotate(
                userId: entry.userId, prevUserEntryHash: prev, deviceId: entry.deviceId,
                newIdentityKeyB64: entry.identityKeyB64, keyVersion: keyVersion
            )
            guard verify(publicKeyB64: device.signingKeyB64, payload: payload, signatureB64: signatureB64) else { return .signature }
            device.identityKeyB64 = entry.identityKeyB64
            device.keyVersion = keyVersion
            device.identityKeys.append(IdentityKey(keyVersion: keyVersion, identityKeyB64: entry.identityKeyB64, sinceMs: entry.createdAtMs))
            state.devices[entry.deviceId] = device
            return nil

        case .signedRevoke, .serverRevoke:
            guard var device = state.devices[entry.deviceId] else { return .deviceUnknown }
            guard device.status != .revoked else { return .deviceState }
            let reason: RevokeReason
            switch detail {
            case let .signedRevoke(signedReason, revokerDeviceId, signatureB64):
                let revoker: DeviceState
                switch activeSigner(state, revokerDeviceId, atMs: entry.createdAtMs, requireAge: false) {
                case let .success(signer): revoker = signer
                case let .failure(error): return error
                }
                let payload = Payload.revoke(
                    userId: entry.userId, prevUserEntryHash: prev, revokerDeviceId: revokerDeviceId,
                    deviceId: entry.deviceId, reason: signedReason
                )
                guard verify(publicKeyB64: revoker.signingKeyB64, payload: payload, signatureB64: signatureB64) else { return .signature }
                reason = signedReason
            case let .serverRevoke(serverReason):
                reason = serverReason
            default:
                return .deviceState
            }
            device.status = .revoked
            device.revokeReason = reason
            device.revokeSeq = entry.seq
            device.revokedAtMs = entry.createdAtMs
            state.devices[entry.deviceId] = device
            if reason != .accountDeleted && state.historyKeyPubB64 != nil { state.rotationDueRevokeSeq = entry.seq }
            return nil

        case let .historyKey(signerDeviceId, hkPubB64, signatureB64):
            // Le premier appareil publie la première HK aussitôt ; ensuite, 24 h d'ancienneté (§5.1).
            let signer: DeviceState
            switch activeSigner(state, signerDeviceId, atMs: entry.createdAtMs, requireAge: state.historyKeyPubB64 != nil) {
            case let .success(device): signer = device
            case let .failure(error): return error
            }
            let payload = Payload.historyKey(
                userId: entry.userId, prevUserEntryHash: prev, signerDeviceId: signerDeviceId,
                previousHkPubB64: state.historyKeyPubB64, hkPubB64: hkPubB64
            )
            guard verify(publicKeyB64: signer.signingKeyB64, payload: payload, signatureB64: signatureB64) else { return .signature }
            state.historyKeys.append(HistoryKeyRecord(
                seq: entry.seq, entryHash: entryHash, hkPubB64: hkPubB64, previousHkPubB64: state.historyKeyPubB64,
                signerDeviceId: signerDeviceId, signerAddedAtMs: signer.addedAtMs, createdAtMs: entry.createdAtMs,
                afterRevokeSeq: state.rotationDueRevokeSeq
            ))
            state.historyKeyPubB64 = hkPubB64
            state.historyKeyEntryHash = entryHash
            state.rotationDueRevokeSeq = nil
            return nil

        case let .mode(signerDeviceId, mode, signatureB64):
            let signer: DeviceState
            switch activeSigner(state, signerDeviceId, atMs: entry.createdAtMs, requireAge: true) {
            case let .success(device): signer = device
            case let .failure(error): return error
            }
            if mode == .strict && state.devices.values.filter({ $0.status == .active }).count < 2 { return .strictNeedsTwoDevices }
            let payload = Payload.mode(userId: entry.userId, prevUserEntryHash: prev, signerDeviceId: signerDeviceId, mode: mode)
            guard verify(publicKeyB64: signer.signingKeyB64, payload: payload, signatureB64: signatureB64) else { return .signature }
            state.mode = mode
            return nil

        case .logKey:
            return .entryUser
        }
    }
}

/// Clé d'historique du compte (HK, contrat E2EE-AUTO §2.2 et §5.6) : scalaire
/// P-256 et preuve de possession avant une rotation.
enum E2EEAutoHistoryKey {
    /// Scalaire HK : exactement 32 octets big-endian, dans `[1, n − 1]`.
    static func isValidScalar(_ scalar: Data) -> Bool {
        guard scalar.count == 32, scalar.contains(where: { $0 != 0 }) else { return false }
        for (byte, limit) in zip(scalar, E2EEV2LowS.curveOrder) where byte != limit {
            return byte < limit
        }
        return false
    }

    /// Clé publique `b64` (X9.63) d'un scalaire HK : la vérification « HK
    /// correspond au journal » du §2.2.
    static func publicKeyB64(scalar: Data) -> String? {
        guard isValidScalar(scalar), let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar) else { return nil }
        return key.publicKey.x963Representation.base64EncodedString()
    }

    static func proofPayload(userId: String, deviceId: String, hkPubB64: String, revokeSeq: Int64) -> String {
        ["SQ-E2EE-AUTO-HK-PROOF", "1", userId, deviceId, hkPubB64, String(revokeSeq)].joined(separator: "\n")
    }

    /// Preuve de possession (§5.6, étape 3), signée par la clé HK elle-même.
    static func verifyProof(userId: String, deviceId: String, hkPubB64: String, revokeSeq: Int64, signatureB64: String) -> Bool {
        E2EEV2Canonical.isOpaque(userId)
            && E2EEV2Canonical.isOpaque(deviceId)
            && E2EEAutoLog.isPublicKey(hkPubB64)
            && revokeSeq >= 1
            && E2EEAutoLog.verify(
                publicKeyB64: hkPubB64,
                payload: proofPayload(userId: userId, deviceId: deviceId, hkPubB64: hkPubB64, revokeSeq: revokeSeq),
                signatureB64: signatureB64
            )
    }

    /// Règle de service d'une rotation de HK (§5.6 étape 4, révision 7), appliquée par
    /// l'émetteur : HK′ ne part qu'aux appareils `ACTIVE` du journal vérifié, hors lui-même,
    /// dont la preuve se vérifie avec la HK précédente et le `revokeSeq` de la rotation.
    /// `deviceId` triés par octets, sans doublon.
    static func servedDevices(
        state: E2EEAutoLog.AccountState, rotation: E2EEAutoLog.HistoryKeyRecord,
        proofs: [(deviceId: String, signatureB64: String)], selfDeviceId: String
    ) -> [String] {
        guard let previousHkPubB64 = rotation.previousHkPubB64, let revokeSeq = rotation.afterRevokeSeq else { return [] }
        var served = Set<String>()
        for proof in proofs where proof.deviceId != selfDeviceId && state.devices[proof.deviceId]?.status == .active {
            if verifyProof(userId: state.userId, deviceId: proof.deviceId, hkPubB64: previousHkPubB64,
                           revokeSeq: revokeSeq, signatureB64: proof.signatureB64) {
                served.insert(proof.deviceId)
            }
        }
        return served.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Produit la preuve avec le scalaire HK. Refuse un scalaire qui ne
    /// correspond pas à `hkPubB64` : une preuve pour une autre clé ne servirait à rien.
    static func signProof(userId: String, deviceId: String, hkPubB64: String, revokeSeq: Int64, scalar: Data) -> String? {
        guard publicKeyB64(scalar: scalar) == hkPubB64,
              E2EEV2Canonical.isOpaque(userId), E2EEV2Canonical.isOpaque(deviceId), revokeSeq >= 1,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar),
              let signature = try? E2EEV2LowS.sign(
                Data(proofPayload(userId: userId, deviceId: deviceId, hkPubB64: hkPubB64, revokeSeq: revokeSeq).utf8),
                with: key
              ) else { return nil }
        return signature.base64EncodedString()
    }
}
