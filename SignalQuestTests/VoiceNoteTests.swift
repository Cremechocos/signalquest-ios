import XCTest
@testable import SignalQuest

/// Deux calculs purs décident de tout l'aspect d'une note vocale : la
/// conversion des décibels et la réduction en barres. Une erreur y donne une
/// forme d'onde plate ou trouée — sans jamais faire échouer quoi que ce soit.
final class VoiceNoteTests: XCTestCase {

    // MARK: Niveaux

    /// L'échelle d'`AVAudioRecorder` est en dB (−160…0) et LOGARITHMIQUE. Une
    /// conversion linéaire écraserait toute la parole normale en bas de la
    /// forme d'onde, qui paraîtrait plate.
    func testSilenceIsZeroAndPeakIsOne() {
        XCTAssertEqual(VoiceNoteRecorder.normalizedLevel(-160), 0)
        XCTAssertEqual(VoiceNoteRecorder.normalizedLevel(-50), 0)
        XCTAssertEqual(VoiceNoteRecorder.normalizedLevel(0), 1, accuracy: 0.001)
    }

    func testNormalSpeechLandsInTheUsableRange() {
        // −25 dB ≈ parole à distance normale : doit occuper le milieu de
        // l'échelle, pas être tassée près de zéro.
        let level = VoiceNoteRecorder.normalizedLevel(-25)
        XCTAssertGreaterThan(level, 0.35)
        XCTAssertLessThan(level, 0.65)
    }

    /// `AVAudioRecorder` peut renvoyer `-inf` avant le premier échantillon : le
    /// laisser passer produirait un `NaN` dans la hauteur de barre, donc un
    /// crash de rendu SwiftUI.
    func testNonFiniteInputIsSafe() {
        XCTAssertEqual(VoiceNoteRecorder.normalizedLevel(-.infinity), 0)
        XCTAssertEqual(VoiceNoteRecorder.normalizedLevel(.nan), 0)
    }

    func testLevelsAreAlwaysWithinBounds() {
        for db in stride(from: Float(-200), through: 20, by: 7) {
            let level = VoiceNoteRecorder.normalizedLevel(db)
            XCTAssertGreaterThanOrEqual(level, 0, "\(db) dB")
            XCTAssertLessThanOrEqual(level, 1, "\(db) dB")
        }
    }

    // MARK: Forme d'onde

    /// Largeur CONSTANTE : une note de 5 s et une de 90 s doivent occuper la
    /// même place, sinon la liste de messages devient irrégulière.
    func testWaveformAlwaysHasTheRequestedNumberOfBars() {
        for count in [1, 10, 40, 400, 5000] {
            let levels = (0..<count).map { Float($0 % 10) / 10 }
            XCTAssertEqual(VoiceNoteRecorder.waveform(from: levels, bars: 40).count, 40, "\(count) échantillons")
        }
    }

    /// Une note plus courte que le nombre de barres est complétée, pas étirée.
    func testShortRecordingsArePaddedNotStretched() {
        let bars = VoiceNoteRecorder.waveform(from: [1, 1, 1], bars: 10)
        XCTAssertEqual(bars.count, 10)
        XCTAssertEqual(bars.prefix(3), [1, 1, 1])
        XCTAssertTrue(bars.suffix(7).allSatisfy { $0 == 0 })
    }

    /// La réduction MOYENNE chaque tranche au lieu d'échantillonner : prendre
    /// un point sur N perdrait les pics, qui sont justement ce qui rend une
    /// forme d'onde lisible.
    func testReductionAveragesInsteadOfSampling() {
        // Un pic isolé au milieu d'un silence doit rester visible.
        var levels = [Float](repeating: 0, count: 100)
        levels[50] = 1
        let bars = VoiceNoteRecorder.waveform(from: levels, bars: 10)
        XCTAssertTrue(bars.contains { $0 > 0 }, "Le pic a disparu : réduction par échantillonnage ?")
    }

    func testEmptyInputProducesNoBars() {
        XCTAssertTrue(VoiceNoteRecorder.waveform(from: [], bars: 40).isEmpty)
    }

    // MARK: Durée

    func testDurationFormatting() {
        XCTAssertEqual(VoiceNotePlayer.formatted(0), "0:00")
        XCTAssertEqual(VoiceNotePlayer.formatted(9), "0:09")
        XCTAssertEqual(VoiceNotePlayer.formatted(75), "1:15")
        XCTAssertEqual(VoiceNotePlayer.formatted(600), "10:00")
    }

    /// Une durée invalide ne doit pas produire « -1:-1 » ni planter.
    func testInvalidDurationsAreSafe() {
        XCTAssertEqual(VoiceNotePlayer.formatted(-5), "0:00")
        XCTAssertEqual(VoiceNotePlayer.formatted(.nan), "0:00")
        XCTAssertEqual(VoiceNotePlayer.formatted(.infinity), "0:00")
    }

    /// Les bornes doivent rester cohérentes : un minimum au-dessus du maximum
    /// rendrait tout enregistrement impossible.
    @MainActor
    func testDurationBoundsAreCoherent() {
        XCTAssertLessThan(VoiceNoteRecorder.minimumDuration, VoiceNoteRecorder.maximumDuration)
        XCTAssertGreaterThan(VoiceNoteRecorder.minimumDuration, 0)
        XCTAssertLessThanOrEqual(VoiceNoteRecorder.maximumDuration, 300)
    }
}
