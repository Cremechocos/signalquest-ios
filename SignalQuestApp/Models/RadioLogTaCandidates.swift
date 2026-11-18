import Foundation

// MARK: - TA-VISION (GET /api/radio-logs/sites/{key}/candidates)

/// Clé d'un nœud du journal pour les routes `/api/radio-logs/sites/{key}/…`.
///
/// `base64url(utf8("<enb>|<gnb>|<mccMnc>"))`, sans remplissage : la même clé que
/// `/points`, rejouée par les vecteurs de `contracts/radio-logs/ta-candidates-v1.json`.
/// Trois segments en chiffres seulement ; eNB et gNB ne sont jamais vides tous les deux.
enum RadioLogTaSiteKey {
    static func make(enb: String, gnb: String, mccMnc: String) -> String? {
        let digits = CharacterSet(charactersIn: "0123456789")
        func isDigits(_ value: String) -> Bool {
            value.unicodeScalars.allSatisfy { digits.contains($0) }
        }
        guard isDigits(enb), isDigits(gnb), isDigits(mccMnc),
              !(enb.isEmpty && gnb.isEmpty), !mccMnc.isEmpty else { return nil }
        return Data("\(enb)|\(gnb)|\(mccMnc)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Clé d'un site du journal. Sans PLMN servant, pas de clé : le serveur ne saurait pas
    /// de quel réseau il s'agit, et un PLMN de SIM n'est pas celui de la cellule.
    static func make(for site: RadioLogSite) -> String? {
        guard let mcc = site.mcc, let mnc = site.mnc else { return nil }
        return make(
            enb: site.kind == .enb ? site.node : "",
            gnb: site.kind == .gnb ? site.node : "",
            mccMnc: mcc + mnc
        )
    }
}

/// Réponse de la route des candidats : les relevés du membre étiquetés par le serveur et les
/// antennes classées par les anneaux TA (contrat TA-VISION r1.2).
///
/// Décodage tolérant : les codes sont additifs (§5). Une valeur inconnue est ignorée, et un
/// `ranking` inconnu vaut « abstention ».
struct RadioLogTaCandidates: Decodable, Equatable, Sendable {
    enum Assessment: String, Sendable {
        case unusable, divergent, convergent
        case noPosition = "no_position"
    }

    enum ReadingStatus: String, Sendable {
        case kept, discarded, near
    }

    struct Reading: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let latitude: Double
        let longitude: Double
        let timingAdvance: Int?
        let radiusMeters: Double
        let toleranceMeters: Double
        let accuracyMeters: Double?
        /// `nil` pour un statut inconnu : le relevé n'est alors pas tracé.
        let status: ReadingStatus?
        /// Code de l'écart (`ta_frozen`, `gps_imprecise`…) ou `ta_zero` pour un TA = 0.
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case id, latitude, longitude, timingAdvance, radiusMeters, toleranceMeters, accuracyMeters, status, reason
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
            latitude = try c.decode(Double.self, forKey: .latitude)
            longitude = try c.decode(Double.self, forKey: .longitude)
            timingAdvance = (try? c.decodeIfPresent(Int.self, forKey: .timingAdvance)) ?? nil
            radiusMeters = (try? c.decodeIfPresent(Double.self, forKey: .radiusMeters)) ?? 0
            toleranceMeters = (try? c.decodeIfPresent(Double.self, forKey: .toleranceMeters)) ?? 0
            accuracyMeters = (try? c.decodeIfPresent(Double.self, forKey: .accuracyMeters)) ?? nil
            status = c.decodeFlexibleString(forKey: .status).flatMap(ReadingStatus.init(rawValue:))
            reason = c.decodeFlexibleString(forKey: .reason)
        }
    }

    struct Counts: Decodable, Equatable, Sendable {
        var kept = 0
        var discarded = 0
        var near = 0
        var total = 0
    }

    struct Zone: Decodable, Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
    }

    enum CandidateKind: String, Sendable {
        case validated, official, community, estimated
    }

    struct Candidate: Decodable, Equatable, Sendable {
        /// Identifiant confirmable tel quel par `identify/direct` ; `nil` pour un site estimé
        /// sans clé candidat (r1.2) : rien à confirmer.
        let siteId: String?
        let candidateKey: String?
        let confirmable: Bool
        /// `nil` pour un genre que cette version ne connaît pas.
        let kind: CandidateKind?
        let operatorKey: String?
        let label: String?
        let generations: [String]
        let bands: [String]
        /// `nil` pour un site communautaire masqué (zone privée de son créateur).
        let latitude: Double?
        let longitude: Double?
        let rank: Int
        let plausible: Bool
        /// `nil` pour un site masqué : jamais comparé aux anneaux.
        let matchedRings: Int?
        let totalRings: Int
        let distanceToZoneCenterMeters: Double?
        let nearestReadingMeters: Double?
        let azimuth: String?
        let frequency: String?
        let reasons: [String]

        enum CodingKeys: String, CodingKey {
            case siteId, candidateKey, confirmable, kind, operatorKey, label, generations, bands
            case latitude, longitude, rank, plausible, matchedRings, totalRings
            case distanceToZoneCenterMeters, nearestReadingMeters, azimuth, frequency, reasons
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            siteId = c.decodeFlexibleString(forKey: .siteId).flatMap { $0.isEmpty ? nil : $0 }
            candidateKey = c.decodeFlexibleString(forKey: .candidateKey)
            kind = c.decodeFlexibleString(forKey: .kind).flatMap(CandidateKind.init(rawValue:))
            // Confirmable seulement avec un identifiant : le serveur le garantit (r1.2), l'app
            // ne l'envoie pas à `identify/direct` s'il manque.
            confirmable = ((try? c.decodeIfPresent(Bool.self, forKey: .confirmable)) ?? nil) == true && siteId != nil
            operatorKey = c.decodeFlexibleString(forKey: .operatorKey)
            label = c.decodeFlexibleString(forKey: .label).flatMap { $0.isEmpty ? nil : $0 }
            generations = c.decodeLossyArray([String].self, forKey: .generations)
            bands = c.decodeLossyArray([String].self, forKey: .bands)
            latitude = (try? c.decodeIfPresent(Double.self, forKey: .latitude)) ?? nil
            longitude = (try? c.decodeIfPresent(Double.self, forKey: .longitude)) ?? nil
            rank = (try? c.decodeIfPresent(Int.self, forKey: .rank)) ?? 0
            plausible = ((try? c.decodeIfPresent(Bool.self, forKey: .plausible)) ?? nil) == true
            matchedRings = (try? c.decodeIfPresent(Int.self, forKey: .matchedRings)) ?? nil
            totalRings = (try? c.decodeIfPresent(Int.self, forKey: .totalRings)) ?? 0
            distanceToZoneCenterMeters = (try? c.decodeIfPresent(Double.self, forKey: .distanceToZoneCenterMeters)) ?? nil
            nearestReadingMeters = (try? c.decodeIfPresent(Double.self, forKey: .nearestReadingMeters)) ?? nil
            azimuth = c.decodeFlexibleString(forKey: .azimuth)
            frequency = c.decodeFlexibleString(forKey: .frequency)
            reasons = c.decodeLossyArray([String].self, forKey: .reasons)
        }

        /// Placé sur la carte : un site masqué n'a pas de marqueur.
        var hasPosition: Bool { latitude != nil && longitude != nil }
    }

    let market: String?
    let readings: [Reading]
    let readingCounts: Counts
    let readingsTruncated: Bool
    let assessment: Assessment?
    let zone: Zone?
    let isRanked: Bool
    let rankingReason: String?
    let validatedSiteId: String?
    let candidates: [Candidate]

    enum CodingKeys: String, CodingKey {
        case market, readings, readingCounts, readingsTruncated, assessment, zone, ranking, rankingReason
        case validatedSite, candidates
    }

    private struct ValidatedSite: Decodable { let siteId: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        market = c.decodeFlexibleString(forKey: .market)
        readings = c.decodeLossyArray([Reading].self, forKey: .readings)
        readingCounts = ((try? c.decodeIfPresent(Counts.self, forKey: .readingCounts)) ?? nil) ?? Counts()
        readingsTruncated = ((try? c.decodeIfPresent(Bool.self, forKey: .readingsTruncated)) ?? nil) == true
        assessment = c.decodeFlexibleString(forKey: .assessment).flatMap(Assessment.init(rawValue:))
        zone = (try? c.decodeIfPresent(Zone.self, forKey: .zone)) ?? nil
        // Toute valeur autre que « ranked » vaut abstention (§5).
        isRanked = c.decodeFlexibleString(forKey: .ranking) == "ranked"
        rankingReason = c.decodeFlexibleString(forKey: .rankingReason)
        validatedSiteId = ((try? c.decodeIfPresent(ValidatedSite.self, forKey: .validatedSite)) ?? nil)?.siteId
        candidates = c.decodeLossyArray([Candidate].self, forKey: .candidates)
            .sorted { $0.rank < $1.rank }
    }

    /// Le site validé est en tête et les anneaux le désignent.
    var confirmsValidatedSite: Bool {
        guard isRanked, let validatedSiteId, let first = candidates.first else { return false }
        return first.kind == .validated && first.siteId == validatedSiteId && first.plausible
    }
}

// MARK: - Ce que l'écran dit

/// Textes tirés d'une réponse TA-VISION, purs et testables. Le `score` brut n'est jamais montré.
enum RadioLogTaVisionText {
    enum Tone: Equatable { case good, warning, neutral }

    struct Summary: Equatable {
        let headline: String
        let detail: String?
        let tone: Tone
        let lines: [String]
    }

    /// Ce que dit le bloc au-dessus des antennes.
    static func summary(_ response: RadioLogTaCandidates) -> Summary {
        let counts = response.readingCounts
        var lines: [String] = []
        if counts.total > 0 {
            lines.append(String(localized: "\(counts.kept) anneaux retenus sur \(counts.total) relevés"))
        }
        if counts.discarded > 0 {
            let breakdown = discardedBreakdown(response.readings, total: counts.discarded)
            lines.append(breakdown.map { String(localized: "\(counts.discarded) écartés : \($0)") }
                ?? String(localized: "\(counts.discarded) écartés"))
        }
        if counts.near > 0 {
            lines.append(String(localized: "\(counts.near) TA 0 : antenne à moins de 400 m, affichés sans compter"))
        }
        if response.readingsTruncated {
            lines.append(String(localized: "Lecture limitée aux 5 000 relevés les plus récents."))
        }

        if response.assessment == .noPosition || response.rankingReason == "no_position" {
            return Summary(
                headline: String(localized: "Aucun relevé n’a de position : antennes proposées par identifiant et fréquence seulement."),
                detail: nil, tone: .neutral, lines: lines
            )
        }
        if response.isRanked {
            if response.confirmsValidatedSite {
                return Summary(headline: String(localized: "Les anneaux confirment le site validé"), detail: nil, tone: .good, lines: lines)
            }
            let headline = response.zone.map {
                String(localized: "Les anneaux se croisent · zone de ≈ \(SQUnits.distance(meters: $0.radiusMeters))")
            } ?? String(localized: "Les anneaux se croisent")
            return Summary(headline: headline, detail: nil, tone: .good, lines: lines)
        }
        if response.assessment == .divergent || response.rankingReason == "rings_divergent" {
            return Summary(
                headline: String(localized: "Les anneaux ne se croisent pas : pas de classement"),
                detail: String(localized: "Aucun point ne tient toutes ces distances. Souvent un changement de cellule ou deux sites sous le même identifiant. Les antennes restent toutes affichées, sans ordre."),
                tone: .warning, lines: lines
            )
        }
        return Summary(
            headline: String(localized: "Trop peu d’anneaux pour classer : repasse près du site pour en ajouter."),
            detail: nil, tone: .neutral, lines: lines
        )
    }

    /// « TA figé (12), au même endroit (9) » — seulement quand les relevés servis couvrent
    /// tous les écartés : sinon le détail mentirait par omission.
    static func discardedBreakdown(_ readings: [RadioLogTaCandidates.Reading], total: Int) -> String? {
        let discarded = readings.filter { $0.status == .discarded }
        guard discarded.count == total, total > 0 else { return nil }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for reading in discarded {
            let label = readingReasonLabel(reading.reason)
            if counts[label] == nil { order.append(label) }
            counts[label, default: 0] += 1
        }
        return order
            .sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
            .map { "\($0) (\(counts[$0] ?? 0))" }
            .joined(separator: ", ")
    }

    static func readingReasonLabel(_ reason: String?) -> String {
        switch reason {
        case "ta_unreliable": return String(localized: "TA non fiable")
        case "ta_frozen": return String(localized: "TA figé")
        case "position_stale": return String(localized: "position trop ancienne")
        case "gps_imprecise": return String(localized: "GPS imprécis")
        case "duplicate_spot": return String(localized: "au même endroit")
        case "over_cap": return String(localized: "au-delà de 24 anneaux")
        case "outlier": return String(localized: "contredit les autres")
        default: return String(localized: "autre raison")
        }
    }

    /// Origine du candidat. Le registre officiel dépend du marché (ANFR, ISED…).
    static func kindLabel(_ kind: RadioLogTaCandidates.CandidateKind?, market: String?) -> String? {
        switch kind {
        case .validated: return String(localized: "Site validé")
        case .official:
            switch market?.uppercased() {
            case "CA": return "ISED"
            case "BE": return "BIPT"
            case "CH": return "OFCOM"
            case "FR", "GP", "MQ", "GF", "RE", "YT", "PM", "BL", "MF": return "ANFR"
            default: return String(localized: "Registre officiel")
            }
        case .community: return String(localized: "Communauté")
        case .estimated: return String(localized: "Estimé")
        case nil: return nil
        }
    }

    /// « Compatible avec 8 de tes 11 passages » — jamais pour un site masqué, ni sans classement,
    /// ni pour zéro passage : « compatible avec 0 » ne dit rien d'utile.
    static func matchLine(_ candidate: RadioLogTaCandidates.Candidate, ranked: Bool) -> String? {
        guard ranked, let matched = candidate.matchedRings, matched > 0, candidate.totalRings > 0 else { return nil }
        return String(localized: "Compatible avec \(matched) de tes \(candidate.totalRings) passages")
    }

    /// Les raisons qui aident à trancher, traduites ; les codes inconnus sont ignorés.
    static func reasonsLine(_ candidate: RadioLogTaCandidates.Candidate) -> String? {
        let labels: [String] = candidate.reasons.compactMap { code in
            switch code {
            case "azimuth_consistent": return String(localized: "Secteur tourné vers tes relevés")
            case "azimuth_back_lobe": return String(localized: "Relevés derrière le secteur")
            case "frequency_match": return String(localized: "Bande relevée présente sur le site")
            case "frequency_mismatch": return String(localized: "Bande relevée absente de la fiche")
            case "ta_ring_impossible": return String(localized: "Trop loin pour un de tes TA")
            case "validated_other_plmn_ignored": return String(localized: "Validé pour un autre réseau")
            default: return nil
            }
        }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
}
