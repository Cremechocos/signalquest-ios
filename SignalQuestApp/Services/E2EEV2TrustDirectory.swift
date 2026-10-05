import CryptoKit
import Foundation

/// Appareils certifiés des membres d'une conversation, figés pour un appel ou
/// un envoi (spec §2.2, §10, §12). Les vérifications synchrones — preuve de
/// jonction, descripteur d'appel, destinataires d'une époque — s'y lisent
/// sans réseau.
struct E2EEV2CertifiedDeviceSet: Equatable, Sendable {
    let devicesByUser: [String: [E2EEV2CertifiedDevice]]
    /// Comptes dont le paquet de confiance a été refusé (UIK changée, liste
    /// invalide ou en recul) : aucun de leurs appareils n'est cru.
    let refusals: [String: E2EEV2IdentityVerification.Failure]
    /// Version de la liste d'appareils vérifiée de chaque compte lu, envoyée
    /// avec une époque (`memberListVersions`, E.2) : le serveur refuse une
    /// époque bâtie sur une liste qui n'est plus la courante.
    var listVersions: [String: Int] = [:]
    /// Comptes supprimés (410 `E2EE_ACCOUNT_DELETED`, D.4 v0.4.30) : membres
    /// sans appareil, ni refusés ni à relire ; un administrateur les retire.
    var deleted: Set<String> = []

    /// Membres qui n'ont pas été lus du tout, ni crus ni refusés : appris par
    /// une synchronisation après la lecture. Ils sont à lire avant toute
    /// époque, jamais tenus pour des membres sans appareil.
    func unread(_ members: Set<String>) -> [String] {
        members.filter { devicesByUser[$0] == nil && refusals[$0] == nil }.sorted()
    }

    func device(userId: String, deviceId: String) -> E2EEV2CertifiedDevice? {
        devicesByUser[userId]?.first { $0.deviceId == deviceId }
    }

    /// L'appareil appelant d'un descripteur n'est désigné que par son
    /// identifiant d'appareil.
    func device(deviceId: String) -> E2EEV2CertifiedDevice? {
        devicesByUser.values.lazy.flatMap { $0 }.first { $0.deviceId == deviceId }
    }

    func signingKey(userId: String, deviceId: String) -> P256.Signing.PublicKey? {
        device(userId: userId, deviceId: deviceId)?.signingKey
    }

    /// Membres dont le paquet est refusé, triés. Ils ne sont jamais exclus en
    /// silence d'une nouvelle époque : rotation, envoi et création attendent
    /// que l'utilisateur ait vu et accepté le changement (§2.4, v0.4.9).
    func untrustedMembers(_ members: Set<String>) -> [String] {
        members.filter { refusals[$0] != nil }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Capacité d'une conversation (§12) : ce que savent faire tous les
    /// appareils pris en compte, triés par octets UTF-8.
    struct CapabilityIntersection: Equatable, Sendable {
        let deviceIds: [String]
        let envelopeVersions: [String]
        let payloadVersions: [String]
        let kinds: [String]
        let features: [String]
    }

    /// Comptent les appareils certifiés et non mis à l'écart des membres ; un
    /// navigateur ne compte pas quand la conversation exclut les navigateurs ;
    /// un membre sans appareil ne compte pas. Un membre dont le paquet est
    /// refusé, ou l'absence de tout appareil actif, la rend indisponible.
    /// Vecteur : `capability-intersection-v1`.
    func capabilityIntersection(nowMs: Int64, excludesWeb: Bool) -> CapabilityIntersection? {
        guard refusals.isEmpty else { return nil }
        let documents = devicesByUser.values.flatMap { $0 }
            .filter { !$0.isSidelined(nowMs: nowMs) && !(excludesWeb && $0.platform == "web") }
            .compactMap { device in device.capabilities.map { (device.deviceId, $0) } }
        guard let first = documents.first?.1 else { return nil }
        var envelopes = Set(first.envelopeVersions), payloads = Set(first.payloadVersions)
        var kinds = Set(first.kinds), features = Set(first.features)
        for (_, document) in documents.dropFirst() {
            envelopes.formIntersection(document.envelopeVersions)
            payloads.formIntersection(document.payloadVersions)
            kinds.formIntersection(document.kinds)
            features.formIntersection(document.features)
        }
        func sorted<S: Sequence>(_ values: S) -> [String] where S.Element == String {
            values.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        }
        return CapabilityIntersection(
            deviceIds: sorted(documents.map(\.0)), envelopeVersions: sorted(envelopes),
            payloadVersions: sorted(payloads), kinds: sorted(kinds), features: sorted(features)
        )
    }

    /// §10.0 : l'appel chiffré n'est possible que si l'intersection contient
    /// « appels vérifiés ». Un membre refusé le rend indisponible : ses
    /// appareils sont inconnus.
    func supportsVerifiedCalls(nowMs: Int64, excludesWeb: Bool) -> Bool {
        capabilityIntersection(nowMs: nowMs, excludesWeb: excludesWeb)?.features.contains("calls") == true
    }
}

/// Ce que cet appareil a épinglé de chaque compte (§2.1, §2.2), dans le coffre
/// E2EE du compte courant. Rien de secret, mais son intégrité compte : une UIK
/// remplacée ici ferait croire un faux appareil.
final class E2EEV2TrustPinStore: @unchecked Sendable {
    static let keyPrefix = "trust-pin-v1"

    private let tokenStore: TokenStore

    init(tokenStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee")) {
        self.tokenStore = tokenStore
    }

    func pin(userId: String, ownerNamespace: String) throws -> E2EEV2TrustPin? {
        guard let raw = try tokenStore.string(for: key(userId: userId, ownerNamespace: ownerNamespace)),
              let data = raw.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(E2EEV2TrustPin.self, from: data)
    }

    func save(_ pin: E2EEV2TrustPin, userId: String, ownerNamespace: String) throws {
        let data = try JSONEncoder().encode(pin)
        guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileWriteUnknown) }
        try tokenStore.set(value, for: key(userId: userId, ownerNamespace: ownerNamespace), accessibility: .afterFirstUnlock)
    }

    func remove(userId: String, ownerNamespace: String) throws {
        try tokenStore.remove(key(userId: userId, ownerNamespace: ownerNamespace))
    }

    static func prefix(ownerNamespace: String) -> String {
        "\(keyPrefix):\(ownerNamespace):"
    }

    private func key(userId: String, ownerNamespace: String) -> String {
        Self.prefix(ownerNamespace: ownerNamespace) + userId
    }
}

/// Lit, vérifie et épingle le paquet de confiance de chaque membre (E.1), puis
/// rend les appareils certifiés. Un paquet refusé retire ce membre sans faire
/// échouer les autres ; une erreur réseau fait échouer l'ensemble.
actor E2EEV2TrustDirectory {
    enum Failure: Error, Equatable {
        case malformedResponse(userId: String)
        /// Le pin de ce compte a changé pendant chaque lecture : rien n'en est cru.
        case concurrentChange(userId: String)
    }

    /// `E2EE_IDENTITY_NOT_FOUND`, levé par `fetch` : refus de ce seul membre.
    struct IdentityNotFound: Error, Equatable {}

    /// `410 E2EE_ACCOUNT_DELETED`, levé par `fetch` : compte supprimé (D.4).
    struct AccountDeleted: Error, Equatable {}

    /// E.1 en production : lecture par session (sans signature), la version
    /// épinglée en `sinceVersion`.
    static func identityFetch(
        transport: E2EEV2APITransport,
        ownerScopeId: String
    ) -> @Sendable (_ userId: String, _ sinceVersion: Int?) async throws -> Data {
        { userId, sinceVersion in
            guard E2EEV2Canonical.isOpaque(userId) else { throw Failure.malformedResponse(userId: userId) }
            let result = await transport.getSessionJSON(
                path: "/api/e2ee/v2/users/\(userId)/identity",
                query: sinceVersion.map { [URLQueryItem(name: "sinceVersion", value: String($0))] } ?? [],
                expectedOwnerScopeId: ownerScopeId,
                capabilitySet: .deviceLifecycle
            )
            switch result {
            case .success(let value, _, _):
                return value
            case .failure(let failure) where failure.statusCode == 404 && failure.code == "E2EE_IDENTITY_NOT_FOUND":
                throw IdentityNotFound()
            case .failure(let failure) where failure.statusCode == 410 && failure.code == "E2EE_ACCOUNT_DELETED":
                throw AccountDeleted()
            case .failure(let failure):
                throw failure
            }
        }
    }

    private let ownerNamespace: String
    private let pins: E2EEV2TrustPinStore
    private let ownUserId: String?
    private let ownAccountKey: @Sendable () -> P256.Signing.PublicKey?
    /// `sinceVersion` : la version épinglée, ou la page suivante de la chaîne (E.1).
    private let fetch: @Sendable (_ userId: String, _ sinceVersion: Int?) async throws -> Data
    /// 50 maillons par page : au-delà, la chaîne est trop longue pour être relue.
    static let maxChainPages = 20
    /// Lectures d'un compte dont le pin a bougé pendant la lecture réseau.
    static let maxPinRaces = 3

    /// `ownAccountKey` : la clé de compte détenue ici. Son propre paquet doit la
    /// porter, sinon le serveur pourrait y glisser une autre clé au premier
    /// contact.
    init(
        ownerNamespace: String,
        pins: E2EEV2TrustPinStore = E2EEV2TrustPinStore(),
        ownUserId: String? = nil,
        ownAccountKey: @escaping @Sendable () -> P256.Signing.PublicKey? = { nil },
        fetch: @escaping @Sendable (_ userId: String, _ sinceVersion: Int?) async throws -> Data
    ) {
        self.ownerNamespace = ownerNamespace
        self.pins = pins
        self.ownUserId = ownUserId
        self.ownAccountKey = ownAccountKey
        self.fetch = fetch
    }

    func certifiedDevices(for userIds: [String]) async throws -> E2EEV2CertifiedDeviceSet {
        var devices: [String: [E2EEV2CertifiedDevice]] = [:]
        var refusals: [String: E2EEV2IdentityVerification.Failure] = [:]
        var versions: [String: Int] = [:]
        var deleted: Set<String> = []
        for userId in Set(userIds).sorted() {
            let expected = userId == ownUserId ? ownAccountKey() : nil
            let read: Read
            do {
                read = try await self.read(userId: userId, expectedUIK: expected)
            } catch is AccountDeleted where userId != ownUserId {
                // Ne fait que retirer un destinataire : sans appareil, sans refus.
                devices[userId] = []
                deleted.insert(userId)
                continue
            } catch is IdentityNotFound {
                // Un pin illisible compte comme un pin : jamais de retour en v1 sur un doute.
                let pinned: Bool
                do { pinned = try pins.pin(userId: userId, ownerNamespace: ownerNamespace) != nil } catch { pinned = true }
                refusals[userId] = pinned ? .identityWithdrawn : .notFound
                continue
            }
            switch read.result {
            case .success(let outcome):
                devices[userId] = outcome.devices
                versions[userId] = outcome.pin.listVersion
            case .failure(let refusal):
                refusals[userId] = refusal
            }
        }
        // Un identifiant d'appareil certifié par deux comptes est ambigu : un
        // descripteur d'appel ne le désigne que par lui. Aucun des deux n'est cru.
        let owners = devices.values.flatMap { $0 }.reduce(into: [String: Int]()) { $0[$1.deviceId, default: 0] += 1 }
        let ambiguous = Set(owners.filter { $0.value > 1 }.keys)
        if !ambiguous.isEmpty {
            devices = devices.mapValues { $0.filter { !ambiguous.contains($0.deviceId) } }
        }
        return E2EEV2CertifiedDeviceSet(devicesByUser: devices, refusals: refusals, listVersions: versions, deleted: deleted)
    }

    /// Son propre compte, vérifié : la liste courante sur laquelle signer la
    /// suivante (approbation, révocation), et ses appareils certifiés. Avec
    /// l'UIK détenue ici, le serveur ne peut pas en servir une autre ; sans
    /// elle (appareil qui vient d'être approuvé), c'est un premier contact.
    struct AccountTrust: Equatable, Sendable {
        let outcome: E2EEV2IdentityVerification.Outcome
        let deviceList: E2EEV2SignedString
        let deviceEntries: [String]
        /// Réinitialisation en attente servie, à vérifier avant d'en parler.
        var pendingIdentityReset: E2EEV2IdentityBundle.PendingReset? = nil
    }

    func ownAccountTrust() async throws -> AccountTrust {
        guard let ownUserId else { throw Failure.malformedResponse(userId: "") }
        let read = try await read(userId: ownUserId, expectedUIK: ownAccountKey())
        switch read.result {
        case .success(let outcome):
            return AccountTrust(
                outcome: outcome, deviceList: read.bundle.deviceList, deviceEntries: read.bundle.deviceEntries,
                pendingIdentityReset: read.bundle.pendingIdentityReset
            )
        case .failure(let failure):
            throw failure
        }
    }

    private struct Read {
        /// Le pin courant à la fin de la lecture : celui qu'elle a écrit si le
        /// paquet a été accepté.
        let pin: E2EEV2TrustPin?
        let bundle: E2EEV2IdentityBundle
        let result: Result<E2EEV2IdentityVerification.Outcome, E2EEV2IdentityVerification.Failure>
    }

    /// Lit le paquet d'un compte, puis, sans autre suspension, le vérifie
    /// contre le pin courant et écrit le nouveau pin. Pendant la lecture
    /// réseau, une autre lecture ou l'écran du numéro de sécurité ont pu
    /// changer ce pin : rien n'est alors cru de ce paquet, demandé pour un pin
    /// périmé, et la lecture recommence. Seul le drapeau « vérifié » peut
    /// changer entre-temps sans la rendre périmée.
    private func read(userId: String, expectedUIK: P256.Signing.PublicKey?) async throws -> Read {
        for _ in 0..<Self.maxPinRaces {
            let pinned = try pins.pin(userId: userId, ownerNamespace: ownerNamespace)
            let bundle = try await bundle(userId: userId, sinceVersion: pinned?.listVersion, pinnedUIK: pinned?.uikX963B64)
            let current = try pins.pin(userId: userId, ownerNamespace: ownerNamespace)
            guard current?.with(verified: false) == pinned?.with(verified: false) else { continue }
            let result = E2EEV2IdentityVerification.verify(bundle, pinned: current, expectedUIK: expectedUIK)
            if case .success(let outcome) = result {
                try pins.save(outcome.pin, userId: userId, ownerNamespace: ownerNamespace)
                return Read(pin: outcome.pin, bundle: bundle, result: result)
            }
            return Read(pin: current, bundle: bundle, result: result)
        }
        throw Failure.concurrentChange(userId: userId)
    }

    /// Le paquet de confiance et toute la chaîne depuis la version épinglée,
    /// page après page (E.1). Une UIK autre que l'épinglée arrête la lecture
    /// dès la première page : sa chaîne ne sera pas vérifiée (v0.4.9).
    private func bundle(userId: String, sinceVersion pinned: Int?, pinnedUIK: String?) async throws -> E2EEV2IdentityBundle {
        var chain: [E2EEV2SignedString] = []
        var since = pinned
        for _ in 0..<Self.maxChainPages {
            let data = try await fetch(userId, since)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var page = E2EEV2IdentityBundle.parse(object, userId: userId) else {
                throw Failure.malformedResponse(userId: userId)
            }
            if let pinnedUIK, chain.isEmpty, !Self.sameKey(page.uikX963B64, pinnedUIK) { return page }
            chain += page.deviceListChain
            guard let next = page.nextSinceVersion else {
                page.deviceListChain = chain
                return page
            }
            // Une page suivante doit avancer, sinon la lecture boucle.
            guard next > (since ?? 0) else { throw Failure.malformedResponse(userId: userId) }
            since = next
        }
        throw Failure.malformedResponse(userId: userId)
    }
}

/// Numéro de sécurité d'un contact (§2.4, D.12), tel que cet appareil le voit.
struct E2EEV2SafetyNumberIdentity: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Confiance à la première utilisation : rien n'a été comparé.
        case unverified
        /// Numéro comparé par l'utilisateur.
        case verified
        /// L'UIK servie n'est plus celle épinglée. Rien n'est cru de ce compte
        /// tant que l'utilisateur n'a pas vu le changement ; si l'ancienne UIK
        /// était vérifiée, seule une nouvelle vérification le lève (§2.4).
        case changed(wasVerified: Bool)
    }

    let userId: String
    /// L'UIK dont le numéro est montré : l'épinglée, ou la nouvelle si elle a changé.
    let uikX963B64: String
    let status: Status
}

/// Ce que l'écran du numéro de sécurité demande à l'annuaire de confiance.
protocol E2EEV2SafetyNumberTrusting: Sendable {
    func safetyNumberIdentity(userId: String) async throws -> E2EEV2SafetyNumberIdentity
    func setVerified(_ verified: Bool, userId: String, uikX963B64: String) async throws
    func acceptChangedIdentity(userId: String, uikX963B64: String, verified: Bool) async throws
}

extension E2EEV2TrustDirectory: E2EEV2SafetyNumberTrusting {
    enum SafetyNumberFailure: Error, Equatable {
        /// L'UIK n'est plus celle dont l'utilisateur a vu le numéro.
        case numberChanged
        /// Une UIK vérifiée ne se remplace qu'après une nouvelle vérification.
        case verificationRequired
        /// Sa propre UIK ne change que par sa propre réinitialisation (D.14).
        case ownAccount
        case refused(E2EEV2IdentityVerification.Failure)
    }

    /// Vérifie et épingle comme `certifiedDevices`, et rend aussi la nouvelle
    /// UIK d'un compte qui a changé, pour en montrer le numéro, sans la croire.
    func safetyNumberIdentity(userId: String) async throws -> E2EEV2SafetyNumberIdentity {
        try requireContact(userId)
        let read: Read
        do {
            read = try await self.read(userId: userId, expectedUIK: nil)
        } catch is IdentityNotFound {
            throw SafetyNumberFailure.refused(.notFound)
        }
        switch read.result {
        case .success:
            guard let pin = read.pin else { throw SafetyNumberFailure.numberChanged }
            return E2EEV2SafetyNumberIdentity(
                userId: userId, uikX963B64: pin.uikX963B64, status: pin.verified ? .verified : .unverified
            )
        case .failure(.uikChanged):
            guard let pin = read.pin else { throw SafetyNumberFailure.refused(.uikChanged) }
            return E2EEV2SafetyNumberIdentity(
                userId: userId, uikX963B64: read.bundle.uikX963B64, status: .changed(wasVerified: pin.verified)
            )
        case .failure(let failure):
            throw SafetyNumberFailure.refused(failure)
        }
    }

    /// L'utilisateur a comparé, ou retire sa vérification. `uikX963B64` est
    /// l'UIK dont il a vu le numéro : seule l'épinglée peut changer d'état.
    func setVerified(_ verified: Bool, userId: String, uikX963B64: String) throws {
        try requireContact(userId)
        guard let pin = try pins.pin(userId: userId, ownerNamespace: ownerNamespace),
              Self.sameKey(pin.uikX963B64, uikX963B64) else {
            throw SafetyNumberFailure.numberChanged
        }
        try pins.save(pin.with(verified: verified), userId: userId, ownerNamespace: ownerNamespace)
    }

    /// Changement d'UIK vu par l'utilisateur (§2.4) : la nouvelle identité est
    /// relue sans `sinceVersion`, car sa chaîne de listes repart de 1 (D.14),
    /// puis épinglée comme au premier contact. Elle n'est acceptée que si
    /// c'est celle dont il a vu le numéro.
    func acceptChangedIdentity(userId: String, uikX963B64: String, verified: Bool) async throws {
        try requireContact(userId)
        guard let pinned = try pins.pin(userId: userId, ownerNamespace: ownerNamespace),
              !Self.sameKey(pinned.uikX963B64, uikX963B64) else {
            throw SafetyNumberFailure.numberChanged
        }
        if pinned.verified && !verified { throw SafetyNumberFailure.verificationRequired }
        let bundle: E2EEV2IdentityBundle
        do {
            bundle = try await self.bundle(userId: userId, sinceVersion: nil, pinnedUIK: nil)
        } catch is IdentityNotFound {
            throw SafetyNumberFailure.refused(.notFound)
        }
        guard Self.sameKey(bundle.uikX963B64, uikX963B64) else { throw SafetyNumberFailure.numberChanged }
        // Pendant la lecture, le pin a pu changer : rien n'est écrasé. La
        // vérification et l'écriture suivent sans autre suspension.
        guard try pins.pin(userId: userId, ownerNamespace: ownerNamespace) == pinned else {
            throw SafetyNumberFailure.numberChanged
        }
        switch E2EEV2IdentityVerification.verify(bundle, pinned: nil) {
        case .success(let outcome):
            try pins.save(outcome.pin.with(verified: verified), userId: userId, ownerNamespace: ownerNamespace)
        case .failure(let failure):
            throw SafetyNumberFailure.refused(failure)
        }
    }

    /// Fermé par défaut : sans son propre identifiant, aucun choix n'est permis.
    private func requireContact(_ userId: String) throws {
        guard let ownUserId, userId != ownUserId else { throw SafetyNumberFailure.ownAccount }
    }

    private static func sameKey(_ a: String, _ b: String) -> Bool {
        guard let left = Data(base64Encoded: a), let right = Data(base64Encoded: b) else { return false }
        return left == right
    }
}
