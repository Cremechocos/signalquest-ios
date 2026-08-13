import Foundation

/// Gravité d'une panne communautaire. Détermine la COULEUR partout où elle s'affiche.
///
/// Énumération et non chaîne libre : l'interface s'y branche pour la teinte, l'icône et le
/// libellé, et une comparaison de chaîne qui rate ne se voit pas — elle produit un état neutre
/// que personne ne remarque.
enum OutageSeverity: String, Codable, Equatable {
    case down
    case degraded

    /// Tolérant : une valeur inconnue du serveur retombe sur la plus grave, jamais sur rien.
    init(rawServerValue: String?) {
        self = rawServerValue?.lowercased() == "degraded" ? .degraded : .down
    }
}

/// Les services touchés, écrits dans la langue de l'app.
///
/// Un SEUL endroit pour ces trois mots : ils apparaissent sous le marqueur de carte, dans la
/// feuille de panne, dans sa chronologie et sur la carte de fil. Le serveur ne rend que des
/// drapeaux (`affectsData`…) — la phrase `outageServices` qu'il compose est en français, et serait
/// lue telle quelle par un utilisateur anglophone.
enum OutageServices {
    static func label(data: Bool, voice: Bool, sms: Bool) -> String {
        var parts: [String] = []
        if data { parts.append(String(localized: "Internet")) }
        if voice { parts.append(String(localized: "Voix")) }
        if sms { parts.append(String(localized: "SMS")) }
        return parts.joined(separator: ", ")
    }

    /// La même liste depuis les codes du serveur (`data`, `voice`, `sms`), que la chronologie
    /// porte sous cette forme. L'ordre est celui d'ici, pas celui de la réponse : deux événements
    /// ne doivent pas énumérer les mêmes services dans deux ordres différents. Un code inconnu est
    /// ignoré — la liste s'allongera avant les clients.
    static func label(codes: [String]) -> String {
        let normalized = Set(codes.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return label(
            data: normalized.contains("data"),
            voice: normalized.contains("voice"),
            sms: normalized.contains("sms")
        )
    }
}

/// Les générations radio touchées, telles qu'on les lit : « 4G, 5G ».
///
/// Un ENSEMBLE de jetons (`4g`, `5g`…) et non trois booléens comme les services, parce que la
/// liste des services est close alors que celle des générations s'allonge — c'est le choix fait
/// côté serveur (`packages/core/outage-technologies.ts`), et le client s'y conforme plutôt que de
/// le retraduire en champs fixes qu'il faudrait rouvrir à chaque génération.
///
/// Aucune traduction, contrairement à `OutageServices` : « 4G » s'écrit « 4G » dans les deux
/// langues de l'app. C'est un sigle, pas un mot — lui donner une entrée de catalogue laisserait
/// croire le contraire.
enum OutageTechnologies {
    /// Ce que le FORMULAIRE propose, dans son ordre d'affichage.
    ///
    /// Plus court que ce que le serveur ACCEPTE : sa validation porte sur la FORME
    /// (`/^([2-9]|[1-9][0-9])g$/`, cf. `outage-technologies.ts`), pas sur cette liste, si bien
    /// qu'un client plus récent qui déclarerait « 6g » verrait sa donnée stockée et non jetée.
    /// La 2G existe encore chez les opérateurs mais n'est pas demandée ici —
    /// un signalement debout dans la rue ne doit pas devenir un questionnaire.
    static let choices = ["3g", "4g", "5g"]

    /// « 4G, 5G ». Chaîne vide quand rien n'est déclaré — le champ est FACULTATIF.
    ///
    /// L'ordre est celui des générations croissantes, quel que soit celui reçu : deux pannes ne
    /// doivent pas énumérer les mêmes technologies dans deux ordres différents. Un jeton hors
    /// forme est ignoré plutôt que rendu tel quel.
    static func label(_ tokens: [String]) -> String {
        sorted(tokens).map { $0.uppercased() }.joined(separator: ", ")
    }

    /// Les mêmes jetons depuis la metadata d'un post de fil, où le serveur les joint par une
    /// virgule (`inputJsonRecord` ne garde que les scalaires : un tableau y disparaîtrait).
    static func label(csv: String?) -> String {
        guard let csv, !csv.isEmpty else { return "" }
        return label(csv.components(separatedBy: ","))
    }

    /// Normalise et trie : minuscules, sans doublon, générations croissantes.
    static func sorted(_ tokens: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [(token: String, generation: Int)] = []
        for token in tokens {
            let normalized = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard let generation = generation(of: normalized), seen.insert(normalized).inserted else { continue }
            kept.append((normalized, generation))
        }
        return kept.sorted { $0.generation < $1.generation }.map(\.token)
    }

    /// `nil` dès que le jeton n'a pas la forme « <génération>g » — même règle que le serveur, pour
    /// qu'un client et lui ne retiennent jamais des jetons différents du même tableau.
    private static func generation(of token: String) -> Int? {
        guard token.hasSuffix("g") else { return nil }
        let digits = token.dropLast()
        guard !digits.isEmpty, digits.count <= 2, digits.allSatisfy(\.isNumber),
              let value = Int(digits), value >= 2
        else { return nil }
        return value
    }

    /// « Internet, Voix · 4G, 5G » — ce qui est touché, services ET générations sur une ligne.
    ///
    /// Le point médian est le séparateur que le serveur emploie déjà dans le texte du post
    /// (`social-post.ts`) : la même panne se lit pareil dans le fil et dans la feuille. Chaque
    /// moitié peut manquer — les technologies sont facultatives, et une panne ancienne n'en porte
    /// aucune.
    static func detail(services: String, technologies: [String]) -> String {
        join(services: services, technologies: label(technologies))
    }

    /// La même ligne depuis la metadata d'un post de fil, qui joint les jetons par une virgule.
    ///
    /// Une surcharge plutôt qu'un appel à `label(csv:)` chez l'appelant : le point médian et la
    /// règle « on n'écrit pas le séparateur d'une moitié absente » ne doivent exister qu'ICI. La
    /// carte de fil et la feuille de panne composaient sinon la même ligne à deux endroits.
    static func detail(services: String, csv: String?) -> String {
        join(services: services, technologies: label(csv: csv))
    }

    private static func join(services: String, technologies: String) -> String {
        [services, technologies].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// État d'une panne communautaire.
///
/// ⚠️ `reported` est VISIBLE : la décision produit du chantier est qu'une panne s'affiche dès le
/// premier signalement, marquée non confirmée. Le seuil ne gouverne que le passage à `confirmed`,
/// les notifications et le gros des points.
enum OutageState: String, Codable, Equatable {
    case reported
    case confirmed
    case dormant
    case resolved
    case rejected

    init(rawServerValue: String?) {
        self = OutageState(rawValue: rawServerValue?.lowercased() ?? "") ?? .reported
    }

    /// Détient encore le verrou côté serveur. `dormant` en fait partie : mise en veille ≠ close.
    var isOpen: Bool { self == .reported || self == .confirmed || self == .dormant }

    /// Affichée sur la carte et dans la fiche.
    var isVisible: Bool { self == .reported || self == .confirmed }
}

/// Genre d'un événement de la chronologie — la liste du contrat serveur, figée.
///
/// Le serveur ne rend AUCUNE phrase rédigée : il rend un genre assez fin pour que chaque client
/// écrive la sienne dans SA langue. Une phrase française renvoyée par l'API serait lue telle
/// quelle par un utilisateur allemand.
enum OutageTimelineKind: String, Decodable, Equatable {
    /// Le premier signalement, celui qui a créé l'agrégat.
    case reported
    /// Le réveil d'une panne mise en veille, ou sa réouverture par la modération.
    case reportedAgain = "reported_again"
    /// Une voix, telle qu'une personne l'a émise — à ne pas confondre avec l'état du groupe.
    case confirm
    case dispute
    case repaired
    /// Le seuil communautaire est franchi. C'est l'état, pas la voix qui l'a fait basculer.
    case stateConfirmed = "state_confirmed"
    case operatorConfirmed = "operator_confirmed"
    case dormant
    case resolvedCommunity = "resolved_community"
    case resolvedAuthor = "resolved_author"
    case resolvedOperator = "resolved_operator"
    case resolvedMeasured = "resolved_measured"
    case resolvedAdmin = "resolved_admin"
    case rejected
}

/// Un événement de la vie d'une panne.
///
/// `isSelf` remplace tout identifiant d'acteur : le contrat ne transporte aucun nom de personne
/// (RGPD), et c'est pourtant ce booléen qui permet d'écrire « Vous » plutôt que « Quelqu'un ».
///
/// L'initialiseur ÉCHOUE sur un genre inconnu, et c'est voulu : la chronologie est décodée par
/// `decodeLossyArray`, qui laisse alors tomber la ligne en silence. Le contrat l'exige — la liste
/// des genres s'allongera, et les trois clients ne se mettent pas à jour le même jour.
struct OutageTimelineEntry: Decodable, Equatable {
    let at: String
    let kind: OutageTimelineKind
    let isSelf: Bool
    /// `data`, `voice`, `sms` — vide quand l'événement ne porte sur aucun service en particulier.
    let services: [String]

    enum CodingKeys: String, CodingKey {
        case at, kind, isSelf, services
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(String.self, forKey: .at)
        kind = try c.decode(OutageTimelineKind.self, forKey: .kind)
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
        services = c.decodeLossyArray([String].self, forKey: .services)
    }
}

/// Une panne signalée par la communauté.
///
/// ⚠️ Type DISTINCT d'`OutageSiteLive`, et c'est délibéré — le plan proposait d'étendre ce
/// dernier. `OutageSiteLive` porte les incidents publiés dans les CSV des opérateurs ; celui-ci
/// porte ce que des utilisateurs déclarent. Les fusionner ferait perdre la distinction que toute
/// la fonctionnalité cherche à établir : qui affirme quoi. Android a fait la même séparation.
struct CommunityOutage: Decodable, Identifiable, Equatable {
    let id: String
    let targetKind: String
    let targetId: String
    let marketCode: String
    let operatorKey: String
    let latitude: Double
    let longitude: Double
    let siteName: String?
    /// Adresse lisible du site, figée au signalement. `nil` pour une cible hors référentiel, qui
    /// n'en a pas — le serveur la dénormalise justement pour que la liste n'ait pas à la résoudre.
    let address: String?

    let state: OutageState
    let severity: OutageSeverity
    let affectsData: Bool
    let affectsVoice: Bool
    let affectsSms: Bool
    /// Jetons de génération radio (`4g`, `5g`…), figés à la création de l'agrégat comme les
    /// services. Vide = « je ne sais pas » : le champ est facultatif au formulaire, et toutes les
    /// pannes ouvertes avant son ajout le rendent vide.
    let affectedTechnologies: [String]
    /// Bandes touchées (`b28`, `n78`) et secteurs touchés (AZIMUTS en degrés).
    ///
    /// Toujours vides sur une panne totale — la question n'y est pas posée — et vides aussi pour
    /// les pannes ouvertes avant l'ajout du champ. Les jetons sont affichés TELS QUELS : une bande
    /// que cette version de l'app ne connaît pas ne doit pas disparaître de l'écran.
    let affectedBands: [String]
    let affectedSectors: [Int]
    /// Résumé PUBLIC des captures jointes, rédigé par le serveur. Jamais de position dedans.
    let radioSummary: String?
    /// Le post qui porte le FIL de la panne, et son nombre de commentaires.
    let socialPostId: String?
    let commentCount: Int

    let confirmCount: Int
    let disputeCount: Int
    /// Voix encore attendues avant confirmation. 0 dès qu'elle est confirmée.
    let confirmationsRemaining: Int
    let confirmThreshold: Int

    /// Le fichier de l'opérateur a fini par reconnaître l'incident.
    let operatorConfirmed: Bool
    /// Cet échelon peut-il seulement exister dans ce marché ?
    ///
    /// `false` partout où aucun opérateur ne publie de flux d'incidents — 47 marchés sur 49. On
    /// MASQUE alors l'échelon au lieu de le montrer « en attente » : quelqu'un en Suisse le voit
    /// exister ailleurs et l'attendrait légitimement, alors qu'il n'arrivera jamais.
    ///
    /// Rendu par le serveur, qui tient la liste des flux, plutôt que redéduit ici : trois clients
    /// qui recomposent la même règle finissent par en avoir trois versions. Défaut à `false` —
    /// un serveur plus ancien qui ne rend pas le champ fait donc taire l'échelon, ce qui est la
    /// bonne moitié de l'erreur à commettre.
    let operatorConfirmationPossible: Bool
    let operatorRaison: String?

    let startedAt: String?
    let reporterName: String?

    /// `report`, `confirm`, `dispute`, `repaired` — ou `nil` si on ne s'est pas prononcé.
    let myVote: String?
    /// Ni auteur, ni déjà positionné, et la panne est ouverte.
    let canVote: Bool
    /// Vous en êtes l'auteur ET elle est encore ouverte : vous pouvez la refermer.
    ///
    /// Arbitré par le serveur, jamais redéduit ici : le contrat ne transporte aucun identifiant de
    /// personne (RGPD), donc `reporter` ne suffirait pas à savoir si c'est vous — et trois clients
    /// qui recomposent la même règle finissent par afficher un bouton qui renvoie un 403.
    let canClose: Bool

    /// Chronologie de la panne, dans l'ordre du serveur — du plus ANCIEN au plus récent.
    ///
    /// `nil` veut dire « non chargée » : la liste paginée ne la rend pas, elle lui coûterait une
    /// jointure par ligne pour un bloc que personne ne regarde depuis une liste. Un tableau vide
    /// dirait « aucun événement », ce qui n'arrive jamais — toute panne porte au moins sa création.
    let timeline: [OutageTimelineEntry]?

    /// Services touchés, tels qu'on les lit — pas trois icônes à décoder.
    var affectedServicesLabel: String {
        OutageServices.label(data: affectsData, voice: affectsVoice, sms: affectsSms)
    }

    /// « Internet, Voix · 4G, 5G » — services et générations sur une ligne.
    var affectedLabel: String {
        OutageTechnologies.detail(services: affectedServicesLabel, technologies: affectedTechnologies)
    }

    enum CodingKeys: String, CodingKey {
        case id, targetKind, targetId, marketCode, operatorKey
        case latitude, longitude, lat, lng
        case siteName, address, state, severity
        case affectsData, affectsVoice, affectsSms, affectedTechnologies
        case affectedBands, affectedSectors, radioSummary, socialPostId, commentCount
        case confirmCount, disputeCount, confirmationsRemaining, confirmThreshold
        case operatorConfirmed, operatorConfirmationPossible, operatorRaison, startedAt
        case reporter, myVote, canVote, canClose, timeline
    }

    private struct Reporter: Decodable { let displayName: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        targetKind = (try? c.decode(String.self, forKey: .targetKind)) ?? "anfr"
        targetId = (try? c.decode(String.self, forKey: .targetId)) ?? ""
        marketCode = (try? c.decode(String.self, forKey: .marketCode)) ?? ""
        operatorKey = (try? c.decode(String.self, forKey: .operatorKey)) ?? ""
        // La fiche REST rend `latitude`/`longitude`, la tuile carte `lat`/`lng`. On accepte les
        // deux plutôt que d'imposer au serveur une convention qu'il n'a pas.
        latitude = (try? c.decode(Double.self, forKey: .latitude))
            ?? (try? c.decode(Double.self, forKey: .lat)) ?? 0
        longitude = (try? c.decode(Double.self, forKey: .longitude))
            ?? (try? c.decode(Double.self, forKey: .lng)) ?? 0
        siteName = try? c.decodeIfPresent(String.self, forKey: .siteName)
        address = try? c.decodeIfPresent(String.self, forKey: .address)

        state = OutageState(rawServerValue: try? c.decodeIfPresent(String.self, forKey: .state))
        severity = OutageSeverity(rawServerValue: try? c.decodeIfPresent(String.self, forKey: .severity))
        affectsData = (try? c.decode(Bool.self, forKey: .affectsData)) ?? false
        affectsVoice = (try? c.decode(Bool.self, forKey: .affectsVoice)) ?? false
        affectsSms = (try? c.decode(Bool.self, forKey: .affectsSms)) ?? false
        // Trié ici et pas seulement à l'affichage : la valeur circule ensuite telle quelle (carte
        // de fil, feuille, chronologie), et un serveur plus ancien qui ne rend pas la clé donne
        // simplement un tableau vide — jamais une erreur de décodage.
        affectedTechnologies = OutageTechnologies.sorted(
            c.decodeLossyArray([String].self, forKey: .affectedTechnologies)
        )
        // Décodage TOLÉRANT, comme les technologies : un serveur antérieur au champ ne rend rien,
        // et l'absence doit produire un tableau vide, jamais une erreur qui ferait perdre toute
        // la panne.
        affectedBands = c.decodeLossyArray([String].self, forKey: .affectedBands)
        affectedSectors = c.decodeLossyArray([Int].self, forKey: .affectedSectors)
        radioSummary = try? c.decodeIfPresent(String.self, forKey: .radioSummary)
        socialPostId = try? c.decodeIfPresent(String.self, forKey: .socialPostId)
        commentCount = (try? c.decode(Int.self, forKey: .commentCount)) ?? 0

        confirmCount = (try? c.decode(Int.self, forKey: .confirmCount)) ?? 0
        disputeCount = (try? c.decode(Int.self, forKey: .disputeCount)) ?? 0
        confirmationsRemaining = (try? c.decode(Int.self, forKey: .confirmationsRemaining)) ?? 0
        confirmThreshold = (try? c.decode(Int.self, forKey: .confirmThreshold)) ?? 3

        operatorConfirmed = (try? c.decode(Bool.self, forKey: .operatorConfirmed)) ?? false
        operatorConfirmationPossible = (try? c.decode(Bool.self, forKey: .operatorConfirmationPossible)) ?? false
        operatorRaison = try? c.decodeIfPresent(String.self, forKey: .operatorRaison)
        startedAt = try? c.decodeIfPresent(String.self, forKey: .startedAt)
        reporterName = (try? c.decodeIfPresent(Reporter.self, forKey: .reporter))??.displayName

        myVote = try? c.decodeIfPresent(String.self, forKey: .myVote)
        canVote = (try? c.decode(Bool.self, forKey: .canVote)) ?? false
        canClose = (try? c.decode(Bool.self, forKey: .canClose)) ?? false

        // `decodeNil` échoue quand la clé est absente et rend `true` quand elle vaut `null` : les
        // deux cas signifient « non chargée ». On ne bascule sur le tableau que lorsque le serveur
        // en a vraiment envoyé un — sinon un `[]` ferait passer une chronologie manquante pour une
        // panne sans histoire, et la feuille afficherait un bloc vide.
        if let isNull = try? c.decodeNil(forKey: .timeline), !isNull {
            timeline = c.decodeLossyArray([OutageTimelineEntry].self, forKey: .timeline)
        } else {
            timeline = nil
        }
    }
}

struct CommunityOutagesResponse: Decodable, Equatable {
    let outages: [CommunityOutage]
    /// Seule la liste paginée le renseigne ; les lectures par site n'en ont pas l'usage.
    let hasMore: Bool?
}

/// La panne seule, telle que `/api/community-outages/{id}` la rend.
///
/// Distincte d'`OutageWriteResponse`, qui décoderait pourtant le même corps : celle-ci ne promet
/// aucun gain de points, et la confondre avec une écriture ferait chercher un award là où il n'y
/// en a jamais.
struct CommunityOutageDetailResponse: Decodable, Equatable {
    let outage: CommunityOutage?
}

// MARK: - Écriture

/// Corps d'un signalement.
///
/// ⚠️ La CIBLE est un identifiant, jamais des coordonnées de site : le serveur résout lui-même la
/// position depuis son référentiel. Si le client fournissait à la fois sa position et celle du
/// site, il tiendrait les deux bouts de la comparaison de proximité et l'éligibilité ne vaudrait
/// plus rien.
struct OutageReportRequest: Encodable {
    let targetKind: String
    let targetId: String?
    let marketCode: String
    let operatorKey: String
    let severity: String
    let affectsData: Bool
    let affectsVoice: Bool
    /// ⚠️ Le formulaire v2 ne PROPOSE plus le SMS — les fiches d'incident des opérateurs ne
    /// croisent que Voix et Data, et c'est sur elles qu'on s'aligne pour rendre les deux sources
    /// comparables. Le champ reste dans le contrat, et les pannes qui le portent déjà continuent
    /// de l'afficher : on ne détruit pas une donnée collectée, on cesse de la demander.
    let affectsSms: Bool
    /// Facultatif : un tableau vide dit « je ne sais pas », et reste un signalement valide.
    let affectedTechnologies: [String]
    /// Bandes touchées (`b28`, `n78`) et secteurs touchés (AZIMUTS en degrés).
    ///
    /// ⚠️ Des azimuts, jamais des numéros de secteur : la numérotation dépend de l'opérateur (SFR
    /// compte à partir de 0, les trois autres à partir de 1, cf. `SectorNumbering` et la note
    /// `SECTOR-TELECOM-01`). Un numéro écrit ici serait FAUX pour un opérateur sur quatre.
    ///
    /// Toujours vides sur une panne totale : « plus rien » veut dire toutes les fréquences et tous
    /// les secteurs, la question n'est donc pas posée.
    let affectedBands: [String]
    let affectedSectors: [Int]
    /// Commentaire libre. Le serveur refuse au-delà de 500 caractères (`COMMENT_TOO_LONG`).
    let comment: String?
    /// Capture réseau, volontairement PARTIELLE sur iOS — voir `OutageRadioCapture`.
    let radioContext: OutageRadioCapture?
    /// Identifiant d'appareil (Keychain), anti-sockpuppet côté serveur.
    let deviceId: String?
    /// Heure du CONSTAT quand elle précède l'envoi. Le serveur accepte 12 h d'antériorité.
    let observedAt: String?
    let latitude: Double?
    let longitude: Double?
    let accuracyMeters: Double?
}

/**
 La capture réseau jointe à un signalement, côté iOS.

 ── Ce qu'elle contient, et pourquoi si peu ──

 iOS n'expose NI le niveau reçu, NI l'identifiant de cellule, NI la bande, NI le PCI : ce n'est pas
 un manque à combler mais une limite d'Apple, actée dans `CLAUDE.md` et `README.md`. Ce qui reste
 lisible — la génération, l'opérateur, le chemin réseau, une sonde de latence — est réel et suffit
 à dire « je n'avais plus rien à 15 h 42 ».

 D'où `platform: "ios"`, qui n'est pas décoratif : le serveur en tire un résumé étiqueté « capture
 partielle — iOS ». Sans lui, une capture iOS et une capture Android s'afficheraient à l'identique
 alors qu'elles ne mesurent pas la même chose — l'interface mentirait par omission.

 `serving` est toujours absent, pour la même raison : nous n'avons aucune cellule servante à
 décrire. Le format est celui de `@sq/core/outage-radio-context` (v1), commun aux trois clients.
 */
struct OutageRadioCapture: Encodable, Equatable {
    let v: Int
    let platform: String
    let capturedAt: String
    /// `in_service`, `out_of_service` ou `unknown` — déduit du chemin réseau, pas du modem.
    let state: String
    let fallbackTechnology: String?
    let connection: String?
    let viaVpn: Bool?
    let `operator`: OutageRadioOperator?
    /// Jamais publiée : le serveur ne la met pas dans le résumé public. Elle sert aux
    /// recoupements et reste lisible par son auteur.
    let position: OutageRadioPosition?
    let probe: OutageRadioProbe?
}

struct OutageRadioOperator: Encodable, Equatable {
    let name: String?
    let mcc: Int?
    let mnc: Int?
    /// `sim` quand CoreTelephony répond encore, `ip-asn` quand c'est le serveur qui a tranché.
    let source: String?
}

struct OutageRadioPosition: Encodable, Equatable {
    let lat: Double?
    let lng: Double?
    let accuracyM: Double?
}

struct OutageRadioProbe: Encodable, Equatable {
    let pingMs: Double?
    let dnsOk: Bool?
}

/// L'état du FORMULAIRE de signalement, extrait de la vue.
///
/// Extrait pour être vérifiable : les trois règles du formulaire v2 — aucune gravité
/// pré-sélectionnée, cascade conservée sur « Plus rien », SMS retiré des choix — sont des règles
/// produit tranchées explicitement, et laissées dans des `@State` privés elles n'étaient
/// démontrables que sur appareil. Ici un test les tient (`MapOutageFilterTests`), et la vue ne
/// fait plus que les afficher.
struct OutageReportDraft: Equatable {
    /// `nil` à l'ouverture : RIEN n'est coché tant que la personne n'a pas répondu.
    ///
    /// Optionnel plutôt qu'une troisième valeur d'`OutageSeverity` : « pas encore répondu » n'est
    /// pas un état de panne, et le serveur n'en connaît que deux.
    var severity: OutageSeverity?
    /// Internet part coché — c'est le service pour lequel on ouvre l'app, et la décision produit ne
    /// retire que la pré-sélection de la GRAVITÉ.
    var affectsData = true
    var affectsVoice = false
    /// Jetons du contrat (`3g`, `4g`, `5g`). Vide = « je ne sais pas », et c'est valide.
    var technologies: Set<String> = []
    /// Bandes cochées (`b28`, `n78`) et secteurs cochés (azimuts). Facultatifs.
    ///
    /// ⚠️ N'ont de sens que pour une DÉGRADATION, et `select(_:)` les vide au passage en « plus
    /// rien » : masquer les blocs ne suffirait pas, l'envoi porterait alors une panne totale
    /// restreinte à deux fréquences — l'inverse de ce que la personne vient de déclarer.
    var bands: Set<String> = []
    var sectors: Set<Int> = []
    /// Commentaire libre, borné comme le serveur (500).
    var comment: String = ""
    /// Joindre la capture réseau. Cochée par défaut : c'est ce qui date et situe le constat.
    var attachRadio = true

    /// Les deux blocs facultatifs n'existent que pour une dégradation.
    var showsImpactFields: Bool { severity == .degraded }

    /// ⚠️ Le SMS n'apparaît pas : le formulaire v2 ne le propose plus, donc il n'est jamais
    /// affirmé. Le champ reste au contrat et les pannes qui le portent continuent de l'afficher —
    /// on cesse de le demander, on ne détruit aucune donnée.
    var canSubmit: Bool { severity != nil && (affectsData || affectsVoice) }

    /// Choisir la gravité, et propager ce que « Plus rien » dit déjà.
    ///
    /// La CASCADE est conservée — elle avait été demandée explicitement plus tôt dans le chantier.
    /// « Plus rien » dit littéralement que rien ne passe : redemander lesquels des services sont
    /// touchés serait reposer une question déjà répondue. Les cases restent modifiables ensuite.
    mutating func select(_ value: OutageSeverity) {
        severity = value
        if value == .down {
            affectsData = true
            affectsVoice = true
            // On VIDE, on ne masque pas : voir la note sur `bands`. Le corps envoyé doit dire ce
            // que la personne a réellement déclaré en dernier.
            bands = []
            sectors = []
        }
    }

    mutating func toggle(band token: String) {
        if bands.contains(token) { bands.remove(token) } else { bands.insert(token) }
    }

    mutating func toggle(sector azimuth: Int) {
        if sectors.contains(azimuth) { sectors.remove(azimuth) } else { sectors.insert(azimuth) }
    }

    mutating func toggle(technology token: String) {
        if technologies.contains(token) {
            technologies.remove(token)
        } else {
            technologies.insert(token)
        }
    }

    /// Le corps à envoyer — `nil` tant que le brouillon n'est pas envoyable.
    ///
    /// Rend l'envoi impossible autrement que par les règles ci-dessus : le bouton désactivé ne
    /// couvre pas les chemins clavier et VoiceOver.
    func request(
        targetKind: String,
        targetId: String,
        marketCode: String,
        operatorKey: String,
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?,
        radioContext: OutageRadioCapture? = nil,
        deviceId: String? = nil,
        observedAt: String? = nil
    ) -> OutageReportRequest? {
        guard let severity, canSubmit else { return nil }
        return OutageReportRequest(
            targetKind: targetKind,
            targetId: targetId,
            marketCode: marketCode,
            operatorKey: operatorKey,
            severity: severity.rawValue,
            affectsData: affectsData,
            affectsVoice: affectsVoice,
            // Plus demandé, donc jamais affirmé : cocher le SMS « parce que plus rien ne passe »
            // ferait dire à la carte de fil quelque chose que personne n'a constaté.
            affectsSms: false,
            affectedTechnologies: OutageTechnologies.sorted(Array(technologies)),
            // Triés : deux personnes qui cochent les mêmes cases dans un ordre différent doivent
            // produire le même corps — c'est ce qui rend les journaux et les tests lisibles.
            affectedBands: bands.sorted(),
            affectedSectors: sectors.sorted(),
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : String(comment.prefix(500)),
            radioContext: attachRadio ? radioContext : nil,
            deviceId: deviceId,
            observedAt: observedAt,
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: accuracyMeters
        )
    }
}

struct OutageVoteRequest: Encodable {
    /// `confirm`, `dispute` ou `repaired` — les trois valent le même geste et le même gain.
    let kind: String
    let latitude: Double?
    let longitude: Double?
    let accuracyMeters: Double?
}

/// Réponse d'écriture. Le gain arrive au format universel de l'app, donc l'affichage des points
/// et des badges suit sans code spécifique.
struct OutageWriteResponse: Decodable {
    let outage: CommunityOutage?
    let award: OutageAward?
    let awards: [OutageAward]?

    struct OutageAward: Decodable {
        let type: String?
        let gamification: GamificationAwardPayload?
    }

    struct GamificationAwardPayload: Decodable {
        let pointsAwarded: Int?
        let levelUp: Bool?
        let capped: Bool?
    }

    /// Tous les gains de la réponse, que le serveur en ait rendu un ou plusieurs.
    ///
    /// Un vote peut en créditer DEUX d'un coup : la voix, et les points de l'auteur si c'est ce
    /// vote qui franchit le seuil et qu'on est cet auteur.
    var allAwards: [OutageAward] {
        if let awards, !awards.isEmpty { return awards }
        if let award { return [award] }
        return []
    }
}
