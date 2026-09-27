import Foundation
import Combine

@MainActor
final class SpeedtestVisibilityViewModel: ObservableObject {
    enum Availability: Equatable {
        case unknown
        case guest
        case noServerReference
        case loaded
        case sessionChanged
    }

    struct PublicationConfirmation: Equatable, Identifiable, Sendable {
        let id: UUID
        let serverID: String
    }

    @Published private(set) var state: SpeedtestVisibilityState?
    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isStateCurrent = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var confirmationMessage: String?
    @Published private(set) var publicationBlockedByVPN = false

    private let clientID: UUID
    private let service: any SpeedtestVisibilityServicing
    private let session: SpeedtestVisibilitySession?
    private let guestMode: Bool
    private let vpnIsActive: @Sendable () -> Bool
    private var generation = UUID()
    private var active = true
    private var publicationConfirmation: PublicationConfirmation?

    init(clientID: UUID, service: any SpeedtestVisibilityServicing, guestMode: Bool,
         vpnIsActive: @escaping @Sendable () -> Bool) {
        self.clientID = clientID
        self.service = service
        self.guestMode = guestMode
        self.vpnIsActive = vpnIsActive
        session = guestMode ? nil : service.visibilitySession
        publicationBlockedByVPN = vpnIsActive()
    }

    var canHide: Bool {
        active && isStateCurrent && !isLoading && !isSaving && currentSessionMatches
            && state?.isOwner == true && state?.isVisibleOnMap == true
    }

    var canPublish: Bool {
        active && isStateCurrent && !isLoading && !isSaving && currentSessionMatches
            && state?.isOwner == true && state?.isVisibleOnMap == false
            && state?.isPublic == true && state?.hasMapPosition == true
            && !publicationBlockedByVPN
    }

    private var currentSessionMatches: Bool {
        session != nil && session == service.visibilitySession
    }

    func refreshAvailability() {
        publicationBlockedByVPN = vpnIsActive()
        if !guestMode, !currentSessionMatches { showSessionChanged() }
    }

    func load() async {
        guard active, !isSaving else { return }
        generation = UUID()
        let currentGeneration = generation
        publicationConfirmation = nil
        errorMessage = nil
        confirmationMessage = nil
        isStateCurrent = false
        if guestMode {
            state = nil
            availability = .guest
            return
        }
        guard let session, currentSessionMatches else { showSessionChanged(); return }
        availability = .unknown
        isLoading = true
        defer { if generation == currentGeneration { isLoading = false } }
        do {
            let loaded = try await service.visibility(forClientID: clientID, session: session)
            guard canApply(currentGeneration) else { return }
            state = loaded
            availability = loaded == nil ? .noServerReference : .loaded
            isStateCurrent = loaded != nil
            publicationBlockedByVPN = vpnIsActive()
        } catch {
            guard canApply(currentGeneration) else { return }
            state = nil
            if !error.isCancellation { errorMessage = Self.message(for: error) }
        }
    }

    /// L'ouverture de la confirmation ne publie rien. Le jeton ne vaut que pour
    /// cette fiche, ce serveur et cette lecture propriétaire.
    func requestPublicationConfirmation() -> PublicationConfirmation? {
        refreshAvailability()
        guard canPublish, let state else { return nil }
        let confirmation = PublicationConfirmation(id: UUID(), serverID: state.id)
        publicationConfirmation = confirmation
        return confirmation
    }

    func cancelPublicationConfirmation() { publicationConfirmation = nil }

    func confirmPublication(_ confirmation: PublicationConfirmation) async {
        refreshAvailability()
        guard publicationConfirmation == confirmation, canPublish,
              state?.id == confirmation.serverID else { return }
        publicationConfirmation = nil
        await update(visible: true)
    }

    func hide() async {
        guard canHide else { return }
        await update(visible: false)
    }

    func deactivate() {
        active = false
        generation = UUID()
        publicationConfirmation = nil
        state = nil
        isStateCurrent = false
        isLoading = false
        isSaving = false
        errorMessage = nil
        confirmationMessage = nil
    }

    private func update(visible: Bool) async {
        guard let session, let before = state, currentSessionMatches else { showSessionChanged(); return }
        let currentGeneration = UUID()
        generation = currentGeneration
        isSaving = true
        isStateCurrent = false
        errorMessage = nil
        confirmationMessage = nil
        defer { if generation == currentGeneration { isSaving = false } }
        do {
            let response = try await service.setVisibility(serverID: before.id, visible: visible, session: session)
            guard canApply(currentGeneration) else { return }
            try response.validate(serverID: before.id, requestedVisibility: visible)
            // Le PATCH confirme l'écriture ; le GET propriétaire permet de lire
            // la valeur persistée, y compris une modification depuis un autre appareil.
            guard let reloaded = try await service.visibility(forClientID: clientID, session: session) else {
                throw SpeedtestVisibilityError.unconfirmedResponse
            }
            guard canApply(currentGeneration) else { return }
            guard reloaded.id == before.id, reloaded.isOwner,
                  reloaded.isVisibleOnMap == response.isVisibleOnMap,
                  reloaded.isPublic == response.isPublic,
                  reloaded.isSharedOnMap == response.isSharedOnMap else {
                throw SpeedtestVisibilityError.unconfirmedResponse
            }
            state = reloaded
            availability = .loaded
            isStateCurrent = true
            confirmationMessage = reloaded.isSharedOnMap
                ? String(localized: "Publication confirmée. Ce test est visible sur la carte publique.")
                : reloaded.isVisibleOnMap
                    ? String(localized: "Visibilité enregistrée. Ce test reste hors de la carte publique.")
                    : String(localized: "Masquage confirmé. Ce test reste dans ton historique.")
        } catch {
            guard canApply(currentGeneration) else { return }
            // L'ancien état reste une référence, jamais une confirmation : une
            // perte de réponse peut survenir après le commit côté serveur.
            isStateCurrent = false
            if !error.isCancellation { errorMessage = Self.message(for: error) }
        }
    }

    private func canApply(_ expectedGeneration: UUID) -> Bool {
        guard active, generation == expectedGeneration else { return false }
        guard currentSessionMatches else { showSessionChanged(); return false }
        return !Task.isCancelled
    }

    private func showSessionChanged() {
        generation = UUID()
        state = nil
        availability = .sessionChanged
        publicationConfirmation = nil
        isStateCurrent = false
        isLoading = false
        isSaving = false
        confirmationMessage = nil
        errorMessage = SpeedtestVisibilityError.sessionChanged.localizedDescription
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? APIError, case let .http(_, code, _, _, _) = apiError {
            switch code {
            case "SPEEDTEST_PRIVATE_ZONE":
                return String(localized: "Ce test se trouve dans une zone privée et reste masqué. Tu peux gérer tes zones dans Confidentialité.")
            case "SPEEDTEST_NOT_SHAREABLE":
                return String(localized: "Ce test n’est pas éligible à la carte publique.")
            case "SPEEDTEST_LOCATION_UNAVAILABLE":
                return String(localized: "Ce test ne dispose pas d’une position exploitable pour la carte.")
            case "SPEEDTEST_PRIVACY_UNAVAILABLE":
                return String(localized: "La protection de tes zones privées est indisponible. Réessaie plus tard.")
            default: break
            }
        }
        return error.localizedDescription
    }
}
