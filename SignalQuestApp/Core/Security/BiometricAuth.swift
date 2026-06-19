import Foundation
import LocalAuthentication

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
            case .none: return "la biométrie"
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

    /// Demande une authentification biométrique. Avec `allowPasscode`, le système
    /// propose le code de l'appareil en repli si la biométrie échoue/indisponible.
    /// Retourne `true` uniquement si l'utilisateur s'authentifie.
    @MainActor
    static func authenticate(reason: String, allowPasscode: Bool = true) async -> Bool {
        let context = LAContext()
        let policy: LAPolicy = allowPasscode ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
