import SwiftUI
import UIKit
import XCTest
@testable import SignalQuest

/// Composer du fil (Lot 4f, SOC-18).
@MainActor
final class FeedComposerTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ComposerSheet.draftText.\(LocalAccountScope.storageNamespace)")
        UserDefaults.standard.removeObject(forKey: "ComposerSheet.draftVisibility.\(LocalAccountScope.storageNamespace)")
        super.tearDown()
    }

    /// Un sondage seul se publie : le bouton restait désactivé.
    func testPollAloneCanBePublished() {
        let model = ComposerViewModel(service: ComposerFeedFixture())
        model.text = ""
        XCTAssertFalse(model.canPublish)
        model.pollEnabled = true
        model.pollQuestion = "Meilleur réseau à Lyon ?"
        model.pollOptions[0].text = "Orange"
        model.pollOptions[1].text = "SFR"
        XCTAssertTrue(model.canPublish)
        XCTAssertEqual(model.fallbackBody, "Meilleur réseau à Lyon ?")
    }

    /// Une photo prise avec l'appareil (E4) devient la photo du post, comme celle de la photothèque ;
    /// des octets illisibles laissent le post sans photo et le disent.
    func testCapturedPhotoBecomesThePostPhoto() throws {
        let model = ComposerViewModel(service: ComposerFeedFixture())
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.jpegData(compressionQuality: 0.9))
        model.loadCapturedPhoto(jpeg)
        XCTAssertNotNil(model.previewImage)
        XCTAssertEqual(model.imageDataForUpload, jpeg)
        XCTAssertNil(model.errorMessage)

        let unreadable = ComposerViewModel(service: ComposerFeedFixture())
        unreadable.loadCapturedPhoto(Data([0x00, 0x01]))
        XCTAssertNil(unreadable.previewImage)
        XCTAssertNotNil(unreadable.errorMessage)
    }

    /// Une photo retirée ne part plus avec la publication ; une photo retouchée
    /// remplace l'originale (plan 3, vague 1 ; E1).
    func testRemovedPhotoIsNotPublishedAndEditedPhotoReplacesIt() throws {
        let model = ComposerViewModel(service: ComposerFeedFixture())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        model.applyEdits(photo, PhotoEdits(blurRegions: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)]))
        XCTAssertEqual(model.imageDataForUpload, photo.jpegData(compressionQuality: 0.92))
        XCTAssertTrue(model.previewImage === photo)
        model.removeImage()
        XCTAssertNil(model.imageDataForUpload, "La photo retirée partait encore avec la publication")
        XCTAssertNil(model.previewImage)
    }

    /// Modifier un post ne remplace pas le brouillon en cours de rédaction.
    func testEditingAPostKeepsTheDraft() throws {
        let draft = ComposerViewModel(service: ComposerFeedFixture())
        draft.text = "Brouillon en cours"
        let editor = ComposerViewModel(service: ComposerFeedFixture())
        let post = try XCTUnwrap(Self.post(text: "Texte publié"))
        editor.beginEditing(post)
        editor.text = "Texte publié, corrigé"
        let reopened = ComposerViewModel(service: ComposerFeedFixture())
        XCTAssertEqual(reopened.text, "Brouillon en cours")
    }

    /// La déconnexion volontaire emporte le brouillon de publication du compte.
    func testEraseDraftsRemovesTheLeavingAccountDraft() {
        let defaults = UserDefaults(suiteName: "composer-erase-\(UUID().uuidString)")!
        let namespace = LocalAccountScope.storageNamespace(for: "user:leaving")
        let other = LocalAccountScope.storageNamespace(for: "user:staying")
        for ns in [namespace, other] {
            defaults.set("brouillon", forKey: "ComposerSheet.draftText.\(ns)")
            defaults.set("friends", forKey: "ComposerSheet.draftVisibility.\(ns)")
        }

        ComposerViewModel.eraseDrafts(ownerScopeId: "user:leaving", defaults: defaults)

        XCTAssertNil(defaults.string(forKey: "ComposerSheet.draftText.\(namespace)"))
        XCTAssertNil(defaults.string(forKey: "ComposerSheet.draftVisibility.\(namespace)"))
        XCTAssertEqual(defaults.string(forKey: "ComposerSheet.draftText.\(other)"), "brouillon")
    }

    /// Rouvrir le composer avec un brouillon n'écrit rien dans `UserDefaults` :
    /// chaque écriture notifiait SwiftUI, et la vue parente, qui recrée le
    /// composer à chaque rendu, tournait en boucle (l'éditeur ne s'ouvrait plus).
    func testReopeningWithADraftWritesNothing() {
        // IOS-017 : une tâche laissée par un test précédent (brouillon effacé, photo du
        // compositeur) écrivait dans UserDefaults pendant ce test, qui comptait ses
        // écritures et lisait un texte vide. On la laisse finir avant de commencer.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let draft = ComposerViewModel(service: ComposerFeedFixture())
        draft.text = "Brouillon en cours"
        final class Count: @unchecked Sendable { var value = 0 }
        let writes = Count()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil
        ) { _ in writes.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<3 {
            XCTAssertEqual(ComposerViewModel(service: ComposerFeedFixture()).text, "Brouillon en cours")
        }
        XCTAssertEqual(writes.value, 0, "Relire le brouillon ne doit pas le réécrire")
    }

    /// Légende de story : coupée au plafond du serveur, compté en unités UTF-16
    /// comme en JavaScript, sans casser un emoji (SOC-34).
    func testStoryCaptionIsCappedLikeTheServerCountsIt() {
        let limit = StoryComposerViewModel.maxTextLength
        XCTAssertEqual(StoryComposerViewModel.clampedCaption("Salut"), "Salut")
        let long = String(repeating: "a", count: limit + 10)
        XCTAssertEqual(StoryComposerViewModel.clampedCaption(long).utf16.count, limit)
        // « 👍🏽 » : un caractère, quatre unités UTF-16.
        let emojis = String(repeating: "👍🏽", count: 400)
        let clamped = StoryComposerViewModel.clampedCaption(emojis)
        XCTAssertEqual(clamped.count, limit / 4)
        XCTAssertEqual(clamped.utf16.count, limit)
    }

    /// Les codes d'erreur des stories ont des mots, et un refus Premium venu
    /// d'une autre fonction ne parle plus du journal radio.
    func testStoryErrorCodesGetPlainWords() {
        for code in ["EMPTY_STORY", "INVALID_STORY_EXPIRATION", "INVALID_STORY"] {
            let shown = APIError.userFacingMessage(status: 400, code: code, serverMessage: code)
            XCTAssertFalse(shown.contains("_"), "\(code) s'affiche brut : « \(shown) »")
            XCTAssertNotEqual(shown, APIError.statusFallback(400), "\(code) retombe sur le repli générique")
        }
        let premium = APIError.userFacingMessage(status: 403, code: "PREMIUM_REQUIRED", serverMessage: "")
        XCTAssertFalse(premium.contains("journal radio"))
    }

    /// Le relevé joint à une story se lit sous `signal` (forme du serveur), sous
    /// `radioSnapshot` ou à plat ; sans opérateur, techno ni RSRP, pas de pastille.
    func testStorySignalPillsReadTheServerShapes() {
        let nested = StorySignalSummary(metadata: [
            "signal": .object(["operator": .string("SFR"), "technology": .string("5g"), "rsrp": .number(-88)])
        ])
        XCTAssertEqual(nested?.pills.first, "SFR · 5G")
        XCTAssertEqual(nested?.pills.count, 2, "La qualité du signal manque")

        let snapshot = StorySignalSummary(metadata: ["radioSnapshot": .object(["networkType": .string("4G")])])
        XCTAssertEqual(snapshot?.pills, ["4G"])

        let flat = StorySignalSummary(metadata: ["operator": .string("Orange")])
        XCTAssertEqual(flat?.pills, ["Orange"])

        XCTAssertNil(StorySignalSummary(metadata: nil))
        XCTAssertNil(StorySignalSummary(metadata: ["signal": .object(["city": .string("Lyon")])]))
    }

    // MARK: Fonds de story (contracts/social/story-background-v1.json, copié à l'octet de 8004e3661)

    private func storyBackgroundContract() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/social/story-background-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func hex(_ raw: Any?) -> UInt32? {
        guard let text = raw as? String, text.hasPrefix("#") else { return nil }
        return UInt32(text.dropFirst(), radix: 16)
    }

    private static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    /// Contraste WCAG le plus faible entre l'encre et tout point du dégradé (interpolé en sRGB).
    private static func minContrast(from: UInt32, to: UInt32, ink: UInt32) -> Double {
        func rgb(_ v: UInt32) -> (Double, Double, Double) {
            (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
        let a = rgb(from), b = rgb(to), inkL = luminance(rgb(ink))
        return (0...200).map { step -> Double in
            let t = Double(step) / 200
            let l = luminance((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t))
            return (max(l, inkL) + 0.05) / (min(l, inkL) + 0.05)
        }.min() ?? 0
    }

    func testStoryBackgroundsAreTheFrozenContract() throws {
        let contract = try storyBackgroundContract()
        let backgrounds = try XCTUnwrap(contract["backgrounds"] as? [String: [String: Any]])
        let inks = try XCTUnwrap(contract["inks"] as? [String: String])
        XCTAssertEqual(Set(StoryBackground.allCases.map(\.rawValue)), Set(backgrounds.keys))
        XCTAssertEqual(StoryBackground.lightInk, Self.hex(inks["light"]))
        XCTAssertEqual(StoryBackground.darkInk, Self.hex(inks["dark"]))
        for background in StoryBackground.allCases where background != .brand {
            let entry = try XCTUnwrap(backgrounds[background.rawValue])
            let palette = background.palette(.light)
            XCTAssertTrue(palette == background.palette(.dark), "\(background) ne dépend pas du thème")
            switch entry["kind"] as? String {
            case "gradient":
                XCTAssertEqual(palette.from, Self.hex(entry["from"]), "\(background)")
                XCTAssertEqual(palette.to, Self.hex(entry["to"]), "\(background)")
            case "solid":
                XCTAssertEqual(palette.from, Self.hex(entry["color"]), "\(background)")
                XCTAssertEqual(palette.to, palette.from, "\(background)")
            default:
                XCTFail("\(background) : genre inconnu")
            }
            XCTAssertEqual(palette.ink, Self.hex(inks[entry["ink"] as? String ?? ""]), "\(background)")
        }
        XCTAssertEqual(backgrounds["brand"]?["kind"] as? String, "named")

        let legacy = try XCTUnwrap((contract["legacyHex"] as? [String: Any])?["map"] as? [String: String])
        XCTAssertEqual(StoryBackground.legacyHex.mapValues(\.rawValue), legacy)
    }

    /// Chaque fond, `brand` compris dans les deux thèmes, tient 4,5:1 sur toute son étendue.
    func testStoryBackgroundInkKeepsTheContrastEverywhere() {
        for background in StoryBackground.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let p = background.palette(scheme)
                XCTAssertGreaterThanOrEqual(Self.minContrast(from: p.from, to: p.to, ink: p.ink), 4.5, "\(background) \(scheme)")
            }
        }
    }

    func testStoryBackgroundReadsKeysLegacyHexAndFallsBackToBrand() {
        XCTAssertEqual(StoryBackground(stored: "ocean"), .ocean)
        XCTAssertEqual(StoryBackground(stored: "brand"), .brand)
        XCTAssertEqual(StoryBackground(stored: "#F3EDE2"), .creme)
        XCTAssertEqual(StoryBackground(stored: "#f3ede2"), .creme)
        XCTAssertEqual(StoryBackground(stored: "#191410"), .nuit)
        for other in [nil, "", "Ocean", "#FFFFFF", "#F3EDE", "rouge"] as [String?] {
            XCTAssertEqual(StoryBackground(stored: other), .brand, String(describing: other))
        }
    }

    /// Comme `linear-gradient(160deg, …)` : ligne par le centre, de longueur |w·sin θ| + |h·cos θ|.
    func testStoryGradientEndpointsFollowCSS() {
        let size = CGSize(width: 90, height: 160)
        let points = StoryBackground.gradientPoints(in: size)
        let theta = 160 * Double.pi / 180
        let length = abs(90 * sin(theta)) + abs(160 * cos(theta))
        let dx = (points.end.x - points.start.x) * 90, dy = (points.end.y - points.start.y) * 160
        XCTAssertEqual((dx * dx + dy * dy).squareRoot(), length, accuracy: 1e-9)
        XCTAssertEqual(atan2(dx, -dy), theta, accuracy: 1e-9)
        XCTAssertEqual((points.start.x + points.end.x) / 2, 0.5, accuracy: 1e-12)
        XCTAssertEqual((points.start.y + points.end.y) / 2, 0.5, accuracy: 1e-12)
    }

    /// Profil réglé sur « personne » : état « Profil privé », sans erreur ni
    /// « Réessayer » (403 PROFILE_PRIVATE, en prod depuis le 30/09).
    func testPrivateProfileShowsACalmStateInsteadOfAnError() async {
        let fixture = ComposerFeedFixture()
        fixture.userProfileError = APIError.http(status: 403, code: "PROFILE_PRIVATE",
                                                 message: "Profil privé", requestId: nil, retryAfter: nil)
        let model = UserProfileViewModel(userId: "u-private", prefill: nil, service: fixture)
        await model.load()
        XCTAssertTrue(model.isPrivate)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.items.isEmpty)
    }

    // MARK: Listes Abonnés / Abonnements

    /// Champs null et fin de liste : la ligne reste affichable (repli « Membre »).
    func testFollowPageDecodesNullFieldsAndNullCursor() throws {
        let json = #"{"people":[{"id":"u1","name":null,"handle":null,"avatarUrl":null,"following":true,"followsMe":true,"friend":false}],"nextCursor":null,"requestId":"r"}"#
        let page = try JSONDecoder.signalQuest.decode(SocialFollowPage.self, from: Data(json.utf8))
        XCTAssertNil(page.nextCursor)
        let person = try XCTUnwrap(page.people.first)
        XCTAssertNil(person.name)
        XCTAssertNil(person.handle)
        XCTAssertNil(person.avatarUrl)
        XCTAssertTrue(person.following)
        XCTAssertTrue(person.followsMe)
        XCTAssertFalse(person.friend)
        XCTAssertEqual(person.displayName, MemberIdentity.someone)
    }

    /// Une clé absente prend sa valeur par défaut, un élément sans id est écarté :
    /// jamais d'échec de toute la page pour un champ.
    func testFollowPageToleratesMissingKeysAndUnreadableItems() throws {
        let json = #"{"people":[{"id":"u1","handle":"zed"},{"name":"Sans id"},{"id":"u2","following":"oui","friend":true}],"nextCursor":"abc"}"#
        let page = try JSONDecoder.signalQuest.decode(SocialFollowPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertEqual(page.people.map(\.id), ["u1", "u2"])
        XCTAssertEqual(page.people[0].displayName, "@zed")
        XCTAssertFalse(page.people[0].following)
        XCTAssertFalse(page.people[0].followsMe)
        XCTAssertFalse(page.people[0].friend)
        // Un drapeau mal typé retombe sur « faux » sans toucher les autres.
        XCTAssertFalse(page.people[1].following)
        XCTAssertTrue(page.people[1].friend)

        let empty = try JSONDecoder.signalQuest.decode(SocialFollowPage.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.people.isEmpty)
        XCTAssertNil(empty.nextCursor)
    }

    /// `profile.privacy.hideFollowLists` : absent (serveur plus ancien) = listes visibles.
    func testProfileDecodesHideFollowListsAbsentAndPresent() throws {
        func profile(_ extra: String) throws -> SocialUserProfile {
            let json = #"{"id":"u1","name":"Léa","isSelf":false\#(extra)}"#
            return try JSONDecoder.signalQuest.decode(SocialUserProfile.self, from: Data(json.utf8))
        }
        let absent = try profile("")
        XCTAssertNil(absent.privacy)
        XCTAssertFalse(absent.followListsHidden)

        let emptyPrivacy = try profile(#","privacy":{}"#)
        XCTAssertFalse(emptyPrivacy.followListsHidden)

        let hidden = try profile(#","privacy":{"hideFollowLists":true}"#)
        XCTAssertEqual(hidden.privacy?.hideFollowLists, true)
        XCTAssertTrue(hidden.followListsHidden)

        let visible = try profile(#","privacy":{"hideFollowLists":false}"#)
        XCTAssertFalse(visible.followListsHidden)
    }

    /// IOS-023 : le profil public montre les points de gamification, comme son propre
    /// profil et Android ; l'ancien compteur ne sert que de repli.
    func testPublicProfileShowsGamificationPoints() throws {
        func stats(_ json: String) throws -> SocialUserProfileStats {
            try JSONDecoder.signalQuest.decode(SocialUserProfileStats.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try stats(#"{"points":3110,"gamificationPoints":0}"#).displayedPoints, 0)
        XCTAssertEqual(try stats(#"{"points":3110,"gamificationPoints":4878}"#).displayedPoints, 4878)
        XCTAssertEqual(try stats(#"{"points":3110}"#).displayedPoints, 3110, "Ancien serveur : repli")
    }

    /// IOS-031 : le niveau du profil d'un membre est celui des missions, comme son
    /// propre profil et Android ; l'ancien niveau stocké ne sert que de repli.
    func testPublicProfileShowsMissionsLevel() throws {
        func stats(_ json: String) throws -> SocialUserProfileStats {
            try JSONDecoder.signalQuest.decode(SocialUserProfileStats.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try stats(#"{"level":1,"missionsLevel":7}"#).displayedLevel, 7)
        XCTAssertEqual(try stats(#"{"level":4}"#).displayedLevel, 4, "Ancien serveur : repli")
        XCTAssertNil(try stats(#"{}"#).displayedLevel)
    }

    /// SOCIAL-BELL-1 : champ absent = cloche masquée ; une valeur inconnue s'affiche « Désactivées ».
    func testProfileDecodesPostNotificationsAbsentServedAndUnknown() throws {
        func profile(_ extra: String) throws -> SocialUserProfile {
            let json = #"{"id":"u1","name":"Léa","isSelf":false,"isFollowing":true\#(extra)}"#
            return try JSONDecoder.signalQuest.decode(SocialUserProfile.self, from: Data(json.utf8))
        }
        XCTAssertNil(try profile("").postNotifications, "Non servi : pas de cloche")
        XCTAssertNil(try profile(#","postNotifications":null"#).postNotifications)
        XCTAssertEqual(try profile(#","postNotifications":"all""#).postNotifications, .all)
        XCTAssertEqual(try profile(#","postNotifications":"posts_reposts""#).postNotifications, .postsReposts)
        XCTAssertEqual(try profile(#","postNotifications":"posts""#).postNotifications, .posts)
        XCTAssertEqual(try profile(#","postNotifications":"off""#).postNotifications, .off)
        XCTAssertEqual(try profile(#","postNotifications":"everything""#).postNotifications, .off)

        let follow = try JSONDecoder.signalQuest.decode(
            SocialFollowResult.self, from: Data(#"{"following":true,"followersCount":3,"postNotifications":"off"}"#.utf8))
        XCTAssertEqual(follow.postNotifications, "off")
        let olderServer = try JSONDecoder.signalQuest.decode(SocialFollowResult.self, from: Data(#"{"following":false}"#.utf8))
        XCTAssertNil(olderServer.postNotifications)
    }

    /// SOCIAL-BELL-1 : PUT /api/social/follows/[userId]/notifications, corps {"level": …}.
    func testSettingPostNotificationsPutsTheLevel() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-bell")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = SocialFeedService(api: APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config)))
        nonisolated(unsafe) var seen: (method: String?, path: String, body: [String: String]?)?
        MockURLProtocol.requestHandler = { request in
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
            }
            seen = (request.httpMethod, request.url?.path ?? "", try? JSONDecoder().decode([String: String].self, from: data))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"following":true,"postNotifications":"posts_reposts"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let saved = try await service.setPostNotifications(userId: "user_followed_1", level: .postsReposts)

        XCTAssertEqual(saved, .postsReposts)
        XCTAssertEqual(seen?.method, "PUT")
        XCTAssertEqual(seen?.path, "/api/social/follows/user_followed_1/notifications")
        XCTAssertEqual(seen?.body, ["level": "posts_reposts"])
    }

    /// `profile.statsHidden` : les nombres restent servis, l'app ne les montre
    /// pas ; absent = visibles ; son propre profil les montre toujours.
    func testProfileStatsHiddenKeepsNumbersButHidesThem() throws {
        func profile(_ extra: String) throws -> SocialUserProfile {
            let json = #"{"id":"u1","name":"Léa","followersCount":12,"followingCount":3\#(extra)}"#
            return try JSONDecoder.signalQuest.decode(SocialUserProfile.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try profile(#","isSelf":false"#).showsStats)

        let hidden = try profile(#","isSelf":false,"statsHidden":true"#)
        XCTAssertTrue(hidden.statsHidden)
        XCTAssertFalse(hidden.showsStats)
        XCTAssertEqual(hidden.followersCount, 12)

        XCTAssertTrue(try profile(#","isSelf":true,"statsHidden":true"#).showsStats)
        XCTAssertTrue(try profile(#","isSelf":false,"statsHidden":"oui""#).showsStats)
    }

    /// IOS-037 : trajets publics et photos récentes, comme Android et le Web. Le serveur met
    /// `publicSessions` à null quand les chiffres sont masqués ; une photo mal formée tombe
    /// seule, sans emporter les autres ni le profil.
    func testProfileDecodesPublicTripsAndRecentPhotos() throws {
        func profile(_ extra: String) throws -> SocialUserProfile {
            let json = #"{"id":"u1","name":"Léa","isSelf":false\#(extra)}"#
            return try JSONDecoder.signalQuest.decode(SocialUserProfile.self, from: Data(json.utf8))
        }
        let older = try profile(#","stats":{"photos":4}"#)
        XCTAssertNil(older.stats?.publicSessions)
        XCTAssertEqual(older.recentPhotos, [])

        let served = try profile(#"""
        ,"stats":{"photos":4,"publicSessions":7},
        "recentPhotos":[
          {"id":"p1","thumbnailUrl":"https://cdn.example.test/p1.jpg","siteId":"site_1"},
          {"thumbnailUrl":"https://cdn.example.test/sans-id.jpg"},
          {"id":"p2","thumbnailUrl":null,"siteId":null}
        ]
        """#)
        XCTAssertEqual(served.stats?.publicSessions, 7)
        XCTAssertEqual(served.recentPhotos.map(\.id), ["p1", "p2"])
        XCTAssertEqual(served.recentPhotos.first?.thumbnailUrl?.absoluteString, "https://cdn.example.test/p1.jpg")
        XCTAssertEqual(served.recentPhotos.first?.siteId, "site_1")
        XCTAssertNil(served.recentPhotos.last?.thumbnailUrl)

        let hidden = try profile(#","statsHidden":true,"stats":{"photos":4,"publicSessions":null}"#)
        XCTAssertNil(hidden.stats?.publicSessions)
        XCTAssertEqual(hidden.stats?.photos, 4)
    }

    /// D13 : `spotlight` du profil et `author.spotlight` du fil, décodés comme Android, sans rien
    /// inventer : couleur inconnue → encre neutre ; série trop courte, hors bornes ou non
    /// numérique, genre inconnu, photo sans adresse → pas de bannière ; plus de 24 valeurs →
    /// les 24 dernières ; `null` → pas de mise en valeur.
    func testSpotlightDecodesLikeAndroidWithoutRepairingAnything() throws {
        func spotlight(_ json: String) throws -> ProfileSpotlight? {
            let profile = #"{"id":"u1","name":"Léa","isSelf":false,"spotlight":\#(json)}"#
            return try JSONDecoder.signalQuest.decode(SocialUserProfile.self, from: Data(profile.utf8)).spotlight
        }
        let five = "[0.1,0.5,1,0.25,0]"
        XCTAssertEqual(try spotlight(#"{"accent":"plum","banner":{"kind":"measures","series":\#(five)}}"#),
                       ProfileSpotlight(accent: .plum, banner: .measures([0.1, 0.5, 1, 0.25, 0])))
        XCTAssertEqual(try spotlight(#"{"accent":"neon","banner":{"kind":"none"}}"#),
                       ProfileSpotlight(accent: .ink, banner: .empty))
        XCTAssertEqual(try spotlight(#"{"accent":"fir","banner":{"kind":"measures","series":[0.1,0.5,1,0.25]}}"#)?.banner, .empty)
        XCTAssertEqual(try spotlight(#"{"accent":"fir","banner":{"kind":"measures","series":[0.1,0.5,1.2,0.25,0]}}"#)?.banner, .empty)
        XCTAssertEqual(try spotlight(#"{"accent":"fir","banner":{"kind":"measures","series":[0.1,"0.5",1,0.25,0]}}"#)?.banner, .empty)
        let thirty = (0..<30).map { Double($0) / 30 }
        let long = "[" + thirty.map { String($0) }.joined(separator: ",") + "]"
        XCTAssertEqual(try spotlight(#"{"accent":"gold","banner":{"kind":"measures","series":\#(long)}}"#)?.banner,
                       .measures(Array(thirty.suffix(24))))
        XCTAssertEqual(try spotlight(#"{"accent":"brick","banner":{"kind":"photo","photoUrl":"https://cdn.example.test/b.jpg"}}"#)?.banner,
                       .photo(URL(string: "https://cdn.example.test/b.jpg")!))
        XCTAssertEqual(try spotlight(#"{"accent":"brick","banner":{"kind":"photo","photoUrl":""}}"#)?.banner, .empty)
        XCTAssertEqual(try spotlight(#"{"accent":"slate","banner":{"kind":"hologram"}}"#)?.banner, .empty)
        XCTAssertNil(try spotlight("null"))
        XCTAssertNil(try spotlight(#""gold""#))

        // Dans le fil : l'auteur porte la sienne ; un auteur gratuit n'en a pas.
        let author = try JSONDecoder.signalQuest.decode(SocialFeedAuthor.self, from: Data(
            #"{"id":"a1","name":"Inès","spotlight":{"accent":"gold","banner":{"kind":"none"}}}"#.utf8))
        XCTAssertEqual(author.spotlight, ProfileSpotlight(accent: .gold, banner: .empty))
        let free = try JSONDecoder.signalQuest.decode(SocialFeedAuthor.self, from: Data(#"{"id":"a2","name":"Tom"}"#.utf8))
        XCTAssertNil(free.spotlight)

        // Le fil se garde en cache : la mise en valeur fait l'aller-retour.
        let again = try JSONDecoder.signalQuest.decode(SocialFeedAuthor.self, from: JSONEncoder().encode(author))
        XCTAssertEqual(again.spotlight, author.spotlight)
    }

    /// La courbe passe par chaque point sans dépasser verticalement entre deux valeurs.
    func testSpotlightCurveNeverOvershootsBetweenTwoValues() {
        let points = SQSpotlightCurve.points([0, 1, 0.2, 0.9, 0.9, 0], in: CGSize(width: 300, height: 100), padX: 12, padY: 10)
        XCTAssertEqual(points.first, CGPoint(x: 12, y: 90))
        XCTAssertEqual(points[1], CGPoint(x: 12 + 276.0 / 5, y: 10))
        let segments = SQSpotlightCurve.segments(points)
        XCTAssertEqual(segments.count, points.count - 1)
        for (i, segment) in segments.enumerated() {
            let lo = min(points[i].y, points[i + 1].y)
            let hi = max(points[i].y, points[i + 1].y)
            XCTAssertTrue((lo...hi).contains(segment.c1.y), "c1 du segment \(i)")
            XCTAssertTrue((lo...hi).contains(segment.c2.y), "c2 du segment \(i)")
            XCTAssertEqual(segment.end, points[i + 1])
        }
        XCTAssertTrue(SQSpotlightCurve.points([0.5], in: CGSize(width: 300, height: 100), padX: 12, padY: 10).isEmpty)
    }

    /// Réglages : on n'enregistre qu'un vrai changement, jamais une bannière photo sans photo ;
    /// chaque refus du serveur a son message ; sous le seuil, l'aperçu n'invente pas de courbe.
    func testSpotlightSettingsSaveOnlyRealChangesAndNameEachRefusal() async throws {
        let served = try JSONDecoder.signalQuest.decode(ProfileSpotlightSettings.self, from: Data(
            #"{"banner":{"kind":"measures","photoId":null},"accent":"gold","measures":{"count":7,"threshold":5},"kept":false}"#.utf8))
        XCTAssertEqual(served, ProfileSpotlightSettings(kind: .measures, photoId: nil, accent: .gold,
                                                        measuresCount: 7, threshold: 5, kept: false))
        XCTAssertFalse(served.belowThreshold)
        let none = try JSONDecoder.signalQuest.decode(ProfileSpotlightSettings.self, from: Data(
            #"{"banner":{"kind":"none","photoId":"p9"},"accent":"plum","measures":{"count":2,"threshold":5},"kept":true}"#.utf8))
        XCTAssertEqual(none.kind, .noBanner)
        XCTAssertNil(none.photoId)
        XCTAssertTrue(none.belowThreshold)
        XCTAssertTrue(none.kept)

        let service = SpotlightServiceFixture(settings: served)
        let model = ProfileSpotlightSettingsModel(service: service) {
            ProfileSpotlight(accent: .gold, banner: .measures([0.2, 0.4, 0.6, 0.8, 1]))
        }
        await model.load()
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(model.previewBanner, .measures([0.2, 0.4, 0.6, 0.8, 1]))

        model.select(.photo)
        XCTAssertFalse(model.canSave, "une bannière photo sans photo ne s'enregistre pas")
        XCTAssertEqual(model.previewBanner, .empty)
        model.choose(ProfileSpotlightPhoto(id: "p1", thumbnailUrl: nil, bannerUrl: URL(string: "https://cdn.example.test/p1.jpg")))
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.previewBanner, .photo(URL(string: "https://cdn.example.test/p1.jpg")!))

        model.select(ProfileSpotlight.Accent.fir)
        await model.save()
        XCTAssertEqual(service.saved?.kind, .photo)
        XCTAssertEqual(service.saved?.photoId, "p1")
        XCTAssertEqual(service.saved?.accent, .fir)
        XCTAssertEqual(model.outcome, .saved)
        XCTAssertFalse(model.canSave, "enregistré : plus rien à enregistrer")

        func refusal(_ code: String, status: Int) -> ProfileSpotlightSettingsModel.Outcome {
            ProfileSpotlightSettingsModel.outcome(for: APIError.http(status: status, code: code, message: "",
                                                                     requestId: nil, retryAfter: nil))
        }
        XCTAssertEqual(refusal("PREMIUM_REQUIRED", status: 403), .premiumRequired)
        XCTAssertEqual(refusal("INVALID_ACCENT", status: 422), .invalidAccent)
        XCTAssertEqual(refusal("PHOTO_NOT_ELIGIBLE", status: 422), .photoNotEligible)
        XCTAssertEqual(refusal("INTERNAL_ERROR", status: 500), .failed)

        // Sous le seuil, « Mes mesures » ne dessine rien dans l'aperçu.
        let below = SpotlightServiceFixture(settings: none)
        let quiet = ProfileSpotlightSettingsModel(service: below) {
            ProfileSpotlight(accent: .plum, banner: .measures([0.2, 0.4, 0.6, 0.8, 1]))
        }
        await quiet.load()
        quiet.select(.measures)
        XCTAssertEqual(quiet.previewBanner, .empty)
    }

    func testFollowListShowsHiddenAndPrivateStatesInsteadOfAnError() async {
        let fixture = ComposerFeedFixture()
        let model = FollowListViewModel(
            route: FollowListRoute(userId: "u1", displayName: "Léa", kind: .followers, isSelf: false),
            service: fixture
        )
        fixture.followListError = APIError.http(status: 403, code: "FOLLOW_LISTS_HIDDEN",
                                                message: "Ce membre masque ses listes", requestId: nil, retryAfter: nil)
        await model.load()
        XCTAssertEqual(model.current.restriction, .listsHidden)
        XCTAssertNil(model.current.errorMessage)

        fixture.followListError = APIError.http(status: 403, code: "PROFILE_PRIVATE",
                                                message: "Profil privé", requestId: nil, retryAfter: nil)
        await model.load()
        XCTAssertEqual(model.current.restriction, .profilePrivate)

        // 404 sans code (route pas encore en production) : erreur propre, avec « Réessayer ».
        fixture.followListError = APIError.http(status: 404, code: nil, message: "", requestId: nil, retryAfter: nil)
        await model.load()
        XCTAssertNil(model.current.restriction)
        XCTAssertNotNil(model.current.errorMessage)
        XCTAssertFalse(model.current.hasLoaded)
    }

    func testFollowListPaginatesWithOpaqueCursorAndSkipsDuplicates() async {
        let fixture = ComposerFeedFixture()
        fixture.followPages = [
            SocialFollowPage(people: [
                SocialFollowPerson(id: "a", name: "A", handle: nil, avatarUrl: nil),
                SocialFollowPerson(id: "b", name: "B", handle: nil, avatarUrl: nil)
            ], nextCursor: "page-2"),
            SocialFollowPage(people: [
                SocialFollowPerson(id: "b", name: "B", handle: nil, avatarUrl: nil),
                SocialFollowPerson(id: "c", name: "C", handle: nil, avatarUrl: nil)
            ], nextCursor: nil)
        ]
        let model = FollowListViewModel(
            route: FollowListRoute(userId: "u1", displayName: "Léa", kind: .following, isSelf: true),
            service: fixture
        )
        await model.load()
        XCTAssertEqual(model.current.people.map(\.id), ["a", "b"])
        XCTAssertEqual(model.current.nextCursor, "page-2")

        await model.loadMore()
        XCTAssertEqual(model.current.people.map(\.id), ["a", "b", "c"])
        XCTAssertNil(model.current.nextCursor)
        XCTAssertEqual(fixture.followListCursors, [nil, "page-2"])

        // Fin de liste : plus aucun appel.
        await model.loadMore()
        XCTAssertEqual(fixture.followListCursors.count, 2)
    }

    func testFollowListKeepsLoadedRowsWhenNextPageFails() async {
        let fixture = ComposerFeedFixture()
        fixture.followPages = [
            SocialFollowPage(people: [SocialFollowPerson(id: "a", name: "A", handle: nil, avatarUrl: nil)], nextCursor: "page-2")
        ]
        let model = FollowListViewModel(
            route: FollowListRoute(userId: "u1", displayName: "Léa", kind: .followers, isSelf: false),
            service: fixture
        )
        await model.load()
        fixture.followListError = APIError.transport("offline")
        await model.loadMore()
        XCTAssertEqual(model.current.people.map(\.id), ["a"])
        XCTAssertTrue(model.current.loadMoreFailed)
        XCTAssertEqual(model.current.nextCursor, "page-2")
        XCTAssertNil(model.current.errorMessage)
    }

    private static func post(text: String) -> UnifiedSocialFeedItem? {
        let json = #"{"id":"post-1","kind":"post","author":{"id":"me","name":"Moi"},"text":"\#(text)"}"#
        return try? JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(json.utf8))
    }
}

private enum ComposerFixtureError: Error { case unused }
/// §8 côté composer : brouillon, choix du menu et modification gardent leur audience.
@MainActor
final class ComposerDefaultAudienceTests: XCTestCase {
    private var textKey: String { "ComposerSheet.draftText.\(LocalAccountScope.storageNamespace)" }
    private var visibilityKey: String { "ComposerSheet.draftVisibility.\(LocalAccountScope.storageNamespace)" }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: textKey)
        UserDefaults.standard.removeObject(forKey: visibilityKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: textKey)
        UserDefaults.standard.removeObject(forKey: visibilityKey)
        super.tearDown()
    }

    func testNewPostStartsFromTheDefaultAudience() {
        let model = ComposerViewModel(service: ComposerFeedFixture())
        XCTAssertEqual(model.visibility, .friends)
        model.applyDefaultAudience(.privateOnly)
        XCTAssertEqual(model.visibility, .privateOnly)
    }

    func testADraftKeepsItsAudienceAcrossReopening() {
        let draft = ComposerViewModel(service: ComposerFeedFixture())
        draft.text = "Brouillon"
        draft.chooseVisibility(.publicWorld)
        let reopened = ComposerViewModel(service: ComposerFeedFixture())
        XCTAssertEqual(reopened.text, "Brouillon")
        XCTAssertEqual(reopened.visibility, .publicWorld, "L'audience du brouillon était réécrite en amis à la relecture")
        reopened.applyDefaultAudience(.privateOnly)
        XCTAssertEqual(reopened.visibility, .publicWorld, "Un brouillon garde son audience")
    }

    func testAMenuChoiceWinsOverALateDefault() {
        let model = ComposerViewModel(service: ComposerFeedFixture())
        model.chooseVisibility(.publicWorld)
        model.applyDefaultAudience(.privateOnly)
        XCTAssertEqual(model.visibility, .publicWorld)
    }

    func testClearingTheDraftReturnsToTheDefaultAudience() {
        let model = ComposerViewModel(service: ComposerFeedFixture())
        model.applyDefaultAudience(.privateOnly)
        model.text = "Brouillon"
        model.chooseVisibility(.publicWorld)
        model.clearDraft()
        XCTAssertEqual(model.visibility, .privateOnly)
        XCTAssertEqual(ComposerViewModel(service: ComposerFeedFixture()).text, "")
    }
}

private final class ComposerFeedFixture: SocialFeedServicing, @unchecked Sendable {
    let handler: @Sendable (String?, String?, FeedTab?) async throws -> SocialFeedPage
    init() { self.handler = { _, _, _ in throw ComposerFixtureError.unused } }
    func loadFeed(cursor: String?, hashtag: String?, tab: FeedTab?) async throws -> SocialFeedPage { try await handler(cursor, hashtag, tab) }
    func post(id: String) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func createPost(
        text: String,
        visibility: String,
        attachments: [CreatePostAttachment],
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func uploadImage(data: Data, mimeType: String) async throws -> CreatePostAttachment { throw ComposerFixtureError.unused }
    func publishPost(
        text: String,
        visibility: String,
        imageData: Data?,
        imageMimeType: String,
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func retryPendingPosts() async {  }
    func react(postId: String, emoji: String) async throws -> ReactionResponse { throw ComposerFixtureError.unused }
    func favorite(postId: String) async throws -> ReactionResponse { throw ComposerFixtureError.unused }
    func repost(postId: String) async throws -> ReactionResponse { throw ComposerFixtureError.unused }
    func muteNotifications(postId: String) async throws -> SuccessResponse { throw ComposerFixtureError.unused }
    func editPost(postId: String, text: String, visibility: String?) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func setVisibility(postId: String, visibility: String) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func deletePost(postId: String) async throws { throw ComposerFixtureError.unused }
    func setPinned(postId: String, pinned: Bool) async throws { throw ComposerFixtureError.unused }
    func votePoll(postId: String, optionId: String?, removing: Bool) async throws -> FeedPoll? { throw ComposerFixtureError.unused }
    func followedHashtags() async throws -> [FollowedHashtag] { throw ComposerFixtureError.unused }
    func setHashtagFollowed(_ tag: String, following: Bool) async throws { throw ComposerFixtureError.unused }
    func mutes() async throws -> SocialMutes { throw ComposerFixtureError.unused }
    func setHashtagMuted(_ tag: String, muted: Bool) async throws { throw ComposerFixtureError.unused }
    func setWordMuted(_ pattern: String, muted: Bool) async throws { throw ComposerFixtureError.unused }
    func explore(query: String?) async throws -> SocialExploreResult { throw ComposerFixtureError.unused }
    func weeklyRecap() async throws -> WeeklyRecapStats? { throw ComposerFixtureError.unused }
    func publishWeeklyRecap() async throws -> WeeklyRecapPublishResponse { throw ComposerFixtureError.unused }
    func share(postId: String, conversationId: String) async throws -> String? { throw ComposerFixtureError.unused }
    var userProfileError: Error = ComposerFixtureError.unused
    func userProfile(userId: String) async throws -> SocialUserProfile { throw userProfileError }
    func toggleFollow(userId: String) async throws -> SocialFollowResult { throw ComposerFixtureError.unused }
    func setPostNotifications(userId: String, level: PostNotificationLevel) async throws -> PostNotificationLevel { throw ComposerFixtureError.unused }
    /// Pages servies dans l'ordre ; une erreur prend le pas quand elle est posée.
    var followPages: [SocialFollowPage] = []
    var followListError: Error?
    var followListCursors: [String?] = []
    func followList(_ kind: SocialFollowListKind, userId: String, cursor: String?, limit: Int) async throws -> SocialFollowPage {
        followListCursors.append(cursor)
        if let followListError { throw followListError }
        guard !followPages.isEmpty else { throw ComposerFixtureError.unused }
        return followPages.removeFirst()
    }
    func userPosts(userId: String, cursor: String?, mine: Bool) async throws -> SocialFeedPage { throw ComposerFixtureError.unused }
    func trendingHashtags() async throws -> [TrendingHashtag] { throw ComposerFixtureError.unused }
    func suggestedUsers() async throws -> [SocialFeedAuthor] { throw ComposerFixtureError.unused }
    func searchUsers(query: String, limit: Int) async throws -> [SocialUserSearchResult] { throw ComposerFixtureError.unused }
    func myLatestSpeedtest() async throws -> SocialShareableSpeedtest? { throw ComposerFixtureError.unused }
    func mySpeedtests(limit: Int) async throws -> [SocialShareableSpeedtest] { throw ComposerFixtureError.unused }
    func mySpeedtests(page: Int, limit: Int) async throws -> (tests: [SocialShareableSpeedtest], hasMore: Bool) { throw ComposerFixtureError.unused }
    func networkPulse(latitude: Double, longitude: Double, radiusMeters: Int?) async throws -> NetworkPulse { throw ComposerFixtureError.unused }
    func nearbyRecentSpeedtests(latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async throws -> [AndroidSpeedtestMarker] { throw ComposerFixtureError.unused }
}

/// Réglages de la mise en valeur sans réseau : rend ce qu'on lui a donné et garde le dernier envoi.
private final class SpotlightServiceFixture: ProfileSpotlightServicing, @unchecked Sendable {
    var settingsValue: ProfileSpotlightSettings
    var saved: (kind: ProfileSpotlightSettings.Kind, photoId: String?, accent: ProfileSpotlight.Accent)?

    init(settings: ProfileSpotlightSettings) { settingsValue = settings }

    func settings() async throws -> ProfileSpotlightSettings { settingsValue }

    func save(kind: ProfileSpotlightSettings.Kind, photoId: String?, accent: ProfileSpotlight.Accent) async throws -> ProfileSpotlightSettings {
        saved = (kind, photoId, accent)
        settingsValue = ProfileSpotlightSettings(kind: kind, photoId: photoId, accent: accent,
                                                 measuresCount: settingsValue.measuresCount,
                                                 threshold: settingsValue.threshold, kept: false)
        return settingsValue
    }

    func photos(cursor: String?) async throws -> ProfileSpotlightPhotoPage {
        ProfileSpotlightPhotoPage(photos: [], nextCursor: nil)
    }
}
