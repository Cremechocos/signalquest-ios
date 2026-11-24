import Darwin
import Foundation

/// Alerte « Nouvelle clé d'historique » (E2EE-AUTO §5.1, révision 23). On juge les HK écrites
/// après la plus récente que l'appareil détient, sauf les HK annulées (§5.6 bis). Une HK est
/// suspecte hors de la forme d'une rotation, ou, en forme de rotation, sans maillon à preuve
/// passé une heure de grâce. La première suspecte non acquittée par « C'est moi » lève
/// l'alerte. Tant qu'une HK n'est pas jugée (rotation à preuve, ou suspecte acquittée), aucune
/// demande §5.3 ne part : règle commune aux trois apps. Un appareil sans HK n'alerte pas.
enum E2EEAutoHistoryKeyAlert {
    static let graceMs: Int64 = 3_600_000

    struct Suspect: Equatable, Sendable {
        let hkPubB64: String
        /// Signataire de la HK suspecte : la ligne « Créée par » et le « Ce n'est pas moi ».
        let signerDeviceId: String
    }

    enum Verdict: Equatable, Sendable {
        /// Rien après la HK détenue, ou tout est jugé : la demande §5.3 est permise.
        case judged
        /// Une rotation sans maillon à preuve, encore dans sa grâce : ni alerte, ni demande.
        case pending
        case alert(Suspect)
    }

    /// Forme d'une rotation du §5.6 : après un `REVOKE`, par-dessus la HK littérale juste avant
    /// elle (annulée ou non : la base ne choisit que le maillon et la clé à prouver).
    static func hasRotationShape(_ keys: [E2EEAutoLog.HistoryKeyRecord], at index: Int) -> Bool {
        index > 0 && keys[index].afterRevokeSeq != nil && keys[index].previousHkPubB64 == keys[index - 1].hkPubB64
    }

    static func judge(
        _ account: E2EEAutoLog.AccountState,
        holds: (String) -> Bool,
        acknowledged: Set<String>,
        vouched: (E2EEAutoLog.HistoryKeyRecord) async -> Bool,
        graceOver: (E2EEAutoLog.HistoryKeyRecord) -> Bool
    ) async -> Verdict {
        let keys = account.historyKeys
        guard let lastHeld = keys.lastIndex(where: { holds($0.hkPubB64) }) else { return .judged }
        let cancelled = Set(account.historyKeyBases.filter(\.cancelled).map(\.hkPubB64))
        var pending = false
        for index in keys.indices where index > lastHeld && !cancelled.contains(keys[index].hkPubB64) {
            let record = keys[index]
            // « C'est moi » vaut jugement, même si la grâce repart après un redémarrage.
            if acknowledged.contains(record.hkPubB64) { continue }
            if hasRotationShape(keys, at: index) {
                if await vouched(record) { continue }
                guard graceOver(record) else {
                    pending = true
                    continue
                }
            }
            return .alert(.init(hkPubB64: record.hkPubB64, signerDeviceId: record.signerDeviceId))
        }
        return pending ? .pending : .judged
    }
}

/// Grâce d'une heure d'une HK en forme de rotation sans maillon à preuve (§5.1 r23). Elle finit
/// quand une heure d'horloge monotone s'est écoulée depuis la première lecture locale de
/// l'entrée, et que l'heure du serveur la plus récente connue (la tête signée vérifiée) dépasse
/// `createdAtMs` + 1 h : une horloge murale en avance ou en retard n'écourte rien. Après un
/// redémarrage, l'horloge monotone repart de zéro et la grâce de la nouvelle première lecture.
struct E2EEAutoHistoryKeyGrace: Sendable {
    struct Stored: Codable, Equatable, Sendable {
        var bootId: String
        var firstReadMs: [String: Int64]
    }

    /// Premières lectures gardées, les plus récentes.
    static let maxKept = 32

    var monotonicMs: @Sendable () -> Int64
    var bootId: @Sendable () -> String
    var serverTimeMs: @Sendable () -> Int64?
    var load: @Sendable () -> Stored?
    var save: @Sendable (Stored) -> Void

    /// Range la première lecture de l'entrée à son premier passage ici.
    func isOver(_ record: E2EEAutoLog.HistoryKeyRecord) -> Bool {
        let now = monotonicMs(), boot = bootId()
        var stored = load() ?? Stored(bootId: boot, firstReadMs: [:])
        if stored.bootId != boot { stored = Stored(bootId: boot, firstReadMs: [:]) }
        let firstRead: Int64
        if let kept = stored.firstReadMs[record.hkPubB64], kept <= now {
            firstRead = kept
        } else {
            firstRead = now
            stored.firstReadMs[record.hkPubB64] = now
            if stored.firstReadMs.count > Self.maxKept {
                let oldest = stored.firstReadMs.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.prefix(stored.firstReadMs.count - Self.maxKept)
                for (key, _) in oldest { stored.firstReadMs[key] = nil }
            }
            save(stored)
        }
        guard now - firstRead >= E2EEAutoHistoryKeyAlert.graceMs, let serverTimeMs = serverTimeMs() else { return false }
        return serverTimeMs > record.createdAtMs + E2EEAutoHistoryKeyAlert.graceMs
    }
}

extension E2EEAutoHistoryKeyGrace {
    static func storageKey(ownerNamespace: String) -> String { "e2ee-auto-hk-grace-v1:\(ownerNamespace)" }

    /// Horloge monotone qui avance pendant la veille et repart au démarrage.
    @Sendable static func monotonicNowMs() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
    }

    /// Identifiant du démarrage (`kern.bootsessionuuid`). Illisible : propre au processus, la
    /// grâce repart alors à chaque lancement (l'alerte n'est que retardée).
    static let bootSessionId: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "process-" + UUID().uuidString }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "process-" + UUID().uuidString }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? "process-" + UUID().uuidString : value
    }()

    /// Heure du serveur : la tête signée gardée par le lecteur du journal, vérifiée à sa lecture
    /// (24 h au plus, 10 min de tolérance).
    static func live(ownerScopeId: String, ownerNamespace: String, markerStore: TokenStore) -> E2EEAutoHistoryKeyGrace {
        let key = storageKey(ownerNamespace: ownerNamespace)
        return E2EEAutoHistoryKeyGrace(
            monotonicMs: monotonicNowMs,
            bootId: { bootSessionId },
            serverTimeMs: { (try? E2EEAutoLogStore().anchor(ownerScopeId: ownerScopeId))?.headCreatedAtMs },
            load: {
                guard let raw = try? markerStore.string(for: key) else { return nil }
                return try? JSONDecoder().decode(Stored.self, from: Data(raw.utf8))
            },
            save: { stored in
                guard let data = try? JSONEncoder().encode(stored) else { return }
                try? markerStore.set(String(decoding: data, as: UTF8.self), for: key, accessibility: .afterFirstUnlock)
            }
        )
    }
}

/// « C'est moi » rangé par `hkPubB64` de la HK suspecte (§5.1 r23), propre à l'appareil : une
/// nouvelle HK suspecte, donc un autre `hkPubB64`, relance l'alerte.
enum E2EEAutoHistoryKeyAcknowledgements {
    static func storageKey(ownerNamespace: String) -> String { "e2ee-auto-hk-acknowledged-v1:\(ownerNamespace)" }

    static func load(_ store: TokenStore, ownerNamespace: String) -> Set<String> {
        guard let raw = try? store.string(for: storageKey(ownerNamespace: ownerNamespace)),
              let keys = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return [] }
        return Set(keys)
    }

    static func acknowledge(_ hkPubB64: String, store: TokenStore, ownerNamespace: String) {
        let keys = load(store, ownerNamespace: ownerNamespace).union([hkPubB64]).sorted()
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? store.set(String(decoding: data, as: UTF8.self), for: storageKey(ownerNamespace: ownerNamespace), accessibility: .afterFirstUnlock)
    }
}
