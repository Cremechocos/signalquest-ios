import SwiftUI
import UIKit

/// Couleurs « Crème » de l'app, recopiées à la main : comme le widget, cette
/// cible ne voit ni `SQColor`, ni le catalogue d'assets de l'app. Les valeurs
/// sont celles de `SignalQuestApp/Design/SQColors.swift` ; une évolution de la
/// charte se reporte ici.
enum ShareColor {
    static let background = dynamic(light: 0xF4F2EC, dark: 0x0F1312)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x181D1B)
    static let fill = dynamic(light: 0xECEAE1, dark: 0x232927)
    static let separator = dynamic(light: 0x1C201E, dark: 0xF1F4F1, lightAlpha: 0.09, darkAlpha: 0.10)
    static let label = dynamic(light: 0x1C201E, dark: 0xF1F4F1)
    /// Encre secondaire ; plus appuyée quand « Augmenter le contraste » est actif.
    static let secondary = dynamic(light: 0x636B66, dark: 0x98A29C, highLight: 0x3C443F, highDark: 0xC9D2CC)
    /// Texte posé sur le bouton encre (`label`).
    static let onInk = dynamic(light: 0xF4F2EC, dark: 0x0F1312)
    static let accent = dynamic(light: 0xA8123A, dark: 0xFF5C7A)
    static let accentSoft = dynamic(light: 0xA8123A, dark: 0xFF5C7A, lightAlpha: 0.10, darkAlpha: 0.14)
    static let success = dynamic(light: 0x187B38, dark: 0x7BD89A)
    static let successSoft = dynamic(light: 0x187B38, dark: 0x7BD89A, lightAlpha: 0.12, darkAlpha: 0.14)
    static let danger = dynamic(light: 0xA82A2F, dark: 0xEC8D90)
    static let dangerSoft = dynamic(light: 0xC5363B, dark: 0xE07A7E, lightAlpha: 0.10, darkAlpha: 0.12)

    private static func dynamic(
        light: UInt32,
        dark: UInt32,
        highLight: UInt32? = nil,
        highDark: UInt32? = nil,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            var hex = isDark ? dark : light
            if traits.accessibilityContrast == .high, let high = isDark ? highDark : highLight { hex = high }
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

enum ShareMetrics {
    /// Cible tactile minimale d'Apple.
    static let touchTarget: CGFloat = 44
    static let cardRadius: CGFloat = 22
    static let thumbnail: CGFloat = 76
}
