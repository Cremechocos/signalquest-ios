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

    /// Si Figtree/Bricolage n'est pas encore enregistré, le repli SF doit suivre
    /// le style Dynamic Type. Les deux seuls replis `.system(size:)` autorisés
    /// sont ceux des helpers `*Fixed`, réservés aux exports bitmap déterministes.
    func testScreenFontFallbacksNeverBecomeFixedSize() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("SignalQuestApp/Design/SQFont.swift"),
            encoding: .utf8
        )
        let lines = source.components(separatedBy: .newlines)
        let fixedSystemLines = lines.indices.filter { lines[$0].contains("return .system(size:") }

        XCTAssertEqual(fixedSystemLines.count, 2, "Un repli écran à taille fixe a été réintroduit")
        for index in fixedSystemLines {
            let context = lines[max(0, index - 8)...index].joined(separator: "\n")
            XCTAssertTrue(
                context.contains("displayFixed") || context.contains("bodyFixed"),
                "`.system(size:)` n'est permis que dans displayFixed/bodyFixed (ligne \(index + 1))"
            )
        }
        XCTAssertTrue(source.contains(".system(style, design: design, weight: weight)"))
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

    /// Le héro Communauté porte plusieurs libellés de 12-13 pt. Leur fond vise
    /// 6:1 nominal pour garder une marge après anticrénelage, pas seulement 4,5:1
    /// sur les valeurs théoriques des tokens.
    func testOnAccentIsReadableOnDenseFeedHero() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let r = ratio(UIColor(SQColor.onAccent), on: UIColor(SQColor.accentTextSurface), style)
            XCTAssertGreaterThanOrEqual(
                r, style == .light ? 8.0 : 6.0,
                "onAccent sur accentTextSurface : \(String(format: "%.2f", r)):1"
            )
        }
    }

    /// Le trou que ce fichier avait laissé passer.
    ///
    /// Tous les tests ci-dessus mesurent les tokens à **alpha plein**, alors que
    /// l'app rend `onAccent` à 0,7-0,92 sur les bulles brique et les tuiles
    /// accentuées — de l'encre translucide qui se rapproche de son propre fond.
    /// `performAccessibilityAudit` a signalé ces textes ; le test unitaire, non.
    ///
    /// Le seuil retenu est **3:1** et non 4,5 : ces usages sont tous du texte
    /// ≥ 18 pt ou semi-gras (sous-titres de tuile, méta de bulle), catégorie
    /// « large text » de WCAG 1.4.3. Les alphas qui n'y arrivent pas doivent
    /// être remontés, pas dispensés.
    func testTranslucentOnAccentStaysReadable() {
        // Les alphas restants sont tous portés par des OBJETS GRAPHIQUES (traits,
        // icônes décoratives, `ProgressView`) ou du grand texte : seuil 3:1.
        // Les 13 petits textes qui les utilisaient sont repassés en alpha plein,
        // parce qu'aucune valeur < 1,0 n'atteint 4,5:1 en mode clair.
        // 0,6 a disparu du code : il donnait 2,82:1 sur la barre de citation.
        let alphas: [CGFloat] = [0.7, 0.75, 0.8, 0.85, 0.9, 0.92]
        var failures: [String] = []
        for style in [UIUserInterfaceStyle.light, .dark] {
            let mode = style == .light ? "clair" : "sombre"
            for alpha in alphas {
                let ink = UIColor(SQColor.onAccent).withAlphaComponent(alpha)
                let composited = composite(ink, over: UIColor(SQColor.brandRed), style)
                let r = ratio(composited, on: UIColor(SQColor.brandRed), style)
                let line = "  α=\(alpha) \(mode) : \(String(format: "%.2f", r)):1"
                print("SQ_ALPHA\(line)")
                if r < 3.0 { failures.append(line) }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "Encre translucide illisible sur brandRed :\n" + failures.joined(separator: "\n")
        )
    }

    /// Garde-fou de SOURCE : aucun `Text` ne doit reprendre un `onAccent`
    /// translucide.
    ///
    /// Le test de ratios ci-dessus ne peut pas l'attraper — il mesure des
    /// couleurs, pas des sites d'appel. Or c'est exactement l'erreur qui s'était
    /// glissée treize fois : une hiérarchie de texte obtenue par l'alpha, qui
    /// n'atteint jamais 4,5:1 sur brique en mode clair (5,05:1 à alpha plein,
    /// 4,39:1 dès 0,9).
    ///
    /// Les objets graphiques gardent leur alpha : WCAG 1.4.11 ne leur demande
    /// que 3:1. La distinction se fait sur la vue qui PRÉCÈDE le modificateur.
    func testNoSmallTextUsesTranslucentOnAccent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SignalQuestApp")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []

        // DEUX filtres, et il faut les deux — chacun seul produit des faux
        // positifs, constatés en les essayant :
        //   • sans le premier, les `.background(…)` translucides d'une `Capsule`
        //     passent pour du texte ;
        //   • sans le second, les `Image(systemName:)` aussi, puisqu'une icône
        //     se colore avec le même `foregroundStyle` qu'un texte.
        let constructors = ["Text(", "Image(", "ProgressView", "Label(", "Circle(", "Rectangle", "Capsule"]

        var offenders: [String] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = source.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                guard line.contains("foregroundStyle("), line.contains("onAccent.opacity(") else { continue }

                let context = lines[max(0, index - 6)...index].joined(separator: "\n")
                let nearest = constructors
                    .compactMap { token in context.range(of: token, options: .backwards).map { ($0.lowerBound, token) } }
                    .max(by: { $0.0 < $1.0 })?.1
                guard nearest == "Text(" else { continue }

                // Seuils mesurés sur brique en clair : 0,92 → 4,53:1 (AA pour du
                // petit texte) ; le grand texte relève de 3:1, franchi dès 0,7.
                let alpha = line.range(of: #"(?<=onAccent\.opacity\()0\.\d+"#, options: .regularExpression)
                    .flatMap { Double(line[$0]) } ?? 0
                let isLargeText = context.contains("SQFont.display(2") || context.contains("SQFont.display(3")
                if alpha < 0.92 && !isLargeText {
                    offenders.append("\(file.lastPathComponent):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Texte translucide sur brique — passer en `SQColor.onAccent` plein :\n"
                + offenders.joined(separator: "\n")
        )
    }

    // MARK: - Palette de gravité des pannes

    /// La gravité qui ÉCRIT n'est pas la gravité qui signale.
    ///
    /// `OutageTint.down/degraded/resolved` sont calibrées comme des aplats de marqueur — WCAG
    /// 1.4.11, 3:1. Posées en texte sur une carte, le rouge échoue dans les deux apparences.
    /// `downInk` / `degradedInk` / `resolvedInk` existent pour ça ; ce test les tient au seuil AA.
    func testOutageInksAreReadableOnCardSurfaces() {
        assertMinimum(UIColor(OutageTint.downInk), named: "OutageTint.downInk", atLeast: 4.5)
        assertMinimum(UIColor(OutageTint.degradedInk), named: "OutageTint.degradedInk", atLeast: 4.5)
        assertMinimum(UIColor(OutageTint.resolvedInk), named: "OutageTint.resolvedInk", atLeast: 4.5)
    }

    /// Chaque encre reste lisible sur le conteneur de SA PROPRE teinte — la pastille à 13 % de la
    /// tête de ligne et de l'en-tête de feuille. C'est le pire fond qu'elle rencontre : plus la
    /// teinte est claire, plus elle rapproche le conteneur de l'encre.
    ///
    /// Seuil 3:1 et non 4,5 : ces pastilles ne portent qu'un pictogramme, un objet graphique au
    /// sens de WCAG 1.4.11. Le texte de gravité, lui, est posé sur la surface nue de la carte —
    /// c'est le test précédent qui le couvre, au seuil AA.
    func testOutageInksAreReadableOnTheirOwnPastille() {
        let cases: [(String, Color, Color)] = [
            ("downInk sur down", OutageTint.downInk, OutageTint.down),
            ("degradedInk sur degraded", OutageTint.degradedInk, OutageTint.degraded),
            ("resolvedInk sur resolved", OutageTint.resolvedInk, OutageTint.resolved)
        ]
        for (name, ink, tint) in cases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let mode = style == .light ? "clair" : "sombre"
                let pastille = composite(UIColor(tint).withAlphaComponent(0.13), over: UIColor(SQColor.surface), style)
                let r = ratio(UIColor(ink), on: pastille, style)
                XCTAssertGreaterThanOrEqual(
                    r, 3.0, "\(name) en \(mode) : \(String(format: "%.2f", r)):1"
                )
            }
        }
    }

    /// L'ambre « dégradé » a quitté #EAB308 pour #B45309 : le jaune-500 tombait à 1,80:1 sur la
    /// crème — une pastille qu'on ne voyait pas. Ce test fige le plancher 3:1 des objets
    /// graphiques, celui auquel ces teintes servent : jauge de confirmation, sélecteur de
    /// gravité, aplat de bouton.
    ///
    /// Deux fonds seulement, et pas les trois d'`assertMinimum` : `SurfaceMuted` ne porte JAMAIS
    /// ces teintes. Mesuré quand même par curiosité, l'ambre y donne 2,77:1 en apparence sombre et
    /// le vert 2,79 — donc si un écran venait à les y poser, il faudrait leurs encres, pas elles.
    func testOutageTintsMeetTheGraphicThreshold() {
        let surfaces: [(String, UIColor)] = [
            ("SurfaceElevated", UIColor(SQColor.surface)),
            ("BackgroundPrimary", UIColor(SQColor.bg))
        ]
        let tints: [(String, Color)] = [
            ("OutageTint.down", OutageTint.down),
            ("OutageTint.degraded", OutageTint.degraded),
            ("OutageTint.resolved", OutageTint.resolved)
        ]
        for (name, tint) in tints {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let mode = style == .light ? "clair" : "sombre"
                for (bgName, bg) in surfaces {
                    let r = ratio(UIColor(tint), on: bg, style)
                    XCTAssertGreaterThanOrEqual(
                        r, 3.0,
                        "\(name) sur \(bgName) en \(mode) : \(String(format: "%.2f", r)):1"
                    )
                }
            }
        }
    }
}
