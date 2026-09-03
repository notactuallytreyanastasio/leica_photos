import XCTest
@testable import M10Kit

/// Byte-exact validation against fixtures extracted from the real M10
/// capture (research/leica_capture2.pcap, Leica Sync working session).
/// If these tests pass, the Swift client speaks the camera's language.
final class CodecGroundTruthTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name.replacingOccurrences(of: ".bin", with: ""),
                                    withExtension: "bin", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    // MARK: command encoding — must match Leica Sync byte-for-byte

    func testOpenSessionMatchesLeicaSyncBytes() throws {
        let expected = try fixture("cmd_open_session.bin")
        let encoded = PtpIpCodec.commandRequest(
            opcode: PtpOpcode.openSession, transactionID: 1, params: [0xFFFF])
        XCTAssertEqual(encoded, expected,
                       "OpenSession encoding must match the captured working client")
    }

    func testLeOpenSessionMatchesLeicaSyncBytes() throws {
        let expected = try fixture("cmd_le_open_session.bin")
        let encoded = PtpIpCodec.commandRequest(
            opcode: PtpOpcode.leOpenSession, transactionID: 2, params: [0xFF55])
        XCTAssertEqual(encoded, expected,
                       "LE vendor OpenSession encoding must match the capture")
    }

    func testCommandRequestAlwaysFiveParamSlots() {
        let one = PtpIpCodec.commandRequest(opcode: 0x1002, transactionID: 1, params: [0xFFFF])
        XCTAssertEqual(one.count, 38, "the M10 requires the full 38-byte command form")
        let zero = PtpIpCodec.commandRequest(opcode: 0x1003, transactionID: 2, params: [])
        XCTAssertEqual(zero.count, 38)
    }

    // MARK: packet decode

    func testParseInitCommandAck() throws {
        let raw = try fixture("init_command_ack.bin")
        let (packets, consumed) = PtpIpCodec.parsePackets(raw)
        XCTAssertEqual(consumed, raw.count)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].type, .initCommandAck)
        var r = LEReader(packets[0].payload)
        XCTAssertEqual(try r.u32(), 1, "connection number")
        _ = try r.u32(); _ = try r.u32(); _ = try r.u32(); _ = try r.u32() // GUID (zeros)
        // NOTE: InitCommandAck name is NUL-terminated UTF-16 (no length prefix)
        XCTAssertEqual(try r.utf16z(), "LEICA M10")
        // trailing version bytes follow — tolerated
    }

    func testParsePacketsAcrossStream() throws {
        let ack = try fixture("init_command_ack.bin")
        let open = try fixture("cmd_open_session.bin")
        let stream = ack + open
        let (packets, consumed) = PtpIpCodec.parsePackets(stream)
        XCTAssertEqual(consumed, stream.count)
        XCTAssertEqual(packets.map(\.type), [.initCommandAck, .commandRequest])
        // partial trailing bytes are retained, not lost
        let (partial, consumed2) = PtpIpCodec.parsePackets(stream + Data([0x26, 0x00]))
        XCTAssertEqual(consumed2, stream.count)
        XCTAssertEqual(partial.count, 2)
    }

    // MARK: DeviceInfo — the PTP/IP variant layout

    func testDeviceInfoFromRealCamera() throws {
        let blob = try fixture("deviceinfo.bin")
        let info = try DeviceInfo(data: blob)
        XCTAssertEqual(info.manufacturer, "Leica Camera AG")
        XCTAssertEqual(info.model, "LEICA M10")
        XCTAssertTrue(info.serial.hasSuffix("5230856"), "serial \(info.serial)")
        XCTAssertEqual(info.operations.count, 48)
        XCTAssertEqual(info.deviceProps.count, 159)
        XCTAssertTrue(info.supports(opcode: PtpOpcode.getObject))
        XCTAssertTrue(info.supports(opcode: PtpOpcode.getObjectHandles))
        XCTAssertTrue(info.supports(opcode: PtpOpcode.getThumb))
        XCTAssertTrue(info.supports(opcode: PtpOpcode.leOpenSession))
        XCTAssertTrue(info.supports(opcode: PtpOpcode.getObjectPropValue),
                      "MTP object properties are the star-rating path")
    }

    // MARK: ObjectHandles

    func testObjectHandlesFromRealCamera() throws {
        let blob = try fixture("objecthandles.bin")
        var r = LEReader(blob)
        let n = try r.u32()
        XCTAssertEqual(n, 1521, "object count observed in the capture (6088B = 4 + 1521×4)")
        let handles = try (0..<n).map { _ in try r.u32() }
        XCTAssertEqual(handles.first, 0x8000_0000, "root object first")
        XCTAssertEqual(handles.last, 0x8190_D951, "newest photo at browse time (= L1003477.DNG, the photo the user downloaded)")
        // photo handles increment by 0x10 with capture order (gaps = deleted photos)
        let photos = handles.filter { $0 > 0x8190_0000 }
        if photos.count >= 2, photos[1] >= photos[0] {
            XCTAssertEqual(photos[1] - photos[0], 0x10)
        }
    }

    // MARK: ObjectInfo

    func testObjectInfoFromRealCamera() throws {
        let blob = try fixture("photo_objinfo.bin")
        let info = try ObjectInfo(data: blob, handle: 0x8190_D951)
        XCTAssertEqual(info.filename, "L1003477.DNG")
        XCTAssertEqual(info.format, .tiffDNG)
        XCTAssertTrue(info.isPhoto)
        XCTAssertEqual(info.size, 30_098_944)
        XCTAssertEqual(info.pixels.w, 5984)
        XCTAssertEqual(info.pixels.h, 3992)
        XCTAssertEqual(info.captured, "20260820T181641.0")
        XCTAssertEqual(info.parent, 0x8190_0000)
    }

    // MARK: XMP rating — the star mechanism

    func testXmpRatingUnstarred() throws {
        let xmp = try fixture("xmp_unstarred.bin")
        XCTAssertEqual(XmpRating.extract(from: xmp), 0)
        XCTAssertFalse(XmpRating.isStarred(xmp))
    }

    func testXmpRatingStarred() throws {
        let xmp = try fixture("xmp_starred.bin")
        XCTAssertEqual(XmpRating.extract(from: xmp), 5)
        XCTAssertTrue(XmpRating.isStarred(xmp))
    }

    func testXmpRatingAbsent() {
        XCTAssertNil(XmpRating.extract(from: Data("no rating here".utf8)))
    }
}
