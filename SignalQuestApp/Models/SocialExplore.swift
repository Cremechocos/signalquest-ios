import Foundation

/// Résultat de `GET /api/social/explore` : publications, personnes et hashtags
/// en **une** requête.
///
/// iOS faisait deux appels et n'obtenait que des utilisateurs — la recherche de
/// publications n'existait tout simplement pas. Les trois listes réutilisent les
/// types déjà décodés par le fil : aucun modèle neuf, aucune divergence à
/// entretenir.
struct SocialExploreResult: Decodable, Equatable {
    let posts: [UnifiedSocialFeedItem]
    let people: [SocialFeedAuthor]
    let hashtags: [TrendingHashtag]

    /// Les trois listes sont facultatives côté serveur selon la requête : un
    /// champ absent vaut liste vide, pas un échec de décodage.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = (try? c.decode([UnifiedSocialFeedItem].self, forKey: .posts)) ?? []
        people = (try? c.decode([SocialFeedAuthor].self, forKey: .people)) ?? []
        hashtags = (try? c.decode([TrendingHashtag].self, forKey: .hashtags)) ?? []
    }

    init(posts: [UnifiedSocialFeedItem] = [], people: [SocialFeedAuthor] = [], hashtags: [TrendingHashtag] = []) {
        self.posts = posts
        self.people = people
        self.hashtags = hashtags
    }

    enum CodingKeys: String, CodingKey { case posts, people, hashtags }

    var isEmpty: Bool { posts.isEmpty && people.isEmpty && hashtags.isEmpty }

    /// `explore` renvoie des `SocialFeedAuthor`, l'écran de recherche affiche des
    /// `SocialUserSearchResult`. Les deux portent les mêmes champs utiles :
    /// convertir ici évite de propager un second type dans toute la vue.
    var peopleAsSearchResults: [SocialUserSearchResult] {
        people.map {
            SocialUserSearchResult(
                id: $0.id, name: $0.name, handle: $0.handle,
                avatarUrl: $0.avatarUrl, isFriend: $0.isFriend
            )
        }
    }
}
