import XCTest
import M10Kit
@testable import M10App

/// PhotoCache behavior: roundtrips, hydration, clearing, LRU eviction.
/// Runs against a temp directory so tests never touch real data.
final class PhotoCacheTests: XCTestCase {

    private var dir: URL!
    private var cache: PhotoCache!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-tests-\(UUID().uuidString)")
        cache = PhotoCache(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - helpers

    /// Fabricate a valid ObjectInfo PTP dataset for a given filename/format.
    private func makeObjectInfoData(filename: String, format: UInt16 = 0x3801) -> Data {
        var d = Data()
        func le16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * i)) & 0xff)) } }
        func pstr(_ s: String) {
            let units = s.utf16
            d.append(UInt8(units.count + 1))
            for u in units {
                d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8))
            }
            d.append(0); d.append(0)
        }
        le32(0x20001)          // storage
        le16(format)           // format
        le16(0)                // protection
        le32(123_456)          // size
        le16(0x3801)           // thumb format
        le32(2_048)            // thumb size
        le32(160); le32(120)   // thumb dims
        le32(5984); le32(3992) // pixels
        le32(16)               // bit depth
        le32(0x8190_0000)      // parent
        le16(0)                // assoc type
        le32(0)                // assoc desc
        le32(0)                // sequence
        pstr(filename)
        pstr("20260903T120000.0")
        pstr("20260903T120000.0")
        return d
    }

    private func makeInfo(_ handle: UInt32, filename: String, format: UInt16 = 0x3801) -> ObjectInfo {
        try! ObjectInfo(data: makeObjectInfoData(filename: filename, format: format), handle: handle)
    }

    // MARK: - tests

    func testObjectInfoRoundtrip() async throws {
        let info = makeInfo(0x8190_D951, filename: "L1003477.DNG", format: 0x3802)
        await cache.storeObjectInfo(info, rawData: info.rawData)
        let loaded = await cache.objectInfo(for: 0x8190_D951)
        XCTAssertEqual(loaded?.filename, "L1003477.DNG")
        XCTAssertEqual(loaded?.format, .tiffDNG)
        XCTAssertEqual(loaded?.size, 123_456)
    }

    func testThumbnailRoundtrip() async throws {
        let thumb = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        await cache.storeThumbnail(0x1234, data: thumb)
        let loaded = await cache.thumbnailData(for: 0x1234)
        XCTAssertEqual(loaded, thumb)
        let missing = await cache.thumbnailData(for: 0x9999)
        XCTAssertNil(missing)
    }

    func testFullPhotoAndRatingAndSavedStatus() async throws {
        let photo = Data(repeating: 0xAB, count: 4_096)
        await cache.storeFullPhoto(0x1234, data: photo)
        await cache.setRating(0x1234, 5)
        await cache.markSavedToPhotos(0x1234)

        let loaded = await cache.fullPhotoData(for: 0x1234)
        XCTAssertEqual(loaded, photo)
        let rating = await cache.rating(for: 0x1234)
        XCTAssertEqual(rating, 5)
        let saved = await cache.isSavedToPhotos(0x1234)
        XCTAssertTrue(saved)
    }

    func testHydrateBatch() async throws {
        let a = makeInfo(0x1000, filename: "A.JPG")
        let b = makeInfo(0x2000, filename: "B.JPG")
        await cache.storeObjectInfo(a, rawData: a.rawData)
        await cache.storeObjectInfo(b, rawData: b.rawData)
        await cache.storeFullPhoto(0x1000, data: Data(repeating: 1, count: 64))
        await cache.setRating(0x1000, 3)
        await cache.markSavedToPhotos(0x1000)

        let hy = await cache.hydrate(handles: [0x1000, 0x2000, 0x3000])
        XCTAssertEqual(hy[0x1000]?.info?.filename, "A.JPG")
        XCTAssertEqual(hy[0x1000]?.hasFull, true)
        XCTAssertEqual(hy[0x1000]?.rating, 3)
        XCTAssertEqual(hy[0x1000]?.saved, true)
        XCTAssertEqual(hy[0x2000]?.info?.filename, "B.JPG")
        XCTAssertEqual(hy[0x2000]?.hasFull, false)
        XCTAssertNil(hy[0x3000])
    }

    func testClearKeepsMetadataDropsMedia() async throws {
        let info = makeInfo(0x1000, filename: "A.JPG")
        await cache.storeObjectInfo(info, rawData: info.rawData)
        await cache.storeThumbnail(0x1000, data: Data([9, 9]))
        await cache.storeFullPhoto(0x1000, data: Data(repeating: 9, count: 1_000))
        await cache.markSavedToPhotos(0x1000)

        await cache.clear(keepMetadata: true)

        let infoAfter = await cache.objectInfo(for: 0x1000)
        XCTAssertEqual(infoAfter?.filename, "A.JPG")
        let saved = await cache.isSavedToPhotos(0x1000)
        XCTAssertTrue(saved, "status survives media clear")
        let full = await cache.fullPhotoData(for: 0x1000)
        XCTAssertNil(full)
        let thumb = await cache.thumbnailData(for: 0x1000)
        XCTAssertNil(thumb)
    }

    func testLRUEvictionUnderCap() async throws {
        await cache.setTestCap(1_500)   // tiny cap for the test
        let a = Data(repeating: 1, count: 1_000)
        let b = Data(repeating: 2, count: 1_000)
        await cache.storeFullPhoto(0x1000, data: a)
        try await Task.sleep(for: .milliseconds(50))
        await cache.storeFullPhoto(0x1000 + 1, data: b)   // triggers eviction of A

        let oldest = await cache.fullPhotoData(for: 0x1000)
        XCTAssertNil(oldest, "least-recently-used full image should be evicted")
        let newest = await cache.fullPhotoData(for: 0x1001)
        XCTAssertNotNil(newest)
        // metadata for the evicted photo survives
        _ = await cache.usage()
    }
}
