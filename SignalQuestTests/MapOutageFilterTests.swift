import XCTest
import SwiftUI
import CoreLocation
@testable import SignalQuest

/// Verrouille la règle produit du chantier « pannes » : **un seul filtre**.
///
/// Une passe précédente avait ajouté une puce « Pannes signalées » à côté de « Pannes » — deux
/// entrées homonymes que l'utilisateur a refusées : « il faut pas plusieurs filtres, le filtre
/// Panne affiche les incidents déclarés par les opérateurs et les communautaires ». Le risque est
/// qu'elle revienne à la faveur d'une refonte du panneau, d'où ce test.
@MainActor
final class MapOutageFilterTests: XCTestCase {

    func testLocaleWithoutRegionDoesNotInventFrance() {
        XCTAssertEqual(MapMarketStore.resolvedLocaleMarketCode(nil), "UNKNOWN")
        XCTAssertEqual(MapMarketStore.resolvedLocaleMarketCode("   "), "UNKNOWN")
        XCTAssertEqual(MapMarketStore.resolvedLocaleMarketCode("ca"), "CA")
    }

    /// Registre minimal : la France (données ANFR) et un marché communautaire, où aucun open data
    /// ne publie d'incident opérateur.
    private func registry() throws -> [MarketRegistryEntry] {
        let json = """
        {
          "markets": [
            {
              "code": "FR", "marketCode": "FR", "label": "France", "sourceMode": "official",
              "capabilities": { "incidents": true, "previsionnel": true },
              "operators": [
                { "key": "ORANGE", "label": "Orange", "shortLabel": "Orange", "color": "#FF6B35" }
              ]
            },
            {
              "code": "BA", "marketCode": "BA", "label": "Bosnie", "sourceMode": "community",
              "capabilities": { "communityLayers": true },
              "operators": [
                { "key": "BHTELECOM", "label": "BH Telecom", "shortLabel": "BH", "color": "#0057B8" }
              ]
            },
            {
              "code": "CA", "marketCode": "CA", "label": "Canada", "sourceMode": "official",
              "capabilities": {},
              "operators": [
                { "key": "TELUS", "label": "Telus", "shortLabel": "Telus", "color": "#00A67E" }
              ]
            }
          ]
        }
        """
        let payload = try JSONDecoder.signalQuest.decode(
            MarketRegistryPayload.self,
            from: Data(json.utf8)
        )
        return payload.markets
    }

    private func sheet(market: String, markets: [MarketRegistryEntry]) -> MapAdvancedFilterSheet {
        MapAdvancedFilterSheet(
            market: .constant(market),
            operatorName: .constant("ALL"),
            technologies: .constant([]),
            bands: .constant([]),
            bandMatch: .constant(.any),
            azimuthStyle: .constant(.lobes),
            sharing: .constant([]),
            speedtestDays: .constant(30),
            coverageDays: .constant(30),
            layers: .constant(MapFilterStore.defaultFilters),
            includeObserved: .constant(false),
            plannedStatuses: .constant([]),
            allMarkets: markets
        )
    }

    /// Aucune puce ne doit porter `.communityOutage` : ce genre est un MARQUEUR, pas une case.
    func testNoSeparateCommunityOutageChip() throws {
        let markets = try registry()
        for market in ["FR", "BA", "CA"] {
            let kinds = sheet(market: market, markets: markets).layerOptions.map(\.0)
            XCTAssertFalse(
                kinds.contains(.communityOutage),
                "Le filtre « Pannes signalées » est revenu sur le marché \(market)"
            )
            XCTAssertEqual(
                kinds.filter { $0 == .outage }.count, 1,
                "Il faut exactement une puce « Pannes » sur le marché \(market)"
            )
        }
    }

    /// « Pannes » est proposée PARTOUT — contrairement aux prévisionnels, qui n'existent qu'en
    /// FR/DROM. Sans cela, un pays sans référentiel public n'aurait aucun moyen d'afficher les
    /// signalements de ses membres, qui y sont la seule panne connaissable.
    func testOutageChipExistsOnEveryMarketButPlannedDoesNot() throws {
        let markets = try registry()
        let france = sheet(market: "FR", markets: markets).layerOptions.map(\.0)
        XCTAssertTrue(france.contains(.outage))
        XCTAssertTrue(france.contains(.planned))

        for market in ["BA", "CA"] {
            let kinds = sheet(market: market, markets: markets).layerOptions.map(\.0)
            XCTAssertTrue(kinds.contains(.outage), "Marché \(market) sans puce « Pannes »")
            XCTAssertFalse(kinds.contains(.planned), "Prévisionnels proposés hors FR/DROM (\(market))")
        }
    }

    /// Toutes les puces de couche ont une traduction ANGLAISE.
    ///
    /// `filterChip` affiche pourtant un `Text(LocalizedStringKey(title))`, donc la recherche a
    /// bien lieu à l'exécution — mais elle ne trouve que ce que le catalogue contient, et un
    /// littéral nu n'y est jamais versé : seul `String(localized:)` déclenche l'extraction par le
    /// compilateur. « Prévisionnels » était resté nu à côté de sa jumelle corrigée.
    ///
    /// La vérification porte sur le bundle `en.lproj` compilé, et pas sur `String(localized:)` :
    /// en français, langue source, une clé absente rend la clé elle-même et l'assertion passerait
    /// quoi qu'il arrive.
    func testEveryLayerChipHasAnEnglishTranslation() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        let absent = "@@absent@@"
        for market in ["FR", "BA", "CA"] {
            for option in sheet(market: market, markets: try registry()).layerOptions {
                XCTAssertFalse(option.1.isEmpty, "Puce sans libellé sur \(market)")
                XCTAssertNotEqual(
                    english.localizedString(forKey: option.1, value: absent, table: nil),
                    absent,
                    "Puce sans traduction anglaise : \(option.1)"
                )
            }
        }
    }

    /// Le vocabulaire de la fonctionnalité, lui aussi, doit exister en anglais : ces phrases sont
    /// composées en Swift puis rendues par `Text(String)`, qui ne traduit rien tout seul.
    func testOutageVocabularyIsTranslated() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        let absent = "@@absent@@"
        let keys = [
            "Panne signalée", "Panne confirmée", "Confirmée par l'opérateur", "Rétablie",
            "Plus aucun service", "Service dégradé", "Oui, c'est HS", "Non, ça marche",
            "Chronologie", "Voir tout", "Signalée par", "Démentis", "La panne est terminée",
            "Internet", "Voix", "SMS", "Touché", "%lld pannes signalées",
            "Panne signalée : service dégradé", "Panne confirmée : plus aucun service",
            // Formulaire v2 et étiquette de gravité de la carte de fil.
            "Technologies touchées", "Technologies", "Si vous le savez. Sinon, laissez vide.",
            "Rien ne passe : ni Internet, ni appels", "Panne", "Dégradé", "Rétabli",
            "Services touchés", "Que constatez-vous ?", "Plus rien", "Touché : %@",
        ]
        for key in keys {
            XCTAssertNotEqual(
                english.localizedString(forKey: key, value: absent, table: nil),
                absent,
                "Sans traduction anglaise : \(key)"
            )
        }
    }

    // MARK: - Formulaire v2

    /// ⚠️ AUCUNE gravité cochée à l'ouverture, et l'envoi reste fermé tant qu'on n'a pas répondu.
    ///
    /// C'est le grief exact de l'utilisateur (« quand j'ouvre la sheet panne ça me sélectionne
    /// directement panne ») : la feuille partait sur `.down`, donc un signalement pouvait s'envoyer
    /// sans que personne n'ait jamais choisi. Le test porte sur `OutageReportDraft` parce que c'est
    /// LUI que la feuille consulte — `canSubmit` du bouton et le corps de la requête en dérivent
    /// tous les deux.
    func testSeverityStartsUnchosenAndBlocksSubmission() {
        let draft = OutageReportDraft()
        XCTAssertNil(draft.severity, "La gravité est de nouveau pré-sélectionnée à l'ouverture")
        XCTAssertFalse(draft.canSubmit, "On peut envoyer sans avoir choisi la gravité")
        XCTAssertNil(
            draft.request(
                targetKind: "anfr", targetId: "1", marketCode: "FR", operatorKey: "ORANGE",
                latitude: nil, longitude: nil, accuracyMeters: nil
            ),
            "Un corps de requête part alors qu'aucune gravité n'est choisie"
        )
    }

    /// La CASCADE, elle, est conservée : « Plus rien » coche les services. Seule la pré-sélection
    /// à l'ouverture disparaît — l'utilisateur avait demandé la cascade explicitement.
    func testDownCascadesOntoServices() {
        var draft = OutageReportDraft()
        draft.affectsData = false
        draft.select(.down)
        XCTAssertTrue(draft.affectsData)
        XCTAssertTrue(draft.affectsVoice)
        XCTAssertTrue(draft.canSubmit)

        // « Dégradé » ne cascade pas : ça passe moins bien, pas « rien ne passe ».
        var degraded = OutageReportDraft()
        degraded.affectsData = false
        degraded.affectsVoice = false
        degraded.select(.degraded)
        XCTAssertFalse(degraded.affectsVoice)
        XCTAssertFalse(degraded.canSubmit, "Une gravité sans aucun service touché n'est pas exploitable")
    }

    /// ⚠️ Le SMS a quitté le FORMULAIRE : il n'est plus jamais affirmé par un envoi, y compris sous
    /// « Plus rien ». La donnée existante, elle, n'est pas touchée — cf. le test suivant.
    func testSmsIsNeverClaimedByTheForm() throws {
        var draft = OutageReportDraft()
        draft.select(.down)
        let body = try XCTUnwrap(draft.request(
            targetKind: "anfr", targetId: "1", marketCode: "FR", operatorKey: "ORANGE",
            latitude: nil, longitude: nil, accuracyMeters: nil
        ))
        XCTAssertFalse(body.affectsSms, "Le formulaire coche le SMS à la place de la personne")
        // Le champ reste au CONTRAT : le serveur l'attend, et une panne ancienne le porte.
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(body)
        ) as? [String: Any]
        XCTAssertNotNil(json?["affectsSms"], "Le champ a disparu du contrat au lieu du formulaire")
    }

    /// Une panne qui PORTE déjà le SMS continue de l'afficher : on cesse de le demander, on ne
    /// détruit aucune donnée.
    func testExistingSmsOutagesStillDisplaySms() {
        XCTAssertEqual(OutageServices.label(data: false, voice: false, sms: true), "SMS")
        XCTAssertEqual(OutageServices.label(codes: ["sms", "data"]), "Internet, SMS")
    }

    /// Les technologies sont FACULTATIVES — ne pas savoir n'empêche pas de constater.
    func testTechnologiesAreOptionalAndSortedByGeneration() throws {
        var draft = OutageReportDraft()
        draft.select(.degraded)
        let bare = try XCTUnwrap(draft.request(
            targetKind: "anfr", targetId: "1", marketCode: "FR", operatorKey: "ORANGE",
            latitude: nil, longitude: nil, accuracyMeters: nil
        ))
        XCTAssertEqual(bare.affectedTechnologies, [], "Une panne sans technologie doit rester envoyable")

        // Cochées dans le désordre, envoyées triées : le serveur stocke une valeur déterministe,
        // le client ne doit pas lui en fournir deux formes pour les mêmes cases.
        draft.toggle(technology: "5g")
        draft.toggle(technology: "3g")
        draft.toggle(technology: "4g")
        draft.toggle(technology: "3g") // décoché
        let body = try XCTUnwrap(draft.request(
            targetKind: "anfr", targetId: "1", marketCode: "FR", operatorKey: "ORANGE",
            latitude: nil, longitude: nil, accuracyMeters: nil
        ))
        XCTAssertEqual(body.affectedTechnologies, ["4g", "5g"])
    }

    /// Ce que le formulaire propose est exactement ce que le serveur documente comme choix
    /// (`OUTAGE_TECHNOLOGY_CHOICES`) : ni la 2G, qui existe chez les opérateurs mais n'est pas
    /// demandée, ni une génération que le serveur refuserait.
    func testFormOffersTheThreeDocumentedGenerations() {
        XCTAssertEqual(OutageTechnologies.choices, ["3g", "4g", "5g"])
    }

    /// La lecture : jetons bruts → « 4G, 5G », sans traduction (c'est un sigle), et un jeton hors
    /// forme est écarté plutôt que rendu tel quel.
    func testTechnologyLabels() {
        XCTAssertEqual(OutageTechnologies.label(["5g", "4g"]), "4G, 5G")
        XCTAssertEqual(OutageTechnologies.label([]), "")
        XCTAssertEqual(OutageTechnologies.label(["4g", "4G", " 5g "]), "4G, 5G")
        XCTAssertEqual(OutageTechnologies.label(["wifi", "g", "1g", "0g"]), "")
        // Une génération que ce client ne connaît pas encore est quand même LUE : le serveur
        // valide la forme et non une liste fermée, c'est tout l'objet du choix de contrat.
        XCTAssertEqual(OutageTechnologies.label(["6g", "4g"]), "4G, 6G")
        // La metadata d'un post joint les jetons par une virgule — un tableau y disparaîtrait.
        XCTAssertEqual(OutageTechnologies.label(csv: "4g,5g"), "4G, 5G")
        XCTAssertEqual(OutageTechnologies.label(csv: nil), "")
        XCTAssertEqual(OutageTechnologies.label(csv: ""), "")
        // Services et générations sur une ligne, point médian comme dans le texte du post.
        XCTAssertEqual(
            OutageTechnologies.detail(services: "Internet, Voix", technologies: ["5g", "4g"]),
            "Internet, Voix · 4G, 5G"
        )
        XCTAssertEqual(OutageTechnologies.detail(services: "Internet", technologies: []), "Internet")
        XCTAssertEqual(OutageTechnologies.detail(services: "", technologies: ["4g"]), "4G")
    }

    /// Une panne de test, avec ou sans technologies déclarées.
    private func outage(_ extra: String = "") throws -> CommunityOutage {
        let json = """
        { "id": "o1", "targetKind": "anfr", "targetId": "1", "marketCode": "FR",
          "operatorKey": "ORANGE", "latitude": 45.1, "longitude": 5.7,
          "state": "reported", "severity": "degraded",
          "affectsData": true, "affectsVoice": true, "affectsSms": false\(extra) }
        """
        return try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: Data(json.utf8))
    }

    /// Le champ traverse le DÉCODAGE, et son absence n'est pas une erreur : le serveur de
    /// production ne le rendait pas avant cette vague, et les pannes d'alors n'en portent pas.
    func testOutageDecodesAffectedTechnologies() throws {
        let withTech = try outage(#", "affectedTechnologies": ["5g", "4g"]"#)
        XCTAssertEqual(withTech.affectedTechnologies, ["4g", "5g"])
        XCTAssertEqual(withTech.affectedLabel, "Internet, Voix · 4G, 5G")

        let without = try outage("")
        XCTAssertEqual(without.affectedTechnologies, [])
        XCTAssertEqual(without.affectedLabel, "Internet, Voix")
    }

    /// Le MARQUEUR de carte énonce lui aussi les générations.
    ///
    /// C'était le dernier endroit à ne dire que les services, alors que le formulaire demande les
    /// technologies et que la fiche antenne, la feuille et la carte de fil les écrivent. Ce même
    /// `subtitle` est lu par VoiceOver (`SQAnnotationDescription`) : la lacune était visuelle ET
    /// sonore, sur le premier écran où l'on croise une panne.
    func testMapMarkerSubtitleCarriesTechnologies() throws {
        XCTAssertEqual(
            MapExplorerView.communityOutageSubtitle(
                operatorLabel: "Orange",
                outage: try outage(#", "affectedTechnologies": ["5g", "4g"]"#)
            ),
            "Orange · Internet, Voix · 4G, 5G"
        )
        // Aucune technologie déclarée : rien de plus, surtout pas « inconnu » ni un séparateur
        // orphelin. C'est le cas de TOUTES les pannes ouvertes avant ce champ.
        XCTAssertEqual(
            MapExplorerView.communityOutageSubtitle(operatorLabel: "Orange", outage: try outage()),
            "Orange · Internet, Voix"
        )
        // Registre pas encore chargé : pas de point médian en tête de ligne.
        XCTAssertEqual(
            MapExplorerView.communityOutageSubtitle(operatorLabel: "", outage: try outage()),
            "Internet, Voix"
        )
    }

    /// La carte de fil compose la MÊME ligne depuis la metadata du post, où les jetons arrivent
    /// joints par une virgule. Une seule tuile « Touché », jamais deux blocs.
    func testFeedCardComposesTheSameAffectedLine() {
        XCTAssertEqual(
            OutageTechnologies.detail(services: "Internet, Voix", csv: "4g,5g"),
            "Internet, Voix · 4G, 5G"
        )
        XCTAssertEqual(OutageTechnologies.detail(services: "Internet", csv: nil), "Internet")
        // Services inconnus mais génération connue : pas de tiret orphelin devant le point médian.
        XCTAssertEqual(OutageTechnologies.detail(services: "", csv: "5g"), "5G")
        XCTAssertEqual(OutageTechnologies.detail(services: "", csv: nil), "")
    }

    // MARK: - Puces du formulaire

    /// ⚠️ Une case COCHÉE doit se voir cochée SANS le secours de la couleur.
    ///
    /// Régression réelle : depuis que la feuille reste neutre tant que la gravité n'est pas
    /// choisie, la teinte de la puce cochée valait exactement celle de la puce vide. Or « Internet »
    /// part coché à l'ouverture — on déclarait donc un service sans le voir. Le test porte sur les
    /// trois marques non colorées, et chacune séparément : il suffirait qu'une seule survive pour
    /// que l'assertion globale passe en laissant le défaut revenir aux deux tiers.
    func testCheckedChipIsVisibleWithoutColour() {
        let checked = OutageChipStyle.of(selected: true)
        let unchecked = OutageChipStyle.of(selected: false)
        XCTAssertNotEqual(checked, unchecked)
        XCTAssertNotEqual(checked.symbol, unchecked.symbol, "La coche ne change plus de forme")
        XCTAssertNotEqual(checked.borderWidth, unchecked.borderWidth, "Le contour a disparu")
        XCTAssertNotEqual(checked.labelIsPrimary, unchecked.labelIsPrimary, "Le libellé garde la même encre")
        XCTAssertTrue(checked.borderWidth > 0)
        // La puce VIDE, elle, n'a pas de contour : un cadre permanent la ferait passer pour un
        // champ de saisie.
        XCTAssertEqual(unchecked.borderWidth, 0)
    }

    /// L'état d'ouverture du formulaire, tel qu'il s'affiche : « Internet » est coché, et se voit
    /// coché. C'est le lien entre la règle de `OutageReportDraft` et celle de `OutageChipStyle` —
    /// séparément vraies, c'est leur rencontre qui avait produit le défaut.
    func testInternetStartsCheckedAndLooksChecked() {
        let draft = OutageReportDraft()
        XCTAssertTrue(draft.affectsData, "Internet ne part plus coché")
        XCTAssertEqual(OutageChipStyle.of(selected: draft.affectsData).symbol, "checkmark.circle.fill")
        XCTAssertNotEqual(
            OutageChipStyle.of(selected: draft.affectsData),
            OutageChipStyle.of(selected: draft.affectsVoice),
            "À l'ouverture, la puce cochée et la puce vide s'affichent pareil"
        )
    }

    /// La même règle, mais vérifiée SUR LES PIXELS de la vraie puce.
    ///
    /// Le test précédent porte sur les valeurs : il empêche `OutageChipStyle` de redevenir
    /// uniforme, pas la VUE de cesser de le consulter. Or c'est exactement ce qui s'était produit —
    /// la règle « une case cochée se voit cochée » n'était écrite nulle part, et la puce ne
    /// distinguait ses deux états que par une teinte devenue neutre.
    ///
    /// La teinte passée est justement la NEUTRE, celle d'une feuille dont la gravité n'est pas
    /// encore choisie — l'état exact où le défaut se produisait.
    ///
    /// ⚠️ La métrique compte les composantes qui diffèrent DE PLUS DE 40 sur 255, pas celles qui
    /// diffèrent tout court. Un simple « différent » vaut 74 % dans les deux versions : l'ancienne
    /// puce cochée remplaçait la crème du fond par un gris à 13 %, donc chaque pixel du rectangle
    /// changeait — d'un cheveu. Un test bâti là-dessus aurait validé la régression, ce qui est
    /// exactement le piège qu'il doit fermer.
    ///
    /// Écarts mesurés sur ce simulateur : 1,4 % pour l'ancienne puce (teinte seule), 10,9 % pour la
    /// nouvelle (coche pleine, contour, encre primaire). Le seuil est posé entre les deux, avec de
    /// la marge des deux côtés pour les variations de rendu d'une version d'iOS à l'autre.
    func testCheckedChipRendersDifferentlyFromUnchecked() throws {
        let neutral = SQColor.labelSecondary
        let checked = try pixels(OutageChip(label: "Internet", selected: true, tint: neutral, toggle: {}))
        let unchecked = try pixels(OutageChip(label: "Internet", selected: false, tint: neutral, toggle: {}))
        XCTAssertEqual(checked.count, unchecked.count)

        let strongly = zip(checked, unchecked).filter { abs(Int($0) - Int($1)) > 40 }.count
        let ratio = Double(strongly) / Double(checked.count)
        XCTAssertGreaterThan(
            ratio, 0.05,
            "La puce cochée ne se distingue plus de la puce vide (\(Int(ratio * 1000)) ‰ de composantes franchement différentes)"
        )
    }

    /// Rend une vue hors écran et rend ses composantes RVBA brutes.
    private func pixels(_ view: some View, width: Int = 180, height: Int = 44) throws -> [UInt8] {
        let renderer = ImageRenderer(
            content: view
                .frame(width: CGFloat(width), height: CGFloat(height))
                .background(Color.white)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage, "ImageRenderer n'a rien peint")
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    // MARK: - Étiquette de la carte de fil

    /// ⚠️ L'étiquette de genre suit la GRAVITÉ RÉELLE, jamais le seul genre du post.
    ///
    /// Le défaut constaté sur capture : « Panne », en rouge, sur une carte dont le titre disait
    /// « Réseau dégradé ». Elle affichait le mot en dur — la gravité et l'état étaient pourtant
    /// déjà dans la metadata, et déjà lus par la carte.
    func testFeedBadgeFollowsSeverityAndState() {
        XCTAssertEqual(OutageFeedBadge.label(severity: "down", state: "reported"), "Panne")
        XCTAssertEqual(OutageFeedBadge.label(severity: "down", state: "confirmed"), "Panne")
        XCTAssertEqual(OutageFeedBadge.label(severity: "degraded", state: "reported"), "Dégradé")
        XCTAssertEqual(OutageFeedBadge.label(severity: "degraded", state: "confirmed"), "Dégradé")
        // Rétabli l'emporte sur la gravité : la panne est finie, dire « Dégradé » ferait lire une
        // coupure en cours.
        XCTAssertEqual(OutageFeedBadge.label(severity: "degraded", state: "resolved"), "Rétabli")
        XCTAssertEqual(OutageFeedBadge.label(severity: "down", state: "resolved"), "Rétabli")
        // Metadata muette ou inconnue : on retombe sur « Panne », la bonne moitié de l'erreur.
        XCTAssertEqual(OutageFeedBadge.label(severity: nil, state: nil), "Panne")
        XCTAssertEqual(OutageFeedBadge.label(severity: "bizarre", state: "bizarre"), "Panne")
    }

    /// Les trois gravités ont trois couleurs DISTINCTES, sinon l'étiquette ne dit plus rien de
    /// plus que le mot. Et c'est l'ENCRE qui est rendue, pas l'aplat : la pastille porte des mots.
    func testFeedBadgeColoursAreDistinctAndUseInk() {
        let down = OutageFeedBadge.ink(severity: "down", state: "reported")
        let degraded = OutageFeedBadge.ink(severity: "degraded", state: "reported")
        let resolved = OutageFeedBadge.ink(severity: "down", state: "resolved")
        XCTAssertNotEqual(down, degraded)
        XCTAssertNotEqual(down, resolved)
        XCTAssertNotEqual(degraded, resolved)
        XCTAssertEqual(down, OutageTint.downInk)
        XCTAssertEqual(degraded, OutageTint.degradedInk)
        XCTAssertEqual(resolved, OutageTint.resolvedInk)
        // L'aplat reste l'aplat : c'est lui qui teinte la pastille du pictogramme.
        XCTAssertEqual(OutageFeedBadge.tint(severity: "degraded", state: "reported"), OutageTint.degraded)
        XCTAssertEqual(OutageFeedBadge.tint(severity: "down", state: "resolved"), OutageTint.resolved)
    }

    /// Un vote compte dans un quorum : il doit donc porter le même identifiant d'installation que
    /// le signalement, sinon plusieurs comptes du même iPhone pèseraient chacun une voix.
    func testOutageVoteCarriesInstallationDeviceId() throws {
        let request = OutageVoteRequest(
            kind: "confirm",
            deviceId: "ios-installation-123456",
            latitude: 48.0,
            longitude: 2.0,
            accuracyMeters: 12
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["deviceId"] as? String, "ios-installation-123456")
    }

    // MARK: - Refus d'écriture

    /// Les codes que les trois routes d'écriture émettent RÉELLEMENT.
    ///
    /// Relevés dans `apps/api/app/api/community-outages/route.ts`, `[id]/vote/route.ts`,
    /// `[id]/close/route.ts`, plus les valeurs d'`OutageSignalRejection` (`packages/db/outages.ts`)
    /// que les deux dernières remontent en majuscules via `error.reason.toUpperCase()`.
    private static let serverWriteCodes: [(code: String, status: Int, frenchServerMessage: String)] = [
        ("UNAUTHORIZED", 401, "Authentification requise"),
        ("NOT_ELIGIBLE", 403, "Vous n'êtes pas assez proche de ce site pour vous prononcer"),
        ("POSITION_REQUIRED", 400, "Activez la localisation pour signaler ici"),
        ("UNKNOWN_SITE", 404, "Ce site n'a pas été reconnu"),
        ("INVALID_TARGET_KIND", 400, "Type de site non reconnu"),
        ("MISSING_SCOPE", 400, "Indiquez le pays et l'opérateur concernés"),
        ("INVALID_OPERATOR", 400, "Indiquez l'opérateur concerné"),
        ("COMMENT_TOO_LONG", 400, "Le commentaire est trop long"),
        ("PAYLOAD_TOO_LARGE", 400, "Les mesures radio jointes sont trop volumineuses"),
        ("INVALID_DEVICE_ID", 400, "L'identifiant d'installation est invalide"),
        ("ALREADY_REPORTED", 409, "Vous avez déjà signalé cette panne"),
        ("OPERATOR_INCIDENT_ACTIVE", 409, "L'opérateur a déjà déclaré cet incident"),
        ("OUTAGE_CLOSED", 409, "Cette panne est close. Signalez-en une nouvelle."),
        ("SELF_CONFIRMATION", 409, "Vous ne pouvez pas confirmer votre propre signalement"),
        ("NOT_FOUND", 404, "Panne introuvable"),
        ("NOT_AUTHOR", 403, "Seul l'auteur peut refermer cette panne"),
        ("DUPLICATE_REPORT", 400, "Vote impossible"),
        ("OPEN_CONFLICT", 400, "Vote impossible"),
    ]

    /// Chaque code connu a SA phrase, écrite par le client.
    ///
    /// C'est la règle du chantier : le serveur rend un CODE, le client rédige — sinon la phrase
    /// française de l'API (« Vous êtes trop loin de ce site ») atteint un lecteur anglophone.
    /// Les trois chemins d'écriture d'iOS l'affichaient encore telle quelle.
    func testEveryServerWriteCodeHasAClientPhrase() {
        for entry in Self.serverWriteCodes {
            XCTAssertNotNil(
                OutageWriteError.phrase(forCode: entry.code),
                "Code sans phrase cliente : \(entry.code)"
            )
        }
    }

    /// La phrase du serveur n'atteint JAMAIS l'écran, code connu ou non.
    func testServerSentenceIsNeverShown() {
        for entry in Self.serverWriteCodes {
            let error = APIError.http(
                status: entry.status,
                code: entry.code,
                message: entry.frenchServerMessage,
                requestId: "req",
                retryAfter: nil
            )
            XCTAssertEqual(OutageWriteError.message(for: error), OutageWriteError.phrase(forCode: entry.code))
        }
        // Un code que le client ne connaît pas encore — le contrat s'allongera avant les clients :
        // repli par STATUT, jamais la phrase du serveur.
        let unknown = APIError.http(
            status: 409,
            code: "UN_CODE_TOUT_NEUF",
            message: "Une phrase française que personne ne doit lire",
            requestId: "req",
            retryAfter: nil
        )
        XCTAssertEqual(OutageWriteError.message(for: unknown), APIError.statusFallback(409))
    }

    /// Une erreur qui n'est pas un refus HTTP garde son propre libellé, déjà localisé côté client.
    func testNonHTTPErrorsKeepTheirOwnMessage() {
        XCTAssertEqual(
            OutageWriteError.message(for: APIError.transport("offline")),
            APIError.transport("offline").localizedDescription
        )
    }

    /// Ces phrases sont composées en Swift puis rendues par `Text(String)`, qui ne traduit rien
    /// tout seul : sans entrée au catalogue, un anglophone lirait le français — c'est-à-dire
    /// exactement le défaut qu'on vient de corriger, déplacé d'un cran.
    func testWriteRefusalPhrasesAreTranslated() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        let absent = "@@absent@@"
        for entry in Self.serverWriteCodes {
            let phrase = try XCTUnwrap(OutageWriteError.phrase(forCode: entry.code))
            XCTAssertNotEqual(
                english.localizedString(forKey: phrase, value: absent, table: nil),
                absent,
                "Sans traduction anglaise : \(phrase)"
            )
        }
    }

    /// Le nom d'opérateur se résout à UN endroit. La page « Pannes signalées » affichait la clé
    /// brute (« ORANGE ») là où la feuille de panne écrivait « Orange » — deux noms pour une même
    /// panne selon l'écran d'où on la regardait.
    func testOperatorLabelComesFromTheRegistry() throws {
        let markets = try registry()
        let france = markets.first { $0.marketCode == "FR" }
        XCTAssertEqual(MarketRegistryEntry.operatorLabel("ORANGE", in: france), "Orange")
        // Registre pas encore chargé : la clé reste ce qu'on a de moins faux.
        XCTAssertEqual(MarketRegistryEntry.operatorLabel("ORANGE", in: nil), "ORANGE")
        // Un opérateur d'un AUTRE marché n'est pas inventé.
        XCTAssertEqual(MarketRegistryEntry.operatorLabel("TELUS", in: france), "TELUS")
    }

    /// Les deux sources ne partagent JAMAIS de silhouette sur la carte.
    ///
    /// Le glyphe est ce qui reste pour dire QUI affirme depuis que la couleur des deux couches est
    /// unifiée sur l'échelle de gravité. Or l'incident opérateur « dégradé » rendait le point
    /// d'exclamation CERCLÉ — celui du signalement communautaire — si bien que les deux marqueurs
    /// devenaient deux disques ambre identiques. Le flux SFR de production portait 107 `degraded`
    /// au moment de la correction : c'est le cas courant, pas la marge.
    func testOperatorAndCommunityMarkersNeverShareAGlyph() {
        let community = MapAnnotationPayload(
            id: "community-outage-1", kind: .communityOutage, title: "Site", subtitle: "SFR",
            coordinate: CLLocationCoordinate2D(latitude: 45.18, longitude: 5.72),
            metric: nil, backendId: "abc", details: nil, antennaId: nil, clusterCount: nil,
            azimuths: [], showsAzimuths: false
        )
        let communityGlyph = SQMapKitMarkerView.glyphName(for: community)
        // `MapExplorerView.outageGlyph` et non `OperatorIncidentCard.glyph` : c'est la première
        // qui peint le marqueur, et c'est là qu'était la divergence. Tester la seconde aurait
        // laissé passer exactement la régression qu'on ferme.
        //
        // Le dernier cas couvre un type que le flux n'a jamais publié : le repli ne doit pas non
        // plus retomber sur la forme de l'autre source.
        for issueType in ["down", "degraded", "maintenance", "un_type_inconnu"] {
            XCTAssertNotEqual(
                MapExplorerView.outageGlyph(for: issueType),
                communityGlyph,
                "L'incident opérateur « \(issueType) » emprunte le glyphe du communautaire"
            )
            // La carte et la fiche antenne disent la même chose de la même panne : c'est ce que
            // le doc-comment d'`OperatorIncidentCard.glyph` affirme, autant le vérifier.
            XCTAssertEqual(
                MapExplorerView.outageGlyph(for: issueType),
                OperatorIncidentCard.glyph(for: issueType)
            )
            // Couleur unifiée sur l'échelle de gravité : le marqueur ne peut plus repartir dans
            // son échelle à lui (l'ancien jaune #EAB308, illisible sur la crème).
            XCTAssertEqual(
                MapExplorerView.outageColor(for: issueType),
                OperatorIncidentCard.tint(for: issueType)
            )
        }
    }

    // MARK: - Les champs de la v2

    /**
     LA règle du chantier : « plus rien » veut dire toutes les fréquences et tous les secteurs.

     On VIDE au lieu de masquer. Masquer aurait suffi à l'écran, mais le corps envoyé aurait porté
     une panne totale restreinte à deux bandes — l'inverse de ce que la personne vient de déclarer,
     et invisible à la relecture.
     */
    func testChoosingTotalOutageClearsBandsAndSectors() {
        var draft = OutageReportDraft()
        draft.select(.degraded)
        draft.toggle(band: "n78")
        draft.toggle(sector: 60)
        XCTAssertTrue(draft.showsImpactFields)
        XCTAssertEqual(draft.bands, ["n78"])

        draft.select(.down)
        XCTAssertFalse(draft.showsImpactFields)
        XCTAssertTrue(draft.bands.isEmpty)
        XCTAssertTrue(draft.sectors.isEmpty)
    }

    /// Les deux blocs n'existent que pour une dégradation — la vue s'appuie sur cette seule règle.
    func testImpactFieldsOnlyExistForDegradation() {
        var draft = OutageReportDraft()
        XCTAssertFalse(draft.showsImpactFields, "Rien de choisi : aucun champ facultatif")
        draft.select(.down)
        XCTAssertFalse(draft.showsImpactFields)
        draft.select(.degraded)
        XCTAssertTrue(draft.showsImpactFields)
    }

    /// Deux personnes qui cochent les mêmes cases dans un ordre différent envoient le même corps.
    func testBandsAndSectorsAreSortedInTheRequest() throws {
        var draft = OutageReportDraft()
        draft.select(.degraded)
        draft.toggle(band: "n78")
        draft.toggle(band: "b7")
        draft.toggle(sector: 180)
        draft.toggle(sector: 60)
        let request = try XCTUnwrap(draft.request(
            targetKind: "anfr", targetId: "123", marketCode: "FR", operatorKey: "ORANGE",
            latitude: nil, longitude: nil, accuracyMeters: nil
        ))
        XCTAssertEqual(request.affectedBands, ["b7", "n78"])
        XCTAssertEqual(request.affectedSectors, [60, 180])
    }

    /// Un commentaire fait d'espaces n'est pas un commentaire, et 500 est la borne du serveur.
    func testCommentIsTrimmedAndBounded() throws {
        var draft = OutageReportDraft()
        draft.select(.degraded)
        draft.comment = "   "
        let blank = try XCTUnwrap(draft.request(
            targetKind: "anfr", targetId: "123", marketCode: "FR", operatorKey: "ORANGE",
            latitude: nil, longitude: nil, accuracyMeters: nil
        ))
        XCTAssertNil(blank.comment)

        draft.comment = String(repeating: "x", count: 620)
        let long = try XCTUnwrap(draft.request(
            targetKind: "anfr", targetId: "123", marketCode: "FR", operatorKey: "ORANGE",
            latitude: nil, longitude: nil, accuracyMeters: nil
        ))
        XCTAssertEqual(long.comment?.count, 500)
    }

    /// Décocher la capture ne doit rien envoyer — pas un objet vide.
    func testDecliningTheCaptureSendsNothing() throws {
        var draft = OutageReportDraft()
        draft.select(.degraded)
        draft.attachRadio = false
        let capture = OutageRadioCaptureBuilder.make(
            status: .unknown, isOnline: true, position: nil
        )
        let request = try XCTUnwrap(draft.request(
            targetKind: "anfr", targetId: "123", marketCode: "FR", operatorKey: "ORANGE",
            latitude: nil, longitude: nil, accuracyMeters: nil, radioContext: capture
        ))
        XCTAssertNil(request.radioContext)
    }

    /**
     La capture iOS s'annonce pour ce qu'elle est.

     `platform: "ios"` n'est pas décoratif : c'est lui qui fait écrire au serveur « capture
     partielle — iOS ». Sans lui, une capture iOS et une capture Android s'afficheraient à
     l'identique alors qu'elles ne mesurent pas la même chose.
     */
    func testIOSCaptureDeclaresItsPlatformAndNeverInventsACell() {
        let capture = OutageRadioCaptureBuilder.make(
            status: .unknown, isOnline: false, position: nil
        )
        XCTAssertEqual(capture.platform, "ios")
        XCTAssertEqual(capture.state, "out_of_service", "Hors ligne : le constat, pas une supposition")
    }

    /// Le Wi-Fi ne dit RIEN du réseau mobile : prétendre qu'il fonctionne serait faux.
    func testWiFiDoesNotClaimTheMobileNetworkWorks() {
        let onWifi = NetworkPathStatus(
            connection: .wifi, cellularTechnology: nil, operatorName: nil,
            operatorMcc: nil, operatorMnc: nil, isExpensive: false, isConstrained: false
        )
        let capture = OutageRadioCaptureBuilder.make(status: onWifi, isOnline: true, position: nil)
        XCTAssertEqual(capture.state, "unknown")
    }

    // MARK: - Le fil, rendu pour de vrai

    /**
     LE test que ce chantier a appris à écrire.

     La première version du fil était un bouton conditionné à un `onOpenThread` optionnel que
     personne ne fournissait : il ne s'affichait JAMAIS. Compilation verte, 739 tests verts,
     fonctionnalité inexistante — seul un essai sur téléphone l'a révélé.

     Celui-ci rend le bloc hors écran et vérifie qu'il PEINT quelque chose. Un composant qui
     disparaît rend une image uniforme ; celui-ci doit produire du contraste — du texte, un champ,
     un bouton.
     */
    func testThreadSectionActuallyPaintsSomething() throws {
        let rendered = try pixels(
            OutageThreadSection(postId: "post_test", commentCount: 0)
                .environmentObject(AppServices(config: .test)),
            width: 320,
            height: 260
        )
        // Une vue vide rend un aplat : toutes les composantes identiques. On mesure donc la
        // DIVERSITÉ des valeurs, pas leur moyenne — un bloc blanc sur blanc la ferait tomber à 1.
        let distinct = Set(rendered).count
        XCTAssertGreaterThan(
            distinct, 8,
            "Le bloc conversation ne peint presque rien (\(distinct) valeurs distinctes) — il a probablement disparu"
        )
    }
}
