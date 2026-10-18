import AVFoundation
import XCTest
@testable import SignalQuest

/// Notes vocales lues dans l'app (SOC-06) : nom de cache stable, durée et
/// forme d'onde tirées du fichier.
final class VoiceNoteCacheTests: XCTestCase {

    /// P04 : au-delà du plafond, les notes les plus anciennes partent, jamais celle qu'on vient d'écrire.
    func testTrimDropsTheOldestNotesAndKeepsTheOneJustWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, modified: TimeInterval) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(repeating: 1, count: 40).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
            return url
        }
        let oldest = try write("a.m4a", modified: 1_000)
        let middle = try write("b.m4a", modified: 2_000)
        let newest = try write("c.m4a", modified: 3_000)

        VoiceNoteCache.trimIfNeeded(directory: directory, keeping: oldest, limit: 100)

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.path), "La note qu'on vient d'écrire reste")
        XCTAssertFalse(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
    }

    /// L'adresse signée change de paramètres d'une réponse à l'autre : le nom
    /// ne doit dépendre que de la pièce jointe.
    func testCacheNameIgnoresSignedQuery() throws {
        let first = try XCTUnwrap(URL(string: "https://s3.example/voice/a1.m4a?X-Amz-Signature=one"))
        let second = try XCTUnwrap(URL(string: "https://s3.example/voice/a1.m4a?X-Amz-Signature=two"))
        XCTAssertEqual(VoiceNoteCache.fileName(remoteURL: first, key: nil), VoiceNoteCache.fileName(remoteURL: second, key: nil))
        XCTAssertEqual(VoiceNoteCache.fileName(remoteURL: first, key: "att-1"), VoiceNoteCache.fileName(remoteURL: second, key: "att-1"))
        XCTAssertNotEqual(VoiceNoteCache.fileName(remoteURL: first, key: "att-1"), VoiceNoteCache.fileName(remoteURL: first, key: "att-2"))
        XCTAssertTrue(VoiceNoteCache.fileName(remoteURL: first, key: nil).hasSuffix(".m4a"))
    }

    /// Une seconde de son puis une seconde de silence : 2 s de durée, et la
    /// forme d'onde retombe dans la seconde moitié.
    func testAnalysisReadsDurationAndLevels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampleRate = 16_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate * 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            channel[index] = index < Int(sampleRate) ? 0.5 * sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) : 0
        }
        do {
            // Le fichier se referme en sortant du bloc : l'en-tête est alors complet.
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let analyzed = try VoiceNoteCache.analyze(url)
        XCTAssertEqual(analyzed.duration, 2, accuracy: 0.05)
        XCTAssertEqual(analyzed.levels.count, 32)
        XCTAssertEqual(analyzed.levels.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertLessThan(analyzed.levels.last ?? 1, 0.01)
    }
}
