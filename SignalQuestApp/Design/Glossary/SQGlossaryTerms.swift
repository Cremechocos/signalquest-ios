import SwiftUI

// Contenu généré depuis la liste relue des termes (Lot 3c) : une phrase simple,
// un exemple et, quand elle aide, une échelle bon / moyen / faible. Les textes
// sont des littéraux, donc extraits dans le catalogue comme le reste de l’app.

/// Familles de termes, dans l’ordre de l’écran « Aide et glossaire ».
enum SQGlossaryGroup: String, CaseIterable, Identifiable {
    case network, measurement, antennas, contributions, security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: return String(localized: "Réseau et radio")
        case .measurement: return String(localized: "Mesures")
        case .antennas: return String(localized: "Antennes et carte")
        case .contributions: return String(localized: "Contributions et jeu")
        case .security: return String(localized: "Sécurité et Sentinelle")
        }
    }
}

/// Un terme technique expliqué par un ⓘ et dans le glossaire du Profil.
enum SQTerm: String, CaseIterable, Identifiable {
    // Réseau et radio
    case rsrp
    case rsrq
    case snr
    case cellIdentifiers
    case plmn
    case band
    case fiveGModes
    // Mesures
    case download
    case upload
    case latency
    case jitter
    case packetLoss
    case testServer
    case ipOperator
    // Antennes et carte
    case sector
    case azimuth
    case tilt
    case siteSharing
    case anfr
    case whiteZone
    // Contributions et jeu
    case driveTest
    case coverageSession
    case identification
    case validation
    case points
    case quests
    case territories
    case networkPulse
    // Sécurité et Sentinelle
    case endToEndEncryption
    case encryptionKey
    case twoFactor
    case sentinelle
    case webhook

    var id: String { rawValue }

    var group: SQGlossaryGroup {
        switch self {
        case .rsrp, .rsrq, .snr, .cellIdentifiers, .plmn, .band, .fiveGModes: return .network
        case .download, .upload, .latency, .jitter, .packetLoss, .testServer, .ipOperator: return .measurement
        case .sector, .azimuth, .tilt, .siteSharing, .anfr, .whiteZone: return .antennas
        case .driveTest, .coverageSession, .identification, .validation, .points, .quests, .territories, .networkPulse: return .contributions
        case .endToEndEncryption, .encryptionKey, .twoFactor, .sentinelle, .webhook: return .security
        }
    }

    /// Termes proposés en fin d’explication, pour aller plus loin.
    var related: [SQTerm] {
        switch self {
        case .rsrp: return [.rsrq, .snr, .band]
        case .rsrq: return [.rsrp, .snr]
        case .snr: return [.rsrp, .rsrq]
        case .cellIdentifiers: return [.identification, .sector]
        case .plmn: return [.ipOperator]
        case .band: return [.fiveGModes, .rsrp]
        case .fiveGModes: return [.band]
        case .download: return [.upload, .latency, .testServer]
        case .upload: return [.download, .latency]
        case .latency: return [.jitter, .packetLoss]
        case .jitter: return [.latency, .packetLoss]
        case .packetLoss: return [.latency, .jitter]
        case .testServer: return [.download, .latency]
        case .ipOperator: return [.plmn]
        case .sector: return [.azimuth, .tilt]
        case .azimuth: return [.sector, .tilt]
        case .tilt: return [.sector, .azimuth]
        case .siteSharing: return [.whiteZone, .anfr]
        case .anfr: return [.siteSharing]
        case .whiteZone: return [.siteSharing]
        case .driveTest: return [.download, .coverageSession]
        case .coverageSession: return [.driveTest, .rsrp]
        case .identification: return [.validation, .cellIdentifiers]
        case .validation: return [.identification, .points]
        case .points: return [.quests, .territories]
        case .quests: return [.points]
        case .territories: return [.points]
        case .networkPulse: return [.download, .rsrp]
        case .endToEndEncryption: return [.encryptionKey]
        case .encryptionKey: return [.endToEndEncryption]
        case .twoFactor: return []
        case .sentinelle: return [.webhook, .latency]
        case .webhook: return [.sentinelle]
        }
    }

    var entry: SQGlossaryEntry {
        switch self {
        case .rsrp:
            return SQGlossaryEntry(
                title: String(localized: "Puissance du signal (RSRP)"),
                definition: String(localized: "La force du signal 4G ou 5G reçu de l’antenne, en dBm. Plus le chiffre est proche de zéro, plus le signal est fort : −80 dBm vaut mieux que −110 dBm."),
                example: String(localized: "À −95 dBm, la navigation reste fluide ; sous −110 dBm, les pages peinent à charger."),
                scale: [
                    (String(localized: "−80 dBm et plus"), String(localized: "excellent, même à l’intérieur")),
                    (String(localized: "−90 à −100 dBm"), String(localized: "correct, parfois fragile à l’intérieur")),
                    (String(localized: "sous −110 dBm"), String(localized: "très faible, coupures probables")),
                ],
                related: related
            )
        case .rsrq:
            return SQGlossaryEntry(
                title: String(localized: "Qualité du signal (RSRQ)"),
                definition: String(localized: "La propreté du signal reçu, en dB : elle baisse quand la cellule est chargée ou brouillée par ses voisines. Proche de zéro, c’est bon."),
                example: String(localized: "Un signal fort mais un RSRQ bas, c’est souvent une antenne saturée à l’heure de pointe."),
                scale: [
                    (String(localized: "−10 dB et plus"), String(localized: "bonne qualité")),
                    (String(localized: "−10 à −15 dB"), String(localized: "moyenne")),
                    (String(localized: "sous −15 dB"), String(localized: "dégradée")),
                ],
                related: related
            )
        case .snr:
            return SQGlossaryEntry(
                title: String(localized: "Rapport signal sur bruit (SNR)"),
                definition: String(localized: "L’écart entre le signal utile et le bruit ambiant, en dB. Plus il est élevé, plus le téléphone peut monter en débit."),
                scale: [
                    (String(localized: "20 dB et plus"), String(localized: "excellent")),
                    (String(localized: "0 à 13 dB"), String(localized: "moyen")),
                    (String(localized: "sous 0 dB"), String(localized: "le bruit domine")),
                ],
                related: related
            )
        case .cellIdentifiers:
            return SQGlossaryEntry(
                title: String(localized: "Identifiants de cellule"),
                definition: String(localized: "Les numéros qui désignent une antenne : l’eNB (4G) ou le gNB (5G) repère le site, le CI une cellule précise, le PCI la distingue de ses voisines, le TAC indique sa zone de rattachement."),
                example: String(localized: "iOS ne donne pas ces numéros aux apps : ils viennent de l’app Android ou de la communauté."),
                related: related
            )
        case .plmn:
            return SQGlossaryEntry(
                title: String(localized: "Code opérateur (MCC-MNC)"),
                definition: String(localized: "Le code d’un réseau mobile : le pays (MCC, 208 pour la France) suivi de l’opérateur (MNC)."),
                example: String(localized: "208-01 Orange, 208-10 SFR, 208-15 Free, 208-20 Bouygues Telecom."),
                related: related
            )
        case .band:
            return SQGlossaryEntry(
                title: String(localized: "Bande de fréquences"),
                definition: String(localized: "La plage de fréquences utilisée par une cellule, notée B en 4G et n en 5G. Les basses fréquences portent loin et traversent les murs ; les hautes offrent plus de débit sur une zone plus petite."),
                example: String(localized: "B20 = 800 MHz, idéale à la campagne ; n78 = 3 500 MHz, la 5G rapide des villes."),
                related: related
            )
        case .fiveGModes:
            return SQGlossaryEntry(
                title: String(localized: "5G NSA et 5G SA"),
                definition: String(localized: "En 5G NSA, la 5G s’appuie sur une connexion 4G qui reste active : le téléphone affiche 5G, mais l’ancre est en 4G. En 5G SA (autonome), tout passe par la 5G."),
                example: String(localized: "Une mesure 5G NSA contient souvent deux cellules : l’ancre 4G et la cellule 5G."),
                related: related
            )
        case .download:
            return SQGlossaryEntry(
                title: String(localized: "Réception"),
                definition: String(localized: "Le débit descendant : la vitesse à laquelle ton téléphone reçoit des données (vidéos, pages web, mises à jour)."),
                scale: [
                    (String(localized: "100 Mbit/s et plus"), String(localized: "tout est fluide, même la 4K")),
                    (String(localized: "10 à 30 Mbit/s"), String(localized: "vidéo HD correcte")),
                    (String(localized: "moins de 3 Mbit/s"), String(localized: "navigation lente")),
                ],
                related: related
            )
        case .upload:
            return SQGlossaryEntry(
                title: String(localized: "Envoi"),
                definition: String(localized: "Le débit montant : la vitesse à laquelle ton téléphone envoie des données (photos, appels vidéo, sauvegardes)."),
                scale: [
                    (String(localized: "20 Mbit/s et plus"), String(localized: "envois rapides")),
                    (String(localized: "3 à 10 Mbit/s"), String(localized: "appel vidéo correct")),
                    (String(localized: "moins de 1 Mbit/s"), String(localized: "envois très lents")),
                ],
                related: related
            )
        case .latency:
            return SQGlossaryEntry(
                title: String(localized: "Latence (ping)"),
                definition: String(localized: "Le temps d’un aller-retour entre ton téléphone et le serveur, en millisecondes. Elle compte pour les appels, la visio et les jeux."),
                scale: [
                    (String(localized: "moins de 30 ms"), String(localized: "réactif")),
                    (String(localized: "30 à 100 ms"), String(localized: "correct")),
                    (String(localized: "plus de 100 ms"), String(localized: "décalage perceptible")),
                ],
                related: related
            )
        case .jitter:
            return SQGlossaryEntry(
                title: String(localized: "Gigue"),
                definition: String(localized: "La variation de la latence d’un paquet à l’autre. Une gigue élevée hache la voix et la vidéo en direct."),
                scale: [
                    (String(localized: "moins de 10 ms"), String(localized: "stable")),
                    (String(localized: "10 à 30 ms"), String(localized: "acceptable")),
                    (String(localized: "plus de 30 ms"), String(localized: "appels hachés")),
                ],
                related: related
            )
        case .packetLoss:
            return SQGlossaryEntry(
                title: String(localized: "Perte de paquets"),
                definition: String(localized: "La part des données qui n’arrivent jamais et doivent être renvoyées. Au-delà de 1 pour cent, les appels coupent et les pages se bloquent."),
                scale: [
                    (String(localized: "aucune"), String(localized: "parfait")),
                    (String(localized: "moins de 1 pour cent"), String(localized: "à peine sensible")),
                    (String(localized: "plus de 2 pour cent"), String(localized: "coupures fréquentes")),
                ],
                related: related
            )
        case .testServer:
            return SQGlossaryEntry(
                title: String(localized: "Serveur de mesure"),
                definition: String(localized: "Le serveur avec lequel le speedtest échange des données. Un serveur proche et bien raccordé mesure ton réseau mobile, pas le chemin vers un serveur lointain."),
                related: related
            )
        case .ipOperator:
            return SQGlossaryEntry(
                title: String(localized: "Opérateur deviné par l’adresse IP"),
                definition: String(localized: "iOS ne dit pas aux apps quel réseau sert le téléphone : SignalQuest reconnaît l’opérateur à l’adresse Internet utilisée. En itinérance ou sous VPN, cette estimation peut se tromper."),
                related: related
            )
        case .sector:
            return SQGlossaryEntry(
                title: String(localized: "Secteur"),
                definition: String(localized: "La partie d’un site qui arrose une direction. Un pylône porte souvent trois secteurs, un tous les 120°."),
                related: related
            )
        case .azimuth:
            return SQGlossaryEntry(
                title: String(localized: "Azimut"),
                definition: String(localized: "La direction vers laquelle pointe un secteur, en degrés depuis le nord : 0° au nord, 90° à l’est, 180° au sud, 270° à l’ouest."),
                related: related
            )
        case .tilt:
            return SQGlossaryEntry(
                title: String(localized: "Tilt"),
                definition: String(localized: "L’inclinaison d’une antenne vers le bas. Elle concentre le signal sur la zone à couvrir au lieu de l’envoyer vers l’horizon."),
                related: related
            )
        case .siteSharing:
            return SQGlossaryEntry(
                title: String(localized: "Mutualisation"),
                definition: String(localized: "Plusieurs opérateurs partagent le même support, voire les mêmes antennes. Sur un site partagé, l’opérateur qui l’exploite peut différer du tien."),
                example: String(localized: "Si l’opérateur affiché pour un site partagé te semble faux, tu peux le signaler depuis sa fiche."),
                related: related
            )
        case .anfr:
            return SQGlossaryEntry(
                title: String(localized: "ANFR"),
                definition: String(localized: "L’Agence nationale des fréquences publie la liste officielle des antennes autorisées en France, avec leurs technologies et leurs dates de mise en service."),
                related: related
            )
        case .whiteZone:
            return SQGlossaryEntry(
                title: String(localized: "Zone blanche"),
                definition: String(localized: "Un endroit sans couverture mobile correcte. Les sites du programme « zones blanches » y sont construits par un opérateur, qui les partage avec les autres."),
                related: related
            )
        case .driveTest:
            return SQGlossaryEntry(
                title: String(localized: "Drive Test"),
                definition: String(localized: "Des speedtests enchaînés automatiquement pendant un trajet, espacés selon la distance, jusqu’au plafond de données que tu choisis."),
                example: String(localized: "Tous les 500 m sur l’autoroute : la carte montre où ton opérateur tient la route."),
                related: related
            )
        case .coverageSession:
            return SQGlossaryEntry(
                title: String(localized: "Session de couverture"),
                definition: String(localized: "Un relevé continu du signal radio pendant un déplacement, enregistré avec l’app Android : iOS ne donne pas accès au signal radio."),
                related: related
            )
        case .identification:
            return SQGlossaryEntry(
                title: String(localized: "Identification"),
                definition: String(localized: "Relier une cellule captée par un téléphone à l’antenne réelle sur la carte. Elle devient publique et rapporte des points."),
                related: related
            )
        case .validation:
            return SQGlossaryEntry(
                title: String(localized: "Validation"),
                definition: String(localized: "Confirmer qu’une identification faite par un autre membre est juste. Plus une identification reçoit de validations, plus elle est fiable."),
                related: related
            )
        case .points:
            return SQGlossaryEntry(
                title: String(localized: "Points"),
                definition: String(localized: "Ce que rapportent tes contributions : mesures, identifications, validations et quêtes. Ils font monter ton niveau et ton rang dans les classements."),
                related: related
            )
        case .quests:
            return SQGlossaryEntry(
                title: String(localized: "Quêtes"),
                definition: String(localized: "Des défis à accomplir, comme mesurer un nouveau lieu ou valider des antennes, qui rapportent des points ; certaines durent une saison."),
                related: related
            )
        case .territories:
            return SQGlossaryEntry(
                title: String(localized: "Territoires"),
                definition: String(localized: "La carte découpée en zones que les mesures de la communauté font passer d’inexplorée à observée, fiable puis complète."),
                related: related
            )
        case .networkPulse:
            return SQGlossaryEntry(
                title: String(localized: "Pouls réseau"),
                definition: String(localized: "Le résumé des mesures récentes de la communauté autour de toi : débit médian, signal moyen et meilleur opérateur de la zone."),
                related: related
            )
        case .endToEndEncryption:
            return SQGlossaryEntry(
                title: String(localized: "Chiffrement de bout en bout"),
                definition: String(localized: "Tes messages sont chiffrés sur ton téléphone et déchiffrés sur celui de tes correspondants : nos serveurs ne stockent que du texte illisible. Deux limites pour l’instant : seul le texte est chiffré, et la clé de chaque conversation est créée par nos serveurs à son ouverture, puis remise chiffrée à chaque membre."),
                related: related
            )
        case .encryptionKey:
            return SQGlossaryEntry(
                title: String(localized: "Clé de chiffrement"),
                definition: String(localized: "La clé privée qui ouvre tes conversations chiffrées. Elle est protégée par un mot de passe distinct de celui de ton compte : s’il est perdu, les anciens messages chiffrés ne peuvent plus être lus."),
                related: related
            )
        case .twoFactor:
            return SQGlossaryEntry(
                title: String(localized: "Double authentification (2FA)"),
                definition: String(localized: "En plus du mot de passe, un code à usage unique généré par une application d’authentification. Un mot de passe volé ne suffit plus pour entrer dans ton compte."),
                related: related
            )
        case .sentinelle:
            return SQGlossaryEntry(
                title: String(localized: "Sentinelle"),
                definition: String(localized: "Surveille en continu une connexion, comme ta box, depuis nos serveurs : chaque minute, même téléphone éteint. Coupures, latence et incidents te sont signalés."),
                related: related
            )
        case .webhook:
            return SQGlossaryEntry(
                title: String(localized: "Webhook"),
                definition: String(localized: "Une adresse web, par exemple un salon Discord, où Sentinelle envoie ses alertes automatiquement."),
                related: related
            )
        }
    }
}
