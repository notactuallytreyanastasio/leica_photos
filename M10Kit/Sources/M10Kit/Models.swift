import Foundation

/// PTP operation codes the M10 supports (ground truth from DeviceInfo).
public enum PtpOpcode {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getStorageIDs: UInt16 = 0x1004
    public static let getNumObjects: UInt16 = 0x1006
    public static let getObjectHandles: UInt16 = 0x1007
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let getThumb: UInt16 = 0x100A
    public static let getDevicePropValue: UInt16 = 0x1015
    // MTP object properties — the metadata/rating path
    public static let getObjectPropsSupported: UInt16 = 0x9801
    public static let getObjectPropValue: UInt16 = 0x9803
    public static let getObjectPropList: UInt16 = 0x9805
    // Leica vendor
    public static let leOpenSession: UInt16 = 0x9005
    public static let leCloseSession: UInt16 = 0x9006
}

public enum PtpResponseCode: UInt16 {
    case ok = 0x2001
    case generalError = 0x2002
    case sessionNotOpen = 0x2003
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case deviceBusy = 0x2013
}

/// Object formats seen on the M10.
public enum ObjectFormat: UInt16, Sendable {
    case association = 0x3001
    case exifJpeg = 0x3801
    case tiffDNG = 0x3802
    case rawB000 = 0xB000
    case unknown = 0

    public var displayName: String {
        switch self {
        case .association: return "folder"
        case .exifJpeg: return "JPEG"
        case .tiffDNG: return "DNG"
        case .rawB000: return "RAW"
        case .unknown: return "?"
        }
    }

    public var isPhoto: Bool {
        switch self {
        case .exifJpeg, .tiffDNG, .rawB000: return true
        default: return false
        }
    }
}

/// DeviceInfo — NOTE: the PTP/IP variant the M10 serves differs from USB:
/// u32 array counts, u8-prefixed UTF-16 strings, 11-byte fixed header.
public struct DeviceInfo: Equatable, Sendable {
    public var standardVersion: UInt16
    public var vendorExtensionID: UInt32
    public var vendorExtensionVersion: UInt16
    public var vendorExtensionDesc: String
    public var functionalMode: UInt16
    public var operations: [UInt16]
    public var events: [UInt16]
    public var deviceProps: [UInt16]
    public var captureFormats: [UInt16]
    public var imageFormats: [UInt16]
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serial: String

    public init(data: Data) throws {
        var r = LEReader(data)
        standardVersion = try r.u16()
        vendorExtensionID = try r.u32()
        vendorExtensionVersion = try r.u16()
        vendorExtensionDesc = try r.ptpString()
        functionalMode = try r.u16()
        func array() throws -> [UInt16] {
            let n = Int(try r.u32())          // u32 counts — the PTP/IP quirk
            guard n <= 512 else { throw LEReader.ParseError.malformed("array too big: \(n)") }
            return try (0..<n).map { _ in try r.u16() }
        }
        operations = try array()
        events = try array()
        deviceProps = try array()
        captureFormats = try array()
        imageFormats = try array()
        manufacturer = try r.ptpString()
        model = try r.ptpString()
        deviceVersion = try r.ptpString()
        serial = try r.ptpString()
    }

    public func supports(opcode: UInt16) -> Bool { operations.contains(opcode) }
}

/// One photo/folder on the camera.
public struct ObjectInfo: Sendable {
    public let handle: UInt32
    public let storageID: UInt32
    public let format: ObjectFormat
    public let formatCode: UInt16
    public let size: UInt32
    public let thumbSize: UInt32
    public let thumbDimensions: (w: UInt32, h: UInt32)
    public let pixels: (w: UInt32, h: UInt32)
    public let parent: UInt32
    public let filename: String
    public let captured: String        // "YYYYMMDDThhmmss.s"
    public let modified: String
    /// The raw dataset as served by the camera — cached verbatim so
    /// re-browsing needs zero camera queries for known photos.
    public let rawData: Data

    /// Fixed part is 52 bytes (same as USB), then 3 u8-prefixed UTF-16
    /// strings: filename, captureDate, modificationDate. One trailing
    /// byte observed on the M10 — tolerated.
    public init(data: Data, handle: UInt32) throws {
        var r = LEReader(data)
        self.handle = handle
        storageID = try r.u32()
        formatCode = try r.u16()
        format = ObjectFormat(rawValue: formatCode) ?? .unknown
        _ = try r.u16()                       // protection status
        size = try r.u32()
        _ = try r.u16()                       // thumb format
        thumbSize = try r.u32()
        thumbDimensions = (try r.u32(), try r.u32())
        pixels = (try r.u32(), try r.u32())
        _ = try r.u32()                       // bit depth
        parent = try r.u32()
        _ = try r.u16()                       // association type
        _ = try r.u32()                       // association desc
        _ = try r.u32()                       // sequence number
        filename = try r.ptpString()
        captured = try r.ptpString()
        modified = try r.ptpString()
        rawData = data
    }

    public var isPhoto: Bool { format.isPhoto }
}

/// Response to a command: code + params.
public struct CommandResponse: Equatable, Sendable {
    public let code: UInt16
    public let transactionID: UInt32
    public let params: [UInt32]
}

/// A camera-side event packet.
public struct CameraEvent: Equatable, Sendable {
    public let code: UInt16
    public let transactionID: UInt32
    public let params: [UInt32]
}
