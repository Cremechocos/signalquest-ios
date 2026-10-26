import Foundation

/// Libellé et dernière activité des appareils de son compte (E2EE-AUTO §4.2,
/// révision 12) : affichage seul. La liste, la plateforme, le statut et
/// l'empreinte viennent du journal vérifié ; cette réponse s'y joint par
/// `deviceId`, et un `deviceId` absent de l'un ou de l'autre reste sans libellé.
enum E2EEAutoDeviceLabels {
    static let path = "/api/e2ee/auto/devices"

    struct Display: Equatable, Sendable {
        let label: String?
        let lastSeenAtMs: Int64?
    }

    /// Réponse à clés exactes, `deviceId` strictement croissants en octets
    /// UTF-8 ; une seule faute et toute la réponse est écartée.
    static func parse(_ data: Data) -> [String: Display]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["devices"], let devices = root["devices"] as? [Any] else { return nil }
        var result: [String: Display] = [:]
        var previous: [UInt8]?
        for item in devices {
            guard let device = item as? [String: Any], Set(device.keys) == ["deviceId", "label", "lastSeenAtMs"],
                  let deviceId = device["deviceId"] as? String, E2EEV2Canonical.isOpaque(deviceId) else { return nil }
            let bytes = Array(deviceId.utf8)
            if let previous, !previous.lexicographicallyPrecedes(bytes) { return nil }
            previous = bytes
            let label: String?
            switch device["label"] {
            case is NSNull: label = nil
            case let text as String where isLabel(text): label = text
            default: return nil
            }
            let lastSeenAtMs: Int64?
            switch device["lastSeenAtMs"] {
            case is NSNull: lastSeenAtMs = nil
            case let text as String:
                guard let value = E2EEAutoLog.decimal(text, in: 0...Int64(9_007_199_254_740_991)) else { return nil }
                lastSeenAtMs = value
            default: return nil
            }
            result[deviceId] = Display(label: label, lastSeenAtMs: lastSeenAtMs)
        }
        return result
    }

    /// Règles du §4.1 (révision 7) : 1 à 64 points de code, ni `Cc`, ni `Cf`,
    /// ni U+2028 ou U+2029, ni `White_Space` en tête ou en fin.
    static func isLabel(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard (1...64).contains(scalars.count),
              let first = scalars.first, let last = scalars.last,
              !first.properties.isWhitespace, !last.properties.isWhitespace else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate: return false
            default: return true
            }
        }
    }

    /// Lecture de la session courante ; nil sur toute erreur : libellés et activités restent inconnus.
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()
    ) -> @Sendable () async -> [String: Display]? {
        let owner = session.ownerScopeId
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        return {
            let result = await transport.getSessionJSON(path: path, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle)
            guard case .success(let data, _, _) = result else { return nil }
            return parse(data)
        }
    }
}
