import Foundation

/// Issue d'un envoi de texte chiffré v2 pour la reprise automatique (QA-066, même règle
/// qu'Android) : remis, panne passagère qui repartira seule, mise à jour attendue, ou refus.
enum E2EEV2PendingSendDisposition: Equatable, Sendable {
    case delivered
    /// Aucune réponse (coupure, appareil verrouillé ou en cours d'inscription), serveur en panne
    /// (5xx), délai (408, 425), frein (429), rejeu en conflit, ou époque encore à synchroniser
    /// après les tours de l'envoi : le même envoi repartira seul.
    case transient
    /// Un membre doit mettre à jour SignalQuest, ou cette app (426) : la bulle reste « Non envoyé »,
    /// l'enveloppe gardée, renvoyable d'un toucher.
    case awaitingUpdate
    /// Tout le reste, dont la limite quotidienne de demandes (429 `MESSAGE_REQUEST_LIMIT`) et la
    /// demande pas encore acceptée : réessayer n'y changerait rien, le texte revient à l'auteur.
    case refused

    init(_ result: E2EEV2MessageSendResultV2) {
        switch result {
        case .sent, .alreadyAccepted: self = .delivered
        case .capabilityMissing: self = .awaitingUpdate
        case .failure(let failure) where failure.statusCode == 426: self = .awaitingUpdate
        case .failure(let failure): self = Self.isTransient(failure) ? .transient : .refused
        // « Synchroniser, puis réessayer » ; Android s'aligne (22/11).
        case .needsEpoch, .needsRotation, .compromisedEpoch: self = .transient
        case .membersNotTrusted: self = .refused
        }
    }

    /// L'annuaire des appareils illisible ou une liste encore périmée sont déjà `.retryable` ;
    /// une synchronisation de la conversation en attente est un état local qui se lève seul
    /// (Android, 5d353dddd). Les autres états locaux (illisibles, invalides) restent des refus.
    static func isTransient(_ failure: E2EEV2TransportFailure) -> Bool {
        switch failure.kind {
        case .retryable: return failure.code != MessageRequestLimitError.code
        case .localState: return failure.message == "e2ee-membership-behind"
        default: return false
        }
    }
}

/// Reprise automatique des textes chiffrés v2 gardés dans la file durable (QA-066, comme
/// `E2EEV2PendingTextResender` d'Android) : un essai 15 s après une panne passagère, puis un délai
/// doublé jusqu'à 5 min ; tout de suite au retour du réseau, au premier plan ou à l'ouverture d'une
/// conversation qui en garde. Un seul passage à la fois, et un texte qu'un écran envoie lui-même
/// est réservé : le passage le saute, jamais deux envois du même message en même temps.
@MainActor
final class E2EEV2PendingSendScheduler {
    static let firstRetry: Duration = .seconds(15)
    static let maxRetry: Duration = .seconds(300)
    /// Un texte rejoué en arrière-plan est remis, attend une mise à jour ou revient à l'auteur :
    /// l'écran de la conversation, s'il est ouvert, met sa bulle à jour.
    static let didResolve = Notification.Name("SignalQuest.E2EEV2PendingSendDidResolve")

    struct Resolution: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case delivered
            case awaitingUpdate(reason: String)
            /// Le texte a quitté la file et attend dans le brouillon de la conversation.
            case refused(reason: String)
        }
        let clientRequestId: String
        let conversationId: String
        let text: String
        let outcome: Outcome
    }

    /// Un passage sur la file ; vrai s'il s'est arrêté sur une panne passagère.
    typealias Pass = @MainActor (E2EEV2PendingSendScheduler) async -> Bool

    private let pass: Pass
    private let sleep: @Sendable (Duration) async -> Void
    private var running: Task<Bool, Never>?
    private var armed: Task<Void, Never>?
    private var retryRequested = false
    private var reserved: Set<String> = []
    /// Attente avant l'essai armé suivant.
    private(set) var nextDelay: Duration = firstRetry

    init(
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        pass: @escaping Pass
    ) {
        self.sleep = sleep
        self.pass = pass
    }

    var isArmed: Bool { armed != nil }

    /// Faux si ce texte part déjà (depuis un écran ou un passage).
    func reserve(_ clientRequestId: String) -> Bool { reserved.insert(clientRequestId).inserted }
    func release(_ clientRequestId: String) { reserved.remove(clientRequestId) }

    /// Passage immédiat, ou attente de celui en cours ; une panne passagère arme l'essai suivant.
    func runNow() async {
        armed?.cancel()
        armed = nil
        if let running {
            _ = await running.value
            return
        }
        retryRequested = false
        let task = Task { await self.pass(self) }
        running = task
        let transient = await task.value
        running = nil
        if transient {
            arm()
        } else {
            nextDelay = Self.firstRetry
            if retryRequested { arm() }
        }
    }

    /// Un écran vient d'essuyer une panne passagère : essai dans 15 s, ou au délai déjà armé.
    func scheduleRetry() {
        if running != nil {
            retryRequested = true
            return
        }
        guard armed == nil else { return }
        arm()
    }

    private func arm() {
        let wait = nextDelay
        nextDelay = min(nextDelay * 2, Self.maxRetry)
        armed = Task { [weak self, sleep] in
            await sleep(wait)
            guard !Task.isCancelled, let self else { return }
            self.armed = nil
            await self.runNow()
        }
    }
}
