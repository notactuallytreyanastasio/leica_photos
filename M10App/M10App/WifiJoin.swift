import Foundation
import NetworkExtension

/// In-app WiFi join for the camera's network (NEHotspotConfiguration —
/// the same mechanism GoPro-style companion apps use).
///
/// Needs the Hotspot Configuration entitlement on a real device; the
/// simulator has no WiFi, so joining is skipped there.
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
        try await NEHotspotConfigurationManager.shared.apply(config)
        #endif
    }

    enum JoinError: LocalizedError {
        case unsupportedOnSimulator
        var errorDescription: String? {
            "WiFi joining isn't available in the simulator — run on a device."
        }
    }
}
