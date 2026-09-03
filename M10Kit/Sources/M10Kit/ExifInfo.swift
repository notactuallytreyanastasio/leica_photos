import Foundation

/// Lightweight EXIF reader for the photo detail view. Handles DNG/TIFF
/// (II/MM) and JPEG (APP1 Exif), reads the handful of tags that matter.
///
/// Validated against a real M10 DNG in the test suite. The M10 writes
/// APEX ShutterSpeedValue/ApertureValue rather than ExposureTime/FNumber,
/// so both paths are handled.
public struct ExifInfo: Equatable, Sendable {
    public var model: String?
    public var lensModel: String?
    public var iso: Int?
    public var exposureSeconds: Double?     // 1/60 → 0.0167
    public var aperture: Double?            // f-number
    public var focalLengthMM: Int?
    public var dateTimeOriginal: String?    // "2026:08:20 18:16:41"

    public static func parse(_ data: Data) -> ExifInfo {
        if data.starts(with: [0xFF, 0xD8]) {
            return parseJPEG(data)
        }
        return parseTIFF(data)
    }

    // MARK: - containers

    private static func parseJPEG(_ data: Data) -> ExifInfo {
        // scan segments for APP1 with "Exif\0\0"
        var i = 2
        let b = [UInt8](data.prefix(1 << 20))
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { break }
            let marker = b[i + 1]
            guard marker != 0xD8, marker != 0xD9, marker != 0x01, !(0xD0...0xD7).contains(marker) else {
                i += 2; continue
            }
            guard i + 4 <= b.count else { break }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard marker == 0xE1, i + 4 + 6 <= b.count,
                  Array(b[(i + 4)..<(i + 10)]) == Array("Exif\u{0}\u{0}".utf8) else {
                i += 2 + len
                continue
            }
            let tiffStart = i + 10
            if tiffStart + 8 <= b.count {
                return parseTIFF(data.subdata(in: tiffStart..<min(data.count, i + 2 + len)))
            }
            break
        }
        return ExifInfo()
    }

    private static func parseTIFF(_ data: Data) -> ExifInfo {
        guard data.count > 12 else { return ExifInfo() }
        let b = [UInt8](data.prefix(1 << 20))
        let endian: Endian
        switch (b[0], b[1]) {
        case (0x49, 0x49): endian = .little
        case (0x4D, 0x4D): endian = .big
        default: return ExifInfo()
        }
        func u16(_ o: Int) -> Int {
            endian == .little ? Int(b[o]) | Int(b[o + 1]) << 8
                              : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> Int {
            var v = 0
            for k in 0..<4 {
                v |= endian == .little ? Int(b[o + k]) << (8 * k) : Int(b[o + k]) << (8 * (3 - k))
            }
            return v
        }
        guard u16(2) == 42 else { return ExifInfo() }

        var info = ExifInfo()
        var visitedIFDs = 0

        func walkIFD(_ offset: Int) {
            guard offset > 0, offset + 2 <= b.count, visitedIFDs < 6 else { return }
            visitedIFDs += 1
            let count = u16(offset)
            guard count < 512, offset + 2 + count * 12 + 4 <= b.count else { return }
            for e in 0..<count {
                let base = offset + 2 + e * 12
                let tag = u16(base)
                let typ = u16(base + 2)
                let cnt = u32(base + 4)
                let sizes = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]
                let size = (typ < sizes.count ? sizes[typ] : 1) * cnt
                let valOff = size <= 4 ? base + 8 : u32(base + 8)
                guard valOff >= 0, valOff + max(size, 1) <= b.count else { continue }

                func asciiStr() -> String? {
                    var s = ""
                    for k in 0..<min(cnt, 256) {
                        let c = b[valOff + k]
                        if c == 0 { break }
                        s.append(Character(UnicodeScalar(c)))
                    }
                    return s.isEmpty ? nil : s
                }
                func rational() -> (Int, Int)? {
                    guard typ == 5 || typ == 10, valOff + 8 <= b.count else { return nil }
                    return (u32(valOff), u32(valOff + 4))
                }
                func intVal() -> Int? {
                    switch typ {
                    case 3: return u16(valOff)
                    case 4: return u32(valOff)
                    default: return nil
                    }
                }

                switch tag {
                case 0x0110: info.model = asciiStr()
                case 0x829a: if let r = rational(), r.1 != 0 { info.exposureSeconds = Double(r.0) / Double(r.1) }
                case 0x829d: if let r = rational(), r.1 != 0 { info.aperture = Double(r.0) / Double(r.1) }
                case 0x8827: info.iso = intVal()
                case 0x9003: info.dateTimeOriginal = asciiStr()
                case 0x9201: if info.exposureSeconds == nil, let r = rational() {
                    // APEX: time = 1 / 2^(value)
                    info.exposureSeconds = pow(2, -Double(r.0) / Double(max(r.1, 1)))
                }
                case 0x9202: if info.aperture == nil, let r = rational() {
                    // APEX: f = 2^(value/2)
                    info.aperture = pow(2, Double(r.0) / Double(max(r.1, 1)) / 2)
                }
                case 0x920a: if let r = rational(), r.1 != 0 {
                    info.focalLengthMM = Int((Double(r.0) / Double(r.1)).rounded())
                }
                case 0xa434: info.lensModel = asciiStr()
                case 0x8769: walkIFD(u32(valOff))   // Exif sub-IFD (value = offset)
                default: break
                }
            }
        }
        walkIFD(u32(4))
        return info
    }

    private enum Endian { case little, big }

    // MARK: - display helpers

    public var exposureLabel: String? {
        guard let s = exposureSeconds, s > 0 else { return nil }
        if s >= 1 { return String(format: "%.0fs", s) }
        let denom = (1 / s).rounded()
        return "1/\(Int(denom))s"
    }

    public var apertureLabel: String? {
        guard let a = aperture, a > 0 else { return nil }
        return String(format: "f/%.1f", a)
    }

    public var summaryLine: String? {
        var parts: [String] = []
        if let l = exposureLabel { parts.append(l) }
        if let l = apertureLabel { parts.append(l) }
        if let iso { parts.append("ISO \(iso)") }
        if let f = focalLengthMM { parts.append("\(f)mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
