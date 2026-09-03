import Foundation

/// PTP/IP packet types as spoken by the Leica M10 (ground truth: captured
/// working session, research/protocol-notes.md).
public enum PtpIpPacketType: UInt32, Sendable {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case initFail = 5
    case commandRequest = 6
    case commandResponse = 7
    case event = 8
    case startData = 9
    case data = 10
    case cancel = 11
    case endData = 12
    case ping = 13
}

/// A decoded PTP/IP packet: type + payload (header stripped).
public struct PtpIpPacket: Equatable, Sendable {
    public let type: PtpIpPacketType
    public let payload: Data

    public init(type: PtpIpPacketType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

/// Wire codec. Header is `[u32 length incl. 8B header][u32 type]`,
/// little-endian throughout.
public enum PtpIpCodec {

    /// Encode a full packet (header + payload).
    public static func encode(_ type: PtpIpPacketType, payload: Data = Data()) -> Data {
        var out = Data(capacity: 8 + payload.count)
        out.appendLE(UInt32(8 + payload.count))
        out.appendLE(type.rawValue)
        out.append(payload)
        return out
    }

    /// Encode a CmdRequest the way the M10 requires (learned the hard way):
    /// - dataphase is ALWAYS 0 (the camera blocks forever on 1)
    /// - ALWAYS all 5 param slots, zero-padded (38 bytes total)
    public static func commandRequest(
        opcode: UInt16, transactionID: UInt32, params: [UInt32]
    ) -> Data {
        precondition(params.count <= 5, "PTP allows at most 5 params")
        var payload = Data(capacity: 30)
        payload.appendLE(UInt32(0))                  // dataphase = 0, always
        payload.appendLE(opcode)
        payload.appendLE(transactionID)
        for i in 0..<5 {
            payload.appendLE(i < params.count ? params[i] : 0)
        }
        return encode(.commandRequest, payload: payload)
    }

    /// Parse a contiguous stream of packets. Stops at the first incomplete
    /// or malformed packet; returns what it decoded and the bytes consumed
    /// (so a transport can retain the remainder).
    public static func parsePackets(_ data: Data) -> (packets: [PtpIpPacket], consumed: Int) {
        var packets: [PtpIpPacket] = []
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 8 <= bytes.count {
            let length = UInt32(leBytes: bytes, at: offset)
            let typeRaw = UInt32(leBytes: bytes, at: offset + 4)
            guard length >= 8, Int(length) + offset <= bytes.count,
                  let type = PtpIpPacketType(rawValue: typeRaw) else { break }
            let payload = data.subdata(in: (offset + 8)..<(offset + Int(length)))
            packets.append(PtpIpPacket(type: type, payload: payload))
            offset += Int(length)
        }
        return (packets, offset)
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xff)); append(UInt8(v >> 8))
    }
    mutating func appendLE(_ v: UInt32) {
        for i in 0..<4 { append(UInt8((v >> (8 * i)) & 0xff)) }
    }
}

public struct LEReader {
    let bytes: [UInt8]
    public var offset: Int = 0
    public var remaining: Int { bytes.count - offset }

    public init(_ data: Data) { bytes = [UInt8](data) }

    public mutating func u8() throws -> UInt8 {
        guard offset + 1 <= bytes.count else { throw ParseError.eof }
        defer { offset += 1 }
        return bytes[offset]
    }
    public mutating func u16() throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw ParseError.eof }
        defer { offset += 2 }
        return UInt16(leBytes: bytes, at: offset)
    }
    public mutating func u32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw ParseError.eof }
        defer { offset += 4 }
        return UInt32(leBytes: bytes, at: offset)
    }
    public mutating func u64() throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw ParseError.eof }
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
        return v
    }
    /// PTP/IP string: u8 length (UTF-16 code units incl. NUL) + UTF-16LE.
    public mutating func ptpString() throws -> String {
        let n = Int(try u8())
        guard offset + 2 * n <= bytes.count else { throw ParseError.eof }
        defer { offset += 2 * n }
        let units = bytes[offset..<offset + 2 * n]
        return Self.decodeUnitsUpToNUL(units)
    }

    /// NUL-terminated UTF-16LE (used in InitCommandAck / InitCommandRequest).
    public mutating func utf16z() throws -> String {
        var i = offset
        while i + 1 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 { break }
            i += 2
        }
        defer { offset = min(i + 2, bytes.count) }
        return Self.decodeUnitsUpToNUL(bytes[offset..<min(i, bytes.count)])
    }

    private static func decodeUnitsUpToNUL(_ units: ArraySlice<UInt8>) -> String {
        var s = ""
        var i = units.startIndex
        while i + 1 < units.endIndex {
            let unit = UInt16(units[i]) | (UInt16(units[i + 1]) << 8)
            if unit == 0 { break }
            if let scalar = UnicodeScalar(unit) { s.append(Character(scalar)) }
            i += 2
        }
        return s
    }

    public enum ParseError: Error { case eof, malformed(String) }
}

extension UInt16 {
    init(leBytes b: [UInt8], at off: Int) {
        self = UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
    }
}
extension UInt32 {
    init(leBytes b: [UInt8], at off: Int) {
        self = UInt32(b[off]) | (UInt32(b[off + 1]) << 8)
            | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }
}
