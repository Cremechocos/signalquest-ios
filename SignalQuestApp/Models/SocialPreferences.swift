import Foundation

/// Hashtag suivi. `notifyOnNew` déclenche une notification à chaque nouvelle
/// publication portant ce tag.
struct FollowedHashtag: Decodable, Equatable, Identifiable {
    let hashtag: String
    let notifyOnNew: Bool
    let createdAt: Date?

    var id: String { hashtag }
    /// Le serveur stocke le tag SANS `#` ; l'affichage le remet.
    var displayTag: String { hashtag.hasPrefix("#") ? hashtag : "#\(hashtag)" }
}

/// Inventaire des masquages, servi en un seul appel par `GET /api/social/mutes`
/// — le backend le dit explicitement : éviter deux requêtes en cascade sur
/// l'écran de réglages.
struct SocialMutes: Decodable, Equatable {
    let hashtags: [MutedHashtag]
    let words: [MutedWord]

    struct MutedHashtag: Decodable, Equatable, Identifiable {
        let hashtag: String
        let createdAt: Date?
        var id: String { hashtag }
        var displayTag: String { hashtag.hasPrefix("#") ? hashtag : "#\(hashtag)" }
    }

    struct MutedWord: Decodable, Equatable, Identifiable {
        let pattern: String
        let createdAt: Date?
        var id: String { pattern }
    }

    /// Un champ absent vaut liste vide : l'écran de réglages ne doit pas se
    /// vider parce qu'une des deux listes manque.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hashtags = (try? c.decode([MutedHashtag].self, forKey: .hashtags)) ?? []
        words = (try? c.decode([MutedWord].self, forKey: .words)) ?? []
    }

    init(hashtags: [MutedHashtag] = [], words: [MutedWord] = []) {
        self.hashtags = hashtags
        self.words = words
    }

    enum CodingKeys: String, CodingKey { case hashtags, words }

    var isEmpty: Bool { hashtags.isEmpty && words.isEmpty }
}

extension String {
    /// Normalise un hashtag pour l'API : sans `#`, en minuscules, sans espaces.
    ///
    /// Le serveur indexe la forme nue. Envoyer « #5G » créerait une entrée
    /// distincte de « 5g » et l'utilisateur verrait deux fois le même tag.
    var normalizedHashtag: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .lowercased()
    }
}
