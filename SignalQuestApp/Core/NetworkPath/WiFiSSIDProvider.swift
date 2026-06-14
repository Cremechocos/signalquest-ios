import Foundation
@preconcurrency import NetworkExtension

enum WiFiSSIDProvider {
    static func currentSSID(timeoutSeconds: Double = 1.0) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await fetchCurrentSSID()
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }

            let ssid = await group.next() ?? nil
            group.cancelAll()
            return ssid
        }
    }

    static func normalizedSSID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed != "--", trimmed != "Wi-Fi", trimmed != "WLAN" else { return nil }
        return trimmed
    }

    private static func fetchCurrentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: normalizedSSID(network?.ssid))
            }
        }
    }
}
