import XCTest
import UIKit
import SwiftUI
@testable import SignalQuest

/// Fige la lisibilité de la palette.
///
/// Les tokens sont résolus par le système (asset catalog + `dynamicTint`) puis
/// mesurés contre les fonds réels de l'app, dans les deux apparences. Sans ce
/// test, un ajustement esthétique d'un colorset pouvait faire repasser un token
/// sous le seuil sans que rien ne le signale — c'est exactement ce qui s'était
/// produit sur `LabelTertiary`.
final class DesignTokenContrastTests: XCTestCase {

    // MARK: - Calcul WCAG 2.1

    private func luminance(_ color: UIColor, _ style: UIUserInterfaceStyle) -> CGFloat {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func ratio(_ a: UIColor, on b: UIColor, _ style: UIUserInterfaceStyle) -> CGFloat {
        let la = luminance(a, style), lb = luminance(b, style)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private var backgrounds: [(String, UIColor)] {
        [("SurfaceElevated", UIColor(SQColor.surface)),
         ("BackgroundPrimary", UIColor(SQColor.bg)),
         ("SurfaceMuted", UIColor(SQColor.surfaceMuted))]
    }

    private func assertMinimum(
        _ token: UIColor, named name: String, atLeast threshold: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let mode = style == .light ? "clair" : "sombre"
            for (bgName, bg) in backgrounds {
                let r = ratio(token, on: bg, style)
                XCTAssertGreaterThanOrEqual(
                    r, threshold,
                    "\(name) sur \(bgName) en \(mode) : \(String(format: "%.2f", r)):1 < \(threshold):1",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: - Texte : seuil AA 4,5:1

    func testBodyTextTokensMeetAA() {
        assertMinimum(UIColor(SQColor.label), named: "label", atLeast: 4.5)
        assertMinimum(UIColor(SQColor.labelSecondary), named: "labelSecondary", atLeast: 4.5)
    }

    /// `labelTertiary` échouait dans LES DEUX modes (2,93 en clair, 2,18 en
    /// sombre). Il est désormais réservé aux éléments GRAPHIQUES porteurs de
    /// sens — icônes, traits, points inactifs — pour lesquels WCAG 1.4.11
    /// demande 3:1 et non 4,5:1. Tous ses usages sur du texte ont été migrés
    /// vers `labelSecondary`.
    func testTertiaryTokenMeetsGraphicThreshold() {
        assertMinimum(UIColor(SQColor.labelTertiary), named: "labelTertiary", atLeast: 3.0)
    }

    /// Aucun `labelTertiary` ne doit revenir sur du texte : le token n'atteint
    /// pas 4,5:1 et ne le peut pas sans détruire la hiérarchie visuelle.
    func testTertiaryTokenStaysBelowTextThresholdOnPurpose() {
        let r = ratio(UIColor(SQColor.labelTertiary), on: UIColor(SQColor.surface), .light)
        XCTAssertLessThan(
            r, 4.5,
            "Si labelTertiary atteint 4,5:1, il est devenu indiscernable de labelSecondary : revoir la hiérarchie"
        )
    }

    func testSemanticTokensMeetAA() {
        assertMinimum(UIColor(SQColor.warning), named: "warning", atLeast: 4.5)
        assertMinimum(UIColor(SQColor.success), named: "success", atLeast: 4.5)
    }

    /// `brandRed` et `danger` portent l'identité de marque : ils restent
    /// inchangés et ne sont donc garantis que pour du grand texte et des
    /// éléments graphiques. Leurs pendants `*Ink` couvrent le texte courant.
    func testBrandTokensMeetGraphicThreshold() {
        assertMinimum(UIColor(SQColor.brandRed), named: "brandRed", atLeast: 3.0)
        assertMinimum(UIColor(SQColor.danger), named: "danger", atLeast: 3.0)
    }

    // MARK: - Texte posé sur sa propre pastille teintée

    /// Composite une teinte translucide sur un fond, comme le fait le rendu.
    private func composite(_ tint: UIColor, over bg: UIColor, _ style: UIUserInterfaceStyle) -> UIColor {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        var br: CGFloat = 0, bg2: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        tint.resolvedColor(with: traits).getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        bg.resolvedColor(with: traits).getRed(&br, green: &bg2, blue: &bb, alpha: &ba)
        return UIColor(
            red: tr * ta + br * (1 - ta),
            green: tg * ta + bg2 * (1 - ta),
            blue: tb * ta + bb * (1 - ta),
            alpha: 1
        )
    }

    /// Poser `brandRed` sur `accentSoft` donnait 4,28:1 — sous le seuil AA.
    /// `accentInk` et `dangerInk` existent pour ce cas précis.
    func testInkTokensAreReadableOnTheirOwnPastille() {
        let cases: [(String, Color, Color)] = [
            ("accentInk sur accentSoft", SQColor.accentInk, SQColor.accentSoft),
            ("dangerInk sur dangerSoft", SQColor.dangerInk, SQColor.dangerSoft)
        ]
        for (name, ink, soft) in cases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let mode = style == .light ? "clair" : "sombre"
                let pastille = composite(UIColor(soft), over: UIColor(SQColor.surface), style)
                let r = ratio(UIColor(ink), on: pastille, style)
                XCTAssertGreaterThanOrEqual(
                    r, 4.5, "\(name) en \(mode) : \(String(format: "%.2f", r)):1"
                )
            }
        }
    }

    /// Les deux autres pastilles n'ont pas besoin d'encre dédiée — ce test le
    /// vérifie, pour qu'on ne l'oublie pas si leurs valeurs changent.
    func testSuccessAndWarningNeedNoDedicatedInk() {
        let cases: [(String, Color, Color)] = [
            ("success sur successSoft", SQColor.success, SQColor.successSoft),
            ("warning sur warningSoft", SQColor.warning, SQColor.warningSoft)
        ]
        for (name, fg, soft) in cases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let pastille = composite(UIColor(soft), over: UIColor(SQColor.surface), style)
                let r = ratio(UIColor(fg), on: pastille, style)
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(name) : \(String(format: "%.2f", r)):1 — une encre dédiée devient nécessaire")
            }
        }
    }

    /// Le texte posé sur une surface accent pleine (boutons brique).
    func testOnAccentIsReadableOnBrandSurface() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let r = ratio(UIColor(SQColor.onAccent), on: UIColor(SQColor.brandRed), style)
            XCTAssertGreaterThanOrEqual(r, 4.5, "onAccent sur brandRed : \(String(format: "%.2f", r)):1")
        }
    }
}
