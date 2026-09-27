import Foundation
import LocalAuthentication

/// Interface étroite pour vérifier les choix de politique et l'annulation sans
/// solliciter un capteur ou une invite système pendant les tests unitaires.
@MainActor
protocol DeviceAuthenticationContext: AnyObject, Sendable {
    func canEvaluate(_ policy: LAPolicy) -> Bool
    func evaluate(_ policy: LAPolicy, reason: String) async -> Bool
    func invalidate()
}

@MainActor
private final class SystemDeviceAuthenticationContext: DeviceAuthenticationContext {
    private let context = LAContext()

    func canEvaluate(_ policy: LAPolicy) -> Bool {
        context.canEvaluatePolicy(policy, error: nil)
    }

    func evaluate(_ policy: LAPolicy, reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    func invalidate() { context.invalidate() }
}

/// Façade LocalAuthentication pour Face ID / Touch ID — verrouillage de l'app et
/// déverrouillage des secrets E2EE. Aucune dépendance backend.
enum BiometricAuth {
    enum Kind {
        case faceID, touchID, none

        /// Libellé utilisateur (« Face ID », « Touch ID »).
        var label: String {
            switch self {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .none: return String(localized: "la biométrie")
            }
        }

        var systemImage: String {
            switch self {
            case .faceID: return "faceid"
            case .touchID: return "touchid"
            case .none: return "lock.shield"
            }
        }
    }

    /// Type de biométrie disponible sur l'appareil, sans déclencher d'invite.
    static var kind: Kind {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    static var isAvailable: Bool { kind != .none }

    /// Capacité du verrou de l'app, distincte de la biométrie seule utilisée par
    /// les secrets E2EE : un appareil avec code, sans Face ID, reste compatible.
    static var canAuthenticateDeviceOwner: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Demande une authentification biométrique. Avec `allowPasscode`, le système
    /// propose le code de l'appareil en repli si la biométrie échoue/indisponible.
    /// Retourne `true` uniquement si l'utilisateur s'authentifie.
    @MainActor
    static func authenticate(reason: String, allowPasscode: Bool = true) async -> Bool {
        await authenticate(reason: reason, allowPasscode: allowPasscode,
            context: SystemDeviceAuthenticationContext())
    }

    @MainActor
    static func authenticate(
        reason: String,
        allowPasscode: Bool = true,
        context: any DeviceAuthenticationContext
    ) async -> Bool {
        let policy: LAPolicy = allowPasscode ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
        guard !Task.isCancelled, context.canEvaluate(policy) else { return false }
        let result = await withTaskCancellationHandler {
            // Le code appareil reste proposé par le système lorsque la biométrie
            // seule est absente ou en lockout. Aucun repli ne contourne la preuve.
            await context.evaluate(policy, reason: reason)
        } onCancel: {
            Task { @MainActor in
                context.invalidate()
            }
        }
        return result && !Task.isCancelled
    }
}
