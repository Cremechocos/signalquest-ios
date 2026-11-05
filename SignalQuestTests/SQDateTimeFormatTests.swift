import XCTest
@testable import SignalQuest

/// Audit UI/UX final (05/11) : `formatted(date:time: .shortened)` affichait
/// « à 0:36 » en français ; l'heure garde ses deux chiffres, comme la barre d'état.
final class SQDateTimeFormatTests: XCTestCase {
    private var night: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 2
        components.hour = 0
        components.minute = 36
        components.timeZone = TimeZone(identifier: "Europe/Paris")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func render(_ dateStyle: DateFormatter.Style, _ identifier: String) -> String {
        // Les espaces insécables varient d'une version d'ICU à l'autre.
        night.sqFormatted(date: dateStyle, locale: Locale(identifier: identifier), timeZone: TimeZone(identifier: "Europe/Paris"))
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testFrenchHourKeepsTwoDigits() {
        XCTAssertEqual(render(.none, "fr_FR"), "00:36")
        XCTAssertEqual(render(.medium, "fr_FR"), "2 nov. 2026 à 00:36")
        XCTAssertEqual(render(.long, "fr_FR"), "2 novembre 2026 à 00:36")
    }

    func testEnglishKeepsTwelveHourClock() {
        XCTAssertEqual(render(.none, "en_US"), "12:36 AM")
        XCTAssertEqual(render(.medium, "en_US"), "Nov 2, 2026 at 12:36 AM")
    }

    /// Tuiles publiques v1 (#982) : heure tronquée par le serveur, jamais « 11:00 ».
    func testServerHourIsShownAsAnApproximateHour() {
        let text = SignalFormatters.dateAroundHour(night)
        XCTAssertFalse(text.contains(":"), text)
        XCTAssertTrue(text.hasPrefix("2 nov. 2026 vers "), text)
    }

    /// Règle A : `timestampPrecision` est en tête de `/map/antenna/{id}`, à côté de `nearbySpeedtests`.
    func testAntennaDetailsReadTheHourPrecisionOfNearbySpeedtests() throws {
        func decode(_ precision: String) throws -> AntennaDetails {
            try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data("""
            {"antenna":{"id":"1","supId":"1","lat":45.0,"lng":5.0,"operators":["ORANGE"],"technologies":["4G"],"azimuts":[]},\(precision)
             "nearbySpeedtests":[{"id":"s1","downloadMbps":120.5,"timestamp":"2026-11-05T11:00:00.000Z"}]}
            """.utf8))
        }
        XCTAssertTrue(try decode(#""timestampPrecision":"hour","#).nearbySpeedtestsHourPrecision)
        XCTAssertFalse(try decode("").nearbySpeedtestsHourPrecision)
    }

    /// Règle A (public-map-tiles v1.1) : une heure tronquée reste approximative même en relatif.
    func testTruncatedHourStaysApproximateWhenRelative() throws {
        let calendar = Calendar.current
        let thisHour = try XCTUnwrap(calendar.dateInterval(of: .hour, for: Date())?.start)
        let today = SignalFormatters.approximateDate(thisHour)
        XCTAssertTrue(today.hasPrefix("aujourd’hui vers "), today)
        XCTAssertFalse(today.contains(":") || today.contains("min"), today)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: thisHour))
        XCTAssertTrue(SignalFormatters.approximateDate(yesterday).hasPrefix("hier vers "))
        let older = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: thisHour))
        XCTAssertEqual(SignalFormatters.approximateDate(older), "il y a 3 jours")
        let old = try XCTUnwrap(calendar.date(byAdding: .day, value: -60, to: thisHour))
        XCTAssertTrue(SignalFormatters.approximateDate(old).contains(" vers "))
    }
}
