import SwiftUI

@main
struct M10AppApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            switch appState.phase {
            case .disconnected:
                ConnectView()
            case .connecting:
                ProgressView("Connecting to camera…")
            case .connected:
                BrowserView()
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(message)
                        .multilineTextAlignment(.center)
                    Button("Back") { appState.phase = .disconnected }
                }
                .padding()
            }
        }
    }
}
