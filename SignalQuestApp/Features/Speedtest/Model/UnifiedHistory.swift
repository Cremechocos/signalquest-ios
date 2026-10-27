import Foundation

/// Sélecteur de l'historique : « Tous · Speedtests · Expérience », comme Android.
enum HistoryKind: String, CaseIterable, Sendable {
    case all, speedtests, experience

    /// Clé de catalogue.
    var title: String {
        switch self {
        case .all: "Tous"
        case .speedtests: "Speedtests"
        case .experience: "Expérience"
        }
    }
}

/// Une ligne de l'historique commun. L'identifiant porte sa source : un speedtest et un
/// test d'expérience ne se confondent jamais.
enum HistoryEntry: Identifiable, Equatable {
    /// Speedtest de ce téléphone.
    case local(SpeedtestRunResult)
    /// Speedtest du compte absent de ce téléphone (UI-12).
    case account(SocialShareableSpeedtest)
    case experience(ExperienceHistoryItem)

    var id: String {
        switch self {
        case .local(let result): "s:\(result.id.uuidString)"
        case .account(let test): "a:\(test.id)"
        case .experience(let item): "e:\(item.id)"
        }
    }

    /// Un test du compte sans date se range tout en bas, jamais « maintenant » : il passerait
    /// sinon devant des tests réels.
    var date: Date {
        switch self {
        case .local(let result): result.createdAt
        case .account(let test): test.timestamp ?? .distantPast
        case .experience(let item): item.measuredAt
        }
    }
}

/// Ce que l'app tient des tests d'expérience : lignes locales et du serveur déjà fusionnées
/// (du plus récent au plus ancien), s'il reste des pages, et jusqu'où le SERVEUR a livré.
struct ExperienceHistorySource: Equatable {
    var items: [ExperienceHistoryItem] = []
    var hasMore = false
    /// Date de la dernière ligne du serveur reçue ; nil tant qu'aucune page n'est arrivée.
    var loadedUntil: Date?

    /// Les lignes locales ne bornent rien : une ligne locale plus ancienne que la dernière ligne
    /// du serveur pourrait précéder des lignes pas encore tirées, elle attend donc la suite.
    var visibleItems: [ExperienceHistoryItem] {
        guard hasMore else { return items }
        guard let loadedUntil else { return [] }
        return items.filter { $0.measuredAt >= loadedUntil }
    }
}

/// Historique commun speedtests + tests d'expérience, fusionné CÔTÉ APP (contrat v1 §3 :
/// deux routes sœurs, pas d'union serveur). Mêmes règles qu'Android (`UnifiedHistory.kt`).
enum UnifiedHistory {
    /// Une source triée du plus récent au plus ancien. `lastDelivered` est la date de la
    /// dernière ligne LIVRÉE par le serveur, avant tout filtre.
    struct Source {
        let entries: [HistoryEntry]
        let hasMore: Bool
        let lastDelivered: Date?
    }

    /// Fusion paginée : seul le PRÉFIXE SÛR est rendu. Tant qu'une source a une page suivante,
    /// une ligne plus ancienne que sa dernière livrée pourrait manquer entre les deux ; on ne
    /// montre donc rien de plus ancien que la plus récente de ces bornes.
    static func safePrefix(_ sources: [Source]) -> [HistoryEntry] {
        var tagged: [(entry: HistoryEntry, source: Int)] = []
        for (index, source) in sources.enumerated() {
            tagged += source.entries.map { (entry: $0, source: index) }
        }
        let merged = tagged
            .sorted { lhs, rhs in
                lhs.entry.date != rhs.entry.date ? lhs.entry.date > rhs.entry.date : lhs.source < rhs.source
            }
            .map(\.entry)
        guard let cutoff = cutoff(sources) else { return merged }
        return merged.filter { $0.date >= cutoff }
    }

    /// La borne : nil quand aucune source n'a de page suivante. Une source paginée qui n'a
    /// encore rien livré borne tout (rien n'est sûr avant sa première page).
    static func cutoff(_ sources: [Source]) -> Date? {
        sources.filter(\.hasMore).map { $0.lastDelivered ?? .distantFuture }.max()
    }

    /// « Tous » : speedtests et tests d'expérience mêlés, du plus récent au plus ancien.
    /// - `local` : speedtests de ce téléphone (jamais paginés) ;
    /// - `account` : toutes les lignes du compte livrées, `accountOnly` celles absentes du téléphone.
    static func allEntries(
        local: [SpeedtestRunResult],
        account: [SocialShareableSpeedtest],
        accountOnly: [SocialShareableSpeedtest],
        accountHasMore: Bool,
        experience: ExperienceHistorySource
    ) -> [HistoryEntry] {
        safePrefix([
            Source(entries: local.map(HistoryEntry.local), hasMore: false, lastDelivered: nil),
            Source(entries: accountOnly.map(HistoryEntry.account), hasMore: accountHasMore,
                   lastDelivered: account.last.map { $0.timestamp ?? .distantPast }),
            Source(entries: experience.visibleItems.map(HistoryEntry.experience),
                   hasMore: experience.hasMore, lastDelivered: experience.loadedUntil)
        ])
    }

    /// Les sources dont la page suivante fait avancer la borne de « Tous » : celles qui ont une
    /// suite et dont la dernière ligne livrée EST la borne.
    static func sourcesToLoad(
        account: [SocialShareableSpeedtest],
        accountHasMore: Bool,
        experience: ExperienceHistorySource
    ) -> (account: Bool, experience: Bool) {
        let accountBound = accountHasMore ? (account.last.map { $0.timestamp ?? .distantPast } ?? .distantFuture) : nil
        let experienceBound = experience.hasMore ? (experience.loadedUntil ?? .distantFuture) : nil
        guard let cutoff = [accountBound, experienceBound].compactMap({ $0 }).max() else { return (false, false) }
        return (accountBound == cutoff, experienceBound == cutoff)
    }
}
