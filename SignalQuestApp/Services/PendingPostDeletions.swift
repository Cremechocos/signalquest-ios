import Foundation
import UIKit

/// Suppressions de publications en attente de leur délai « Annuler » (choix d'Alexandre du
/// 25/11 : annulable partout, et fiable).
///
/// La publication quitte l'écran tout de suite ; la requête ne part qu'au terme du délai. Avant,
/// ce délai ne vivait que dans une tâche du fil : app tuée ou fil fermé pendant les 5 s, rien ne
/// partait et la publication revenait au chargement suivant, alors que l'écran avait dit
/// « Publication supprimée » (constat COM-01). Chaque suppression est donc aussi inscrite sur
/// l'appareil, par compte, et `flush` envoie au lancement ou au retour du réseau celles dont le
/// délai est passé sans envoi.
@MainActor
final class PendingPostDeletions {
    static let shared = PendingPostDeletions()

    struct Entry: Codable, Equatable {
        let postId: String
        let ownerScopeId: String
        let due: Date
    }

    /// Délai « Annuler » : 5 s, comme Android et le web ; le double avec VoiceOver, le temps
    /// d'entendre le bandeau et d'atteindre son bouton (WCAG 2.2.1).
    static var undoDelay: Duration {
        UIAccessibility.isVoiceOverRunning ? .seconds(10) : .seconds(5)
    }

    /// Une inscription plus vieille que ça n'est plus envoyée : la publication a pu être
    /// supprimée ailleurs, ou le compte changé depuis longtemps.
    nonisolated static let maxAge: TimeInterval = 7 * 24 * 3600

    private let defaults: UserDefaults
    private let storageKey: String
    private var timers: [String: Task<Void, Never>] = [:]
    private var sending: Set<String> = []

    init(defaults: UserDefaults = .standard, storageKey: String = "SignalQuest.PendingPostDeletions.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// Publication en cours de suppression pour le compte courant : un rechargement ne doit
    /// pas la rendre.
    func isPending(_ postId: String) -> Bool {
        pendingPostIds.contains(postId)
    }

    /// Toutes les publications en attente du compte courant, lues une fois pour filtrer une page.
    var pendingPostIds: Set<String> {
        let owner = LocalAccountScope.currentOwnerScopeId
        return Set(entries.filter { $0.ownerScopeId == owner }.map(\.postId))
    }

    /// Programme la suppression. `completion` reçoit le verdict du serveur si l'app tourne
    /// encore au terme du délai ; après un refus, la publication n'est plus en attente.
    func schedule(
        postId: String,
        after delay: Duration,
        service: SocialFeedServicing,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        guard timers[postId] == nil, !sending.contains(postId) else { return }
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        var all = entries.filter { $0.postId != postId }
        all.append(Entry(postId: postId, ownerScopeId: LocalAccountScope.currentOwnerScopeId,
                         due: Date().addingTimeInterval(seconds)))
        entries = all
        timers[postId] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.timers[postId] = nil
            let result = await self.send(postId, service: service)
            completion(result)
        }
    }

    /// « Annuler » : vrai si rien n'est encore parti. Trop tard une fois la requête envoyée.
    @discardableResult
    func cancel(_ postId: String) -> Bool {
        guard !sending.contains(postId) else { return false }
        guard let timer = timers.removeValue(forKey: postId) else { return false }
        timer.cancel()
        entries = entries.filter { $0.postId != postId }
        return true
    }

    /// Envoie les suppressions échues du compte courant qu'aucun délai en cours ne porte :
    /// celles d'une app tuée ou suspendue pendant le délai. Un refus définitif (404 compris :
    /// déjà supprimée) les retire ; une panne passagère les garde pour la fois suivante.
    func flush(using service: SocialFeedServicing, now: Date = Date()) async {
        let owner = LocalAccountScope.currentOwnerScopeId
        entries = entries.filter { now.timeIntervalSince($0.due) < Self.maxAge }
        let due = entries.filter {
            $0.ownerScopeId == owner && $0.due <= now && timers[$0.postId] == nil && !sending.contains($0.postId)
        }
        // Pas encore échues (app relancée pendant le délai) : elles partent à leur échéance
        // restante, comme sur Android ; la publication reste masquée d'ici là.
        for entry in entries where entry.ownerScopeId == owner && entry.due > now
            && timers[entry.postId] == nil && !sending.contains(entry.postId) {
            let postId = entry.postId
            let remaining = entry.due.timeIntervalSince(now)
            timers[postId] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, let self else { return }
                self.timers[postId] = nil
                _ = await self.send(postId, service: service, keepOnTransientFailure: true)
            }
        }
        for entry in due {
            _ = await send(entry.postId, service: service, keepOnTransientFailure: true)
        }
    }

    private func send(
        _ postId: String,
        service: SocialFeedServicing,
        keepOnTransientFailure: Bool = false
    ) async -> Result<Void, Error> {
        sending.insert(postId)
        defer { sending.remove(postId) }
        do {
            try await service.deletePost(postId: postId)
            entries = entries.filter { $0.postId != postId }
            return .success(())
        } catch {
            if !keepOnTransientFailure || error.isPermanentRequestFailure {
                entries = entries.filter { $0.postId != postId }
            }
            return .failure(error)
        }
    }

    private var entries: [Entry] {
        get {
            guard let data = defaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
            return decoded
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: storageKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: storageKey)
            }
        }
    }
}
