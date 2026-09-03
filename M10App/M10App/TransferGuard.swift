import UIKit
import Combine

/// Keeps transfers alive across screen-off / backgrounding, within iOS's
/// rules (there is no background mode for long network transfers — GoPro's
/// app lives with the same constraint):
///
/// 1. While a transfer is active in the foreground, the screen will not
///    auto-lock — a 30MB DNG over the M10's slow WiFi can take minutes,
///    and an accidental lock would suspend the app mid-transfer, hitting
///    the camera with an unclean disconnect (the wedge scenario).
/// 2. If the app is backgrounded/locked anyway, a background task buys
///    iOS's ~30s grace so small transfers can finish.
/// 3. If the grace expires mid-transfer, we CLOSE THE SESSION POLITELY
///    (CloseSession + FIN) instead of letting iOS suspend us mid-write.
///    The camera stays healthy; the user reconnects and resumes — with
///    the cache, almost nothing is lost.
@MainActor
final class TransferGuard: ObservableObject {

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellable: AnyCancellable?
    private weak var appState: AppState?

    nonisolated init() {}

    func attach(to appState: AppState) {
        self.appState = appState

        // idle timer follows transfer activity (MainActor via receive)
        cancellable = appState.$hasActiveTransfer
            .receive(on: DispatchQueue.main)
            .sink { active in
                UIApplication.shared.isIdleTimerDisabled = active
            }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func didEnterBackground() {
        MainActor.assumeIsolated {
            guard let appState, appState.hasActiveTransfer else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "m10-transfer") {
                Task { @MainActor in
                    await appState.backgroundGraceExpired()
                    self.endBackgroundTask()
                }
            }
        }
    }

    @objc private func willEnterForeground() {
        MainActor.assumeIsolated {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
