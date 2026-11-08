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
        /// Maillon d'un contact sans son entrée, par `userId` : ce contact seul ne
        /// reçoit plus rien, et rien ne lève l'alerte seul (§3.5 point 5).
        var accountAlerts: [String: Alert]?
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
        /// `429` d'une route du journal : aucun appel avant l'heure dite (révision 13).
        case rateLimited
    }

    /// Les deux routes partagent le quota de lecture du compte ; `log/accounts`
    /// a en plus son quota de comptes (`429 E2EE_AUTO_ACCOUNT_QUOTA`).
    enum Quota: String, CaseIterable, Sendable {
        case reads
        case accounts
    }

    /// Sans `Retry-After` lisible, l'app attend une heure (révision 13).
    static let defaultRetrySeconds = 3_600

    /// Au-delà de 100 000 maillons, le contrat passe à un arbre de Merkle (§3.5).
    static let maxLinkPages = 100
    static let maxAccountPages = 20

    /// Clé du journal épinglée et clé suivante (§3.4), en X9.63 base64 : tirées
    /// par Alexandre le 26/10 (logKeyId `pMHQt1dV…` et `hL8oRK4X…`). Le lecteur
    /// reste coupé tant que `SQFeatures.e2eeAutoLogEnabled` est fermé.
    static let productionLogKeys: (current: String, next: [String])? = (
        current: "BCaJETLIVIYzLKqloGCh3ORVJDBqye6azjdY77hDMSCiUCBLgJSTwuWPrlmM8mCtgj0zlZBm3DKQwHn2MKEtYho=",
        next: ["BF5ImQG7MrKenFAYOmzOSOrjRBAS6W14Lv/KlOQiv0ARjQtrP7HYUBfvLRug6WBvd0vJ32L07KU7+b87PvXXwm8="]
    )

    /// Clés épinglées par le lecteur en service : celles de production, sauf
    /// sur la pile QA locale, qui sert le journal des vecteurs du contrat
    /// (`AppEnvironment.pinsAutoLogVectorKeysQA`, simulateur Debug seulement).
    static var liveLogKeys: (current: String, next: [String])? {
        #if DEBUG && targetEnvironment(simulator)
        if AppEnvironment.pinsAutoLogVectorKeysQA {
            return (
                current: "BIrx4dBr9DqJJZBauOvSYPcwkjmlcN4621RM4+9XNc2fHkuT9JRrH2vSFZcRUlCf5e2WY4ydg/AGZdUyrUVRvnQ=",
                next: ["BAiH9ZnXqJSoqkIKdvmI9dOIRhRcjPm+3lVsuU96TEUEn3RcvKb2LRN9eTHK6M6GbsY30g3zda+GwTg3D6MiwHc="]
            )
        }
        #endif
        return productionLogKeys
    }

    typealias FetchLinks = @Sendable (_ after: Int64) async throws -> (data: Data, serverDate: Date?)
    /// Entrées de seq dans `]after, upTo]` ; nil : compte non servi (404).
    typealias FetchAccount = @Sendable (_ userId: String, _ after: Int64, _ upTo: Int64) async throws -> Data?
    /// Fichier de la sonde ; nil : absent, injoignable ou refusé (§7.8 E5).
    typealias FetchProbe = @Sendable () async -> Data?

    let ownerScopeId: String
    private let pinnedLogKeyB64: String
    private let nextLogKeysB64: [String]
    private let store: E2EEAutoLogStore
    private let fetchLinks: FetchLinks
    private let fetchAccount: FetchAccount
    private let fetchProbe: FetchProbe
    private let probeKeys: [String: String]
    private let now: @Sendable () -> Date
    /// Heure de fin d'attente après un `429`, par quota : survit au relancement.
    private let defaults: UserDefaults

    private var chain: E2EEAutoLog.ChainState?
    private var linksBySeq: [Int64: String] = [:]
    /// Horloge du serveur moins l'horloge locale, mesurée sur l'en-tête `Date`
    /// des maillons : sert seulement à dater un manifeste (§7.1).
    private(set) var clockOffsetMs: Int64?
    /// Appareils apparus depuis la dernière lecture vérifiée de leur compte
    /// (`ADD` hors `GENESIS`, `ACTIVATE`), par compte : repris par `takeAddedDevices`.
    private var addedDevices: [String: Set<String>] = [:]
    private var checkingProbe = false

    init(
        ownerScopeId: String,
        pinnedLogKeyB64: String,
        nextLogKeysB64: [String],
        store: E2EEAutoLogStore = E2EEAutoLogStore(),
        fetchLinks: @escaping FetchLinks,
        fetchAccount: @escaping FetchAccount,
        fetchProbe: @escaping FetchProbe = { nil },
        probeKeys: [String: String] = E2EEAutoProbeHead.pinnedKeys,
        now: @escaping @Sendable () -> Date = Date.init,
        defaults: UserDefaults = .standard
    ) {
        self.ownerScopeId = ownerScopeId
        self.pinnedLogKeyB64 = pinnedLogKeyB64
        self.nextLogKeysB64 = nextLogKeysB64
        self.store = store
        self.fetchLinks = fetchLinks
        self.fetchAccount = fetchAccount
        self.fetchProbe = fetchProbe
        self.probeKeys = probeKeys
        self.now = now
        self.defaults = defaults
    }

    /// Lecteur de la session courante, par les routes `log/*` lues par session.
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) -> E2EEAutoLogReader? {
        guard let keys = liveLogKeys, session.ownerScopeId.hasPrefix("user:") else { return nil }
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
            fetchAccount: { userId, after, upTo in
                guard E2EEV2Canonical.isOpaque(userId) else { return nil }
                let result = await transport.getSessionJSON(
                    path: "/api/e2ee/auto/log/accounts/\(userId)",
                    query: [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "upTo", value: String(upTo))],
                    expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle
                )
                switch result {
                case .success(let value, _, _): return value
                case .failure(let failure) where isAccountNotFound(failure): return nil
                case .failure(let failure): throw failure
                }
            },
            fetchProbe: fetchProbeHead
        )
    }

    static let maxProbeBytes = 16_384

    /// GET de la sonde, hors session : sans cookie ni cache, `200` seulement.
    @Sendable static func fetchProbeHead() async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: E2EEAutoProbeHead.url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxProbeBytes else { return nil }
        return data
    }

    /// Seul ce code est décisif ; tout autre `404` de `log/accounts` est non concluant (révision 13).
    static func isAccountNotFound(_ failure: E2EEV2TransportFailure) -> Bool {
        failure.statusCode == 404 && failure.code == "E2EE_AUTO_ACCOUNT_NOT_FOUND"
    }

    private var nowMs: Int64 { Int64((now().timeIntervalSince1970 * 1_000).rounded(.down)) }

    /// Horloge corrigée de l'écart mesuré : pour dater un manifeste et le
    /// contrôle « plus de `T` dans le futur » seulement, jamais pour l'âge de la tête.
    func correctedNowMs() -> Int64 { nowMs + (clockOffsetMs ?? 0) }

    // MARK: Quotas (révision 13)

    private func retryKey(_ quota: Quota) -> String {
        let owner = SHA256.hash(data: Data(ownerScopeId.utf8)).map { String(format: "%02x", $0) }.joined()
        return "e2ee-auto-log-retry-v1:\(quota.rawValue):\(owner)"
    }

    /// Fin de l'attente d'un quota, si elle n'est pas passée.
    func retryAtMs(_ quota: Quota) -> Int64? {
        let until = Int64(defaults.double(forKey: retryKey(quota)))
        return until > nowMs ? until : nil
    }

    private func checkQuotas(_ quotas: [Quota]) throws {
        if quotas.contains(where: { retryAtMs($0) != nil }) { throw Failure.rateLimited }
    }

    /// Un `429` est non concluant : il retient l'appel suivant jusqu'à `Retry-After`,
    /// ou une heure sans lui. Les autres erreurs passent telles quelles.
    private func throttled<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let failure as E2EEV2TransportFailure where failure.statusCode == 429 {
            let quota: Quota = failure.code == "E2EE_AUTO_ACCOUNT_QUOTA" ? .accounts : .reads
            let seconds = min(max(failure.retryAfterSeconds ?? Self.defaultRetrySeconds, 1), 86_400)
            defaults.set(Double(nowMs + Int64(seconds) * 1_000), forKey: retryKey(quota))
            throw Failure.rateLimited
        }
    }

    // MARK: Maillons et tête

    func refreshLinks() async throws -> Status {
        let anchor = try store.anchor(ownerScopeId: ownerScopeId)
        if let alert = anchor?.alert { return .alert(alert) }
        try checkQuotas([.reads])
        var file = store.load(ownerScopeId: ownerScopeId)
        let state = rebuiltChain(file, anchor: anchor)
        if state == nil { file = E2EEAutoLogStore.LogFile() }
        var chainState = state ?? .initial(pinnedLogKeyB64: pinnedLogKeyB64, nextLogKeysB64: nextLogKeysB64)
        // Chaîne partie de la tête gardée ; sinon relue depuis 1, et la tête gardée se contrôle à la fin.
        var fromKept = state != nil
        var previousHeadSeq: Int64?
        // Le chaînage se lit avant le format (révision 13) : nombre et condensat des
        // maillons reçus, quel que soit leur texte, puis la première faute du §3.3
        // avec l'état au dernier maillon admis.
        var received = (seq: chainState.seq, linkHash: chainState.linkHash)
        var invalid: (failure: E2EEAutoLog.ChainFailure, state: E2EEAutoLog.ChainState)?

        pages: for _ in 0..<Self.maxLinkPages {
            let (data, serverDate) = try await throttled { try await fetchLinks(received.seq) }
            let receivedAtMs = nowMs
            guard let page = E2EEAutoLogPages.parseLinks(data) else { throw Failure.malformed }
            // La tête peut avancer d'une page à l'autre, jamais reculer (révision 6).
            let after = received.seq
            if let headSeq = E2EEAutoLog.parseHead(page.headText)?.seq {
                if let previousHeadSeq, headSeq < previousHeadSeq { throw Failure.malformed }
                previousHeadSeq = headSeq
                // Page qui contredit sa tête : non concluante. Une page vide sous `after` va à la
                // vérification : valide, c'est un retour en arrière (révision 6).
                if page.links.isEmpty ? headSeq > after : headSeq <= after { throw Failure.malformed }
            }
            var linkHash = received.linkHash
            for (offset, text) in page.links.enumerated() {
                guard E2EEAutoLog.chainedPrevLinkHash(text) == linkHash else {
                    if offset == 0, fromKept, after == state?.seq {
                        // Le serveur ne prolonge pas la tête gardée. Fourche seulement si une tête vérifiée
                        // le prouve (révision 6) : relecture depuis 1, puis contrôle de la tête gardée.
                        (file, chainState, fromKept) = (E2EEAutoLogStore.LogFile(), .initial(pinnedLogKeyB64: pinnedLogKeyB64, nextLogKeysB64: nextLogKeysB64), false)
                        received = (chainState.seq, chainState.linkHash)
                        continue pages
                    }
                    // Chaînage rompu : la tête ne prouve rien sur ces maillons, non concluant.
                    throw Failure.invalidChain(.init(error: .linkPrevHash, seq: after + Int64(offset) + 1))
                }
                linkHash = E2EEAutoLog.digest(text)
            }
            received = (after + Int64(page.links.count), linkHash)
            if invalid == nil {
                let extended = E2EEAutoLog.extendChainPartially(chainState, links: page.links, logKeyEntries: page.logKeyEntries)
                chainState = extended.state
                if let failure = extended.failure {
                    invalid = (failure, extended.state)
                } else {
                    // Exactement une entrée `LOG_KEY` par maillon de tag `-` de la page, pas une de plus.
                    let logKeySeqs = Set(page.links.compactMap(E2EEAutoLog.parseLink).filter(\.isLogKey).map(\.seq))
                    if let extra = Set(page.logKeyEntries.keys).subtracting(logKeySeqs).min() {
                        // Sans maillon, rien ne s'enchaîne : non concluant.
                        guard !page.links.isEmpty else { throw Failure.malformed }
                        invalid = (.init(error: .logKeyEntryInvalid, seq: extra), extended.state)
                    }
                    file.links += page.links
                    for (seq, entry) in page.logKeyEntries { file.logKeyEntries[String(seq)] = entry }
                }
            }
            if page.hasMore {
                // `hasMore` si et seulement si le dernier maillon précède la tête.
                guard !page.links.isEmpty, let headSeq = previousHeadSeq, received.seq < headSeq else { throw Failure.malformed }
                continue
            }
            let headSeq = E2EEAutoLog.parseHead(page.headText)?.seq
            // Un dernier maillon autre que la tête : page incohérente, pas un retour en arrière.
            if !page.links.isEmpty && headSeq != received.seq { throw Failure.malformed }
            if let serverDate { clockOffsetMs = Int64((serverDate.timeIntervalSince1970 * 1_000).rounded(.down)) - receivedAtMs }
            if let invalid {
                // La tête engage ces maillons si elle les termine, signée par la clé en vigueur
                // au dernier maillon admis et à jour : alerte « chaîne invalide », comme une fourche.
                guard headSeq == received.seq,
                      case .ok(let head) = E2EEAutoLog.checkHead(
                        text: page.headText, signatureB64: page.headSignatureB64, logKeyB64: invalid.state.logKeyB64, nowMs: receivedAtMs
                      ),
                      head.linkHash == received.linkHash else { throw Failure.invalidChain(invalid.failure) }
                return try raise(.init(error: .chainInvalid, seq: invalid.failure.seq), anchor: anchor)
            }
            // Une tête en arrière se vérifie avec la clé du journal en vigueur à son `seq`.
            var logKeyB64 = chainState.logKeyB64
            if let headSeq, headSeq < chainState.seq, let earlier = fileChain(file, upTo: headSeq) { logKeyB64 = earlier.logKeyB64 }
            let check = E2EEAutoLog.checkHead(
                text: page.headText, signatureB64: page.headSignatureB64, logKeyB64: logKeyB64, nowMs: receivedAtMs
            )
            var head: E2EEAutoLog.Head, isCurrent: Bool
            switch check {
            // Une tête plus courte que la gardée se juge sans son âge : retour en arrière (révision 7).
            case .ok(let verified): (head, isCurrent) = (verified, true)
            case .stale(let verified): (head, isCurrent) = (verified, false)
            case .invalid(let error): throw Failure.invalidHead(error)
            }
            switch E2EEAutoLog.compare(head: head, to: chainState) {
            case .match:
                // Même tête que la gardée : la plus fraîche des deux borne les 24 h (révision 7).
                if let anchor, anchor.seq == head.seq, anchor.linkHash == head.linkHash, anchor.headCreatedAtMs > head.createdAtMs {
                    head = .init(seq: head.seq, linkHash: head.linkHash, logKeyId: head.logKeyId, createdAtMs: anchor.headCreatedAtMs)
                    isCurrent = E2EEAutoLog.isFresh(createdAtMs: head.createdAtMs, nowMs: receivedAtMs)
                }
            case .ahead: throw Failure.malformed
            case .failure(let error): return try raise(.init(error: error, seq: head.seq), anchor: anchor)
            }
            // Le fichier perdu a été relu depuis 1 : la tête gardée doit en faire partie.
            if let anchor, !fromKept {
                guard anchor.seq <= chainState.seq else { return try raise(.init(error: .rollback, seq: chainState.seq), anchor: anchor) }
                let kept = anchor.seq == 0 ? E2EEAutoLog.genesisHash : E2EEAutoLog.digest(file.links[Int(anchor.seq) - 1])
                guard kept == anchor.linkHash else { return try raise(.init(error: .fork, seq: anchor.seq), anchor: anchor) }
            }
            try store.save(file, ownerScopeId: ownerScopeId)
            try store.saveAnchor(
                .init(
                    seq: head.seq, linkHash: head.linkHash, headCreatedAtMs: head.createdAtMs,
                    accountAlerts: anchor?.accountAlerts, probeCheckedAtMs: anchor?.probeCheckedAtMs
                ),
                ownerScopeId: ownerScopeId
            )
            chain = chainState
            linksBySeq = Dictionary(uniqueKeysWithValues: file.links.enumerated().map { (Int64($0.offset + 1), $0.element) })
            return isCurrent ? .current(head) : .notCurrent(head)
        }
        throw Failure.malformed
    }

    /// La chaîne du fichier gardé, si elle mène exactement à la tête du trousseau.
    private func rebuiltChain(_ file: E2EEAutoLogStore.LogFile, anchor: E2EEAutoLogStore.Anchor?) -> E2EEAutoLog.ChainState? {
        guard let anchor, Int64(file.links.count) == anchor.seq,
              let state = fileChain(file, upTo: anchor.seq), state.linkHash == anchor.linkHash else { return nil }
        return state
    }

    /// L'état de la chaîne du fichier au maillon `seq`.
    private func fileChain(_ file: E2EEAutoLogStore.LogFile, upTo seq: Int64) -> E2EEAutoLog.ChainState? {
        guard seq >= 0, seq <= Int64(file.links.count) else { return nil }
        var entries: [Int64: String] = [:]
        for (key, entry) in file.logKeyEntries {
            guard let seq = Int64(key) else { return nil }
            entries[seq] = entry
        }
        let initial = E2EEAutoLog.ChainState.initial(pinnedLogKeyB64: pinnedLogKeyB64, nextLogKeysB64: nextLogKeysB64)
        guard case .success(let state) = E2EEAutoLog.extendChain(initial, links: Array(file.links.prefix(Int(seq))), logKeyEntries: entries),
              state.seq == seq else { return nil }
        return state
    }

    private func raise(_ failure: E2EEAutoLog.ChainFailure, anchor: E2EEAutoLogStore.Anchor?) throws -> Status {
        let alert = E2EEAutoLogStore.Alert(error: failure.error.rawValue, seq: failure.seq)
        try keep(anchor) { $0.alert = alert }
        return .alert(alert)
    }

    private func keep(_ anchor: E2EEAutoLogStore.Anchor?, _ change: (inout E2EEAutoLogStore.Anchor) -> Void) throws {
        var kept = anchor ?? .init(seq: 0, linkHash: E2EEAutoLog.genesisHash, headCreatedAtMs: 0)
        change(&kept)
        try store.saveAnchor(kept, ownerScopeId: ownerScopeId)
        NotificationCenter.default.post(name: E2EEAutoLogAlerts.didChange, object: nil)
    }

    /// Maillon sans entrée (§3.5 point 5) : sur son propre compte, l'alerte
    /// globale de la fourche ; chez un contact, une alerte pour lui seul.
    private func raiseAccount(_ failure: E2EEAutoLog.AccountFailure, userId: String) throws {
        let alert = E2EEAutoLogStore.Alert(error: failure.error.rawValue, seq: failure.seq ?? 0)
        let anchor = try store.anchor(ownerScopeId: ownerScopeId)
        if ownerScopeId == "user:\(userId)" {
            try keep(anchor) { $0.alert = alert }
        } else {
            try keep(anchor) { $0.accountAlerts = ($0.accountAlerts ?? [:]).merging([userId: alert]) { kept, _ in kept } }
        }
    }

    // MARK: Comptes

    /// Le journal vérifié d'un compte, sur les maillons de la dernière lecture.
    /// nil : compte non servi (404). Un refus n'écrit rien, sauf un maillon sans
    /// entrée, gardé jusqu'à ce que l'utilisateur oublie le journal (§3.5 point 5).
    func account(_ userId: String) async throws -> Result<E2EEAutoLog.AccountState, E2EEAutoLog.AccountFailure>? {
        guard let chain else { throw Failure.linksNotRead }
        // Maillons figés avec la chaîne : l'acteur est réentrant, et une relecture
        // des maillons pendant `fetchAccount` ajoutait un maillon au-delà des
        // entrées demandées (`upTo` = cette chaîne). Le compte se jugeait alors sur
        // un maillon sans son entrée : fausse alerte « entrée du journal absente »,
        // gardée, et plus d'envoi chiffré (pile QA, 08/11, juste après la
        // publication de HK par l'appareil lui-même).
        let links = linksBySeq.filter { $0.key <= chain.seq }
        if let alert = try store.anchor(ownerScopeId: ownerScopeId)?.accountAlerts?[userId] {
            return .failure(.init(error: E2EEAutoLog.AccountError(rawValue: alert.error) ?? .entryMissing, seq: alert.seq))
        }
        try checkQuotas(Quota.allCases)
        var file = store.load(ownerScopeId: ownerScopeId)
        let kept = file.accounts[userId]
        var salt = kept?.accountSaltB64
        var entries = kept?.entries ?? []
        var after = entries.last.flatMap { E2EEAutoLog.parseEntry($0)?.entry.seq } ?? 0
        // Les entrées gardées au-delà de la chaîne lue (fichier d'un autre état) sont relues.
        let reread = after > chain.seq
        if reread { (entries, after) = ([], 0) }
        // Un compte lu pour la première fois n'a aucun appareil « nouveau » :
        // seules les entrées d'après une lecture vérifiée en disent un (§3.5).
        let seenUpTo: Int64? = kept == nil || reread ? nil : after

        var pageSalt: String??
        for _ in 0..<Self.maxAccountPages {
            guard let data = try await throttled({ try await fetchAccount(userId, after, chain.seq) }) else { return nil }
            guard let page = E2EEAutoLogPages.parseAccount(data, userId: userId) else { throw Failure.malformed }
            // Pages strictes : même sel sur toutes les pages (révision 6).
            if let pageSalt, pageSalt != page.accountSaltB64 { throw Failure.malformed }
            pageSalt = page.accountSaltB64
            salt = page.accountSaltB64
            // Une entrée au-delà de la tête vérifiée attend la prochaine lecture des maillons :
            // écartée sans erreur ni alerte (révision 6). Une entrée illisible reste, le vérificateur la refuse.
            let kept = page.entries.filter { (E2EEAutoLog.parseEntry($0)?.entry.seq ?? 0) <= chain.seq }
            // `seq` strictement croissants dans ]after, upTo], sans doublon.
            var previous = after
            for seq in kept.compactMap({ E2EEAutoLog.parseEntry($0)?.entry.seq }) {
                guard seq > previous else { throw Failure.malformed }
                previous = seq
            }
            entries += kept
            if page.hasMore {
                guard let last = page.entries.last.flatMap({ E2EEAutoLog.parseEntry($0)?.entry.seq }), last > after else {
                    throw Failure.malformed
                }
                after = last
                continue
            }
            let result: Result<E2EEAutoLog.AccountState, E2EEAutoLog.AccountFailure>
            if let salt {
                result = E2EEAutoLog.verifyAccount(userId: userId, accountSaltB64: salt, entries: entries, links: links, chain: chain)
            } else if let link = chain.accounts[E2EEAutoLog.accountId(userId: userId)] {
                // Le maillon `ACCOUNT` existe, le serveur tait le compte.
                result = .failure(.init(error: .accountWithheld, seq: link.seq))
            } else {
                return .success(E2EEAutoLog.AccountState(userId: userId, accountSaltB64: Self.emptySalt))
            }
            if case .failure(let failure) = result, failure.isMissingLink {
                try raiseAccount(failure, userId: userId)
            }
            if case .success = result {
                file.accounts[userId] = .init(accountSaltB64: salt, entries: entries)
                try store.save(file, ownerScopeId: ownerScopeId)
                if let seenUpTo {
                    let added = Self.addedDevices(entries, after: seenUpTo)
                    if !added.isEmpty { addedDevices[userId, default: []].formUnion(added) }
                }
            }
            return result
        }
        throw Failure.malformed
    }

    /// Appareils apparus depuis la dernière reprise, vidés à la lecture.
    func takeAddedDevices() -> [String: Set<String>] {
        defer { addedDevices = [:] }
        return addedDevices
    }

    /// Appareils ajoutés par les entrées d'après `seq` : un `ADD` `GENESIS`
    /// (reprise v2, §3.6) n'en ajoute aucun, ni pour une alerte ni pour une rotation (§7).
    static func addedDevices(_ entries: [String], after seq: Int64) -> Set<String> {
        Set(entries.compactMap(E2EEAutoLog.parseEntry).compactMap { parsed -> String? in
            guard parsed.entry.seq > seq else { return nil }
            switch parsed.detail {
            case .add(genesis: false), .activate: return parsed.entry.deviceId
            default: return nil
            }
        })
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

    enum ProbeCheck: Equatable, Sendable {
        /// Déjà comparée depuis moins de 24 h, alerte gardée ou maillons pas encore lus.
        case skipped
        /// Fichier absent, injoignable, invalide, trop vieux, ou relecture non concluante :
        /// aucune alerte, nouvel essai au jour suivant (§7.8 E5).
        case ignored
        case agree
        /// Alerte de fourche levée et gardée.
        case fork
    }

    /// Comparaison avec la tête publiée par la sonde, une fois par jour au plus,
    /// après `refreshLinks` (§3.7, §7.8 E5). Seuls `seq` et `linkHash` comptent ;
    /// une sonde en avance fait relire les maillons, et seule une relecture
    /// concluante peut conclure à une fourche.
    func checkProbeIfDue() async -> ProbeCheck {
        guard !checkingProbe, chain != nil, var anchor = try? store.anchor(ownerScopeId: ownerScopeId), anchor.alert == nil else {
            return .skipped
        }
        let startedAtMs = nowMs
        if let last = anchor.probeCheckedAtMs, last <= startedAtMs, startedAtMs - last < E2EEAutoProbeHead.checkIntervalMs {
            return .skipped
        }
        checkingProbe = true
        defer { checkingProbe = false }
        anchor.probeCheckedAtMs = startedAtMs
        guard (try? store.saveAnchor(anchor, ownerScopeId: ownerScopeId)) != nil else { return .ignored }

        // La sonde d'abord, sans la clé du journal : un fichier faux ne fait rien relire.
        guard let data = await fetchProbe(),
              case .ok(let probe) = E2EEAutoProbeHead.verify(data, probeKeys: probeKeys, logKeyB64: nil, nowMs: nowMs) else {
            return .ignored
        }
        var reread = false
        if let chain, probe.seq > chain.seq {
            guard case .current? = try? await refreshLinks() else { return .ignored }
            reread = true
        }
        guard let chain else { return .ignored }
        // La tête de la sonde se vérifie par la clé du journal en vigueur à son `seq`.
        let logKeyB64 = probe.seq <= chain.seq
            ? fileChain(store.load(ownerScopeId: ownerScopeId), upTo: probe.seq)?.logKeyB64
            : chain.logKeyB64
        guard let logKeyB64,
              case .ok = E2EEAutoProbeHead.verify(data, probeKeys: probeKeys, logKeyB64: logKeyB64, nowMs: nowMs) else {
            return .ignored
        }
        switch compareProbe(seq: probe.seq, linkHash: probe.linkHash) {
        case .agree: return .agree
        case .behind where !reread: return .ignored
        case .behind, .fork:
            // Deux têtes signées par la clé du journal ne se contredisent jamais, et le journal ne raccourcit pas.
            guard let current = try? store.anchor(ownerScopeId: ownerScopeId), current.alert == nil,
                  (try? raise(.init(error: .fork, seq: probe.seq), anchor: current)) != nil else { return .ignored }
            return .fork
        }
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
