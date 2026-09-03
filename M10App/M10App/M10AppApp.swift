import SwiftUI

@main
struct M10AppApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var guardBox = GuardBox()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onAppear {
                    if guardBox.guard_ == nil {
                        let g = TransferGuard()
                        g.attach(to: appState)
                        guardBox.guard_ = g
                    }
                    // permission bootstrap (used by the UI test; harmless otherwise)
                    if ProcessInfo.processInfo.arguments.contains("-m10-request-photo-access") {
                        Task { _ = await PhotoKitService.requestAccess() }
                    }
                }
        }
    }
}

/// TransferGuard isn't ObservableObject-friendly for @StateObject (it is,
/// but we only need one instance attached once); this box keeps it alive
/// for the app's lifetime.
@MainActor
final class GuardBox: ObservableObject {
    var guard_: TransferGuard?
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
