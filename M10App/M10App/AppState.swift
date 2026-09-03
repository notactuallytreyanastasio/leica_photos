import Foundation
import Photos
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

    // download state
    @Published var downloadProgress: [UInt32: Double] = [:]
    @Published var downloaded: [UInt32: Data] = [:]
    @Published var ratings: [UInt32: Int] = [:]
    @Published var savedToPhotos: Set<UInt32> = []

    // wifi join fields
    @Published var ssid: String = ""
    @Published var wifiPassword: String = ""
    @Published var wifiStatus: String?

    /// The camera session, when connected. All camera I/O goes through it
    /// with GentleClientRules enforced (first timeout aborts, session cap).
    private(set) var session: M10Session?

    private nonisolated static let sessionRules: GentleClientRules = {
        var r = GentleClientRules()
        // interactive browsing session: longer than the probe default,
        // still capped. First timeout always aborts regardless.
        r.maxSessionDuration = 600
        return r
    }()
    func connect() {
        phase = .connecting
        Task.detached(priority: .userInitiated) {
            do {
                let endpoint = try await CameraDiscovery.findCamera()
                let session = M10Session(host: endpoint.host, port: endpoint.port,
                                         rules: Self.sessionRules)
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
        downloadProgress = [:]   // unblock any UI progress pumps
        phase = .failed(message)
    }

    func disconnect() {
        session?.close()
        session = nil
        photos = []
        downloadProgress = [:]
        downloaded = [:]
        ratings = [:]
        savedToPhotos = []
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

    // MARK: - Download & rating

    /// Download the full photo from the camera. On completion the star
    /// rating (xmp:Rating in the file) is known.
    func downloadPhoto(_ handle: UInt32) async {
        guard let session, downloaded[handle] == nil else { return }
        downloadProgress[handle] = 0
        let box = ProgressBox()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try session.download(handle: handle) { done, total in
                    box.update(done: done, total: total)
                }
                await self?.finishDownload(handle: handle, data: data)
            } catch {
                await self?.failConnect("Download failed: \(error)")
            }
        }
        // pump progress to the UI while the transfer runs; the entry is
        // cleared on completion (or failure tears the session down)
        while downloadProgress[handle] != nil {
            if let (done, total) = box.snapshot(), total > 0 {
                downloadProgress[handle] = Double(done) / Double(total)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishDownload(handle: UInt32, data: Data) {
        downloaded[handle] = data
        ratings[handle] = XmpRating.extract(from: data) ?? 0
        downloadProgress[handle] = nil
    }

    // MARK: - Apple Photos

    /// Save a downloaded photo to Apple Photos. Album rules:
    /// starred → Favorite + "Best of Leica"; DNG → "RAW Leica".
    func saveToPhotos(_ handle: UInt32) async {
        guard let data = downloaded[handle],
              let info = photos.first(where: { $0.handle == handle })?.info else { return }
        let favorite = (ratings[handle] ?? 0) > 0
        let albums = PhotoKitService.albums(
            favorite: favorite, filename: info.filename,
            formatCode: info.formatCode)
        do {
            try await PhotoKitService.importPhoto(
                data: data, filename: info.filename,
                favorite: favorite, albums: albums)
            savedToPhotos.insert(handle)
        } catch {
            wifiStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Album names for a downloaded photo, per the product rules
    /// (starred → "Best of Leica", DNG → "RAW Leica").
    func albumNames(for handle: UInt32) -> [String] {
        guard let info = photos.first(where: { $0.handle == handle })?.info else { return [] }
        return PhotoKitService.albums(
            favorite: (ratings[handle] ?? 0) > 0,
            filename: info.filename,
            formatCode: info.formatCode)
    }

    /// Sequential importer for the downloaded-and-starred photos.
    /// The M10 can't do bulk (sessions wedge) — so: one at a time, stop on
    /// the first failure, resume where it left off. Not a bulk queue.
    @Published var starredImportRunning = false
    @Published var starredImportMessage: String?

    func saveStarredDownloaded() async {
        guard !starredImportRunning else { return }
        let pending = photos.map(\.handle).filter {
            (ratings[$0] ?? 0) > 0 && downloaded[$0] != nil && !savedToPhotos.contains($0)
        }
        guard !pending.isEmpty else {
            starredImportMessage = "No starred downloads waiting."
            return
        }
        starredImportRunning = true
        starredImportMessage = nil
        for handle in pending {
            starredImportMessage = "Saving \(pending.index(of: handle)! + 1) of \(pending.count)…"
            await saveToPhotos(handle)
            if !savedToPhotos.contains(handle) {
                starredImportMessage = "Stopped: \(wifiStatus ?? "save failed") — tap again to resume."
                starredImportRunning = false
                return
            }
        }
        starredImportMessage = "Saved \(pending.count) starred photos to “\(PhotoKitService.starredAlbum)”."
        starredImportRunning = false
    }

    // MARK: - WiFi join

    /// Join the camera's WiFi network via NEHotspotConfiguration
    /// (the GoPro-style in-app join prompt). Requires the Hotspot
    /// Configuration entitlement on a real device.
    func joinCameraWiFi() async {
        guard !ssid.isEmpty else {
            wifiStatus = "Enter the camera's network name (shown on its screen)"
            return
        }
        do {
            try await WifiJoin.join(ssid: ssid, passphrase: wifiPassword.isEmpty ? nil : wifiPassword)
            wifiStatus = "Joined \(ssid)."
        } catch {
            wifiStatus = "Join failed: \(error.localizedDescription)"
        }
    }

    var visiblePhotos: [PhotoItem] {
        if starredOnly {
            // starred status is known once downloaded (xmp:Rating in the
            // file); the MTP object-property path can pre-read it later.
            photos.filter { (ratings[$0.handle] ?? 0) > 0 }
        } else {
            photos
        }
    }
}

/// Thread-safe progress box: written from the session queue, read by UI.
private final class ProgressBox: @unchecked Sendable {
    private var done = 0
    private var total = 0
    private let lock = NSLock()

    func update(done d: Int, total t: Int) {
        lock.lock(); defer { lock.unlock() }
        done = d; total = t
    }

    func snapshot() -> (Int, Int)? {
        lock.lock(); defer { lock.unlock() }
        return total > 0 ? (done, total) : nil
    }
}

/// One photo in the browser.
struct PhotoItem: Identifiable {
    let handle: UInt32
    var info: ObjectInfo?
    var thumb: Data?

    var id: UInt32 { handle }
}
