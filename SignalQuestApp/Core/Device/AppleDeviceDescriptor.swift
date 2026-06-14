import Foundation
import UIKit

enum AppleDeviceDescriptor {
    static var currentModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }

    static var currentModelName: String {
        marketingName(for: currentModelIdentifier)
    }

    static var currentShareModelName: String {
        let identifier = currentModelIdentifier
        let name = marketingName(for: identifier)
        guard !identifier.isEmpty, name != identifier else { return name.isEmpty ? "iPhone" : "iPhone (\(identifier))" }
        return "\(name) (\(identifier))"
    }

    static var currentOSVersionLabel: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return "iOS \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    static func marketingName(for identifier: String) -> String {
        switch identifier {
        case "i386", "x86_64", "arm64":
            return "iPhone Simulator"
        case "iPhone10,1", "iPhone10,4":
            return "iPhone 8"
        case "iPhone10,2", "iPhone10,5":
            return "iPhone 8 Plus"
        case "iPhone10,3", "iPhone10,6":
            return "iPhone X"
        case "iPhone11,2":
            return "iPhone XS"
        case "iPhone11,4", "iPhone11,6":
            return "iPhone XS Max"
        case "iPhone11,8":
            return "iPhone XR"
        case "iPhone12,1":
            return "iPhone 11"
        case "iPhone12,3":
            return "iPhone 11 Pro"
        case "iPhone12,5":
            return "iPhone 11 Pro Max"
        case "iPhone12,8":
            return "iPhone SE 2"
        case "iPhone13,1":
            return "iPhone 12 mini"
        case "iPhone13,2":
            return "iPhone 12"
        case "iPhone13,3":
            return "iPhone 12 Pro"
        case "iPhone13,4":
            return "iPhone 12 Pro Max"
        case "iPhone14,4":
            return "iPhone 13 mini"
        case "iPhone14,5":
            return "iPhone 13"
        case "iPhone14,2":
            return "iPhone 13 Pro"
        case "iPhone14,3":
            return "iPhone 13 Pro Max"
        case "iPhone14,6":
            return "iPhone SE 3"
        case "iPhone14,7":
            return "iPhone 14"
        case "iPhone14,8":
            return "iPhone 14 Plus"
        case "iPhone15,2":
            return "iPhone 14 Pro"
        case "iPhone15,3":
            return "iPhone 14 Pro Max"
        case "iPhone15,4":
            return "iPhone 15"
        case "iPhone15,5":
            return "iPhone 15 Plus"
        case "iPhone16,1":
            return "iPhone 15 Pro"
        case "iPhone16,2":
            return "iPhone 15 Pro Max"
        case "iPhone17,3":
            return "iPhone 16"
        case "iPhone17,4":
            return "iPhone 16 Plus"
        case "iPhone17,1":
            return "iPhone 16 Pro"
        case "iPhone17,2":
            return "iPhone 16 Pro Max"
        case "iPhone17,5":
            return "iPhone 16e"
        case "iPhone18,1":
            return "iPhone 17 Pro"
        default:
            return identifier
        }
    }
}

extension UIDevice {
    var modelName: String { AppleDeviceDescriptor.currentModelName }
}
