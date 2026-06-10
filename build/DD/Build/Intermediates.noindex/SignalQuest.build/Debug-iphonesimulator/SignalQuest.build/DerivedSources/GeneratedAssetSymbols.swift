import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "AccentColor" asset catalog color resource.
    static let accent = DeveloperToolsSupport.ColorResource(name: "AccentColor", bundle: resourceBundle)

    /// The "BackgroundPrimary" asset catalog color resource.
    static let backgroundPrimary = DeveloperToolsSupport.ColorResource(name: "BackgroundPrimary", bundle: resourceBundle)

    /// The "BackgroundSecondary" asset catalog color resource.
    static let backgroundSecondary = DeveloperToolsSupport.ColorResource(name: "BackgroundSecondary", bundle: resourceBundle)

    /// The "BrandBlue" asset catalog color resource.
    static let brandBlue = DeveloperToolsSupport.ColorResource(name: "BrandBlue", bundle: resourceBundle)

    /// The "BrandGreen" asset catalog color resource.
    static let brandGreen = DeveloperToolsSupport.ColorResource(name: "BrandGreen", bundle: resourceBundle)

    /// The "BrandOrange" asset catalog color resource.
    static let brandOrange = DeveloperToolsSupport.ColorResource(name: "BrandOrange", bundle: resourceBundle)

    /// The "BrandPink" asset catalog color resource.
    static let brandPink = DeveloperToolsSupport.ColorResource(name: "BrandPink", bundle: resourceBundle)

    /// The "Danger" asset catalog color resource.
    static let danger = DeveloperToolsSupport.ColorResource(name: "Danger", bundle: resourceBundle)

    /// The "Fill" asset catalog color resource.
    static let fill = DeveloperToolsSupport.ColorResource(name: "Fill", bundle: resourceBundle)

    /// The "Info" asset catalog color resource.
    static let info = DeveloperToolsSupport.ColorResource(name: "Info", bundle: resourceBundle)

    /// The "LabelPrimary" asset catalog color resource.
    static let labelPrimary = DeveloperToolsSupport.ColorResource(name: "LabelPrimary", bundle: resourceBundle)

    /// The "LabelSecondary" asset catalog color resource.
    static let labelSecondary = DeveloperToolsSupport.ColorResource(name: "LabelSecondary", bundle: resourceBundle)

    /// The "LabelTertiary" asset catalog color resource.
    static let labelTertiary = DeveloperToolsSupport.ColorResource(name: "LabelTertiary", bundle: resourceBundle)

    /// The "Like" asset catalog color resource.
    static let like = DeveloperToolsSupport.ColorResource(name: "Like", bundle: resourceBundle)

    /// The "Separator" asset catalog color resource.
    static let separator = DeveloperToolsSupport.ColorResource(name: "Separator", bundle: resourceBundle)

    /// The "Success" asset catalog color resource.
    static let success = DeveloperToolsSupport.ColorResource(name: "Success", bundle: resourceBundle)

    /// The "SurfaceElevated" asset catalog color resource.
    static let surfaceElevated = DeveloperToolsSupport.ColorResource(name: "SurfaceElevated", bundle: resourceBundle)

    /// The "SurfaceMuted" asset catalog color resource.
    static let surfaceMuted = DeveloperToolsSupport.ColorResource(name: "SurfaceMuted", bundle: resourceBundle)

    /// The "Warning" asset catalog color resource.
    static let warning = DeveloperToolsSupport.ColorResource(name: "Warning", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

}

