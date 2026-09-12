import Foundation

/// Identité de connexion opaque, indépendante de la rotation du token HTTP.
struct SpeedtestVisibilitySession: Equatable, Sendable {
    let credentialSessionID: UUID
    let ownerScopeID: String
    let localSessionID: String
}

struct SpeedtestVisibilityState: Equatable, Sendable {
    let id: String
    let isOwner: Bool
    let isVisibleOnMap: Bool
    let isPublic: Bool
    let hasMapPosition: Bool

    var isSharedOnMap: Bool { isPublic && isVisibleOnMap && hasMapPosition }
}

struct SpeedtestVisibilityResponse: Decodable, Equatable, Sendable {
    let success: Bool
    let id: String
    let isVisibleOnMap: Bool
    let isPublic: Bool
    let isSharedOnMap: Bool
    let changed: Bool
    let mapEpoch: Int64?

    func validate(serverID: String, requestedVisibility: Bool) throws {
        guard success, id == serverID, !id.isEmpty,
              isVisibleOnMap == requestedVisibility,
              !isSharedOnMap || (isVisibleOnMap && isPublic) else {
            throw SpeedtestVisibilityError.unconfirmedResponse
        }
    }
}

protocol SpeedtestVisibilityServicing: Sendable {
    var visibilitySession: SpeedtestVisibilitySession? { get }
    func visibility(forClientID clientID: UUID, session: SpeedtestVisibilitySession) async throws -> SpeedtestVisibilityState?
    func setVisibility(serverID: String, visible: Bool, session: SpeedtestVisibilitySession) async throws -> SpeedtestVisibilityResponse
}

enum SpeedtestVisibilityError: LocalizedError, Equatable {
    case unconfirmedResponse
    case sessionChanged

    var errorDescription: String? {
        switch self {
        case .unconfirmedResponse:
            String(localized: "La visibilité n’a pas pu être confirmée. Réessaie de la vérifier avant de modifier ce test.")
        case .sessionChanged:
            String(localized: "Le compte a changé. Rouvre la fiche depuis ton compte pour gérer ce test.")
        }
    }
}

/// Événement local de mutation confirmée : le consommateur doit vérifier la
/// session avant d'invalider sa couche. Cet événement ne prétend pas purger la carte.
struct SpeedtestMapVisibilityChange: Equatable, Sendable {
    let serverID: String
    let session: SpeedtestVisibilitySession
    let isSharedOnMap: Bool
    let mapEpoch: Int64?
}

extension Notification.Name {
    static let sqSpeedtestMapVisibilityChanged = Notification.Name("fr.signalquest.ios.speedtestMapVisibilityChanged")
}
