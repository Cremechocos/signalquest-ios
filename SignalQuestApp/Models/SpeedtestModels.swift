import Foundation

/// Corps du PATCH de visibilité d'un speedtest déjà envoyé.
struct SpeedtestVisibilityUpdate: Encodable, Sendable {
    let isVisibleOnMap: Bool
    let shareExactLocation: Bool
}

enum SpeedtestPublishError: LocalizedError {
    /// Test antérieur à la mémorisation de l'id serveur, ou jamais envoyé.
    case unknownServerId

    var errorDescription: String? {
        switch self {
        case .unknownServerId:
            return String(localized: "Ce test ne peut pas être publié : il a été enregistré avant que l'app ne mémorise sa référence serveur.")
        }
    }
}

enum SpeedtestDownloadTarget: String, Codable, CaseIterable, Identifiable {
    case hybridAuto = "hybrid_auto"
    // OVH proof
    case rbx = "rbx"
    case sbg = "sbg"
    case gra = "gra"
    case bom = "bom"
    /// Legacy : OVH n'expose plus à Beauharnois que 5208/5209, et ces daemons
    /// acceptent le TCP sans jamais répondre au handshake iPerf3 — POP retiré du
    /// catalogue, migre vers Auto.
    case bhs = "bhs"
    case us = "us"
    // Bouygues Telecom iPerf (BBR / CUBIC) — poi.cubic retiré du sélecteur (host down)
    case bytelParisBbr = "bytel_paris_bbr"
    case bytelParisCubic = "bytel_paris_cubic"
    case bytelMrsBbr = "bytel_mrs_bbr"
    case bytelMrsCubic = "bytel_mrs_cubic"
    case bytelLyoBbr = "bytel_lyo_bbr"
    case bytelLyoCubic = "bytel_lyo_cubic"
    case bytelTlsBbr = "bytel_tls_bbr"
    case bytelTlsCubic = "bytel_tls_cubic"
    case bytelStrBbr = "bytel_str_bbr"
    case bytelStrCubic = "bytel_str_cubic"
    case bytelPoiBbr = "bytel_poi_bbr"
    /// Legacy : host `poi.cubic` non joignable — migre vers Auto.
    case bytelPoiCubic = "bytel_poi_cubic"
    case bytelRenBbr = "bytel_ren_bbr"
    case bytelRenCubic = "bytel_ren_cubic"
    // Scaleway / online.net public iPerf (ports 5200–5209)
    case onlineNet = "online_net"
    case onlineNet6 = "online_net6"
    case onlineNet90ms = "online_net_90ms"
    case onlineNet6_90ms = "online_net6_90ms"
    // MilkyWan (AS2027) — iPerf3 public, même plage de ports que Bouygues
    case milkywan = "milkywan_cbo"
    // POP iPerf3 publics France & Europe (vérifiés vivants juil. 2026 : handshake
    // iPerf3 réel). Serveurs mono-slot → toujours enregistrer la PLAGE de ports.
    case mojiParis = "moji_paris"          // iperf3.moji.fr, Paris, 41 ports (top FR)
    case clouviderFra = "clouvider_fra"    // fra.speedtest.clouvider.net, Francfort
    case clouviderAms = "clouvider_ams"    // ams.speedtest.clouvider.net, Amsterdam
    case clouviderLon = "clouvider_lon"    // lon.speedtest.clouvider.net, Londres
    case clouviderMan = "clouvider_man"    // man.speedtest.clouvider.net, Manchester
    case leasewebFra = "leaseweb_fra"      // speedtest.fra1.de.leaseweb.net, Francfort
    // Ajoutés au catalogue le 2026-08-10 pour combler le trou nord-américain
    // (`proof.ovh.us` mort, `proof.ovh.ca` retiré), mais oubliés ICI : ils
    // n'existaient que côté Android, donc iOS les reléguait dans « Catalogue »
    // au lieu de leur groupe fournisseur. Même catalogue, deux rangements.
    case clouviderAsh = "clouvider_ash"    // ash.speedtest.clouvider.net, Ashburn
    case leasewebMtl = "leaseweb_mtl"      // speedtest.mtl2.ca.leaseweb.net, Montréal
    case init7 = "init7_ch"                // speedtest.init7.net, Suisse (FAI premium)
    // Cloudflare — moteur HTTPS anycast (couverture mondiale, DL/UL/ping même edge)
    case cloudflare = "cloudflare_edge"
    // LibreSpeed — moteur HTTPS (garbage.php/empty.php) sur le POP LibreSpeed le
    // plus proche ; licence LGPL propre, aucune contrainte Ookla.
    case libreSpeed = "librespeed_auto"
    // POP iPerf3 choisi dans le CATALOGUE servi par l'API, désigné par
    // `SpeedtestRunSettings.iperfServerId`. Sans ce cas, seuls les POPs listés
    // en dur ci-dessus seraient sélectionnables : un serveur ajouté côté serveur
    // resterait invisible tant que l'app n'aurait pas été mise à jour.
    // Symétrique de `.libreSpeed`, qui fonctionne déjà ainsi.
    case iperfCatalog = "iperf_catalog"

    // Legacy cases left for soft migration or parsing safely:
    case cloudflareR2 = "cloudflare_r2"
    case awsCloudFront = "aws_cloudfront"
    case vpsInternal = "vps_internal"

    var id: String { rawValue }

    /// Cases proposés à l'utilisateur (réglages).
    static var selectableCases: [SpeedtestDownloadTarget] {
        [.hybridAuto]
            + ovhCases
            + bouyguesCases
            + scalewayCases
            + milkywanCases
            + publicEuropeCases
            + publicAmericaCases
            + cloudflareCases
            + [.libreSpeed]
    }

    /// Hosts OVH sains (Beauharnois exclu du sélecteur : TCP ouvert, iPerf3 muet).
    static var ovhCases: [SpeedtestDownloadTarget] {
        // `.us` retiré : `proof.ovh.us` (Ashburn) ne répond plus sur AUCUN port de
        // sa plage, vérifié par handshake le 2026-08-10. Le case reste défini pour
        // décoder une préférence existante — `migrated` l'envoie sur Auto, comme
        // Android le fait déjà via LEGACY_MIGRATED_TARGET_IDS.
        [.rbx, .sbg, .gra, .bom]
    }

    /// Hosts Bouygues sains (poi.cubic exclu du sélecteur).
    static var bouyguesCases: [SpeedtestDownloadTarget] {
        [
            .bytelParisBbr, .bytelParisCubic,
            .bytelMrsBbr, .bytelMrsCubic,
            .bytelLyoBbr, .bytelLyoCubic,
            .bytelTlsBbr, .bytelTlsCubic,
            .bytelStrBbr, .bytelStrCubic,
            .bytelPoiBbr,
            .bytelRenBbr, .bytelRenCubic,
        ]
    }

    static var scalewayCases: [SpeedtestDownloadTarget] {
        // Les variantes « +90 ms » (latence artificielle) sont des cibles de DEBUG :
        // elles faussent volontairement la mesure et ne doivent pas être proposées à
        // l'utilisateur (INT-02). Les cases restent définies pour la compat de décodage
        // d'une sélection persistée éventuelle.
        [.onlineNet, .onlineNet6]
    }

    static var milkywanCases: [SpeedtestDownloadTarget] {
        [.milkywan]
    }

    /// POP iPerf3 publics FR/EU vérifiés (Moji Paris + Clouvider/Leaseweb/Init7).
    static var publicEuropeCases: [SpeedtestDownloadTarget] {
        [.mojiParis, .clouviderFra, .clouviderAms, .clouviderLon, .clouviderMan, .leasewebFra, .init7]
    }

    /// POPs nord-américains. Un groupe à part plutôt qu'un ajout à
    /// `publicEuropeCases`, dont le nom deviendrait faux.
    static var publicAmericaCases: [SpeedtestDownloadTarget] {
        [.clouviderAsh, .leasewebMtl]
    }

    static var cloudflareCases: [SpeedtestDownloadTarget] {
        [.cloudflare]
    }

    /// Toujours visibles dans le sélecteur : ce sont des moteurs (auto,
    /// edge anycast mondial), pas des POP d'un fournisseur.
    static var ungroupedCases: [SpeedtestDownloadTarget] {
        [.hybridAuto, .cloudflare, .libreSpeed]
    }

    /// Accordéons du sélecteur, par fournisseur. Source unique : la vue
    /// dérive ses groupes d'ici, sinon un serveur ajouté au catalogue reste
    /// invisible dans l'UI.
    static var pickerGroups: [(region: String, targets: [SpeedtestDownloadTarget])] {
        [
            ("OVH", ovhCases),
            ("Bouygues Telecom", bouyguesCases),
            ("Scaleway", scalewayCases),
            ("MilkyWan", milkywanCases),
            ("iPerf3 · France & Europe", publicEuropeCases),
            ("iPerf3 · Amérique du Nord", publicAmericaCases),
        ]
    }

    /// Migration douce : CDN legacy + host bytel mort → « Auto ».
    var migrated: SpeedtestDownloadTarget {
        switch self {
        case .cloudflareR2, .awsCloudFront, .vpsInternal, .bytelPoiCubic, .bhs, .us,
             .onlineNet90ms, .onlineNet6_90ms:
            return .hybridAuto
        default:
            return self
        }
    }

    /// Libellé court (cartes, badges, historique).
    var displayName: String {
        switch self {
        case .hybridAuto: return "Auto"
        case .rbx: return "Roubaix"
        case .sbg: return "Strasbourg"
        case .gra: return "Gravelines"
        case .bom: return "Mumbai"
        case .bhs: return "Beauharnois"
        case .us: return "Ashburn"
        case .clouviderAsh: return "Ashburn (Clouvider)"
        case .leasewebMtl: return "Montréal"
        case .bytelParisBbr: return "Paris · BBR"
        case .bytelParisCubic: return "Paris · CUBIC"
        case .bytelMrsBbr: return "Marseille · BBR"
        case .bytelMrsCubic: return "Marseille · CUBIC"
        case .bytelLyoBbr: return "Lyon · BBR"
        case .bytelLyoCubic: return "Lyon · CUBIC"
        case .bytelTlsBbr: return "Toulouse · BBR"
        case .bytelTlsCubic: return "Toulouse · CUBIC"
        case .bytelStrBbr: return "Strasbourg · BBR"
        case .bytelStrCubic: return "Strasbourg · CUBIC"
        case .bytelPoiBbr: return "Poitiers · BBR"
        case .bytelPoiCubic: return "Poitiers · CUBIC"
        case .bytelRenBbr: return "Rennes · BBR"
        case .bytelRenCubic: return "Rennes · CUBIC"
        case .onlineNet: return "Paris · Scaleway"
        case .onlineNet6: return "Paris · Scaleway IPv6"
        case .onlineNet90ms: return "Paris · +90 ms"
        case .onlineNet6_90ms: return "Paris · IPv6 +90 ms"
        case .milkywan: return "Croissy-Beaubourg"
        case .mojiParis: return "Paris · Moji"
        case .clouviderFra: return "Francfort · Clouvider"
        case .clouviderAsh: return "Ashburn · Clouvider"
        case .leasewebMtl: return "Montréal · Leaseweb"
        case .clouviderAms: return "Amsterdam · Clouvider"
        case .clouviderLon: return "Londres · Clouvider"
        case .clouviderMan: return "Manchester · Clouvider"
        case .leasewebFra: return "Francfort · Leaseweb"
        case .init7: return "Suisse · Init7"
        case .cloudflare: return "Cloudflare"
        case .libreSpeed: return "LibreSpeed"
        case .iperfCatalog: return "Catalogue"
        case .cloudflareR2: return "Cloudflare"
        case .awsCloudFront: return "AWS CloudFront"
        case .vpsInternal: return "VPS OVH Gravelines"
        }
    }

    /// Sous-titre pour le sélecteur (ville / région).
    var subtitle: String {
        switch self {
        case .hybridAuto: return String(localized: "Sélection mesurée · iPerf3 ou Cloudflare")
        case .rbx: return "OVH · RBX · France"
        case .sbg: return "OVH · SBG · France"
        case .gra: return "OVH · GRA · France"
        case .bom: return "OVH · YNM · Inde"
        case .bhs: return "OVH · BHS · Canada"
        case .us: return String(localized: "OVH · US-EAST · États-Unis")
        case .bytelParisBbr: return "Bouygues · paris.bbr · :9200–9240"
        case .bytelParisCubic: return "Bouygues · paris.cubic · :9200–9240"
        case .bytelMrsBbr: return "Bouygues · mrs.bbr · :9200–9240"
        case .bytelMrsCubic: return "Bouygues · mrs.cubic · :9200–9240"
        case .bytelLyoBbr: return "Bouygues · lyo.bbr · :9200–9240"
        case .bytelLyoCubic: return "Bouygues · lyo.cubic · :9200–9240"
        case .bytelTlsBbr: return "Bouygues · tls.bbr · :9200–9240"
        case .bytelTlsCubic: return "Bouygues · tls.cubic · :9200–9240"
        case .bytelStrBbr: return "Bouygues · str.bbr · :9200–9240"
        case .bytelStrCubic: return "Bouygues · str.cubic · :9200–9240"
        case .bytelPoiBbr: return "Bouygues · poi.bbr · :9200–9240"
        case .bytelPoiCubic: return "Bouygues · poi.cubic · indisponible"
        case .bytelRenBbr: return "Bouygues · ren.bbr · :9200–9240"
        case .bytelRenCubic: return "Bouygues · ren.cubic · :9200–9240"
        case .onlineNet: return "Scaleway · ping.online.net · :5200–5209"
        case .onlineNet6: return "Scaleway · ping6.online.net · :5200–5209"
        case .onlineNet90ms: return "Scaleway · latence artificielle +90 ms (test)"
        case .onlineNet6_90ms: return "Scaleway · IPv6 · latence artificielle +90 ms (test)"
        case .milkywan: return "MilkyWan · speedtest.milkywan.fr · :9200–9240"
        case .mojiParis: return "Moji · iperf3.moji.fr · :5200–5240"
        case .clouviderFra: return "Clouvider · fra.speedtest.clouvider.net · :5200–5209"
        case .clouviderAsh: return "Clouvider · ash.speedtest.clouvider.net · :5200–5209"
        case .leasewebMtl: return "Leaseweb · speedtest.mtl2.ca.leaseweb.net · :5201–5210"
        case .clouviderAms: return "Clouvider · ams.speedtest.clouvider.net · :5200–5209"
        case .clouviderLon: return "Clouvider · lon.speedtest.clouvider.net · :5200–5209"
        case .clouviderMan: return "Clouvider · man.speedtest.clouvider.net · :5200–5209"
        case .leasewebFra: return "Leaseweb · speedtest.fra1.de.leaseweb.net · :5201–5210"
        case .init7: return "Init7 · speedtest.init7.net · :5201–5204"
        case .cloudflare: return String(localized: "Edge anycast mondial · HTTPS · DL/UL/ping même serveur")
        case .libreSpeed: return "POP LibreSpeed le plus proche · HTTPS · DL/UL/ping"
        case .iperfCatalog: return "POP iPerf3 du catalogue · TCP · DL/UL/ping"
        case .cloudflareR2: return "CDN Cloudflare"
        case .awsCloudFront: return "CDN AWS"
        case .vpsInternal: return "VPS SignalQuest"
        }
    }

    /// Groupe collapsible du sélecteur.
    var regionLabel: String {
        switch self {
        case .hybridAuto: return String(localized: "Recommandé")
        case .rbx, .sbg, .gra, .bom, .bhs, .us: return "OVH"
        case .bytelParisBbr, .bytelParisCubic,
             .bytelMrsBbr, .bytelMrsCubic,
             .bytelLyoBbr, .bytelLyoCubic,
             .bytelTlsBbr, .bytelTlsCubic,
             .bytelStrBbr, .bytelStrCubic,
             .bytelPoiBbr, .bytelPoiCubic,
             .bytelRenBbr, .bytelRenCubic:
            return "Bouygues Telecom"
        case .onlineNet, .onlineNet6, .onlineNet90ms, .onlineNet6_90ms:
            return "Scaleway"
        case .milkywan: return "MilkyWan"
        case .mojiParis, .clouviderFra, .clouviderAms, .clouviderLon, .clouviderMan, .leasewebFra, .init7:
            return "iPerf3 · France & Europe"
        case .clouviderAsh, .leasewebMtl:
            return "iPerf3 · Amérique du Nord"
        case .cloudflare, .libreSpeed: return "Mondial"
        // Section propre, alimentée par l'API : son contenu varie d'un lancement à
        // l'autre, il ne peut donc pas être rattaché à un groupe figé.
        case .iperfCatalog: return "Catalogue"
        case .cloudflareR2, .awsCloudFront, .vpsInternal: return "Legacy"
        }
    }

    /// SF Symbol du sélecteur.
    var systemImage: String {
        switch self {
        case .hybridAuto: return "location.magnifyingglass"
        case .rbx, .sbg, .gra: return "building.2.fill"
        case .bhs: return "leaf.fill"
        case .us: return "globe.americas.fill"
        case .bom: return "globe.asia.australia.fill"
        case .bytelParisBbr, .bytelParisCubic,
             .bytelMrsBbr, .bytelMrsCubic,
             .bytelLyoBbr, .bytelLyoCubic,
             .bytelTlsBbr, .bytelTlsCubic,
             .bytelStrBbr, .bytelStrCubic,
             .bytelPoiBbr, .bytelPoiCubic,
             .bytelRenBbr, .bytelRenCubic:
            return "antenna.radiowaves.left.and.right"
        case .onlineNet, .onlineNet90ms: return "server.rack"
        case .onlineNet6, .onlineNet6_90ms: return "network"
        case .milkywan: return "server.rack"
        case .mojiParis, .clouviderFra, .clouviderAms, .clouviderLon, .clouviderMan, .leasewebFra, .init7,
             .clouviderAsh, .leasewebMtl: return "server.rack"
        case .cloudflare: return "globe"
        case .libreSpeed: return "speedometer"
        case .iperfCatalog: return "server.rack"
        case .cloudflareR2, .awsCloudFront, .vpsInternal: return "server.rack"
        }
    }
}

struct SpeedtestRunSettings: Codable, Equatable {
    var downloadTarget: SpeedtestDownloadTarget
    var durationSeconds: Int
    var streams: Int
    var reliabilityMode: Bool
    /// Serveur LibreSpeed choisi manuellement (hostname du catalogue). `nil` =
    /// le plus proche automatiquement. Ignoré si `downloadTarget != .libreSpeed`.
    var libreSpeedHost: String?
    /// POP iPerf3 choisi manuellement, par son id de CATALOGUE. Symétrique de
    /// `libreSpeedHost`, et c'est ce qui permet de sélectionner un serveur que
    /// l'API a introduit mais que cette version de l'app ne connaît pas en dur.
    /// Ignoré si `downloadTarget != .iperfCatalog`.
    var iperfServerId: String?

    // Rétro-compat de décodage : `libreSpeedHost` absent des réglages persistés
    // avant l'ajout du choix manuel LibreSpeed, `iperfServerId` avant le catalogue
    // distant. Les deux se décodent donc en optionnel.
    enum CodingKeys: String, CodingKey {
        case downloadTarget, durationSeconds, streams, reliabilityMode, libreSpeedHost, iperfServerId
    }
    init(
        downloadTarget: SpeedtestDownloadTarget,
        durationSeconds: Int,
        streams: Int,
        reliabilityMode: Bool,
        libreSpeedHost: String? = nil,
        iperfServerId: String? = nil
    ) {
        self.downloadTarget = downloadTarget
        self.durationSeconds = durationSeconds
        self.streams = streams
        self.reliabilityMode = reliabilityMode
        self.libreSpeedHost = libreSpeedHost
        self.iperfServerId = iperfServerId
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadTarget = try c.decode(SpeedtestDownloadTarget.self, forKey: .downloadTarget)
        durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        streams = try c.decode(Int.self, forKey: .streams)
        reliabilityMode = try c.decode(Bool.self, forKey: .reliabilityMode)
        libreSpeedHost = try c.decodeIfPresent(String.self, forKey: .libreSpeedHost)
        iperfServerId = try c.decodeIfPresent(String.self, forKey: .iperfServerId)
    }

    static let androidDefault = SpeedtestRunSettings(
        downloadTarget: .hybridAuto,
        durationSeconds: 10,
        streams: 16,
        reliabilityMode: true
    )
}

struct SpeedtestRunResult: Codable, Identifiable, Equatable {
    let id: UUID
    let label: String
    let downloadMbps: Double
    let downloadAverageMbps: Double
    let downloadMaxMbps: Double
    let downloadP90Mbps: Double?
    let downloadP95Mbps: Double?
    let uploadMbps: Double?
    let uploadAverageMbps: Double?
    let uploadMaxMbps: Double?
    let uploadP90Mbps: Double?
    let uploadP95Mbps: Double?
    let pingMs: Double?
    let pingMedianMs: Double?
    let pingMinMs: Double?
    let pingMaxMs: Double?
    let jitterMs: Double?
    let pingDlMs: Double?
    let jitterDlMs: Double?
    let pingUlMs: Double?
    let jitterUlMs: Double?
    let pingProtocol: String?
    let durationSeconds: Double
    let connectionType: NetworkConnectionKind
    let cellularTechnology: CellularRadioTechnology?
    let networkOperatorName: String?
    let networkOperatorMcc: Int?
    let networkOperatorMnc: Int?
    let marketCode: String?
    let operatorKey: String?
    let wifiSSID: String?
    let city: String?
    /// Adresse (rue + commune) reverse-géocodée du point de mesure. Envoyée au
    /// backend pour situer le test ; volontairement sans numéro de voirie pour
    /// rester cohérent avec la minimisation des coordonnées (RGPD art. 5.1.c).
    let address: String?
    let coordinate: Coordinates?
    /// Serveur de MESURE (VPS sélectionné par la session). C'est lui qui réalise
    /// l'upload et sert de référence pour la latence/le partage.
    let serverName: String?
    /// Origine des octets de download (ex. CDN CloudFront) quand elle diffère du
    /// serveur de mesure. Distinct de `serverName` pour ne plus afficher « AWS »
    /// comme serveur de test.
    let downloadServerName: String?
    /// Id de catalogue du serveur de download (`rbx`, `bytel_paris_bbr`,
    /// `cloudflare_CDG`…) + code POP court. Ces deux valeurs partent en base et
    /// sont communes à Android : elles doivent rester stables dans le temps.
    let downloadServerId: String?
    let downloadServerCode: String?
    /// Hôte et port réellement mesurés — l'id n'étant qu'un alias, eux seuls
    /// permettent de savoir a posteriori quel POP a produit la mesure, et sur
    /// quel port (le port-walk le fait varier d'un test à l'autre).
    let downloadServerHost: String?
    let downloadServerPort: Int?
    /// Moteur ayant RÉELLEMENT produit la mesure (`iperf3`, `cloudflare`,
    /// `librespeed`), raison du repli le cas échéant, et cible demandée AVANT
    /// bascule. `downloadServerId` porte le serveur OBTENU : c'est l'écart entre
    /// les deux qui rend une bascule lisible a posteriori.
    let engine: String?
    let engineFallbackReason: String?
    let requestedServerId: String?
    let createdAt: Date
    let downloadSeriesMbps: [Double]?
    let uploadSeriesMbps: [Double]?
    /// Nombre de fenêtres de GRÂCE (warm-up/omit) en tête des séries — le
    /// renderer distingue visuellement la montée en charge du régime établi.
    /// nil/0 = pas de segment de grâce (ex. moteur Cloudflare, historique).
    let downloadGraceWindowCount: Int?
    let uploadGraceWindowCount: Int?
    let uploadMeasurementSource: String?
    let deviceModel: String?
    let osVersion: String?

    init(
        id: UUID = UUID(),
        label: String,
        downloadMbps: Double,
        downloadAverageMbps: Double,
        downloadMaxMbps: Double,
        downloadP90Mbps: Double? = nil,
        downloadP95Mbps: Double? = nil,
        uploadMbps: Double? = nil,
        uploadAverageMbps: Double? = nil,
        uploadMaxMbps: Double? = nil,
        uploadP90Mbps: Double? = nil,
        uploadP95Mbps: Double? = nil,
        pingMs: Double? = nil,
        pingMedianMs: Double? = nil,
        pingMinMs: Double? = nil,
        pingMaxMs: Double? = nil,
        jitterMs: Double? = nil,
        pingDlMs: Double? = nil,
        jitterDlMs: Double? = nil,
        pingUlMs: Double? = nil,
        jitterUlMs: Double? = nil,
        pingProtocol: String? = nil,
        durationSeconds: Double,
        connectionType: NetworkConnectionKind,
        cellularTechnology: CellularRadioTechnology? = nil,
        networkOperatorName: String? = nil,
        networkOperatorMcc: Int? = nil,
        networkOperatorMnc: Int? = nil,
        marketCode: String? = nil,
        operatorKey: String? = nil,
        wifiSSID: String? = nil,
        city: String? = nil,
        address: String? = nil,
        coordinate: Coordinates? = nil,
        serverName: String? = nil,
        downloadServerName: String? = nil,
        downloadServerId: String? = nil,
        downloadServerCode: String? = nil,
        downloadServerHost: String? = nil,
        downloadServerPort: Int? = nil,
        engine: String? = nil,
        engineFallbackReason: String? = nil,
        requestedServerId: String? = nil,
        createdAt: Date = Date(),
        downloadSeriesMbps: [Double]? = nil,
        uploadSeriesMbps: [Double]? = nil,
        downloadGraceWindowCount: Int? = nil,
        uploadGraceWindowCount: Int? = nil,
        uploadMeasurementSource: String? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil
    ) {
        self.id = id
        self.label = label
        self.downloadMbps = downloadMbps
        self.downloadAverageMbps = downloadAverageMbps
        self.downloadMaxMbps = downloadMaxMbps
        self.downloadP90Mbps = downloadP90Mbps
        self.downloadP95Mbps = downloadP95Mbps
        self.uploadMbps = uploadMbps
        self.uploadAverageMbps = uploadAverageMbps
        self.uploadMaxMbps = uploadMaxMbps
        self.uploadP90Mbps = uploadP90Mbps
        self.uploadP95Mbps = uploadP95Mbps
        self.pingMs = pingMs
        self.pingMedianMs = pingMedianMs
        self.pingMinMs = pingMinMs
        self.pingMaxMs = pingMaxMs
        self.jitterMs = jitterMs
        self.pingDlMs = pingDlMs
        self.jitterDlMs = jitterDlMs
        self.pingUlMs = pingUlMs
        self.jitterUlMs = jitterUlMs
        self.pingProtocol = pingProtocol
        self.durationSeconds = durationSeconds
        self.connectionType = connectionType
        self.cellularTechnology = cellularTechnology
        self.networkOperatorName = networkOperatorName
        self.networkOperatorMcc = networkOperatorMcc
        self.networkOperatorMnc = networkOperatorMnc
        self.marketCode = marketCode
        self.operatorKey = operatorKey
        self.wifiSSID = wifiSSID
        self.city = city
        self.address = address
        self.coordinate = coordinate
        self.serverName = serverName
        self.downloadServerName = downloadServerName
        self.downloadServerId = downloadServerId
        self.downloadServerCode = downloadServerCode
        self.downloadServerHost = downloadServerHost
        self.downloadServerPort = downloadServerPort
        self.engine = engine
        self.engineFallbackReason = engineFallbackReason
        self.requestedServerId = requestedServerId
        self.createdAt = createdAt
        self.downloadSeriesMbps = downloadSeriesMbps
        self.uploadSeriesMbps = uploadSeriesMbps
        self.downloadGraceWindowCount = downloadGraceWindowCount
        self.uploadGraceWindowCount = uploadGraceWindowCount
        self.uploadMeasurementSource = uploadMeasurementSource
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }

    var networkDisplayName: String {
        switch connectionType {
        case .wifi:
            return "WiFi"
        case .cellular:
            return cellularTechnology?.displayName ?? "Cellulaire"
        case .wired:
            return "Ethernet"
        case .other:
            return "Autre"
        }
    }

    var networkShareDisplayName: String {
        switch connectionType {
        case .wifi:
            // Affiche le FAI (résolu par IP, porté par networkOperatorName) plutôt
            // que le SSID — plus parlant et évite d'exposer le nom du réseau privé.
            if let fai = networkOperatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !fai.isEmpty {
                return "\(fai) • WiFi"
            }
            return "WiFi"
        case .cellular:
            let technology = cellularTechnology?.displayName
            switch (networkOperatorName, technology) {
            case let (.some(operatorName), .some(technology)):
                return "\(operatorName) \(technology)"
            case let (.some(operatorName), .none):
                return operatorName
            case let (.none, .some(technology)):
                return technology
            case (.none, .none):
                return "Cellulaire"
            }
        case .wired, .other:
            return networkDisplayName
        }
    }

    var speedtestConnectionType: String {
        switch connectionType {
        case .cellular:
            return cellularTechnology?.displayName ?? connectionType.rawValue
        default:
            return connectionType.rawValue
        }
    }

    static let empty = SpeedtestRunResult(
        id: UUID(),
        label: "iOS speedtest — métriques radio non disponibles",
        downloadMbps: 0,
        downloadAverageMbps: 0,
        downloadMaxMbps: 0,
        downloadP90Mbps: nil,
        downloadP95Mbps: nil,
        uploadMbps: nil,
        uploadAverageMbps: nil,
        uploadMaxMbps: nil,
        uploadP90Mbps: nil,
        uploadP95Mbps: nil,
        pingMs: nil,
        pingMedianMs: nil,
        pingMinMs: nil,
        pingMaxMs: nil,
        jitterMs: nil,
        pingDlMs: nil,
        jitterDlMs: nil,
        pingUlMs: nil,
        jitterUlMs: nil,
        pingProtocol: nil,
        durationSeconds: 0,
        connectionType: .other,
        cellularTechnology: nil,
        networkOperatorName: nil,
        networkOperatorMcc: nil,
        networkOperatorMnc: nil,
        marketCode: nil,
        operatorKey: nil,
        wifiSSID: nil,
        city: nil,
        coordinate: nil,
        serverName: nil,
        downloadServerName: nil,
        downloadServerId: nil,
        downloadServerCode: nil,
        createdAt: Date(),
        downloadSeriesMbps: nil,
        uploadSeriesMbps: nil,
        downloadGraceWindowCount: nil,
        uploadGraceWindowCount: nil,
        uploadMeasurementSource: nil,
        deviceModel: nil,
        osVersion: nil
    )
}

enum NetworkConnectionKind: String, Codable, Equatable, CaseIterable, Sendable {
    case cellular = "CELLULAR"
    case wifi = "WIFI"
    case wired = "WIRED"
    case other = "OTHER"
}

struct Coordinates: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct DeviceInfo: Codable, Equatable {
    let type: String
    let model: String
}

struct SpeedtestSubmission: Encodable, Equatable {
    let clientSubmissionId: String
    let downloadSpeed: Double
    let averageSpeed: Double
    let maxSpeed: Double
    let uploadSpeed: Double?
    let uploadAvg: Double?
    let uploadMax: Double?
    let downloadAvg: Double
    let downloadP90: Double?
    let downloadP95: Double?
    let downloadPeakMbps: Double?
    let downloadMax: Double?
    let uploadP90: Double?
    let uploadP95: Double?
    let uploadPeakMbps: Double?
    let ping: Double?
    let pingAvg: Double?
    let pingMedian: Double?
    let pingMin: Double?
    let pingMax: Double?
    let pingProtocol: String?
    let jitter: Double?
    let pingDl: Double?
    let jitterDl: Double?
    let pingUl: Double?
    let jitterUl: Double?
    let testDuration: Double
    let streams: Int
    let connectionType: String
    let networkType: String
    let coordinates: Coordinates?
    let city: String?
    let address: String?
    let mobileOperator: String?
    let mcc: Int?
    let mnc: Int?
    let marketCode: String?
    let operatorKey: String?
    let device: DeviceInfo
    let deviceType: String
    let deviceModel: String
    let isVisibleOnMap: Bool
    let shareExactLocation: Bool
    let guestDeleteToken: String?
    /// Id LOCAL de la session Drive Test en cours (UUID) quand ce speedtest est lancé
    /// pendant un drive. Le backend rattache le speedtest à la session de couverture via
    /// cet id (résolu par `CoverageSession.sourceSessionId`, ou backfill à l'import).
    /// `nil` pour un speedtest manuel hors drive.
    let sessionId: String?
    let server: String?
    let downloadServerName: String?
    let downloadServerId: String?
    let downloadServerCode: String?
    let downloadServerHost: String?
    let downloadServerPort: Int?
    /// Moteur ayant RÉELLEMENT produit la mesure (`iperf3`, `cloudflare`,
    /// `librespeed`), raison du repli le cas échéant, et cible demandée AVANT
    /// bascule. `downloadServerId` porte le serveur OBTENU : c'est l'écart entre
    /// les deux qui rend une bascule lisible a posteriori.
    let engine: String?
    let engineFallbackReason: String?
    let requestedServerId: String?

    /// Version de la méthodologie de mesure, commune aux deux plateformes.
    ///
    /// iOS ne l'envoyait pas du tout : filtrer les agrégats dessus aurait donc
    /// exclu 100 % du corpus iOS, ce qui explique que le champ n'ait jamais été
    /// exploité côté serveur. À partir de 4, le même numéro garantit la MÊME
    /// méthodologie ici et sur Android (gigue en écart-type de part et d'autre) —
    /// c'est ce qui rend un agrégat tous téléphones confondus légitime.
    /// Contrat lu par `apps/web/lib/speedtest-comparability.ts`.
    ///
    /// **5** — le débit crête passe du « max des fenêtres d'1 s » à la moyenne de
    /// la meilleure fenêtre glissante couvrant 30 % de la durée, définition de
    /// nPerf. `downloadMax`/`uploadMax` BAISSENT donc à partir de cette version,
    /// d'autant plus que le lien est instable (~+14 % d'écart en cellulaire,
    /// jusqu'à +88 % sur une rafale courte, mesuré en simulation). Sans ce
    /// numéro, la rupture dans la série historique serait inexplicable et se
    /// lirait comme une dégradation du réseau. Moyenne, p90 et p95 sont
    /// INCHANGÉES : seul le max est concerné.
    static let currentMethodologyVersion = 5

    enum CodingKeys: String, CodingKey {
        case clientSubmissionId, downloadSpeed, averageSpeed, maxSpeed, uploadSpeed, uploadAvg, uploadMax, downloadAvg, downloadP90, downloadP95, downloadPeakMbps, downloadMax, uploadP90, uploadP95, uploadPeakMbps, ping, pingAvg, pingMedian, pingMin, pingMax, pingProtocol, jitter, testDuration, streams, connectionType, networkType, coordinates, city, address, mobileOperator, mcc, mnc, marketCode, operatorKey, device, deviceType, deviceModel, isVisibleOnMap, shareExactLocation, guestDeleteToken, sessionId, server, downloadServerName, downloadServerId, downloadServerCode, downloadServerHost, downloadServerPort, methodologyVersion, engine, engineFallbackReason, requestedServerId
        case rsrp, rsrq, snr, cellId, pci, enb, gnb, radioSnapshots
        case pingDl, jitterDl, pingUl, jitterUl
    }

    /// Réduit la précision des coordonnées avant tout envoi au backend, pour
    /// respecter la minimisation (RGPD art. 5.1.c). Même grille que la couverture
    /// (`CoveragePointUpload.minimizedCoordinates`) : les deux DOIVENT rester
    /// alignées, sinon un speedtest et le point de couverture pris au même endroit
    /// atterrissent sur deux positions différentes de la carte.
    static func minimizedCoordinates(_ coordinate: Coordinates?) -> Coordinates? {
        guard let coordinate else { return nil }
        return Coordinates(
            latitude: CoordinateGrid.snap(coordinate.latitude),
            longitude: CoordinateGrid.snap(coordinate.longitude)
        )
    }

    static func iosPayload(
        from result: SpeedtestRunResult,
        streams: Int,
        deviceModel: String,
        mobileOperator: String? = nil,
        isVisibleOnMap: Bool = false,
        shareExactLocation: Bool = false,
        guestDeleteToken: String? = nil,
        sessionId: String? = nil
    ) -> SpeedtestSubmission {
        SpeedtestSubmission(
            clientSubmissionId: result.id.uuidString,
            downloadSpeed: result.downloadAverageMbps,
            averageSpeed: result.downloadAverageMbps,
            // `maxSpeed` (champ legacy backend) reçoit délibérément le P90, pas le
            // pic réel : c'est un « max robuste » qui écrête les rafales aberrantes
            // pour l'affichage. Le vrai maximum instantané est transmis à part dans
            // `downloadMax`/`downloadPeakMbps` (TEL-14).
            maxSpeed: result.downloadP90Mbps ?? result.downloadAverageMbps,
            uploadSpeed: result.uploadAverageMbps,
            uploadAvg: result.uploadAverageMbps,
            uploadMax: result.uploadMaxMbps,
            downloadAvg: result.downloadAverageMbps,
            downloadP90: result.downloadP90Mbps,
            downloadP95: result.downloadP95Mbps,
            downloadPeakMbps: result.downloadMaxMbps,
            downloadMax: result.downloadMaxMbps,
            uploadP90: result.uploadP90Mbps,
            uploadP95: result.uploadP95Mbps,
            uploadPeakMbps: result.uploadMaxMbps,
            ping: result.pingMinMs ?? result.pingMs,
            pingAvg: result.pingMs,
            pingMedian: result.pingMedianMs,
            pingMin: result.pingMinMs,
            pingMax: result.pingMaxMs,
            pingProtocol: result.pingProtocol,
            jitter: result.jitterMs,
            pingDl: result.pingDlMs,
            jitterDl: result.jitterDlMs,
            pingUl: result.pingUlMs,
            jitterUl: result.jitterUlMs,
            testDuration: result.durationSeconds,
            streams: streams,
            connectionType: result.speedtestConnectionType,
            networkType: result.connectionType.rawValue,
            coordinates: shareExactLocation ? result.coordinate : minimizedCoordinates(result.coordinate),
            city: result.city,
            address: result.address,
            mobileOperator: mobileOperator ?? result.networkOperatorName,
            mcc: result.networkOperatorMcc,
            mnc: result.networkOperatorMnc,
            marketCode: result.marketCode,
            operatorKey: result.operatorKey,
            device: DeviceInfo(type: "iPhone", model: deviceModel),
            deviceType: "iPhone",
            deviceModel: deviceModel,
            isVisibleOnMap: isVisibleOnMap,
            shareExactLocation: shareExactLocation,
            guestDeleteToken: guestDeleteToken,
            sessionId: sessionId,
            server: result.serverName,
            downloadServerName: result.downloadServerName ?? result.serverName,
            downloadServerId: result.downloadServerId,
            downloadServerCode: result.downloadServerCode,
            downloadServerHost: result.downloadServerHost,
            downloadServerPort: result.downloadServerPort,
            engine: result.engine,
            engineFallbackReason: result.engineFallbackReason,
            requestedServerId: result.requestedServerId
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientSubmissionId, forKey: .clientSubmissionId)
        try c.encode(downloadSpeed, forKey: .downloadSpeed)
        try c.encode(averageSpeed, forKey: .averageSpeed)
        try c.encode(maxSpeed, forKey: .maxSpeed)
        try c.encodeIfPresent(uploadSpeed, forKey: .uploadSpeed)
        try c.encodeIfPresent(uploadAvg, forKey: .uploadAvg)
        try c.encodeIfPresent(uploadMax, forKey: .uploadMax)
        try c.encode(downloadAvg, forKey: .downloadAvg)
        try c.encodeIfPresent(downloadP90, forKey: .downloadP90)
        try c.encodeIfPresent(downloadP95, forKey: .downloadP95)
        try c.encodeIfPresent(downloadPeakMbps, forKey: .downloadPeakMbps)
        try c.encodeIfPresent(downloadMax, forKey: .downloadMax)
        try c.encodeIfPresent(uploadP90, forKey: .uploadP90)
        try c.encodeIfPresent(uploadP95, forKey: .uploadP95)
        try c.encodeIfPresent(uploadPeakMbps, forKey: .uploadPeakMbps)
        try c.encodeIfPresent(ping, forKey: .ping)
        try c.encodeIfPresent(pingAvg, forKey: .pingAvg)
        try c.encodeIfPresent(pingMedian, forKey: .pingMedian)
        try c.encodeIfPresent(pingMin, forKey: .pingMin)
        try c.encodeIfPresent(pingMax, forKey: .pingMax)
        try c.encodeIfPresent(pingProtocol, forKey: .pingProtocol)
        try c.encodeIfPresent(jitter, forKey: .jitter)
        try c.encodeIfPresent(pingDl, forKey: .pingDl)
        try c.encodeIfPresent(jitterDl, forKey: .jitterDl)
        try c.encodeIfPresent(pingUl, forKey: .pingUl)
        try c.encodeIfPresent(jitterUl, forKey: .jitterUl)
        try c.encode(testDuration, forKey: .testDuration)
        try c.encode(streams, forKey: .streams)
        try c.encode(connectionType, forKey: .connectionType)
        try c.encode(networkType, forKey: .networkType)
        try c.encodeIfPresent(coordinates, forKey: .coordinates)
        try c.encodeIfPresent(city, forKey: .city)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encodeIfPresent(mobileOperator, forKey: .mobileOperator)
        try c.encodeIfPresent(mcc, forKey: .mcc)
        try c.encodeIfPresent(mnc, forKey: .mnc)
        try c.encodeIfPresent(marketCode, forKey: .marketCode)
        try c.encodeIfPresent(operatorKey, forKey: .operatorKey)
        try c.encode(device, forKey: .device)
        try c.encode(deviceType, forKey: .deviceType)
        try c.encode(deviceModel, forKey: .deviceModel)
        try c.encode(isVisibleOnMap, forKey: .isVisibleOnMap)
        try c.encode(shareExactLocation, forKey: .shareExactLocation)
        try c.encodeIfPresent(guestDeleteToken, forKey: .guestDeleteToken)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(server, forKey: .server)
        try c.encodeIfPresent(downloadServerName, forKey: .downloadServerName)
        try c.encodeIfPresent(downloadServerId, forKey: .downloadServerId)
        try c.encodeIfPresent(downloadServerCode, forKey: .downloadServerCode)
        try c.encodeIfPresent(downloadServerHost, forKey: .downloadServerHost)
        try c.encode(Self.currentMethodologyVersion, forKey: .methodologyVersion)
        try c.encodeIfPresent(engine, forKey: .engine)
        try c.encodeIfPresent(engineFallbackReason, forKey: .engineFallbackReason)
        try c.encodeIfPresent(requestedServerId, forKey: .requestedServerId)
        try c.encodeIfPresent(downloadServerPort, forKey: .downloadServerPort)
        try c.encodeNil(forKey: .rsrp)
        try c.encodeNil(forKey: .rsrq)
        try c.encodeNil(forKey: .snr)
        try c.encodeNil(forKey: .cellId)
        try c.encodeNil(forKey: .pci)
        try c.encodeNil(forKey: .enb)
        try c.encodeNil(forKey: .gnb)
        try c.encodeNil(forKey: .radioSnapshots)
    }
}

struct SpeedtestSaveResponse: Codable {
    let success: Bool
    let id: String?
    let data: JSONValue?
    let requestId: String?
    /// Renvoyé uniquement à la création anonyme. Le serveur n'en conserve que le hash.
    let deleteToken: String?

    /// Le backend historique renvoie `data.id` lors de la création et `id` lors
    /// d'un rejeu idempotent. Accepter les deux évite de perdre le reçu invité
    /// précisément lorsque le premier POST a réussi.
    var resolvedID: String? {
        if let id, !id.isEmpty { return id }
        guard case .object(let object) = data,
              case .string(let nestedID) = object["id"],
              !nestedID.isEmpty else { return nil }
        return nestedID
    }
}

struct SpeedtestDetail: Decodable, Identifiable, Equatable {
    let id: String
    let timestamp: Date?
    let createdAt: Date?
    let downloadSpeed: Double?
    let maxSpeed: Double?
    let averageSpeed: Double?
    let downloadAvg: Double?
    let downloadP90: Double?
    let downloadP95: Double?
    let downloadMax: Double?
    let downloadPeakMbps: Double?
    let testDuration: Double?
    let streams: Int?
    let uploadSpeed: Double?
    let uploadAvg: Double?
    let uploadMax: Double?
    let uploadP90: Double?
    let uploadP95: Double?
    let uploadPeakMbps: Double?
    let ping: Double?
    let pingAvg: Double?
    let pingMedian: Double?
    let pingMin: Double?
    let pingMax: Double?
    let pingProtocol: String?
    let jitter: Double?
    let pingDl: Double?
    let jitterDl: Double?
    let pingUl: Double?
    let jitterUl: Double?
    let server: String?
    let downloadServerId: String?
    let downloadServerName: String?
    let connectionType: String?
    let networkType: String?
    let mobileOperator: String?
    let mcc: Int?
    let mnc: Int?
    let latitude: Double?
    let longitude: Double?
    let address: String?
    let locationBlurred: Bool?
    let deviceType: String?
    let deviceModel: String?
    let isPublic: Bool?
    let isVisibleOnMap: Bool?
    let shareExactLocation: Bool?
    let isOwner: Bool?
    let rsrp: Double?
    let rsrq: Double?
    let snr: Double?
    let timingAdvance: Double?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, createdAt, downloadSpeed, maxSpeed, averageSpeed, downloadAvg, downloadP90, downloadP95, downloadMax, downloadPeakMbps, testDuration, streams, uploadSpeed, uploadAvg, uploadMax, uploadP90, uploadP95, uploadPeakMbps, ping, pingAvg, pingMedian, pingMin, pingMax, pingProtocol, jitter, server, downloadServerId, downloadServerName, connectionType, networkType, mobileOperator, mcc, mnc, latitude, longitude, address, locationBlurred, deviceType, deviceModel, isPublic, isVisibleOnMap, shareExactLocation, isOwner, rsrp, rsrq, snr, timingAdvance
        case pingDl, jitterDl, pingUl, jitterUl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        downloadSpeed = try? c.decodeIfPresent(Double.self, forKey: .downloadSpeed)
        maxSpeed = try? c.decodeIfPresent(Double.self, forKey: .maxSpeed)
        averageSpeed = try? c.decodeIfPresent(Double.self, forKey: .averageSpeed)
        downloadAvg = try? c.decodeIfPresent(Double.self, forKey: .downloadAvg)
        downloadP90 = try? c.decodeIfPresent(Double.self, forKey: .downloadP90)
        downloadP95 = try? c.decodeIfPresent(Double.self, forKey: .downloadP95)
        downloadMax = try? c.decodeIfPresent(Double.self, forKey: .downloadMax)
        downloadPeakMbps = try? c.decodeIfPresent(Double.self, forKey: .downloadPeakMbps)
        testDuration = try? c.decodeIfPresent(Double.self, forKey: .testDuration)
        streams = try? c.decodeIfPresent(Int.self, forKey: .streams)
        uploadSpeed = try? c.decodeIfPresent(Double.self, forKey: .uploadSpeed)
        uploadAvg = try? c.decodeIfPresent(Double.self, forKey: .uploadAvg)
        uploadMax = try? c.decodeIfPresent(Double.self, forKey: .uploadMax)
        uploadP90 = try? c.decodeIfPresent(Double.self, forKey: .uploadP90)
        uploadP95 = try? c.decodeIfPresent(Double.self, forKey: .uploadP95)
        uploadPeakMbps = try? c.decodeIfPresent(Double.self, forKey: .uploadPeakMbps)
        ping = try? c.decodeIfPresent(Double.self, forKey: .ping)
        pingAvg = try? c.decodeIfPresent(Double.self, forKey: .pingAvg)
        pingMedian = try? c.decodeIfPresent(Double.self, forKey: .pingMedian)
        pingMin = try? c.decodeIfPresent(Double.self, forKey: .pingMin)
        pingMax = try? c.decodeIfPresent(Double.self, forKey: .pingMax)
        pingProtocol = c.decodeFlexibleString(forKey: .pingProtocol)
        jitter = try? c.decodeIfPresent(Double.self, forKey: .jitter)
        pingDl = try? c.decodeIfPresent(Double.self, forKey: .pingDl)
        jitterDl = try? c.decodeIfPresent(Double.self, forKey: .jitterDl)
        pingUl = try? c.decodeIfPresent(Double.self, forKey: .pingUl)
        jitterUl = try? c.decodeIfPresent(Double.self, forKey: .jitterUl)
        server = c.decodeFlexibleString(forKey: .server)
        downloadServerId = c.decodeFlexibleString(forKey: .downloadServerId)
        downloadServerName = c.decodeFlexibleString(forKey: .downloadServerName)
        connectionType = c.decodeFlexibleString(forKey: .connectionType)
        networkType = c.decodeFlexibleString(forKey: .networkType)
        mobileOperator = c.decodeFlexibleString(forKey: .mobileOperator)
        mcc = try? c.decodeIfPresent(Int.self, forKey: .mcc)
        mnc = try? c.decodeIfPresent(Int.self, forKey: .mnc)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        address = c.decodeFlexibleString(forKey: .address)
        locationBlurred = try? c.decodeIfPresent(Bool.self, forKey: .locationBlurred)
        deviceType = c.decodeFlexibleString(forKey: .deviceType)
        deviceModel = c.decodeFlexibleString(forKey: .deviceModel)
        isPublic = try? c.decodeIfPresent(Bool.self, forKey: .isPublic)
        isVisibleOnMap = try? c.decodeIfPresent(Bool.self, forKey: .isVisibleOnMap)
        shareExactLocation = try? c.decodeIfPresent(Bool.self, forKey: .shareExactLocation)
        isOwner = try? c.decodeIfPresent(Bool.self, forKey: .isOwner)
        rsrp = try? c.decodeIfPresent(Double.self, forKey: .rsrp)
        rsrq = try? c.decodeIfPresent(Double.self, forKey: .rsrq)
        snr = try? c.decodeIfPresent(Double.self, forKey: .snr)
        timingAdvance = try? c.decodeIfPresent(Double.self, forKey: .timingAdvance)
    }
}

enum SpeedtestPhase: Equatable {
    case idle
    case ping
    case download
    case upload
    case saving
    case finished
    case failed(String)
}

struct SpeedMetricCalculator {
    static func mbps(bytes: Int, seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        return (Double(bytes) * 8.0 / 1_000_000.0) / seconds
    }

    static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Gigue = ÉCART-TYPE des RTT, méthodologie Ookla — identique à Android
    /// (`SpeedtestMetricsCalculator.kt`). Les deux implémentations doivent rester
    /// alignées, sinon les gigues des deux plateformes cessent d'être comparables
    /// et aucun agrégat ne veut plus rien dire.
    ///
    /// Cette fonction calculait auparavant la moyenne des écarts consécutifs
    /// (IPDV, famille RFC 3550). Deux raisons de l'abandonner :
    ///
    /// 1. L'IPDV suppose une série RÉGULIÈRE : il mesure |RTT(i) − RTT(i−1)|. Dès
    ///    qu'un échantillon expire, il faut soit sauter — et comparer alors deux
    ///    mesures espacées de deux intervalles, ce qui gonfle la gigue — soit
    ///    interpoler, ce qui la sous-estime. En 4G/5G, 10 à 30 % des échantillons
    ///    expirent : ce n'est pas un cas limite, c'est le régime normal.
    ///    L'écart-type, lui, ne dépend ni de l'ordre ni de la cadence.
    /// 2. L'utilisateur qui compare SignalQuest à Speedtest.net compare à un
    ///    écart-type. Une gigue systématiquement différente de la référence du
    ///    marché passe pour un bug, pas pour une méthodologie.
    ///
    /// ⚠️ Effet attendu : pour un bruit gaussien, E[|Xᵢ − Xᵢ₋₁|] ≈ 1,13 σ. La gigue
    /// iOS baisse donc d'environ 13 % en régime calme, davantage en présence de
    /// pics isolés (un pic compte deux fois dans l'IPDV, une seule dans l'écart-type).
    /// C'est le correctif, pas une régression.
    ///
    /// Écart-type de POPULATION (division par n), comme Android : on décrit la
    /// série mesurée, on n'estime pas une population plus large.
    static func jitter(_ pings: [Double]) -> Double? {
        guard pings.count > 1 else { return nil }
        let mean = pings.reduce(0, +) / Double(pings.count)
        let variance = pings.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(pings.count)
        return variance.squareRoot()
    }

    static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }
}
