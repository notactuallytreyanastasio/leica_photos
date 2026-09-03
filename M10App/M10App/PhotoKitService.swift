import Foundation
import Photos

/// Apple Photos integration.
///
/// Album rules (per the product owner):
/// - starred (xmp:Rating > 0) → Photos Favorite + "Best of Leica" album
/// - DNG → "RAW Leica" album (starred DNGs go in both)
/// - plain JPEGs land in the library without an album
///
/// No bulk anything: the M10's PTP/IP server can't take it. Transfers are
/// driven one at a time by the caller.
enum PhotoKitService {

    static let starredAlbum = "Best of Leica"
    static let rawAlbum = "RAW Leica"

    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Which albums a photo belongs in, per the rules above.
    static func albums(favorite: Bool, filename: String, formatCode: UInt16) -> [String] {
        var result: [String] = []
        if favorite { result.append(starredAlbum) }
        if filename.uppercased().hasSuffix(".DNG") || formatCode == 0x3802 {
            result.append(rawAlbum)
        }
        return result
    }

    /// Import image data into the Photos library, marked Favorite when
    /// starred, filed into the given albums (created if missing).
    /// - Returns the new asset's localIdentifier.
    @discardableResult
    static func importPhoto(data: Data, filename: String,
                            favorite: Bool, albums: [String]) async throws -> String {
        guard await requestAccess() else {
            throw PhotoKitError.notAuthorized
        }

        // phase 1: create the asset (favorite set at creation)
        var assetID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: .photo, data: data, options: options)
            request.isFavorite = favorite
            assetID = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = assetID else { throw PhotoKitError.importFailed }

        // phase 2: file it into albums (each created if missing)
        for album in albums {
            try await addToAlbum(assetID: id, album: album)
        }
        return id
    }

    private static func addToAlbum(assetID: String, album: String) async throws {
        let created = try await PHPhotoLibrary.shared().performChanges {
            // existing album?
            let fetch = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: nil)
            var existing: PHAssetCollection?
            fetch.enumerateObjects { c, _, stop in
                if c.localizedTitle == album {
                    existing = c
                    stop.pointee = true
                }
            }
            if existing == nil {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
            }
        }
        _ = created

        // fetch the (now certainly existing) album + the asset, add
        try await PHPhotoLibrary.shared().performChanges {
            let collFetch = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: nil)
            var collection: PHAssetCollection?
            collFetch.enumerateObjects { c, _, stop in
                if c.localizedTitle == album {
                    collection = c
                    stop.pointee = true
                }
            }
            guard let collection else { return }
            let assetFetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            guard let asset = assetFetch.firstObject else { return }
            PHAssetCollectionChangeRequest(for: collection)?
                .addAssets([asset] as NSArray)
        }
    }

    enum PhotoKitError: LocalizedError {
        case notAuthorized
        case importFailed
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Photos access was not granted."
            case .importFailed: return "Photos import failed."
            }
        }
    }
}
