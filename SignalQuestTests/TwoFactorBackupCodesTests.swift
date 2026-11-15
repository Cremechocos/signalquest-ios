import XCTest
@testable import SignalQuest

/// Repère de la règle A en mémoire.
final class MemoryBackupCodesMarkers: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TwoFactorBackupCodesMarker?
    var value: TwoFactorBackupCodesMarker? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var store: TwoFactorBackupCodesMarkerStore {
        TwoFactorBackupCodesMarkerStore(load: { self.value }, save: { self.value = $0 })
    }
}

/// Codes de secours (contrat 2FA r3.3) : saisie, règle A, textes du §8 et corps des requêtes.
final class TwoFactorBackupCodesTests: XCTestCase {
    private let generatedAt = "2026-11-15T21:37:00.000Z"

    func testValidateIsEnabledFromTenCharactersWithoutSpacesAndDashes() {
        for input in ["ABCDE-FGHJK", "abcde fghjk", "ABCDEFGHJK", " ab cd e-fg hj k "] {
            XCTAssertTrue(TwoFactorBackupCodes.isInputReady(input), input)
        }
        for input in ["", "ABCDE-FGHJ", "ABCDE -- FGHJ", String(repeating: "A", count: 25)] {
            XCTAssertFalse(TwoFactorBackupCodes.isInputReady(input), input)
        }
        XCTAssertTrue(TwoFactorEnrollmentService.isReady(.backup("abcde-fghjk")))
        XCTAssertFalse(TwoFactorEnrollmentService.isReady(.backup("12345")))
        XCTAssertTrue(TwoFactorEnrollmentService.isReady(.app("123456")))
        XCTAssertFalse(TwoFactorEnrollmentService.isReady(.app("ABCDE-FGHJK")))
    }

    func testProofBodiesCarryExactlyOneFactorAsTyped() throws {
        let backup = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            TwoFactorVerifyRequest(tempToken: "t", proof: .backup("abcde fghjk")))) as? [String: Any]
        XCTAssertEqual(backup?["backupCode"] as? String, "abcde fghjk")
        XCTAssertNil(backup?["code"])
        XCTAssertEqual(backup?["tempToken"] as? String, "t")
        let app = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            TwoFactorProofRequest(proof: .app("123456")))) as? [String: Any]
        XCTAssertEqual(app?["code"] as? String, "123456")
        XCTAssertNil(app?["backupCode"])
        XCTAssertEqual(app?.count, 1)
    }

    func testLoginAnswerReadsTheRemainingCodesOnlyWhenServed() throws {
        let afterBackup = try JSONDecoder.signalQuest.decode(LoginResponse.self, from: Data(
            #"{"user":null,"backupCodesRemaining":0}"#.utf8))
        XCTAssertEqual(afterBackup.backupCodesRemaining, 0)
        let afterApp = try JSONDecoder.signalQuest.decode(LoginResponse.self, from: Data(#"{"user":null}"#.utf8))
        XCTAssertNil(afterApp.backupCodesRemaining)
    }

    func testReconcileFollowsTheShownBatch() {
        let served = TwoFactorBackupCodeStatus(remaining: 10, generatedAt: generatedAt)
        let off = TwoFactorBackupCodeStatus(remaining: 0, generatedAt: nil)
        XCTAssertNil(TwoFactorBackupCodesMarker.reconcile(nil, with: served))
        // Lot refait ailleurs, ou 2FA coupée : le repère tombe.
        XCTAssertNil(TwoFactorBackupCodesMarker.reconcile(.batch(generatedAt: "older"), with: served))
        XCTAssertNil(TwoFactorBackupCodesMarker.reconcile(.batch(generatedAt: generatedAt), with: off))
        XCTAssertEqual(TwoFactorBackupCodesMarker.reconcile(.batch(generatedAt: generatedAt), with: served),
                       .batch(generatedAt: generatedAt))
        // Réponse perdue : un nouveau lot est adopté, l'ancien jamais.
        XCTAssertEqual(TwoFactorBackupCodesMarker.reconcile(.unknown(previous: "older"), with: served),
                       .batch(generatedAt: generatedAt))
        XCTAssertNil(TwoFactorBackupCodesMarker.reconcile(.unknown(previous: generatedAt), with: served))
        XCTAssertNil(TwoFactorBackupCodesMarker.reconcile(.unknown(previous: nil), with: off))
    }

    func testTrackedCreationPosesTheMarkerBeforeSending() async throws {
        let markers = MemoryBackupCodesMarkers()
        markers.value = .batch(generatedAt: "older")
        let seenWhileSending = MemoryBackupCodesMarkers()
        let generatedAt = generatedAt
        let batch = try await TwoFactorBackupCodes.createTracked(
            previous: "older", markers: markers.store,
            create: {
                seenWhileSending.value = markers.value
                return TwoFactorBackupCodeBatch(codes: ["ABCDE-FGHJK"], generatedAt: generatedAt)
            },
            readStatus: { XCTFail("Served generatedAt needs no read"); throw APIError.cancelled })
        XCTAssertEqual(seenWhileSending.value, .unknown(previous: "older"))
        XCTAssertEqual(batch?.codes, ["ABCDE-FGHJK"])
        XCTAssertEqual(markers.value, .batch(generatedAt: generatedAt))
    }

    func testTrackedCreationReadsTheBatchWhenTheAnswerLacksIt() async throws {
        let markers = MemoryBackupCodesMarkers()
        let generatedAt = generatedAt
        _ = try await TwoFactorBackupCodes.createTracked(
            previous: "older", markers: markers.store,
            create: { TwoFactorBackupCodeBatch(codes: ["ABCDE-FGHJK"], generatedAt: nil) },
            readStatus: { TwoFactorBackupCodeStatus(remaining: 10, generatedAt: generatedAt) })
        XCTAssertEqual(markers.value, .batch(generatedAt: generatedAt))

        // Relecture qui échoue, ou qui rend encore l'ancien lot : le repère attend.
        let failed = MemoryBackupCodesMarkers()
        _ = try await TwoFactorBackupCodes.createTracked(
            previous: "older", markers: failed.store,
            create: { TwoFactorBackupCodeBatch(codes: ["ABCDE-FGHJK"], generatedAt: nil) },
            readStatus: { throw APIError.transport("synthetic") })
        XCTAssertEqual(failed.value, .unknown(previous: "older"))
        let stale = MemoryBackupCodesMarkers()
        _ = try await TwoFactorBackupCodes.createTracked(
            previous: "older", markers: stale.store,
            create: { TwoFactorBackupCodeBatch(codes: ["ABCDE-FGHJK"], generatedAt: nil) },
            readStatus: { TwoFactorBackupCodeStatus(remaining: 10, generatedAt: "older") })
        XCTAssertEqual(stale.value, .unknown(previous: "older"))
    }

    func testRefusalRestoresTheMarkerAndAnAmbiguousFailureKeepsIt() async {
        let refusals: [Error] = [
            TwoFactorEnrollmentError.invalidCode, TwoFactorEnrollmentError.invalidBackupCode,
            APIError.http(status: 429, code: nil, message: "", requestId: nil, retryAfter: 30),
        ]
        for error in refusals {
            let markers = MemoryBackupCodesMarkers()
            markers.value = .batch(generatedAt: "older")
            do {
                _ = try await TwoFactorBackupCodes.createTracked(previous: "older", markers: markers.store,
                    create: { throw error }, readStatus: { throw APIError.cancelled })
                XCTFail("Refusal expected")
            } catch {}
            XCTAssertEqual(markers.value, .batch(generatedAt: "older"), "\(error)")
        }
        let ambiguous: [Error] = [
            APIError.transport("synthetic"), TwoFactorEnrollmentError.unconfirmedResponse,
            TwoFactorEnrollmentError.sessionChanged,
            APIError.http(status: 503, code: nil, message: "", requestId: nil, retryAfter: nil),
        ]
        for error in ambiguous {
            let markers = MemoryBackupCodesMarkers()
            do {
                _ = try await TwoFactorBackupCodes.createTracked(previous: nil, markers: markers.store,
                    create: { throw error }, readStatus: { throw APIError.cancelled })
                XCTFail("Failure expected")
            } catch {}
            XCTAssertEqual(markers.value, .unknown(previous: nil), "\(error)")
        }
    }

    func testMarkerStoreRoundTripsPerAccount() {
        let store = TwoFactorBackupCodesMarkerStore.live(userID: "backup-codes-test-\(UUID().uuidString)")
        defer { store.save(nil) }
        XCTAssertNil(store.load())
        store.save(.unknown(previous: nil))
        XCTAssertEqual(store.load(), .unknown(previous: nil))
        store.save(.unknown(previous: generatedAt))
        XCTAssertEqual(store.load(), .unknown(previous: generatedAt))
        store.save(.batch(generatedAt: generatedAt))
        XCTAssertEqual(store.load(), .batch(generatedAt: generatedAt))
        store.save(nil)
        XCTAssertNil(store.load())
    }

    func testCounterGivesZeroItsOwnTextThenPlurals() {
        let french = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
        XCTAssertEqual(TwoFactorBackupCodes.remainingText(0), french ? "Aucun code de secours restant" : "No backup codes left")
        XCTAssertEqual(TwoFactorBackupCodes.remainingText(1), french ? "1 code de secours restant" : "1 backup code left")
        XCTAssertEqual(TwoFactorBackupCodes.remainingText(7), french ? "7 codes de secours restants" : "7 backup codes left")
    }

    func testSecurityStateShowsTheUnconfirmedTextFirst() {
        let french = Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
        let status = TwoFactorBackupCodeStatus(remaining: 3, generatedAt: generatedAt)
        XCTAssertEqual(TwoFactorBackupCodes.stateText(status: status, unconfirmed: true), french
            ? "Tu n’as pas confirmé avoir noté tes codes de secours. Génère-en de nouveaux pour les noter."
            : "You didn’t confirm you saved your backup codes. Generate new ones to save them.")
        let state = TwoFactorBackupCodes.stateText(status: status, unconfirmed: false)
        XCTAssertEqual(state?.hasPrefix(french ? "3 codes de secours restants · Générés le " : "3 backup codes left · Generated on "), true,
                       state ?? "nil")
        XCTAssertEqual(TwoFactorBackupCodes.stateText(status: .init(remaining: 0, generatedAt: nil), unconfirmed: false),
                       french ? "Aucun code de secours restant" : "No backup codes left")
        XCTAssertNil(TwoFactorBackupCodes.stateText(status: nil, unconfirmed: false))
        XCTAssertNotNil(TwoFactorBackupCodes.parseDate("2026-11-15T21:37:00Z"))
        XCTAssertNotNil(TwoFactorBackupCodes.parseDate(generatedAt))
    }
}

/// Règle B : après une connexion par code de secours, rien s'il en reste ; le dernier appelle un message.
@MainActor
final class TwoFactorBackupCodeLoginTests: XCTestCase {
    private func signedInWithBackupCode(remaining: Int?) async -> (AuthSessionViewModel, MockAuthService) {
        let service = MockAuthService()
        service.appleResponses = [.success(LoginResponse(user: nil, requires2FA: true, tempToken: "temporary"))]
        service.verifyResponses = [.success(LoginResponse(user: .mock, requires2FA: nil, tempToken: nil,
                                                          backupCodesRemaining: remaining))]
        let session = AuthSessionViewModel(service: service)
        await session.bootstrap()
        _ = await session.signInWithApple(identityToken: "synthetic", fullName: nil, acceptedTerms: false)
        XCTAssertEqual(session.state, .requires2FA(tempToken: "temporary"))
        await session.verify2FA(proof: .backup("abcde-fghjk"))
        return (session, service)
    }

    func testLastBackupCodeShowsTheNoticeOnce() async {
        let (session, service) = await signedInWithBackupCode(remaining: 0)
        XCTAssertEqual(service.verifyProofs, [.backup("abcde-fghjk")])
        XCTAssertEqual(session.state, .authenticated(AuthUser.mock.withConfirmedTwoFactor(enabled: true)))
        XCTAssertTrue(session.lastBackupCodeNotice)
        session.cancelTwoFactor()
        XCTAssertFalse(session.lastBackupCodeNotice, "Leaving the session drops the notice")
    }

    func testRemainingCodesOrAnAppCodeShowNothing() async {
        for remaining in [1, 9, nil] as [Int?] {
            let (session, _) = await signedInWithBackupCode(remaining: remaining)
            XCTAssertFalse(session.lastBackupCodeNotice, "\(String(describing: remaining))")
        }
    }
}
