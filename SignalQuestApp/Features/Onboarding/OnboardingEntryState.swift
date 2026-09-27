import Foundation
import Combine

enum OnboardingEntryDestination: String, Codable, Equatable, Sendable {
    case map, measure
}

struct OnboardingEntryRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: OnboardingEntryDestination

    init(destination: OnboardingEntryDestination, id: UUID = UUID()) {
        self.id = id
        self.destination = destination
    }
}

/// Préférence de navigation uniquement : ne possède aucun consentement,
/// service GPS ou droit de lancer une mesure.
@MainActor
final class OnboardingEntryState: ObservableObject {
    static let completionKey = "sq.hasCompletedOnboarding"
    static let pendingKey = "sq.onboarding.pendingEntry.v1"

    enum Access: Equatable { case checking, loggedOut, twoFactor, offline, authenticated }
    enum Resolution: Equatable {
        case wait
        case guest(OnboardingEntryRequest)
        case authenticated(OnboardingEntryRequest)
        case superseded(OnboardingEntryRequest)
    }

    @Published private(set) var hasCompleted: Bool
    @Published private(set) var pending: OnboardingEntryRequest?
    @Published private(set) var guestPresentationRevision = 0
    private var preferredGuestSceneID: UUID?
    private var guestReservation: (id: UUID, sceneID: UUID, requestID: UUID)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompleted = defaults.bool(forKey: Self.completionKey)
        // Un reset QA/une installation non terminée ne rejoue jamais une
        // ancienne destination, même si l'écriture de complétion fut interrompue.
        pending = hasCompleted ? defaults.data(forKey: Self.pendingKey).flatMap {
            try? JSONDecoder().decode(OnboardingEntryRequest.self, from: $0)
        } : nil
    }

    func finish(destination: OnboardingEntryDestination?, sceneID: UUID? = nil) {
        guard !hasCompleted else { return }
        let request = destination.map { OnboardingEntryRequest(destination: $0) }
        if let request, let data = try? JSONEncoder().encode(request) {
            defaults.set(data, forKey: Self.pendingKey)
        } else {
            defaults.removeObject(forKey: Self.pendingKey)
        }
        defaults.set(true, forKey: Self.completionKey)
        preferredGuestSceneID = request == nil ? nil : sceneID
        pending = request
        hasCompleted = true
    }

    /// Le callback d'une ancienne présentation ne consomme pas un autre choix.
    func consume(_ request: OnboardingEntryRequest) {
        guard pending?.id == request.id else { return }
        defaults.removeObject(forKey: Self.pendingKey)
        guestReservation = nil
        preferredGuestSceneID = nil
        pending = nil
        guestPresentationRevision += 1
    }

    /// Une seule scène réserve le choix ; la scène du geste reste prioritaire
    /// tant qu'elle est active. Cette réservation ne survit pas au process.
    func reserveGuestPresentation(_ request: OnboardingEntryRequest, sceneID: UUID) -> OnboardingGuestLease? {
        guard pending?.id == request.id, guestReservation == nil,
              preferredGuestSceneID == nil || preferredGuestSceneID == sceneID else { return nil }
        let id = UUID()
        guestReservation = (id, sceneID, request.id)
        guestPresentationRevision += 1
        return OnboardingGuestLease(id: id, request: request, state: self)
    }

    fileprivate func isGuestReservationValid(_ id: UUID, requestID: UUID) -> Bool {
        guestReservation?.id == id && guestReservation?.requestID == requestID && pending?.id == requestID
    }

    fileprivate func releaseGuestReservation(_ id: UUID) {
        guard guestReservation?.id == id else { return }
        guestReservation = nil
        guestPresentationRevision += 1
    }

    func releaseGuestScene(_ sceneID: UUID) {
        let ownsReservation = guestReservation?.sceneID == sceneID
        let ownsPreference = preferredGuestSceneID == sceneID
        guard ownsReservation || ownsPreference else { return }
        if ownsReservation { guestReservation = nil }
        if ownsPreference { preferredGuestSceneID = nil }
        guestPresentationRevision += 1
    }

    func resolve(access: Access, updateRequired: Bool, locked: Bool,
                 hasExternalRoute: Bool) -> Resolution {
        guard hasCompleted, let pending, !updateRequired, !locked else { return .wait }
        switch access {
        case .checking, .twoFactor, .offline: return .wait
        case .loggedOut, .authenticated:
            if hasExternalRoute { return .superseded(pending) }
            return access == .loggedOut ? .guest(pending) : .authenticated(pending)
        }
    }
}

/// Le jeton de réservation empêche un ancien callback de confirmer une nouvelle
/// présentation. Une disparition de la vue libère le choix, sans le consommer.
@MainActor
final class OnboardingGuestLease {
    let id: UUID
    let request: OnboardingEntryRequest
    private weak var state: OnboardingEntryState?
    private(set) var didPresent = false

    fileprivate init(id: UUID, request: OnboardingEntryRequest, state: OnboardingEntryState) {
        self.id = id
        self.request = request
        self.state = state
    }

    var isValid: Bool { state?.isGuestReservationValid(id, requestID: request.id) == true }

    func acknowledge() -> Bool {
        guard !didPresent, isValid, let state else { return false }
        didPresent = true
        state.consume(request)
        return true
    }

    func release() {
        state?.releaseGuestReservation(id)
        state = nil
    }

    deinit {
        let state = state, id = id
        Task { @MainActor in state?.releaseGuestReservation(id) }
    }
}

/// Durée de vie de la scène, indépendante des covers de LoginView.
@MainActor
final class OnboardingSceneContext: ObservableObject {
    let id = UUID()
    private weak var entry: OnboardingEntryState?
    func attach(to entry: OnboardingEntryState) { self.entry = entry }
    deinit {
        let entry = entry, id = id
        Task { @MainActor in entry?.releaseGuestScene(id) }
    }
}

