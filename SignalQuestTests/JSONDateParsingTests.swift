import Foundation
import XCTest
@testable import SignalQuest

final class JSONDateParsingTests: XCTestCase {
    func testCanonicalUTCRepresentsExpectedInstants() throws {
        let cases: [(String, TimeInterval)] = [
            ("1970-01-01T00:00:00Z", 0),
            ("1970-01-01T00:00:00.000Z", 0),
            ("2000-01-01T00:00:00Z", 946_684_800),
            ("2000-01-01T00:00:00.123Z", 946_684_800.123),
            ("2024-02-29T00:00:00Z", 1_709_164_800),
            ("2024-02-29T00:00:00.999Z", 1_709_164_800.999)
        ]
        for (input, epoch) in cases {
            let actual = try XCTUnwrap(SQDateParsing.parse(input), input)
            XCTAssertEqual(actual, Date(timeIntervalSince1970: epoch), input)
        }
    }

    func testCanonicalUTCPreservesExactDatesAcrossEpochAndYearBoundaries() {
        var inputs = Self.canonicalInputs(count: 128, milliseconds: true)
        inputs += Self.canonicalInputs(count: 128, milliseconds: false)
        for year in [1900, 1969, 1970, 1999, 2000, 2001, 2038, 2099] {
            for fraction in ["", ".000", ".001", ".007", ".123", ".499", ".999"] {
                inputs.append("\(year)-01-01T00:00:00\(fraction)Z")
                inputs.append("\(year)-12-31T23:59:59\(fraction)Z")
            }
        }
        for year in [1900, 2000, 2024, 2025] {
            for month in [2, 4, 6, 9, 11] {
                for day in [28, 29, 30, 31] {
                    for fraction in ["", ".123"] {
                        inputs.append(String(format: "%04d-%02d-%02dT23:59:59%@Z", year, month, day, fraction))
                    }
                }
            }
        }
        assertLegacyEquivalent(inputs)
    }

    func testFractionPrecisionOffsetsAndLocalDatesKeepLegacyBehavior() {
        var inputs = ["2026-09-08", "2024-02-29", "2026-09-08 12:34:56"]
        for fraction in ["", ".0", ".1", ".01", ".12", ".001", ".123", ".123456", ".123456789"] {
            for zone in ["Z", "z", "+00:00", "+02:00", "+0200", "-05:30", "-0530", ""] {
                inputs.append("2026-09-08T12:34:56\(fraction)\(zone)")
            }
        }
        assertLegacyEquivalent(inputs)
    }

    func testHistoricalAndFarFutureDatesKeepLegacyBehavior() {
        var inputs: [String] = []
        for year in ["0000", "0001", "1500", "1582", "1700", "1899", "2100", "2400", "9999"] {
            for fraction in ["", ".123", ".999"] {
                inputs.append("\(year)-01-01T12:34:56\(fraction)Z")
            }
        }
        assertLegacyEquivalent(inputs)
    }

    func testMalformedAndOutOfRangeDatesKeepLegacyAcceptanceRules() {
        // Some malformed calendar dates are normalized by Foundation. Preserve
        // the deployed result rather than imposing a new validation policy.
        assertLegacyEquivalent(Self.edgeInputs)
        for input in ["", "not-a-date", "2026-09-08T12:34:60Z", "2016-12-31T23:59:60.000Z"] {
            XCTAssertNil(SQDateParsing.parse(input), input)
        }
    }

    func testJSONDecoderPreservesStringDatesAndNumericEpochUnits() throws {
        struct DateBox: Decodable { let date: Date }
        let cases: [(String, TimeInterval)] = [
            ("0", 0),
            ("-1", -1),
            ("1715421600", 1_715_421_600),
            ("1715421600.125", 1_715_421_600.125),
            ("1715421600123", 1_715_421_600.123),
            ("999999999999", 999_999_999_999),
            ("1000000000000", 1_000_000_000)
        ]
        for (number, seconds) in cases {
            let payload = Data("{\"date\":\(number)}".utf8)
            let decoded = try JSONDecoder.signalQuest.decode(DateBox.self, from: payload)
            XCTAssertEqual(decoded.date, Date(timeIntervalSince1970: seconds), number)
        }
        for input in ["1999-01-01T12:34:56.123Z", "2026-09-08T12:34:56Z", "2026-09-08"] {
            let payload = try JSONSerialization.data(withJSONObject: ["date": input])
            let decoded = try JSONDecoder.signalQuest.decode(DateBox.self, from: payload)
            XCTAssertEqual(decoded.date, try XCTUnwrap(LegacyDateParsingReference.parse(input)), input)
        }
        for payload in ["{\"date\":\"not-a-date\"}", "{\"date\":null}", "{\"date\":true}"] {
            XCTAssertThrowsError(try JSONDecoder.signalQuest.decode(DateBox.self, from: Data(payload.utf8)))
        }
    }

    func testConcurrentRepeatedParsingKeepsExactLegacyResults() {
        let inputs = Self.canonicalInputs(count: 24, milliseconds: true)
            + Self.canonicalInputs(count: 24, milliseconds: false)
            + ["2026-09-08", "2026-09-08T12:34:56.123456+02:00", "1700-01-01T12:34:56.123Z"]
            + Array(Self.edgeInputs.prefix(8))
        let expected = inputs.map(LegacyDateParsingReference.parse)
        // The configured parsers are shared across workers, as in simultaneous
        // tile/feed decodes. Expectations are calculated before concurrency.
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for _ in 0..<2 {
                for (index, input) in inputs.enumerated() {
                    XCTAssertEqual(SQDateParsing.parse(input), expected[index], "worker=\(worker) \(input)")
                }
            }
        }
    }

    func testCanonicalParsingPerformanceQA() throws {
        guard ProcessInfo.processInfo.environment["SQ_DATE_PERFORMANCE_QA"] == "1" else {
            throw XCTSkip("Opt-in QA iOS 27 : activer SQ_DATE_PERFORMANCE_QA=1 pour le budget relatif du parseur.")
        }
        // Campaign budget for the iOS 27 reference environment: at least 5x
        // faster than the previous five SHARED formatters, for each UTC family.
        // This is intentionally opt-in, not an absolute timing gate for CI or
        // a promise about older Foundation releases or end-to-end map latency.
        for milliseconds in [true, false] {
            let inputs = Self.canonicalInputs(count: 2_000, milliseconds: milliseconds)
            assertLegacyEquivalent(inputs)
            let referenceWarmup = Self.sample(inputs, parse: LegacyDateParsingReference.parse)
            let candidateWarmup = Self.sample(inputs, parse: SQDateParsing.parse)
            XCTAssertEqual(referenceWarmup.count, inputs.count)
            XCTAssertEqual(candidateWarmup.count, inputs.count)
            XCTAssertEqual(candidateWarmup.checksum, referenceWarmup.checksum)

            var referenceTimes: [Double] = []
            var candidateTimes: [Double] = []
            for repetition in 0..<3 {
                let reference: ParseSample
                let candidate: ParseSample
                if repetition.isMultiple(of: 2) {
                    reference = Self.sample(inputs, parse: LegacyDateParsingReference.parse)
                    candidate = Self.sample(inputs, parse: SQDateParsing.parse)
                } else {
                    candidate = Self.sample(inputs, parse: SQDateParsing.parse)
                    reference = Self.sample(inputs, parse: LegacyDateParsingReference.parse)
                }
                XCTAssertEqual(reference.count, inputs.count)
                XCTAssertEqual(candidate.count, inputs.count)
                XCTAssertEqual(reference.checksum, referenceWarmup.checksum)
                XCTAssertEqual(candidate.checksum, referenceWarmup.checksum)
                referenceTimes.append(reference.seconds)
                candidateTimes.append(candidate.seconds)
            }
            let referenceMedian = referenceTimes.sorted()[1]
            let candidateMedian = candidateTimes.sorted()[1]
            let speedup = referenceMedian / candidateMedian
            let family = milliseconds ? "UTC .SSS" : "UTC seconds"
            print("DATE_PERFORMANCE_QA \(family): reference=\(referenceTimes) candidate=\(candidateTimes) medianSpeedup=\(speedup)x")
            XCTAssertGreaterThanOrEqual(speedup, 5,
                "Budget QA iOS 27, \(family) : médianes de 3 lots de 2 000 dates, formatters échauffés et partagés.")
        }
    }

    private func assertLegacyEquivalent(_ inputs: [String], file: StaticString = #filePath, line: UInt = #line) {
        for input in inputs {
            XCTAssertEqual(SQDateParsing.parse(input), LegacyDateParsingReference.parse(input),
                           input.debugDescription, file: file, line: line)
        }
    }

    private static func canonicalInputs(count: Int, milliseconds: Bool) -> [String] {
        (0..<count).map { index in
            let year = 1900 + index % 200
            let month = 1 + (index / 7) % 12
            let day = 1 + (index / 13) % 28
            let hour = index % 24
            let minute = (index / 3) % 60
            let second = (index / 11) % 60
            let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second)
            return base + (milliseconds ? String(format: ".%03dZ", (index * 137) % 1_000) : "Z")
        }
    }

    private struct ParseSample {
        let seconds: Double
        let checksum: UInt64
        let count: Int
    }

    private static func sample(_ inputs: [String], parse: (String) -> Date?) -> ParseSample {
        var checksum: UInt64 = 2_166_136_261
        var count = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for input in inputs {
            if let date = parse(input) {
                checksum = (checksum &* 16_777_619) ^ date.timeIntervalSinceReferenceDate.bitPattern
                count += 1
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return ParseSample(seconds: Double(elapsed) / 1_000_000_000, checksum: checksum, count: count)
    }

    private static let edgeInputs = [
        "", "not-a-date", "2026-09-08T12:34:60Z", "2016-12-31T23:59:60.000Z",
        "2025-02-29T12:34:56Z", "2024-02-30T12:34:56.123Z", "2026-04-31T12:34:56Z",
        "2026-00-01T12:34:56Z", "2026-13-01T12:34:56.123Z", "2026-01-00T12:34:56Z",
        "2026-01-32T12:34:56.123Z", "2026-09-08T24:00:00Z", "2026-09-08T25:00:00.123Z",
        "2026-09-08T12:60:00Z", "2026-09-08T12:61:00.123Z", "2026-09-08T12:34:61.123Z",
        "2026-09-08T12:34:56.Z", "2026-09-08T12:34:56,123Z", "2026-9-8T12:34:56Z",
        "２０２６-09-08T12:34:56Z", "2026-09-08T12:34:5éZ", "2026-09-08t12:34:56Z",
        "2026-09-08T12:34:56Zsuffix", " 2026-09-08T12:34:56Z", "2026-09-08T12:34:56Z ",
        "2026-09-08T12:34:56Z\n", "2026-09-08T12:34:56.123Z\0", "2026-09-08T12:34:56+25:00",
        "2025-02-29", "2026-13-01", "0", "1700000000", "1700000000000", "NaN"
    ]
}

/// Frozen pre-optimization behavior. Each formatter is configured ONCE, just
/// like the production baseline; construction cost is never charged per parse.
private enum LegacyDateParsingReference {
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localWithFraction = makeLocal("yyyy-MM-dd'T'HH:mm:ss.SSS")
    private static let localNoFraction = makeLocal("yyyy-MM-dd'T'HH:mm:ss")
    private static let dateOnly = makeLocal("yyyy-MM-dd")

    private static func makeLocal(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    static func parse(_ value: String) -> Date? {
        if let date = isoWithFraction.date(from: value) { return date }
        if let date = isoNoFraction.date(from: value) { return date }
        if let date = localWithFraction.date(from: value) { return date }
        if let date = localNoFraction.date(from: value) { return date }
        if let date = dateOnly.date(from: value) { return date }
        return nil
    }
}
