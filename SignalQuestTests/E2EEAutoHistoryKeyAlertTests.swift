import CryptoKit
import XCTest
@testable import SignalQuest

/// Alerte « Nouvelle clé d'historique » (E2EE-AUTO §5.1, révision 23) : jugement des HK
/// après la plus récente détenue (vecteurs texte 12 à 14i), grâce d'une heure, acquittement
/// par `hkPubB64`, coordinateur de l'écran (A1 à A4).
final class E2EEAutoHistoryKeyAlertTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()
    private let ownId = "ios_device_own_000000000"

    private static func newKey() -> String {
        P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
    }

    /// `HISTORY_KEY` dans l'ordre, signées par `signer` ; `afterRevokeSeq` non nul et `previous`
    /// laissé vide donnent la forme d'une rotation.
    private func log(
        _ keys: [(hk: String, afterRevokeSeq: Int64?, previous: String?)], signer: String? = nil
    ) -> E2EEAutoLog.AccountState {
        var state = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
        for (index, key) in keys.enumerated() {
            state.historyKeys.append(.init(
                seq: Int64(10 * (index + 1)), entryHash: E2EEAutoLog.digest("hk\(index)"), hkPubB64: key.hk,
                previousHkPubB64: key.previous ?? (index > 0 ? keys[index - 1].hk : nil), signerDeviceId: signer ?? ownId,
                signerAddedAtMs: 1, createdAtMs: Int64(index + 1), afterRevokeSeq: key.afterRevokeSeq
            ))
        }
        state.historyKeyPubB64 = keys.last?.hk
        return state
    }

    /// La HK `index` signée par un appareil révoqué juste après elle : `NOT_ME` l'annule (§5.6 bis).
    private func signedByRevoked(
        _ state: E2EEAutoLog.AccountState, _ index: Int, reason: E2EEAutoLog.RevokeReason = .notMe
    ) -> E2EEAutoLog.AccountState {
        var state = state
        let record = state.historyKeys[index], deviceId = "web_device_intruder_000\(index)", key = Self.newKey()
        state.historyKeys[index] = .init(
            seq: record.seq, entryHash: record.entryHash, hkPubB64: record.hkPubB64, previousHkPubB64: record.previousHkPubB64,
            signerDeviceId: deviceId, signerAddedAtMs: 1, createdAtMs: record.createdAtMs, afterRevokeSeq: record.afterRevokeSeq
        )
        state.devices[deviceId] = E2EEAutoLog.DeviceState(
            deviceId: deviceId, platform: .web, identityKeyB64: key, signingKeyB64: Self.newKey(), keyVersion: 1, status: .revoked,
            addedAtMs: 1, activatedAtMs: 1, addEntryHash: E2EEAutoLog.digest("add-\(deviceId)"),
            identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: 1)],
            revokeReason: reason, revokeSeq: record.seq + 1, revokedAtMs: 2
        )
        return state
    }

    private func judge(
        _ account: E2EEAutoLog.AccountState, holds: Set<String>, acknowledged: Set<String> = [],
        vouched: Set<String> = [], graceOver: Set<String> = []
    ) async -> E2EEAutoHistoryKeyAlert.Verdict {
        await E2EEAutoHistoryKeyAlert.judge(
            account, holds: { holds.contains($0) }, acknowledged: acknowledged,
            vouched: { vouched.contains($0.hkPubB64) }, graceOver: { graceOver.contains($0.hkPubB64) }
        )
    }

    private func alert(_ hk: String, signer: String? = nil) -> E2EEAutoHistoryKeyAlert.Verdict {
        .alert(.init(hkPubB64: hk, signerDeviceId: signer ?? ownId))
    }

    // MARK: Jugement (vecteurs texte)

    /// 12 : HK2 hors rotation, signataire révoqué en `USER` : pas annulée, l'alerte se lève.
    /// 13 : signataire révoqué en `NOT_ME`, puis une rotation à preuve : plus rien à juger.
    /// 14 : la plus ancienne annulée, la suivante hors rotation : alerte sur la suivante.
    func testCancelledKeysLeaveTheJudgementOthersDoNot() async {
        let a = Self.newKey(), b = Self.newKey(), c = Self.newKey(), d = Self.newKey()
        let user = signedByRevoked(log([(a, nil, nil), (b, nil, nil)]), 1, reason: .user)
        let twelve = await judge(user, holds: [a])
        XCTAssertEqual(twelve, alert(b, signer: "web_device_intruder_0001"))

        let rotated = signedByRevoked(log([(a, nil, nil), (b, nil, nil), (c, 21, nil)]), 1)
        let thirteen = await judge(rotated, holds: [a], vouched: [c])
        XCTAssertEqual(thirteen, .judged)

        let fourteen = await judge(signedByRevoked(log([(a, nil, nil), (b, nil, nil), (c, nil, nil), (d, 31, nil)]), 1), holds: [a], vouched: [d])
        XCTAssertEqual(fourteen, alert(c))
    }

    /// 14b : un appareil qui ne détient aucune HK n'alerte pas (il la demande, §5.3).
    func testDeviceWithoutAnyKeyDoesNotAlert() async {
        let a = Self.newKey(), b = Self.newKey()
        let verdict = await judge(log([(a, nil, nil), (b, nil, nil)]), holds: [])
        XCTAssertEqual(verdict, .judged)
        let held = await judge(log([(a, nil, nil), (b, nil, nil)]), holds: [b])
        XCTAssertEqual(held, .judged, "la dernière HK détenue : rien après elle")
    }

    /// 14c : « C'est moi » acquitte HK2 par son `hkPubB64` ; une HK4 suspecte relance l'alerte.
    func testAcknowledgementCoversOnlyThatKey() async {
        let a = Self.newKey(), b = Self.newKey(), c = Self.newKey()
        let before = await judge(log([(a, nil, nil), (b, nil, nil)]), holds: [a])
        XCTAssertEqual(before, alert(b))
        let acknowledged = await judge(log([(a, nil, nil), (b, nil, nil)]), holds: [a], acknowledged: [b])
        XCTAssertEqual(acknowledged, .judged, "acquittée : la demande §5.3 peut partir")
        let next = await judge(log([(a, nil, nil), (b, nil, nil), (c, nil, nil)]), holds: [a], acknowledged: [b])
        XCTAssertEqual(next, alert(c))
    }

    /// 14d (jugement) : une rotation sans maillon à preuve attend sa grâce, puis alerte ; le
    /// maillon arrivé, l'alerte tombe. 14f : pendant la grâce, ni alerte ni demande.
    func testUnprovenRotationWaitsForItsGrace() async {
        let a = Self.newKey(), b = Self.newKey()
        let account = log([(a, nil, nil), (b, 40, nil)])
        let during = await judge(account, holds: [a])
        XCTAssertEqual(during, .pending)
        let after = await judge(account, holds: [a], graceOver: [b])
        XCTAssertEqual(after, alert(b))
        let proven = await judge(account, holds: [a], vouched: [b], graceOver: [b])
        XCTAssertEqual(proven, .judged)
        let acknowledged = await judge(account, holds: [a], acknowledged: [b])
        XCTAssertEqual(acknowledged, .judged, "« C'est moi » compte même si la grâce repart après un redémarrage")
    }

    /// 14e : HK_r de A, `NOT_ME` de A par B, HK3 de B en forme de rotation dont le maillon sur
    /// HK_r est refusé (pas de preuve admise) : l'alerte reste, passé la grâce.
    func testAttackerWithTwoDevicesKeepsTheAlert() async {
        let a = Self.newKey(), r = Self.newKey(), k3 = Self.newKey()
        let account = signedByRevoked(log([(a, nil, nil), (r, nil, nil), (k3, 41, nil)]), 1)
        let verdict = await judge(account, holds: [a], graceOver: [k3])
        XCTAssertEqual(verdict, alert(k3))
    }

    /// 14g : HK2 suspecte acquittée, HK3 rotation à preuve, HK4 suspecte : alerte sur HK4.
    func testAlertMovesToTheNextSuspect() async {
        let a = Self.newKey(), b = Self.newKey(), c = Self.newKey(), d = Self.newKey()
        let verdict = await judge(log([(a, nil, nil), (b, nil, nil), (c, 40, nil), (d, nil, nil)]), holds: [a], acknowledged: [b], vouched: [c])
        XCTAssertEqual(verdict, alert(d))
    }

    /// Une rotation encore dans sa grâce n'empêche pas l'alerte sur une suspecte qui la suit.
    func testPendingRotationDoesNotHideALaterSuspect() async {
        let a = Self.newKey(), b = Self.newKey(), c = Self.newKey()
        let verdict = await judge(log([(a, nil, nil), (b, 40, nil), (c, nil, nil)]), holds: [a])
        XCTAssertEqual(verdict, alert(c))
    }

    /// 14i (T4) : signataire déjà révoqué en `USER`, HK non annulable : l'alerte reste.
    func testSignerRemovedForAnotherReasonKeepsTheAlert() async {
        let a = Self.newKey(), b = Self.newKey()
        let account = signedByRevoked(log([(a, nil, nil), (b, nil, nil)]), 1, reason: .user)
        XCTAssertEqual(account.historyKeyBase(b)?.cancelled, false)
        let verdict = await judge(account, holds: [a])
        XCTAssertEqual(verdict, alert(b, signer: "web_device_intruder_0001"))
    }

    func testRotationShapeNeedsARevokeAndTheLiteralPreviousKey() {
        let a = Self.newKey(), b = Self.newKey(), c = Self.newKey()
        XCTAssertTrue(E2EEAutoHistoryKeyAlert.hasRotationShape(log([(a, nil, nil), (b, 40, nil)]).historyKeys, at: 1))
        XCTAssertFalse(E2EEAutoHistoryKeyAlert.hasRotationShape(log([(a, nil, nil), (b, nil, nil)]).historyKeys, at: 1))
        XCTAssertFalse(E2EEAutoHistoryKeyAlert.hasRotationShape(log([(a, nil, nil), (b, 40, c)]).historyKeys, at: 1))
        XCTAssertFalse(E2EEAutoHistoryKeyAlert.hasRotationShape(log([(a, 40, nil)]).historyKeys, at: 0))
    }

    // MARK: Grâce

    private final class Clock: @unchecked Sendable {
        var monotonicMs: Int64 = 0
        var bootId = "boot-1"
        var serverTimeMs: Int64?
        var stored: E2EEAutoHistoryKeyGrace.Stored?
        var saves = 0

        var grace: E2EEAutoHistoryKeyGrace {
            E2EEAutoHistoryKeyGrace(
                monotonicMs: { [self] in monotonicMs }, bootId: { [self] in bootId }, serverTimeMs: { [self] in serverTimeMs },
                load: { [self] in stored }, save: { [self] in stored = $0; saves += 1 }
            )
        }
    }

    private func record(_ hk: String, createdAtMs: Int64) -> E2EEAutoLog.HistoryKeyRecord {
        .init(seq: 20, entryHash: E2EEAutoLog.digest("hk"), hkPubB64: hk, previousHkPubB64: nil, signerDeviceId: ownId,
              signerAddedAtMs: 1, createdAtMs: createdAtMs, afterRevokeSeq: 40)
    }

    /// 14d : `createdAtMs` = T, première lecture à T + 5 min : pas d'alerte à T + 50 min, alerte
    /// à T + 66 min. L'horloge murale n'entre pas en jeu : en avance de 2 h, même résultat.
    func testGraceNeedsAnHourOfLocalReadingAndOfServerTime() {
        let minute: Int64 = 60_000, t: Int64 = 1_800_000_000_000
        let clock = Clock()
        let hk = record(Self.newKey(), createdAtMs: t)
        clock.monotonicMs = 500 * minute
        clock.serverTimeMs = t + 5 * minute
        XCTAssertFalse(clock.grace.isOver(hk), "première lecture")
        clock.monotonicMs += 45 * minute
        clock.serverTimeMs = t + 50 * minute
        XCTAssertFalse(clock.grace.isOver(hk))
        clock.monotonicMs += 16 * minute
        clock.serverTimeMs = t + 66 * minute
        XCTAssertTrue(clock.grace.isOver(hk))
        XCTAssertEqual(clock.saves, 1, "la première lecture n'est rangée qu'une fois")

        // Heure serveur en retard sur la lecture locale : la grâce attend l'une et l'autre.
        let lagging = Clock()
        lagging.serverTimeMs = t + 30 * minute
        XCTAssertFalse(lagging.grace.isOver(hk))
        lagging.monotonicMs += 2 * 60 * minute
        XCTAssertFalse(lagging.grace.isOver(hk), "serveur pas encore à T + 1 h")
        lagging.serverTimeMs = t + 60 * minute
        XCTAssertFalse(lagging.grace.isOver(hk), "T + 1 h tout juste : pas encore dépassé")
        lagging.serverTimeMs = t + 60 * minute + 1
        XCTAssertTrue(lagging.grace.isOver(hk))

        let unknown = Clock()
        _ = unknown.grace.isOver(hk)
        unknown.monotonicMs += 2 * 60 * minute
        XCTAssertFalse(unknown.grace.isOver(hk), "heure serveur inconnue : la grâce dure")
    }

    /// Après un redémarrage, l'horloge monotone repart de zéro : la grâce repart de la nouvelle
    /// première lecture. Une valeur rangée plus grande que maintenant repart aussi.
    func testGraceRestartsAfterAReboot() {
        let hour: Int64 = 3_600_000
        let clock = Clock()
        let hk = record(Self.newKey(), createdAtMs: 0)
        clock.serverTimeMs = 10 * hour
        clock.monotonicMs = 5 * hour
        XCTAssertFalse(clock.grace.isOver(hk))
        clock.bootId = "boot-2"
        clock.monotonicMs = 2 * hour
        XCTAssertFalse(clock.grace.isOver(hk), "nouveau démarrage : nouvelle première lecture")
        XCTAssertEqual(clock.stored?.bootId, "boot-2")
        XCTAssertEqual(clock.stored?.firstReadMs[hk.hkPubB64], 2 * hour)
        clock.monotonicMs = 3 * hour
        XCTAssertTrue(clock.grace.isOver(hk))

        let rewound = Clock()
        rewound.serverTimeMs = 10 * hour
        rewound.stored = .init(bootId: "boot-1", firstReadMs: [hk.hkPubB64: 9 * hour])
        rewound.monotonicMs = 4 * hour
        XCTAssertFalse(rewound.grace.isOver(hk))
        XCTAssertEqual(rewound.stored?.firstReadMs[hk.hkPubB64], 4 * hour)
    }

    func testGraceKeepsTheMostRecentFirstReadings() {
        let clock = Clock()
        clock.serverTimeMs = 0
        let keys = (0...E2EEAutoHistoryKeyGrace.maxKept).map { _ in Self.newKey() }
        for (index, hk) in keys.enumerated() {
            clock.monotonicMs = Int64(index)
            _ = clock.grace.isOver(record(hk, createdAtMs: 0))
        }
        XCTAssertEqual(clock.stored?.firstReadMs.count, E2EEAutoHistoryKeyGrace.maxKept)
        XCTAssertNil(clock.stored?.firstReadMs[keys[0]], "la plus ancienne sort")
        XCTAssertNotNil(clock.stored?.firstReadMs[keys[keys.count - 1]])
    }

    // MARK: Acquittements

    func testAcknowledgementsAreKeptPerAccount() {
        let store = InMemoryTokenStore()
        E2EEAutoHistoryKeyAcknowledgements.acknowledge("hk-b", store: store, ownerNamespace: "ns-1")
        E2EEAutoHistoryKeyAcknowledgements.acknowledge("hk-a", store: store, ownerNamespace: "ns-1")
        E2EEAutoHistoryKeyAcknowledgements.acknowledge("hk-a", store: store, ownerNamespace: "ns-1")
        XCTAssertEqual(E2EEAutoHistoryKeyAcknowledgements.load(store, ownerNamespace: "ns-1"), ["hk-a", "hk-b"])
        XCTAssertEqual(E2EEAutoHistoryKeyAcknowledgements.load(store, ownerNamespace: "ns-2"), [])
        XCTAssertEqual(
            try store.string(for: E2EEAutoHistoryKeyAcknowledgements.storageKey(ownerNamespace: "ns-1")), #"["hk-a","hk-b"]"#
        )
    }

    // MARK: Coordinateur (A1 à A4)

    @MainActor
    private func devicesModel(
        _ account: E2EEAutoLog.AccountState, revoked: @escaping @Sendable (String) -> Void = { _ in }
    ) -> E2EEAutoDevicesViewModel {
        let ownId = ownId
        return E2EEAutoDevicesViewModel(dependencies: .init(
            ownDeviceId: { ownId },
            readOwnAccount: { .verified(account) },
            revoke: { id, _ in revoked(id); return .revoked(ownDevice: false) },
            readLabels: { ["web_device_signer_0000001": .init(label: "Chrome sur Windows", lastSeenAtMs: 1)] },
            nowMs: { 100 * E2EEAutoLog.signerMinAgeMs }
        ))
    }

    private func accountWithSigner(status: E2EEAutoLog.DeviceStatus, reason: E2EEAutoLog.RevokeReason? = nil) -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
        for (id, platform, deviceStatus, revokeReason) in [
            (ownId, E2EEAutoLog.Platform.ios, E2EEAutoLog.DeviceStatus.active, E2EEAutoLog.RevokeReason?.none),
            ("web_device_signer_0000001", .web, status, reason),
        ] {
            let key = Self.newKey()
            account.devices[id] = E2EEAutoLog.DeviceState(
                deviceId: id, platform: platform, identityKeyB64: key, signingKeyB64: Self.newKey(), keyVersion: 1, status: deviceStatus,
                addedAtMs: 1, activatedAtMs: 1, addEntryHash: E2EEAutoLog.digest("add-\(id)"),
                identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: 1)],
                revokeReason: revokeReason, revokeSeq: revokeReason == nil ? nil : 9, revokedAtMs: revokeReason == nil ? nil : 2
            )
        }
        account.lastEntryHash = E2EEAutoLog.digest("last")
        return account
    }

    private func info(_ outcome: E2EEAutoHistoryKeyPublication.Outcome, namespace: String = "ns") -> [AnyHashable: Any]? {
        let received = Received()
        let token = NotificationCenter.default.addObserver(forName: E2EEAutoHistoryKeyAlertCoordinator.changed, object: nil, queue: nil) {
            received.userInfo = $0.userInfo
        }
        E2EEAutoHistoryKeyAlertCoordinator.post(outcome, ownerNamespace: namespace)
        NotificationCenter.default.removeObserver(token)
        return received.userInfo
    }

    @MainActor
    func testOutcomesRaiseClearOrKeepTheBanner() {
        var acknowledged: [String] = []
        let coordinator = E2EEAutoHistoryKeyAlertCoordinator { acknowledged.append("\($0)@\($1)") }
        let suspect = E2EEAutoHistoryKeyAlert.Suspect(hkPubB64: "hk-2", signerDeviceId: "web_device_signer_0000001")
        coordinator.apply(info(.unexpected(suspect), namespace: "other"), ownerNamespace: "ns")
        XCTAssertFalse(coordinator.showsBanner, "un autre compte : rien")
        coordinator.apply(info(.unexpected(suspect)), ownerNamespace: "ns")
        XCTAssertTrue(coordinator.showsBanner)
        XCTAssertEqual(coordinator.alert?.suspect, suspect)

        // Un échec de lecture : le bandeau reste.
        for kept: E2EEAutoHistoryKeyPublication.Outcome in [.retryLater(afterSeconds: nil), .logRefused, .notActive, .tooRecent] {
            XCTAssertNil(info(kept))
        }
        XCTAssertTrue(coordinator.showsBanner)
        coordinator.apply(info(.unvouched(hkPubB64: "hk-3")), ownerNamespace: "ns")
        XCTAssertFalse(coordinator.showsBanner, "tout est jugé, ou en grâce : l'alerte tombe")

        // r23.2 : une dernière HK annulée fait tomber l'alerte, sans attendre la rotation depuis la base.
        coordinator.apply(info(.unexpected(suspect)), ownerNamespace: "ns")
        XCTAssertTrue(coordinator.showsBanner)
        coordinator.apply(info(.cancelled(hkPubB64: "hk-2")), ownerNamespace: "ns")
        XCTAssertFalse(coordinator.showsBanner)

        coordinator.apply(info(.unexpected(suspect)), ownerNamespace: "ns")
        XCTAssertEqual(coordinator.itsMe()?.suspect, suspect)
        XCTAssertEqual(acknowledged, ["hk-2@ns"])
        XCTAssertFalse(coordinator.showsBanner)
        XCTAssertNil(coordinator.itsMe())

        coordinator.apply(info(.unexpected(suspect)), ownerNamespace: "ns")
        coordinator.reset()
        XCTAssertFalse(coordinator.showsBanner, "déconnexion")
    }

    /// A2 puis A4 : « Ce n'est pas moi » retire le signataire en `NOT_ME` ; déjà retiré
    /// autrement (T4), rien ne part et la fenêtre l'explique.
    @MainActor
    func testNotMeRevokesTheActiveSignerOnly() async {
        let calls = RevokeLog()
        let coordinator = E2EEAutoHistoryKeyAlertCoordinator { _, _ in }
        let suspect = E2EEAutoHistoryKeyAlert.Suspect(hkPubB64: "hk-2", signerDeviceId: "web_device_signer_0000001")
        coordinator.apply(info(.unexpected(suspect)), ownerNamespace: "ns")
        await coordinator.open { devicesModel(accountWithSigner(status: .active)) { calls.append($0) } }
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.signerRow?.id, "web_device_signer_0000001")
        XCTAssertEqual(
            coordinator.signerRow.map(E2EEAutoHistoryKeyAlertView.deviceName), String(localized: "Navigateur web") + " · Chrome sur Windows"
        )
        await coordinator.notMe()
        XCTAssertTrue(coordinator.answeredNotMe)
        XCTAssertEqual(calls.ids, ["web_device_signer_0000001"])
        XCTAssertNotNil(coordinator.model?.confirmationMessage, "retrait écrit : la fenêtre passe à « Appareil retiré »")
        // r23.2 : la HK est annulée, le bandeau tombe ; la fenêtre « Appareil retiré » garde son signataire.
        coordinator.apply(info(.cancelled(hkPubB64: "hk-2")), ownerNamespace: "ns")
        XCTAssertFalse(coordinator.showsBanner)
        XCTAssertTrue(coordinator.isPresented, "un retrait affiché reste jusqu'à « OK »")
        XCTAssertEqual(coordinator.signerRow?.id, "web_device_signer_0000001")
        coordinator.close()
        XCTAssertNil(coordinator.signerRow)

        let t4 = E2EEAutoHistoryKeyAlertCoordinator { _, _ in }
        t4.apply(info(.unexpected(suspect)), ownerNamespace: "ns")
        await t4.open { devicesModel(accountWithSigner(status: .revoked, reason: .user)) { calls.append($0) } }
        await t4.notMe()
        XCTAssertTrue(t4.answeredNotMe)
        XCTAssertEqual(calls.ids.count, 1, "T4 : aucun nouveau retrait")
        XCTAssertEqual(t4.signerRow.map(E2EEAutoHistoryKeyAlertView.removedAsNotMe), false)

        let removed = E2EEAutoHistoryKeyAlertCoordinator { _, _ in }
        removed.apply(info(.unexpected(suspect)), ownerNamespace: "ns")
        await removed.open { devicesModel(accountWithSigner(status: .revoked, reason: .notMe)) }
        XCTAssertEqual(removed.signerRow.map(E2EEAutoHistoryKeyAlertView.removedAsNotMe), true)
    }

    /// Une autre HK suspecte pendant la question : la fenêtre se referme et le bandeau la porte.
    @MainActor
    func testANewSuspectClosesTheQuestion() async {
        let coordinator = E2EEAutoHistoryKeyAlertCoordinator { _, _ in }
        coordinator.apply(info(.unexpected(.init(hkPubB64: "hk-2", signerDeviceId: "web_device_signer_0000001"))), ownerNamespace: "ns")
        await coordinator.open { devicesModel(accountWithSigner(status: .active)) }
        XCTAssertTrue(coordinator.isPresented)
        coordinator.apply(info(.unexpected(.init(hkPubB64: "hk-4", signerDeviceId: "web_device_signer_0000001"))), ownerNamespace: "ns")
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertEqual(coordinator.alert?.suspect.hkPubB64, "hk-4")
    }

    private final class Received: @unchecked Sendable {
        var userInfo: [AnyHashable: Any]?
    }

    private final class RevokeLog: @unchecked Sendable {
        private(set) var ids: [String] = []
        func append(_ id: String) { ids.append(id) }
    }
}
