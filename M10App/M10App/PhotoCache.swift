import Foundation
import M10Kit

/// Disk cache for everything fetched from the camera, keyed by object
/// handle (stable for a given photo while it exists on the card).
///
/// What's cached and why:
/// - ObjectInfo datasets (~154 B each): re-browsing skips the per-photo
///   metadata queries — 1,500 queries become zero for known photos
/// - thumbnails (~12 KB): the bulk of browsing cost; instant from disk
/// - full downloads (DNGs up to ~30 MB): LRU-evicted at a size cap
/// - star rating + saved-to-Photos status: so imports never repeat
///
/// Everything lives under Documents/PhotoCache; the index is a single
/// JSON file, blobs are `<handle>.img` / `<handle>.thumb`.
actor PhotoCache {

    struct Entry: Codable {
        var handle: UInt32
        var objectInfoData: Data?
        var rating: Int?           // nil = not yet known (needs the file)
        var savedToPhotos = false
        var hasFull = false
        var hasThumb = false
        var filename: String?
        var lastAccess: Date
    }

    private(set) var entries: [UInt32: Entry] = [:]
    private let directory: URL
    private let indexURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Soft cap on stored full-size files. Thumbnails and metadata are
    /// tiny and are never evicted.
    var maxFullBytes: Int = 1_000_000_000

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoCache", isDirectory: true)
        self.directory = base
        self.indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let loaded = try? decoder.decode([String: Entry].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: loaded.map { (UInt32($0.key) ?? 0, $0.value) })
        }
    }

    private func saveIndex() {
        let asStrings = Dictionary(uniqueKeysWithValues: entries.map { (String($0.key), $0.value) })
        if let data = try? encoder.encode(asStrings) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func imageURL(_ handle: UInt32) -> URL {
        directory.appendingPathComponent("\(handle).img")
    }

    private func thumbURL(_ handle: UInt32) -> URL {
        directory.appendingPathComponent("\(handle).thumb")
    }

    // MARK: - metadata

    func objectInfo(for handle: UInt32) -> ObjectInfo? {
        guard let data = entry(handle)?.objectInfoData else { return nil }
        noteAccess(handle)
        return try? ObjectInfo(data: data, handle: handle)
    }

    func storeObjectInfo(_ info: ObjectInfo, rawData: Data) {
        mutateEntry(info.handle) {
            $0.objectInfoData = rawData
            $0.filename = info.filename
        }
        saveIndex()
    }

    // MARK: - thumbnails

    func thumbnailData(for handle: UInt32) -> Data? {
        guard entries[handle]?.hasThumb == true else { return nil }
        noteAccess(handle)
        return try? Data(contentsOf: thumbURL(handle))
    }

    func storeThumbnail(_ handle: UInt32, data: Data) {
        try? data.write(to: thumbURL(handle), options: .atomic)
        mutateEntry(handle) { $0.hasThumb = true }
        noteAccess(handle)
        saveIndex()
    }

    // MARK: - full downloads

    func fullPhotoURL(for handle: UInt32) -> URL? {
        guard entries[handle]?.hasFull == true else { return nil }
        noteAccess(handle)
        let url = imageURL(handle)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fullPhotoData(for handle: UInt32) -> Data? {
        fullPhotoURL(for: handle).flatMap { try? Data(contentsOf: $0) }
    }

    func storeFullPhoto(_ handle: UInt32, data: Data) {
        try? data.write(to: imageURL(handle), options: .atomic)
        mutateEntry(handle) { $0.hasFull = true }
        noteAccess(handle)
        evictIfNeeded()
        saveIndex()
    }

    // MARK: - status

    func rating(for handle: UInt32) -> Int? {
        entry(handle)?.rating
    }

    func setRating(_ handle: UInt32, _ rating: Int) {
        mutateEntry(handle) { $0.rating = rating }
        saveIndex()
    }

    func isSavedToPhotos(_ handle: UInt32) -> Bool {
        entries[handle]?.savedToPhotos ?? false
    }

    func markSavedToPhotos(_ handle: UInt32) {
        mutateEntry(handle) { $0.savedToPhotos = true }
        saveIndex()
    }

    // MARK: - batch hydration (one actor hop for a whole session's photos)

    struct Hydration: Sendable {
        public var info: ObjectInfo?
        public var hasFull: Bool
        public var rating: Int?
        public var saved: Bool
    }

    func hydrate(handles: [UInt32]) -> [UInt32: Hydration] {
        var out: [UInt32: Hydration] = [:]
        for h in handles {
            guard let e = entries[h] else { continue }
            out[h] = Hydration(
                info: e.objectInfoData.flatMap { try? ObjectInfo(data: $0, handle: h) },
                hasFull: e.hasFull && FileManager.default.fileExists(atPath: imageURL(h).path),
                rating: e.rating,
                saved: e.savedToPhotos)
        }
        return out
    }

    // MARK: - housekeeping

    func usage() -> (entries: Int, fulls: Int, thumbs: Int, bytes: Int) {
        let fulls = entries.filter(\.value.hasFull)
        let thumbs = entries.filter(\.value.hasThumb)
        let fullBytes = fulls.reduce(0) { $0 + fileSize(imageURL($1.key)) }
        let thumbBytes = thumbs.reduce(0) { $0 + fileSize(thumbURL($1.key)) }
        return (entries.count, fulls.count, thumbs.count, fullBytes + thumbBytes)
    }

    func clear(keepMetadata: Bool) {
        for (h, e) in entries {
            if !keepMetadata {
                try? FileManager.default.removeItem(at: thumbURL(h))
                entries[h] = nil
            } else {
                // keep ObjectInfo + status; drop the heavy media
                try? FileManager.default.removeItem(at: imageURL(h))
                try? FileManager.default.removeItem(at: thumbURL(h))
                entries[h]?.hasFull = false
                entries[h]?.hasThumb = false
            }
        }
        saveIndex()
    }

    // MARK: - eviction (full images only, LRU)

    private func noteAccess(_ handle: UInt32) {
        mutateEntry(handle) { $0.lastAccess = Date() }
    }

    private func evictIfNeeded() {
        var total = entries.filter(\.value.hasFull)
            .reduce(0) { $0 + fileSize(imageURL($1.key)) }
        guard total > maxFullBytes else { return }
        // evict least-recently-used full images until under cap
        let byAge = entries.filter { $0.value.hasFull }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (handle, _) in byAge {
            guard total > maxFullBytes else { break }
            let url = imageURL(handle)
            total -= fileSize(url)
            try? FileManager.default.removeItem(at: url)
            entries[handle]?.hasFull = false
        }
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }

    // MARK: - entry access helpers

    private func entry(_ handle: UInt32) -> Entry? {
        entries[handle]
    }

    private func mutateEntry(_ handle: UInt32, _ body: (inout Entry) -> Void) {
        var e = entries[handle] ?? Entry(handle: handle, lastAccess: Date())
        body(&e)
        entries[handle] = e
    }
}
