import Foundation
import M10Kit

/// App-wide state machine + camera session owner.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published var phase: Phase = .disconnected
    @Published var cameraName: String = ""
    @Published var batteryPercent: Int = -1
    @Published var photos: [PhotoItem] = []
    @Published var starredOnly = false

    /// The camera session, when connected. All camera I/O goes through it
    /// with GentleClientRules enforced (first timeout aborts, session cap).
    private var session: M10Session?

    func connect() {
        phase = .connecting
        Task.detached(priority: .userInitiated) {
            do {
                // Discover the camera via Bonjour (_ptp._tcp) on the
                // camera's WiFi network.
                let endpoint = try await CameraDiscovery.findCamera()
                let session = M10Session(host: endpoint.host, port: endpoint.port)
                try session.connectAndOpenSession()

                let info = try session.deviceInfo()
                let battery = (try? session.batteryPercent()) ?? -1
                let handles = try session.objectHandles()

                await self.finishConnect(session: session, name: info.model,
                                         battery: battery, handles: handles)
            } catch {
                await self.failConnect(String(describing: error))
            }
        }
    }

    private func finishConnect(session: M10Session, name: String,
                               battery: Int, handles: [UInt32]) {
        self.session = session
        self.cameraName = name
        self.batteryPercent = battery
        // newest-first: photo handles ascend with capture order
        let photoHandles = handles.filter { $0 > 0x8190_0000 }.sorted(by: >)
        self.photos = photoHandles.map { PhotoItem(handle: $0) }
        self.phase = .connected
    }

    private func failConnect(_ message: String) {
        session?.close()
        session = nil
        phase = .failed(message)
    }

    func disconnect() {
        session?.close()
        session = nil
        photos = []
        phase = .disconnected
    }

    /// Fetch metadata for the next batch of visible photos (paging in
    /// newest-first order, gently paced by the session rules).
    func loadInfos(for items: [PhotoItem]) async {
        guard let session else { return }
        let unknown = items.filter { $0.info == nil }
        for item in unknown.prefix(30) {
            do {
                let info = try session.objectInfo(handle: item.handle)
                if let idx = photos.firstIndex(where: { $0.handle == item.handle }) {
                    photos[idx].info = info
                }
            } catch {
                // First failure aborts the session (camera fragility rule)
                failConnect("Camera stopped responding: \(error)")
                return
            }
        }
    }

    /// Fetch a thumbnail for one photo (called lazily by the grid).
    func thumbnail(for item: PhotoItem) async -> Data? {
        guard let session, item.thumb == nil else { return item.thumb }
        do {
            let data = try session.thumbnail(handle: item.handle)
            if let idx = photos.firstIndex(where: { $0.handle == item.handle }) {
                photos[idx].thumb = data
            }
            return data
        } catch {
            failConnect("Camera stopped responding: \(error)")
            return nil
        }
    }

    var visiblePhotos: [PhotoItem] {
        if starredOnly {
            // starred status is known only after download (xmp:Rating in
            // the file); with MTP object properties it can be pre-read.
            // For now: starred filter applies to downloaded photos.
            photos.filter { $0.isStarredKnown }
        } else {
            photos
        }
    }
}

/// One photo in the browser.
struct PhotoItem: Identifiable {
    let handle: UInt32
    var info: ObjectInfo?
    var thumb: Data?
    var isStarredKnown = false

    var id: UInt32 { handle }
}
