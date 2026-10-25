import CryptoKit
import Foundation

/// Réponses des deux routes de lecture du journal (E2EE-AUTO §3.5, forme des
/// routes de la phase 2). Le contenu signé (maillons, entrées, tête) est lu et
/// vérifié par `E2EEAutoLog` ; ici, seulement l'enveloppe JSON.
enum E2EEAutoLogPages {
    /// 1 000 maillons ou entrées par page au plus.
    static let maxPageItems = 1_000

    struct Links: Equatable, Sendable {
        /// `seq` `after + 1` et suivants, croissants.
        let links: [String]
        /// Entrées `LOG_KEY` jointes aux maillons de tag `-` de la page, par `seq`.
        let logKeyEntries: [Int64: String]
        /// La tête courante ; seule celle de la dernière page compte.
        let headText: String
        let headSignatureB64: String
        let hasMore: Bool
    }

    struct Account: Equatable, Sendable {
        /// nil (et aucune entrée) : compte sans maillon `ACCOUNT`, pas encore passé en auto.
        let accountSaltB64: String?
        let entries: [String]
        let hasMore: Bool
    }

    static func parseLinks(_ data: Data) -> Links? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let links = root["links"] as? [String], links.count <= maxPageItems,
              let rawEntries = root["logKeyEntries"] as? [String: String],
              let head = root["head"] as? [String: Any],
              let headText = head["text"] as? String,
              let headSignatureB64 = head["signatureB64"] as? String,
              let hasMore = boolean(root["hasMore"]) else { return nil }
        var logKeyEntries: [Int64: String] = [:]
        for (key, entry) in rawEntries {
            guard let seq = E2EEAutoLog.decimal(key, in: 1...E2EEV2Canonical.maxSafeInteger) else { return nil }
            logKeyEntries[seq] = entry
        }
        return Links(links: links, logKeyEntries: logKeyEntries, headText: headText, headSignatureB64: headSignatureB64, hasMore: hasMore)
    }

    static func parseAccount(_ data: Data, userId: String) -> Account? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["userId"] as? String == userId,
              let entries = root["entries"] as? [String], entries.count <= maxPageItems,
              let hasMore = boolean(root["hasMore"]) else { return nil }
        switch root["accountSaltB64"] {
        case let salt as String:
            return Account(accountSaltB64: salt, entries: entries, hasMore: hasMore)
        case is NSNull:
            guard entries.isEmpty, !hasMore else { return nil }
            return Account(accountSaltB64: nil, entries: [], hasMore: false)
        default:
            return nil
        }
    }

    /// Un vrai booléen JSON : `JSONSerialization` rend aussi 0 et 1 en `NSNumber`.
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// Ce que cet appareil garde du journal, par compte connecté (§3.5) : la
/// dernière tête vérifiée dans le trousseau, qui fait foi contre un retour en
/// arrière ; les maillons et les entrées lus dans un fichier scellé, simple
/// cache que le trousseau valide. Sur le modèle de `E2EEV2MessageStoreV2`.
final class E2EEAutoLogStore: @unchecked Sendable {
    static let keyService = "fr.signalquest.ios.e2ee-auto-log"
    static let anchorPrefix = "auto-log-head-v1"

    /// Dernière tête vérifiée, et l'alerte de sécurité levée, qui ne se lève
    /// jamais seule (§3.5).
    struct Anchor: Codable, Equatable, Sendable {
        let seq: Int64
        let linkHash: String
        let headCreatedAtMs: Int64
        var alert: Alert?
        /// Dernière comparaison avec la tête de la sonde (§3.7), une fois par jour au plus.
        var probeCheckedAtMs: Int64?
    }

    struct Alert: Codable, Equatable, Sendable {
        let error: String
        let seq: Int64
    }

    struct AccountFile: Codable, Equatable, Sendable {
        let accountSaltB64: String?
        let entries: [String]
    }

    struct LogFile: Codable, Equatable, Sendable {
        var version = 1
        /// Maillons de 1 à la tête gardée, dans l'ordre.
        var links: [String] = []
        /// Entrées `LOG_KEY`, par `seq` décimal.
        var logKeyEntries: [String: String] = [:]
        var accounts: [String: AccountFile] = [:]
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let keyStore: TokenStore
    private let anchorStore: TokenStore
    private static let lock = NSLock()

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        keyStore: TokenStore = KeychainStore(service: keyService),
        anchorStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee")
    ) {
        self.fileManager = fileManager
        self.keyStore = keyStore
        self.anchorStore = anchorStore
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.rootURL = support
                .appendingPathComponent("SignalQuestPrivate", isDirectory: true)
                .appendingPathComponent("e2ee-auto-log", isDirectory: true)
        }
    }

    func anchor(ownerScopeId: String) throws -> Anchor? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let raw = try anchorStore.string(for: Self.anchorKey(ownerScopeId)) else { return nil }
        return try JSONDecoder().decode(Anchor.self, from: Data(raw.utf8))
    }

    func saveAnchor(_ anchor: Anchor, ownerScopeId: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let value = String(decoding: try JSONEncoder().encode(anchor), as: UTF8.self)
        try anchorStore.set(value, for: Self.anchorKey(ownerScopeId), accessibility: .afterFirstUnlock)
    }

    /// Le fichier gardé ; vide s'il manque ou ne s'ouvre pas (il sera relu).
    func load(ownerScopeId: String) -> LogFile {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let url = fileURL(ownerScopeId: ownerScopeId)
        guard fileManager.fileExists(atPath: url.path),
              let key = try? sealingKey(ownerScopeId: ownerScopeId, create: false),
              let box = try? AES.GCM.SealedBox(combined: Data(contentsOf: url)),
              let clear = try? AES.GCM.open(box, using: key, authenticating: Data(ownerScopeId.utf8)),
              let file = try? JSONDecoder().decode(LogFile.self, from: clear), file.version == 1 else { return LogFile() }
        return file
    }

    func save(_ file: LogFile, ownerScopeId: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let url = fileURL(ownerScopeId: ownerScopeId)
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var root = rootURL
            try? root.setResourceValues(values)
        }
        guard let key = try sealingKey(ownerScopeId: ownerScopeId, create: true) else {
            throw E2EEV2ConversationStateStore.Failure.invalidRecord
        }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(file), using: key, authenticating: Data(ownerScopeId.utf8))
        guard let combined = sealed.combined else { throw E2EEV2ConversationStateStore.Failure.invalidRecord }
        try combined.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func purge(ownerScopeId: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let url = fileURL(ownerScopeId: ownerScopeId)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try keyStore.remove(Self.digest(ownerScopeId))
        try anchorStore.remove(Self.anchorKey(ownerScopeId))
    }

    /// Lisible après le premier déverrouillage : le journal se relit en arrière-plan.
    private func sealingKey(ownerScopeId: String, create: Bool) throws -> SymmetricKey? {
        let name = Self.digest(ownerScopeId)
        if let stored = try keyStore.string(for: name), let data = Data(base64Encoded: stored), data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        try keyStore.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: name, accessibility: .afterFirstUnlock)
        return key
    }

    private func fileURL(ownerScopeId: String) -> URL {
        rootURL.appendingPathComponent(Self.digest(ownerScopeId) + ".sealed")
    }

    private static func anchorKey(_ ownerScopeId: String) -> String {
        "\(anchorPrefix):\(digest(ownerScopeId))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Lit et vérifie le journal pour le compte connecté (§3.5) : maillons depuis
/// la tête gardée, tête signée et son âge à l'horloge locale non corrigée
/// (§3.4), puis les entrées des comptes demandés. Une fourche ou un retour en
/// arrière lève une alerte gardée, que rien ne lève seul.
actor E2EEAutoLogReader {
    enum Status: Equatable, Sendable {
        case current(E2EEAutoLog.Head)
        /// Tête valide mais hors de l'âge accepté : aucune alerte, aucun nouveau
        /// destinataire, nouvel essai plus tard (§3.4).
        case notCurrent(E2EEAutoLog.Head)
        /// Alerte de sécurité gardée (fourche, retour en arrière).
        case alert(E2EEAutoLogStore.Alert)
    }

    enum Failure: Error, Equatable {
        /// Réponse illisible, page incohérente ou tête invalide : rien n'est adopté.
        case malformed
        case invalidChain(E2EEAutoLog.ChainFailure)
        case invalidHead(E2EEAutoLog.HeadError)
        /// Les entrées d'un compte se lisent après les maillons.
        case linksNotRead
    }

    /// Au-delà de 100 000 maillons, le contrat passe à un arbre de Merkle (§3.5).
    static let maxLinkPages = 100
    static let maxAccountPages = 20

    /// Clé du journal épinglée et clés suivantes (§3.4) : posées avec la clé de
    /// prod, que génère Alexandre. Sans elles, pas de lecteur.
    static let productionLogKeys: (current: String, next: [String])? = nil

    typealias FetchLinks = @Sendable (_ after: Int64) async throws -> (data: Data, serverDate: Date?)
    /// nil : compte non servi (404).
    typealias FetchAccount = @Sendable (_ userId: String, _ after: Int64) async throws -> Data?

    private let ownerScopeId: String
    private let pinnedLogKeyB64: String
    private let nextLogKeysB64: [String]
    private let store: E2EEAutoLogStore
    private let fetchLinks: FetchLinks
    private let fetchAccount: FetchAccount
    private let now: @Sendable () -> Date

    private var chain: E2EEAutoLog.ChainState?
    private var linksBySeq: [Int64: String] = [:]
    /// Horloge du serveur moins l'horloge locale, mesurée sur l'en-tête `Date`
    /// des maillons : sert seulement à dater un manifeste (§7.1).
    private(set) var clockOffsetMs: Int64?

    init(
        ownerScopeId: String,
        pinnedLogKeyB64: String,
        nextLogKeysB64: [String],
        store: E2EEAutoLogStore = E2EEAutoLogStore(),
        fetchLinks: @escaping FetchLinks,
        fetchAccount: @escaping FetchAccount,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.ownerScopeId = ownerScopeId
        self.pinnedLogKeyB64 = pinnedLogKeyB64
        self.nextLogKeysB64 = nextLogKeysB64
        self.store = store
        self.fetchLinks = fetchLinks
        self.fetchAccount = fetchAccount
        self.now = now
    }

    /// Lecteur de la session courante, par les routes `log/*` lues par session.
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) -> E2EEAutoLogReader? {
        guard let keys = productionLogKeys, session.ownerScopeId.hasPrefix("user:") else { return nil }
        let owner = session.ownerScopeId
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        return E2EEAutoLogReader(
            ownerScopeId: owner, pinnedLogKeyB64: keys.current, nextLogKeysB64: keys.next,
            fetchLinks: { after in
                let read = await transport.getSessionJSONWithServerDate(
                    path: "/api/e2ee/auto/log/links", query: [URLQueryItem(name: "after", value: String(after))],
                    expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle
                )
                switch read.result {
                case .success(let value, _, _): return (value, read.serverDate)
                case .failure(let failure): throw failure
                }
            },
            fetchAccount: { userId, after in
                guard E2EEV2Canonical.isOpaque(userId) else { return nil }
                let result = await transport.getSessionJSON(
                    path: "/api/e2ee/auto/log/accounts/\(userId)", query: [URLQueryItem(name: "after", value: String(after))],
                    expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle
                )
                switch result {
                case .success(let value, _, _): return value
                case .failure(let failure) where failure.statusCode == 404: return nil
                case .failure(let failure): throw failure
                }
            }
        )
    }

    private var nowMs: Int64 { Int64((now().timeIntervalSince1970 * 1_000).rounded(.down)) }

    /// Horloge corrigée de l'écart mesuré : pour dater un manifeste et le
    /// contrôle « plus de `T` dans le futur » seulement, jamais pour l'âge de la tête.
    func correctedNowMs() -> Int64 { nowMs + (clockOffsetMs ?? 0) }

    // MARK: Maillons et tête

    func refreshLinks() async throws -> Status {
        let anchor = try store.anchor(ownerScopeId: ownerScopeId)
        if let alert = anchor?.alert { return .alert(alert) }
        var file = store.load(ownerScopeId: ownerScopeId)
        let state = rebuiltChain(file, anchor: anchor)
        if state == nil { file = E2EEAutoLogStore.LogFile() }
        var chainState = state ?? .initial(pinnedLogKeyB64: pinnedLogKeyB64, nextLogKeysB64: nextLogKeysB64)

        for _ in 0..<Self.maxLinkPages {
            let (data, serverDate) = try await fetchLinks(chainState.seq)
            let receivedAtMs = nowMs
            guard let page = E2EEAutoLogPages.parseLinks(data) else { throw Failure.malformed }
            switch E2EEAutoLog.extendChain(chainState, links: page.links, logKeyEntries: page.logKeyEntries) {
            case .success(let extended):
                chainState = extended
            case .failure(let failure) where failure.error == .linkPrevHash && failure.seq == chainState.seq + 1:
                // Le serveur ne prolonge pas ce qui est gardé : une autre histoire.
                return try raise(.init(error: .fork, seq: chainState.seq), anchor: anchor)
            case .failure(let failure):
                throw Failure.invalidChain(failure)
            }
            file.links += page.links
            for (seq, entry) in page.logKeyEntries { file.logKeyEntries[String(seq)] = entry }
            if page.hasMore {
                guard !page.links.isEmpty else { throw Failure.malformed }
                continue
            }
            if let serverDate { clockOffsetMs = Int64((serverDate.timeIntervalSince1970 * 1_000).rounded(.down)) - receivedAtMs }
            let check = E2EEAutoLog.checkHead(
                text: page.headText, signatureB64: page.headSignatureB64, logKeyB64: chainState.logKeyB64, nowMs: receivedAtMs
            )
            let head: E2EEAutoLog.Head
            switch check {
            case .ok(let verified), .stale(let verified): head = verified
            case .invalid(let error): throw Failure.invalidHead(error)
            }
            switch E2EEAutoLog.compare(head: head, to: chainState) {
            case .match: break
            case .ahead: throw Failure.malformed
            case .failure(let error): return try raise(.init(error: error, seq: head.seq), anchor: anchor)
            }
            // Le fichier perdu a été relu depuis 1 : la tête gardée doit en faire partie.
            if let anchor, state == nil {
                guard anchor.seq <= chainState.seq else { return try raise(.init(error: .rollback, seq: chainState.seq), anchor: anchor) }
                let kept = anchor.seq == 0 ? E2EEAutoLog.genesisHash : E2EEAutoLog.digest(file.links[Int(anchor.seq) - 1])
                guard kept == anchor.linkHash else { return try raise(.init(error: .fork, seq: anchor.seq), anchor: anchor) }
            }
            try store.save(file, ownerScopeId: ownerScopeId)
            try store.saveAnchor(
                .init(seq: head.seq, linkHash: head.linkHash, headCreatedAtMs: head.createdAtMs, probeCheckedAtMs: anchor?.probeCheckedAtMs),
                ownerScopeId: ownerScopeId
            )
            chain = chainState
            linksBySeq = Dictionary(uniqueKeysWithValues: file.links.enumerated().map { (Int64($0.offset + 1), $0.element) })
            if case .ok = check { return .current(head) }
            return .notCurrent(head)
        }
        throw Failure.malformed
    }

    /// La chaîne du fichier gardé, si elle mène exactement à la tête du trousseau.
    private func rebuiltChain(_ file: E2EEAutoLogStore.LogFile, anchor: E2EEAutoLogStore.Anchor?) -> E2EEAutoLog.ChainState? {
        guard let anchor, Int64(file.links.count) == anchor.seq else { return nil }
        var entries: [Int64: String] = [:]
        for (key, entry) in file.logKeyEntries {
            guard let seq = Int64(key) else { return nil }
            entries[seq] = entry
        }
        let initial = E2EEAutoLog.ChainState.initial(pinnedLogKeyB64: pinnedLogKeyB64, nextLogKeysB64: nextLogKeysB64)
        guard case .success(let state) = E2EEAutoLog.extendChain(initial, links: file.links, logKeyEntries: entries),
              state.seq == anchor.seq, state.linkHash == anchor.linkHash else { return nil }
        return state
    }

    private func raise(_ failure: E2EEAutoLog.ChainFailure, anchor: E2EEAutoLogStore.Anchor?) throws -> Status {
        let alert = E2EEAutoLogStore.Alert(error: failure.error.rawValue, seq: failure.seq)
        var kept = anchor ?? .init(seq: 0, linkHash: E2EEAutoLog.genesisHash, headCreatedAtMs: 0)
        kept.alert = alert
        try store.saveAnchor(kept, ownerScopeId: ownerScopeId)
        return .alert(alert)
    }

    // MARK: Comptes

    /// Le journal vérifié d'un compte, sur les maillons de la dernière lecture.
    /// nil : compte non servi (404). Un refus n'écrit rien.
    func account(_ userId: String) async throws -> Result<E2EEAutoLog.AccountState, E2EEAutoLog.AccountFailure>? {
        guard let chain else { throw Failure.linksNotRead }
        var file = store.load(ownerScopeId: ownerScopeId)
        let kept = file.accounts[userId]
        var salt = kept?.accountSaltB64
        var entries = kept?.entries ?? []
        var after = entries.last.flatMap { E2EEAutoLog.parseEntry($0)?.entry.seq } ?? 0
        // Les entrées gardées au-delà de la chaîne lue (fichier d'un autre état) sont relues.
        if after > chain.seq { (entries, after) = ([], 0) }

        for _ in 0..<Self.maxAccountPages {
            guard let data = try await fetchAccount(userId, after) else { return nil }
            guard let page = E2EEAutoLogPages.parseAccount(data, userId: userId) else { throw Failure.malformed }
            salt = page.accountSaltB64
            entries += page.entries
            if page.hasMore {
                guard let last = page.entries.last.flatMap({ E2EEAutoLog.parseEntry($0)?.entry.seq }), last > after else {
                    throw Failure.malformed
                }
                after = last
                continue
            }
            let result: Result<E2EEAutoLog.AccountState, E2EEAutoLog.AccountFailure>
            if let salt {
                result = E2EEAutoLog.verifyAccount(userId: userId, accountSaltB64: salt, entries: entries, links: linksBySeq, chain: chain)
            } else if let link = chain.accounts[E2EEAutoLog.accountId(userId: userId)] {
                // Le maillon `ACCOUNT` existe, le serveur tait le compte.
                result = .failure(.init(error: .accountLinkMissing, seq: link.seq))
            } else {
                return .success(E2EEAutoLog.AccountState(userId: userId, accountSaltB64: Self.emptySalt))
            }
            if case .success = result {
                file.accounts[userId] = .init(accountSaltB64: salt, entries: entries)
                try store.save(file, ownerScopeId: ownerScopeId)
            }
            return result
        }
        throw Failure.malformed
    }

    /// Sel d'un compte sans maillon `ACCOUNT` : son état vide ne sert qu'à dire « aucun appareil ».
    static let emptySalt = Data(count: 16).base64EncodedString()

    // MARK: Sonde (§3.7)

    enum ProbeComparison: Equatable, Sendable {
        case agree
        /// La sonde a vu plus loin : relire les maillons, puis comparer de nouveau.
        case behind
        /// Même `seq`, autre condensat : même alerte qu'une fourche.
        case fork
    }

    /// Tête de la sonde face aux maillons vérifiés ici. Après une relecture, une
    /// sonde encore en avance alors que la tête d'ici n'est plus à jour vaut une
    /// fourche (§3.4) : c'est à l'appelant d'en juger.
    func compareProbe(seq: Int64, linkHash: String) -> ProbeComparison {
        guard let chain, seq <= chain.seq else { return .behind }
        let ours = seq == 0 ? E2EEAutoLog.genesisHash : linksBySeq[seq].map(E2EEAutoLog.digest)
        return ours == linkHash ? .agree : .fork
    }
}
