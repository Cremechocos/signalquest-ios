import UIKit
import XCTest
@testable import SignalQuest

/// Polices de la carte de partage.
///
/// Deux échecs possibles, tous deux SILENCIEUX : une police absente du bundle
/// (`UIAppFonts` mal renseigné) fait composer la carte en Helvetica, et un axe de
/// graisse non appliqué rend toutes les graisses identiques. Ni l'un ni l'autre ne
/// lève d'erreur — seule l'image finale les trahit, et seulement à l'œil.
final class SQShareFontsTests: XCTestCase {

    /// Sans ces polices, la carte iOS ne peut pas ressembler à celle d'Android :
    /// c'est la raison même de leur ajout au bundle.
    func testBothFontsAreEmbedded() {
        XCTAssertTrue(
            SQShareFonts.areEmbedded,
            "Sora et/ou JetBrains Mono absentes du bundle — vérifier UIAppFonts dans Info.plist"
        )
    }

    func testDisplayResolvesToSoraAndNotAFallback() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        let font = SQShareFonts.display(size: 116, weight: 800)
        XCTAssertTrue(
            font.familyName.contains("Sora"),
            "La police d'affichage est retombée sur « \(font.familyName) »"
        )
        XCTAssertEqual(font.pointSize, 116, accuracy: 0.01)
    }

    func testMonoResolvesToJetBrainsMono() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        let font = SQShareFonts.mono(size: 12, weight: 700)
        XCTAssertTrue(
            font.familyName.replacingOccurrences(of: " ", with: "").contains("JetBrains"),
            "La monospace est retombée sur « \(font.familyName) »"
        )
    }

    /// Le test central : l'axe `wght` doit RÉELLEMENT s'appliquer. Une police
    /// variable dont on ne pilote pas l'axe rend toutes les graisses au poids par
    /// défaut (400), et les chiffres de débit — l'élément dominant de la carte —
    /// perdent leur épaisseur sans que rien ne le signale.
    ///
    /// On compare des LARGEURS de rendu plutôt que des attributs déclarés : c'est
    /// la seule preuve que la variation a été honorée par le moteur de texte.
    func testWeightAxisActuallyChangesTheRendering() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        let sample = "1240,6"
        let light = (sample as NSString).size(withAttributes: [.font: SQShareFonts.display(size: 116, weight: 100)])
        let heavy = (sample as NSString).size(withAttributes: [.font: SQShareFonts.display(size: 116, weight: 800)])
        XCTAssertGreaterThan(
            heavy.width, light.width,
            "L'axe de graisse n'est pas appliqué : le 800 rend exactement comme le 100"
        )
    }

    /// La chasse fixe doit le rester quelle que soit la graisse — c'est ce qui
    /// aligne les colonnes de chiffres de la bande basse et du pied technique.
    func testMonoStaysMonospacedAcrossWeights() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        for weight in [CGFloat(400), 700] {
            let font = SQShareFonts.mono(size: 20, weight: weight)
            let narrow = ("1" as NSString).size(withAttributes: [.font: font]).width
            let wide = ("W" as NSString).size(withAttributes: [.font: font]).width
            XCTAssertEqual(narrow, wide, accuracy: 0.5, "Chasse non fixe à la graisse \(weight)")
        }
    }

    /// Une graisse hors de l'axe (100-800) ne doit ni planter ni produire une
    /// police nulle : la carte doit rester générable en toute circonstance.
    func testOutOfRangeWeightsStayUsable() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        for weight in [CGFloat(0), 50, 900, 2_000] {
            let font = SQShareFonts.display(size: 40, weight: weight)
            XCTAssertEqual(font.pointSize, 40, accuracy: 0.01, "Graisse \(weight) inutilisable")
        }
    }
}
