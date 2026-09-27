import Foundation
import Combine

@MainActor
final class TwoFactorSetupViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, ready, confirming, loadFailed, needsNewSetup
        case refreshingProfile, profileRefreshFailed, complete, sessionChanged
    }

    @Published private(set) var phase: Phase = .idle
    @Published var code = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var didEnable = false
    @Published private(set) var serverAlreadyEnabled = false

    private let service: TwoFactorEnrollmentServicing
    private let now: () -> Date
    private let acknowledge: @MainActor () throws -> Void
    private let refreshProfile: @MainActor () async throws -> Void
    private var storedSetup: TwoFactorSetupResponse?
    private var operationID = UUID()
    private var closed = false

    init(service: TwoFactorEnrollmentServicing, now: @escaping () -> Date = Date.init,
         acknowledge: @escaping @MainActor () throws -> Void,
         refreshProfile: @escaping @MainActor () async throws -> Void) {
        self.service = service
        self.now = now
        self.acknowledge = acknowledge
        self.refreshProfile = refreshProfile
    }

    var setup: TwoFactorSetupResponse? { isCurrent ? storedSetup : nil }
    var isCurrent: Bool { !closed && service.isCurrent() }
    var isBusy: Bool { [.loading, .confirming, .refreshingProfile].contains(phase) }
    var canConfirm: Bool {
        phase == .ready && setup != nil && TwoFactorEnrollmentService.validCode(normalizedCode)
    }
    var needsProfileRefresh: Bool { didEnable || serverAlreadyEnabled }
    private var normalizedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A malformed URI must not generate a QR for a different secret. Manual
    /// enrollment remains available when an older server does not supply a URI.
    var qrCodeURI: String? {
        guard let setup, let uri = setup.uri, let components = URLComponents(string: uri),
              components.scheme?.lowercased() == "otpauth", components.host?.lowercased() == "totp",
              components.queryItems?.filter({ $0.name == "secret" }).map(\.value) == [setup.secret] else { return nil }
        return uri
    }

    func load() async {
        guard requireCurrent(), !isBusy, !needsProfileRefresh else { return }
        let operation = begin(.loading)
        eraseSecret()
        do {
            let value = try await service.setup()
            guard current(operation) else { return }
            if let expiry = value.expiresAt, expiry <= now() { throw TwoFactorEnrollmentError.expiredSetup }
            storedSetup = value
            phase = .ready
        } catch {
            guard current(operation) else { return }
            handleSetupError(error)
            if serverAlreadyEnabled { await reloadProfile(operation: operation) }
        }
    }

    func confirm() async {
        guard requireCurrent(), phase == .ready, let setup = storedSetup else { return }
        guard TwoFactorEnrollmentService.validCode(normalizedCode) else {
            errorMessage = TwoFactorEnrollmentError.invalidCode.localizedDescription
            return
        }
        if let expiry = setup.expiresAt, expiry <= now() {
            eraseSecret()
            phase = .needsNewSetup
            errorMessage = TwoFactorEnrollmentError.expiredSetup.localizedDescription
            return
        }
        let submittedCode = normalizedCode
        let operation = begin(.confirming)
        do {
            try await service.confirm(secret: setup.secret, code: submittedCode)
            guard current(operation) else { return }
            // A consumed challenge cannot be submitted again after this point,
            // including when the subsequent profile read fails or is cancelled.
            didEnable = true
            eraseSecret()
            try acknowledge()
            guard current(operation) else { return }
            await reloadProfile(operation: operation)
        } catch {
            guard current(operation) else { return }
            code = ""
            if didEnable {
                phase = .profileRefreshFailed
                errorMessage = error.localizedDescription
            } else if let failure = error as? TwoFactorEnrollmentError,
                      [.expiredSetup, .replacedSetup, .alreadyEnabled].contains(failure) {
                handleSetupError(failure)
                if serverAlreadyEnabled { await reloadProfile(operation: operation) }
            } else {
                phase = .ready
                errorMessage = error.localizedDescription
            }
        }
    }

    func retryProfile() async {
        guard requireCurrent(), needsProfileRefresh, !isBusy, phase != .complete else { return }
        let operation = begin(.refreshingProfile)
        await reloadProfile(operation: operation)
    }

    private func reloadProfile(operation: UUID) async {
        phase = .refreshingProfile
        errorMessage = nil
        do {
            try await refreshProfile()
            guard current(operation) else { return }
            phase = .complete
        } catch {
            guard current(operation) else { return }
            phase = .profileRefreshFailed
            errorMessage = error.localizedDescription
        }
    }

    func sessionDidChange() { _ = requireCurrent() }

    func close() {
        closed = true
        operationID = UUID()
        eraseSecret()
    }

    private func handleSetupError(_ error: Error) {
        eraseSecret()
        if error as? TwoFactorEnrollmentError == .alreadyEnabled {
            serverAlreadyEnabled = true
            phase = .profileRefreshFailed
        } else if let failure = error as? TwoFactorEnrollmentError, [.expiredSetup, .replacedSetup].contains(failure) {
            phase = .needsNewSetup
        } else {
            phase = .loadFailed
        }
        errorMessage = error.localizedDescription
    }

    private func begin(_ phase: Phase) -> UUID {
        let operation = UUID()
        operationID = operation
        errorMessage = nil
        self.phase = phase
        return operation
    }

    private func current(_ operation: UUID) -> Bool {
        guard operationID == operation else { return false }
        guard requireCurrent() else { return false }
        guard !Task.isCancelled else {
            eraseSecret()
            phase = needsProfileRefresh ? .profileRefreshFailed : .loadFailed
            errorMessage = APIError.cancelled.localizedDescription
            return false
        }
        return true
    }

    private func requireCurrent() -> Bool {
        guard isCurrent else {
            operationID = UUID()
            eraseSecret()
            didEnable = false
            serverAlreadyEnabled = false
            phase = .sessionChanged
            errorMessage = TwoFactorEnrollmentError.sessionChanged.localizedDescription
            return false
        }
        return true
    }

    private func eraseSecret() {
        storedSetup = nil
        code = ""
    }
}
