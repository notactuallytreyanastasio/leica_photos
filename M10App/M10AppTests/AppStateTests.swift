import XCTest
import M10Kit
@testable import M10App

/// AppState logic: filters, friendly error copy, disconnect teardown.
@MainActor
final class AppStateTests: XCTestCase {

    private func item(_ handle: UInt32, format: ObjectFormat?) -> PhotoItem {
        let it = PhotoItem(handle: handle)
        if let format {
            // fabricate minimal info with the given format
            var d = Data()
            func le16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
            func le32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * i)) & 0xff)) } }
            func pstr(_ s: String) {
                let units = s.utf16
                d.append(UInt8(units.count + 1))
                for u in units { d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8)) }
                d.append(0); d.append(0)
            }
            le32(0x20001); le16(format.rawValue); le16(0); le32(1_000)
            le16(0x3801); le32(2_000); le32(160); le32(120)
            le32(5984); le32(3992); le32(16); le32(0)
            le16(0); le32(0); le32(0)
            pstr("X.JPG"); pstr("20260903T120000.0"); pstr("20260903T120000.0")
            it.info = try! ObjectInfo(data: d, handle: handle)
        }
        return it
    }

    func testInitialPhaseDisconnected() {
        let state = AppState()
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertTrue(state.photos.isEmpty)
        XCTAssertEqual(state.filter, .all)
    }

    func testFilters() {
        let state = AppState()
        state.photos = [
            item(1, format: .exifJpeg),
            item(2, format: .tiffDNG),
            item(3, format: .exifJpeg),
        ]
        state.ratings = [1: 0, 2: 5, 3: 1]

        state.filter = .all
        XCTAssertEqual(state.visiblePhotos.count, 3)
        state.filter = .starred
        XCTAssertEqual(state.visiblePhotos.map(\.handle), [2, 3])
        state.filter = .jpeg
        XCTAssertEqual(state.visiblePhotos.map(\.handle), [1, 3])
        state.filter = .dng
        XCTAssertEqual(state.visiblePhotos.map(\.handle), [2])
    }

    func testFriendlyErrorCopy() {
        XCTAssertEqual(
            AppState.friendlyMessage(M10Error.timeout(opcode: 0x1002)).contains("rest"), true)
        XCTAssertEqual(
            AppState.friendlyMessage(M10Error.sessionExpired).contains("Reconnect"), true)
        XCTAssertEqual(
            AppState.friendlyMessage(M10Error.cameraUnreachable("x")).contains("WiFi"), true)
        XCTAssertEqual(
            AppState.friendlyMessage(M10Error.initFailed(reason: 3)).contains("FOTOS"), true)
    }

    func testDisconnectClearsEverything() {
        let state = AppState()
        state.photos = [item(1, format: .exifJpeg)]
        state.ratings = [1: 5]
        state.fullPhotos = [1]
        state.savedToPhotos = [1]
        state.downloadProgress = [1: 0.5]

        state.disconnect()

        XCTAssertTrue(state.photos.isEmpty)
        XCTAssertTrue(state.ratings.isEmpty)
        XCTAssertTrue(state.fullPhotos.isEmpty)
        XCTAssertTrue(state.savedToPhotos.isEmpty)
        XCTAssertTrue(state.downloadProgress.isEmpty)
        XCTAssertEqual(state.phase, .disconnected)
    }

    func testAlbumNamesFollowProductRules() {
        let state = AppState()
        state.photos = [
            item(0x8190_D951, format: .tiffDNG),   // L1003477.DNG
        ]
        state.photos[0].info = nil
        // fabricate DNG-named info via cache-style data
        var d = Data()
        func le16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * i)) & 0xff)) } }
        func pstr(_ s: String) {
            let units = s.utf16
            d.append(UInt8(units.count + 1))
            for u in units { d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8)) }
            d.append(0); d.append(0)
        }
        le32(0x20001); le16(0x3802); le16(0); le32(30_098_944)
        le16(0x3801); le32(12_674); le32(160); le32(120)
        le32(5984); le32(3992); le32(16); le32(0x8190_0000)
        le16(0); le32(0); le32(0)
        pstr("L1003477.DNG"); pstr("20260820T181641.0"); pstr("20260820T181641.0")
        state.photos[0].info = try! ObjectInfo(data: d, handle: 0x8190_D951)

        state.ratings = [0x8190_D951: 0]
        XCTAssertEqual(state.albumNames(for: 0x8190_D951), ["RAW Leica"])
        state.ratings = [0x8190_D951: 5]
        XCTAssertEqual(state.albumNames(for: 0x8190_D951), ["Best of Leica", "RAW Leica"])
    }
}

/// WifiJoin on the simulator reports unsupported instead of crashing.
final class WifiJoinTests: XCTestCase {
    func testSimulatorJoinIsUnsupported() async {
        #if targetEnvironment(simulator)
        do {
            try await WifiJoin.join(ssid: "LeicaM10-Test", passphrase: "12345678")
            XCTFail("should throw on simulator")
        } catch {
            // expected
        }
        #else
        throw XCTSkip("device-only behavior")
        #endif
    }
}

/// Transfer-state machine for screen-lock protection.
@MainActor
final class TransferStateTests: XCTestCase {
    func testActiveTransferTracksDownloadsAndImports() {
        let state = AppState()
        XCTAssertFalse(state.hasActiveTransfer)

        state.downloadProgress = [1: 0.4]
        state.refreshActiveTransfer()
        XCTAssertTrue(state.hasActiveTransfer, "download in flight = active transfer")

        state.downloadProgress = [:]
        state.starredImportRunning = true
        state.refreshActiveTransfer()
        XCTAssertTrue(state.hasActiveTransfer, "starred import = active transfer")

        state.starredImportRunning = false
        state.refreshActiveTransfer()
        XCTAssertFalse(state.hasActiveTransfer)
    }

    func testBackgroundGraceExpiredFailsCleanlyWhenTransferring() async {
        let state = AppState()
        // not transferring: no-op
        await state.backgroundGraceExpired()
        XCTAssertEqual(state.phase, .disconnected)

        // transferring but no session (synthetic state): transfer state is
        // cleared, nothing to fail — phase unchanged
        state.downloadProgress = [1: 0.5]
        state.refreshActiveTransfer()
        await state.backgroundGraceExpired()
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertFalse(state.hasActiveTransfer, "grace expiry clears transfer state")
        XCTAssertTrue(state.downloadProgress.isEmpty, "progress pumps unblocked")
    }
}
