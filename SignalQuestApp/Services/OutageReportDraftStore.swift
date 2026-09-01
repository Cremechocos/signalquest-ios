import CryptoKit
import Foundation

struct OutageReportDraftScope: Equatable {
    let ownerScopeId: String
    let targetKind: String
    let targetId: String
    let marketCode: String
    let operatorKey: String
}

/// Brouillon local, sans position ni capture radio : ces preuves sont reprises à l'envoi.
enum OutageReportDraftStore {
    private struct Envelope: Codable {
        let version: Int
        let savedAtMs: Int64
        let draft: OutageReportDraft
    }

    private static let prefix = "SignalQuest.CommunityOutageDraft.v1"
    static let ttlMs: Int64 = 7 * 24 * 60 * 60 * 1_000

    private static func ownerPrefix(_ ownerScopeId: String) -> String {
        "\(prefix).\(LocalAccountScope.storageNamespace(for: ownerScopeId))."
    }

    private static func key(_ scope: OutageReportDraftScope) -> String {
        let raw = [
            scope.marketCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            scope.operatorKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            scope.targetKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            scope.targetId.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return ownerPrefix(scope.ownerScopeId) + digest
    }

    private static func normalized(_ value: OutageReportDraft) -> OutageReportDraft {
        var draft = value
        draft.comment = String(draft.comment.prefix(500))
        draft.technologies = Set(draft.technologies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.range(of: #"^\d{1,2}g$"#, options: .regularExpression) != nil })
        draft.bands = Set(draft.bands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.range(of: #"^[bn]\d{1,4}$"#, options: .regularExpression) != nil })
        draft.sectors = Set(draft.sectors.filter { (0..<360).contains($0) })
        if draft.severity != .degraded {
            draft.bands = []
            draft.sectors = []
        }
        return draft
    }

    private static func meaningful(_ draft: OutageReportDraft) -> Bool {
        draft.severity != nil || !draft.affectsData || draft.affectsVoice ||
            !draft.technologies.isEmpty || !draft.bands.isEmpty || !draft.sectors.isEmpty ||
            !draft.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachRadio
    }

    static func save(
        _ value: OutageReportDraft,
        scope: OutageReportDraftScope,
        defaults: UserDefaults = .standard,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        currentOwnerScopeId: String = LocalAccountScope.currentOwnerScopeId
    ) {
        // Un Task retardé ne ressuscite pas A après A→logout/B.
        guard scope.ownerScopeId.hasPrefix("user:"), currentOwnerScopeId == scope.ownerScopeId else { return }
        let storageKey = key(scope)
        let draft = normalized(value)
        guard meaningful(draft) else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let envelope = Envelope(version: 1, savedAtMs: nowMs, draft: draft)
        guard let data = try? JSONEncoder.signalQuest.encode(envelope) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func restore(
        scope: OutageReportDraftScope,
        defaults: UserDefaults = .standard,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        currentOwnerScopeId: String = LocalAccountScope.currentOwnerScopeId
    ) -> OutageReportDraft? {
        guard scope.ownerScopeId.hasPrefix("user:"), currentOwnerScopeId == scope.ownerScopeId else { return nil }
        let storageKey = key(scope)
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONDecoder.signalQuest.decode(Envelope.self, from: data),
              envelope.version == 1,
              envelope.savedAtMs > 0,
              envelope.savedAtMs <= nowMs + 60_000,
              nowMs - envelope.savedAtMs <= ttlMs else {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        let draft = normalized(envelope.draft)
        guard meaningful(draft) else {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        return draft
    }

    static func clear(scope: OutageReportDraftScope, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(scope))
    }

    static func purge(ownerScopeId: String, defaults: UserDefaults = .standard) {
        let prefix = ownerPrefix(ownerScopeId)
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .forEach(defaults.removeObject(forKey:))
    }
}
