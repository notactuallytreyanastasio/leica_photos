import XCTest
import Photos
@testable import M10App

/// Integration tests against a REAL Photos library (the simulator's).
/// They verify the album/favorite behavior end-to-end:
///   import → Favorite set → “Best of Leica” + “RAW Leica” exist and contain it.
///
/// They auto-skip unless photo access is already granted, because the
/// system TCC prompt can’t be answered inside unit tests. To run them for
/// real on a simulator:
///   xcrun simctl privacy "iPhone 17 Pro" grant photos-add com.glmfunk.M10App
///   xcrun simctl privacy "iPhone 17 Pro" grant photos com.glmfunk.M10App
final class PhotoKitServiceTests: XCTestCase {

    private var photoAccessGranted: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func testImportSetsFavoriteAndFilesIntoAlbums() async throws {
        try XCTSkipUnless(photoAccessGranted,
            "Grant photo access on the simulator to run this for real " +
            "(see the doc comment on this class)")
        // a real JPEG so Photos accepts it
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let filename = "M10KitTest-\(Int(Date().timeIntervalSince1970)).jpg"

        // starred photo rules: Favorite + both albums
        let id = try await PhotoKitService.importPhoto(
            data: data, filename: filename, favorite: true,
            albums: ["Best of Leica", "RAW Leica"])

        // asset exists and is a Favorite
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        XCTAssertNotNil(asset, "asset should exist in the library")
        XCTAssertEqual(asset?.isFavorite, true, "starred import must be a Favorite")

        // both albums exist and contain the asset
        for title in ["Best of Leica", "RAW Leica"] {
            let collection = try XCTUnwrap(findAlbum(titled: title),
                                           "album “\(title)” should have been created")
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            XCTAssertGreaterThan(assets.count, 0,
                                 "album “\(title)” should contain the import")
        }
    }

    func testPlainJpegImportHasNoAlbum() async throws {
        try XCTSkipUnless(photoAccessGranted,
            "Grant photo access on the simulator to run this for real")

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        let image = renderer.image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let filename = "M10KitPlain-\(Int(Date().timeIntervalSince1970)).jpg"

        // plain JPEG rules: no favorite, no albums (library only)
        let id = try await PhotoKitService.importPhoto(
            data: data, filename: filename, favorite: false, albums: [])

        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.isFavorite, false)
    }

    func testAlbumRulesDerivation() {
        // starred DNG → both albums
        XCTAssertEqual(
            PhotoKitService.albums(favorite: true, filename: "L1003477.DNG", formatCode: 0x3802),
            ["Best of Leica", "RAW Leica"])
        // unstarred DNG → RAW only
        XCTAssertEqual(
            PhotoKitService.albums(favorite: false, filename: "L1003477.DNG", formatCode: 0x3802),
            ["RAW Leica"])
        // starred JPEG → Best of only
        XCTAssertEqual(
            PhotoKitService.albums(favorite: true, filename: "L1004471.JPG", formatCode: 0x3801),
            ["Best of Leica"])
        // plain JPEG → nothing
        XCTAssertEqual(
            PhotoKitService.albums(favorite: false, filename: "L1004471.JPG", formatCode: 0x3801),
            [])
    }

    private func findAlbum(titled title: String) -> PHAssetCollection? {
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        var found: PHAssetCollection?
        fetch.enumerateObjects { c, _, stop in
            if c.localizedTitle == title {
                found = c
                stop.pointee = true
            }
        }
        return found
    }
}
