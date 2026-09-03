import Foundation
import UIKit
import M10Kit

/// App-wide state machine, camera session owner, and cache front-end.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case starred = "★"
        case jpeg = "JPEG"
        case dng = "DNG"
        var id: String { rawValue }
    }

    @Published var phase: Phase = .disconnected
    // camera info header
    @Published var cameraName: String = ""
    @Published var firmwareVersion: String = ""
    @Published var serialNumber: String = ""
    @Published var batteryPercent: Int = -1

    @Published var photos: [PhotoItem] = []
    @Published var filter: Filter = .all

    // download state (disk-backed via cache)
    @Published var downloadProgress: [UInt32: Double] = [:]
    @Published var fullPhotos: Set<UInt32> = []
    @Published var ratings: [UInt32: Int] = [:]
    @Published var savedToPhotos: Set<UInt32> = []

    // wifi join
    @Published var ssid: String = UserDefaults.standard.string(forKey: "m10.ssid") ?? ""
    @Published var wifiPassword: String = ""
    @Published var wifiStatus: String?

    // sequential starred import
    @Published var starredImportRunning = false
    @Published var starredImportMessage: String?

    // settings
    @Published var cacheUsage: (entries: Int, fulls: Int, thumbs: Int, bytes: Int)?
    @Published var showSettings = false

    private(set) var session: M10Session?
    private let cache = PhotoCache()

    private nonisolated static let sessionRules: GentleClientRules = {
        var r = GentleClientRules()
        r.maxSessionDuration = 600   // interactive session; still capped
        return r
    }()

    // MARK: - connect / disconnect

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
                await self.finishConnect(session: session, info: info,
                                         battery: battery, handles: handles)
            } catch {
                await self.failConnect(error)
            }
        }
    }

    private func finishConnect(session: M10Session, info: DeviceInfo,
                               battery: Int, handles: [UInt32]) async {
        self.session = session
        cameraName = info.model
        firmwareVersion = info.deviceVersion
        serialNumber = info.serial
        batteryPercent = battery

        let photoHandles = handles.filter { $0 > 0x8190_0000 }.sorted(by: >)
        // hydrate from disk cache — known photos cost the camera nothing
        let hydration = await cache.hydrate(handles: photoHandles)
        photos = photoHandles.map { h in
            let hy = hydration[h]
            let item = PhotoItem(handle: h)
            item.info = hy?.info
            item.thumb = nil   // thumbs load lazily from cache/camera
            if hy?.hasFull == true { fullPhotos.insert(h) }
            if let r = hy?.rating { ratings[h] = r }
            if hy?.saved == true { savedToPhotos.insert(h) }
            return item
        }
        phase = .connected
        await refreshCacheUsage()
        if experimentalPreread {
            await probeObjectProps()
        }
    }

    private func failConnect(_ error: Error) {
        session?.close()
        session = nil
        downloadProgress = [:]
        phase = .failed(Self.friendlyMessage(error))
    }

    static func friendlyMessage(_ error: Error) -> String {
        if let m10 = error as? M10Error {
            switch m10 {
            case .cameraUnreachable:
                return "Can't reach the camera. Check you're on its WiFi network, then try again."
            case .timeout:
                return "The camera stopped responding — it may need a rest. Cycle its WiFi and reconnect."
            case .sessionExpired:
                return "Session ended (camera safety cap). Reconnect to start a fresh session."
            case .cameraWedged:
                return "The camera's server is stuck. Turn its WiFi off and on, then reconnect."
            case .initFailed:
                return "The camera declined the connection. Is another device (FOTOS app) connected?"
            case .cameraErrorResponse, .unexpectedPacket, .parse:
                return "Camera communication hiccup: \(String(describing: m10))"
            }
        }
        if let d = error as? CameraDiscovery.DiscoveryError {
            return d.errorDescription ?? "No camera found."
        }
        return "Something went wrong: \(String(describing: error))"
    }

    func disconnect() {
        session?.close()
        session = nil
        photos = []
        downloadProgress = [:]
        fullPhotos = []
        ratings = [:]
        savedToPhotos = []
        phase = .disconnected
    }

    // MARK: - browsing (cache-first, paged)

    @Published var metadataLoading = false
    @Published var metadataLoadedCount = 0
    @Published var searchText = ""

    /// Load the next page of photo metadata (newest-first), 50 at a time,
    /// cache-first. Called by the browser as the user scrolls.
    func loadNextMetadataPage(count: Int = 50) async {
        guard !metadataLoading else { return }
        guard let session else { return }
        let unknown = photos.filter { $0.info == nil }
        guard !unknown.isEmpty else { return }
        metadataLoading = true
        defer { metadataLoading = false }

        for item in unknown.prefix(count) {
            do {
                let info = try session.objectInfo(handle: item.handle)
                if let idx = photos.firstIndex(where: { $0.handle == item.handle }) {
                    photos[idx].info = info
                }
                await cache.storeObjectInfo(info, rawData: info.rawData)
            } catch {
                failConnect(error)
                return
            }
        }
        metadataLoadedCount = photos.lazy.filter { $0.info != nil }.count
    }

    /// Single-photo metadata fetch (used by the detail view).
    func loadInfos(for items: [PhotoItem]) async {
        guard let session else { return }
        let unknown = items.filter { $0.info == nil }
        for item in unknown.prefix(30) {
            do {
                let info = try session.objectInfo(handle: item.handle)
                if let idx = photos.firstIndex(where: { $0.handle == item.handle }) {
                    photos[idx].info = info
                }
                await cache.storeObjectInfo(info, rawData: info.rawData)
            } catch {
                failConnect(error)
                return
            }
        }
        metadataLoadedCount = photos.lazy.filter { $0.info != nil }.count
    }

    func thumbnail(for item: PhotoItem) async -> Data? {
        if item.thumb != nil { return item.thumb }
        // disk cache first
        if let data = await cache.thumbnailData(for: item.handle) {
            if let idx = photos.firstIndex(where: { $0.handle == item.handle }) {
                photos[idx].thumb = data
            }
            return data
        }
        guard let session else { return nil }
        do {
            let data = try session.thumbnail(handle: item.handle)
            await cache.storeThumbnail(item.handle, data: data)
            if let idx = photos.firstIndex(where: { $0.handle == item.handle }) {
                photos[idx].thumb = data
            }
            return data
        } catch {
            failConnect(error)
            return nil
        }
    }

    // MARK: - download (cache-first)

    func downloadPhoto(_ handle: UInt32) async {
        guard session != nil, !fullPhotos.contains(handle),
              downloadProgress[handle] == nil else { return }

        // already on disk from a previous session?
        if let data = await cache.fullPhotoData(for: handle) {
            fullPhotos.insert(handle)
            ratings[handle] = XmpRating.extract(from: data) ?? 0
            await cache.setRating(handle, ratings[handle] ?? 0)
            Haptics.success()
            return
        }

        guard let session else { return }
        downloadProgress[handle] = 0
        let box = ProgressBox()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try session.download(handle: handle) { done, total in
                    box.update(done: done, total: total)
                }
                await self?.finishDownload(handle: handle, data: data)
            } catch {
                await self?.failConnect(error)
            }
        }
        while downloadProgress[handle] != nil {
            if let (done, total) = box.snapshot(), total > 0 {
                downloadProgress[handle] = Double(done) / Double(total)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishDownload(handle: UInt32, data: Data) async {
        await cache.storeFullPhoto(handle, data: data)
        let rating = XmpRating.extract(from: data) ?? 0
        await cache.setRating(handle, rating)
        fullPhotos.insert(handle)
        ratings[handle] = rating
        downloadProgress[handle] = nil
        Haptics.success()
    }

    /// Full photo bytes from disk cache (nil if not downloaded).
    func photoData(for handle: UInt32) async -> Data? {
        await cache.fullPhotoData(for: handle)
    }

    // MARK: - Apple Photos

    func albumNames(for handle: UInt32) -> [String] {
        guard let info = photos.first(where: { $0.handle == handle })?.info else { return [] }
        return PhotoKitService.albums(
            favorite: (ratings[handle] ?? 0) > 0,
            filename: info.filename,
            formatCode: info.formatCode)
    }

    func saveToPhotos(_ handle: UInt32) async {
        guard let data = await cache.fullPhotoData(for: handle),
              let info = photos.first(where: { $0.handle == handle })?.info else { return }
        let favorite = (ratings[handle] ?? 0) > 0
        let albums = PhotoKitService.albums(
            favorite: favorite, filename: info.filename, formatCode: info.formatCode)
        do {
            try await PhotoKitService.importPhoto(
                data: data, filename: info.filename,
                favorite: favorite, albums: albums)
            savedToPhotos.insert(handle)
            await cache.markSavedToPhotos(handle)
            Haptics.success()
        } catch {
            wifiStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Sequential importer for downloaded-and-starred photos. The M10
    /// can't do bulk — one at a time, stop on first failure, resumable.
    func saveStarredDownloaded() async {
        guard !starredImportRunning else { return }
        let pending = photos.map(\.handle).filter {
            (ratings[$0] ?? 0) > 0 && fullPhotos.contains($0) && !savedToPhotos.contains($0)
        }
        guard !pending.isEmpty else {
            starredImportMessage = "No starred downloads waiting — download photos first, then run this."
            return
        }
        starredImportRunning = true
        starredImportMessage = nil
        for handle in pending {
            starredImportMessage = "Saving \(pending.firstIndex(of: handle)! + 1) of \(pending.count)…"
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

    func joinCameraWiFi() async {
        guard !ssid.isEmpty else {
            wifiStatus = "Enter the camera's network name (shown on its screen)"
            return
        }
        // remember SSID; password goes in the keychain, not UserDefaults
        UserDefaults.standard.set(ssid, forKey: "m10.ssid")
        if wifiPassword.isEmpty {
            wifiPassword = Keychain.loadPassword(forSSID: ssid) ?? ""
        }
        do {
            try await WifiJoin.join(ssid: ssid,
                                    passphrase: wifiPassword.isEmpty ? nil : wifiPassword)
            Keychain.savePassword(wifiPassword, forSSID: ssid)
            wifiStatus = "Joined \(ssid)."
        } catch {
            wifiStatus = "Join failed: \(error.localizedDescription)"
        }
    }

    // MARK: - filters

    var visiblePhotos: [PhotoItem] {
        var list: [PhotoItem]
        switch filter {
        case .all:
            list = photos
        case .starred:
            list = photos.filter { (ratings[$0.handle] ?? 0) > 0 }
        case .jpeg:
            list = photos.filter { $0.info?.format == .exifJpeg }
        case .dng:
            list = photos.filter { $0.info?.format == .tiffDNG }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.info?.filename.localizedCaseInsensitiveContains(q) == true
            }
        }
        return list
    }

    // MARK: - settings / cache maintenance

    func refreshCacheUsage() async {
        cacheUsage = await cache.usage()
    }

    /// EXPERIMENTAL (hardware day): ask the newest photo which object
    /// properties the camera exposes — one query per session, logged for
    /// analysis in Settings. Groundwork for pre-download star ratings.
    @Published var experimentalPreread = UserDefaults.standard.bool(forKey: "m10.exp.preread") {
        didSet { UserDefaults.standard.set(experimentalPreread, forKey: "m10.exp.preread") }
    }
    @Published var discoveredObjectProps: [UInt16]?

    func probeObjectProps() async {
        guard let session, discoveredObjectProps == nil,
              let newest = photos.first else { return }
        do {
            let codes = try session.objectPropsSupported(handle: newest.handle)
            discoveredObjectProps = codes
        } catch {
            wifiStatus = "Property probe failed (harmless): \(String(describing: error))"
        }
    }

    func clearCache(keepMetadata: Bool) async {
        await cache.clear(keepMetadata: keepMetadata)
        if keepMetadata {
            // media dropped; metadata + status survive
        } else {
            fullPhotos = []
            ratings = [:]
            savedToPhotos = []
            for idx in photos.indices { photos[idx].thumb = nil }
        }
        await refreshCacheUsage()
        Haptics.success()
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

/// Impact feedback, kept in one place.
enum Haptics {
    static func success() {
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)
    }
}

/// One photo in the browser.
final class PhotoItem: Identifiable {
    let handle: UInt32
    var info: ObjectInfo?
    var thumb: Data?

    init(handle: UInt32, info: ObjectInfo? = nil, thumb: Data? = nil) {
        self.handle = handle
        self.info = info
        self.thumb = thumb
    }

    var id: UInt32 { handle }
}
