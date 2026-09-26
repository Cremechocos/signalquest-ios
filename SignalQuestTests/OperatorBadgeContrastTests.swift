import SwiftUI
import UIKit
import XCTest
@testable import SignalQuest

@MainActor
final class OperatorBadgeContrastTests: XCTestCase {
    func testEveryOperatorBadgeMeetsNormalTextContrastInBothAppearances() {
        let palette = Array(SQBrand.operators.values) + [SQBrand.defaultOperator]
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: appearance)
            for colors in palette {
                let background = UIColor(colors.solid).resolvedColor(with: traits)
                let foreground = UIColor(colors.badgeForeground).resolvedColor(with: traits)
                let ratio = contrastRatio(foreground, background)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(colors.name), \(appearance): \(ratio)")
            }
        }
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: UIColor) -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
