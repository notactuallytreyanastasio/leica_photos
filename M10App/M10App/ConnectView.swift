import SwiftUI

/// Step 1: join the camera's WiFi, then connect.
/// In a future iteration this can drive NEHotspotConfiguration to prompt
/// the join automatically (needs the Hotspot Configuration entitlement).
struct ConnectView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "camera.aperture")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Leica M10")
                .font(.title.bold())
            Text("Browse and download photos straight from the camera.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if appState.phase == .disconnected {
                instructions
                Button("Connect") { appState.connect() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Enable WiFi on the camera (favorite button in playback)")
            } icon: {
                Image(systemName: "1.circle.fill")
            }
            Label {
                Text("Join the camera's network in Settings → Wi-Fi")
            } icon: {
                Image(systemName: "2.circle.fill")
            }
            Label {
                Text("Come back and tap Connect")
            } icon: {
                Image(systemName: "3.circle.fill")
            }
        }
        .font(.subheadline)
    }
}
