import Foundation
import NetworkExtension

/// In-app WiFi join for the camera's network (NEHotspotConfiguration —
/// the GoPro-style prompt).
///
/// NOTE: requires the Hotspot Configuration entitlement, which needs a
/// PAID developer account — free/personal teams can't use it. Without the
/// entitlement, joining fails and the UI points at the manual path
/// (Settings → Wi-Fi), which works everywhere.
enum WifiJoin {
    static func join(ssid: String, passphrase: String?) async throws {
        #if targetEnvironment(simulator)
        throw JoinError.unsupportedOnSimulator
        #else
        let config: NEHotspotConfiguration
        if let passphrase, !passphrase.isEmpty {
            config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        } else {
            config = NEHotspotConfiguration(ssid: ssid)
        }
        // don't persist the camera network — it drops us off the internet
        config.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch {
            // missing entitlement (free team) or user decline → manual path
            throw JoinError.manualJoinNeeded
        }
        #endif
    }

    enum JoinError: LocalizedError {
        case unsupportedOnSimulator
        case manualJoinNeeded
        var errorDescription: String? {
            switch self {
            case .unsupportedOnSimulator:
                return "WiFi joining isn't available in the simulator — run on a device."
            case .manualJoinNeeded:
                return "Couldn't join from the app (needs a paid developer account for " +
                       "the Hotspot entitlement). Join manually: Settings → Wi-Fi → " +
                       "the camera's network, then come back and tap Connect."
            }
        }
    }
}
