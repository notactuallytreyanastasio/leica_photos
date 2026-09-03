import SwiftUI

/// Step 1: join the camera's WiFi, then connect.
/// "Join camera WiFi" uses NEHotspotConfiguration (the GoPro-style prompt)
/// — needs the Hotspot entitlement on a real device; in the simulator,
/// join from Mac settings instead.
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
                joinCard
                Button("Connect") { appState.connect() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
    }

    private var joinCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Join the camera's WiFi", systemImage: "wifi")
                .font(.headline)

            TextField("Network name (e.g. LeicaM10-5230856)",
                      text: $appState.ssid)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)

            SecureField("Password (shown on the camera)",
                        text: $appState.wifiPassword)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await appState.joinCameraWiFi() }
            } label: {
                Label("Join camera WiFi", systemImage: "wifi.router")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if let status = appState.wifiStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Then tap Connect — the camera is found automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
