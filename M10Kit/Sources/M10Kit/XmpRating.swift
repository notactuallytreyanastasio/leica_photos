import Foundation

/// Extracts the Leica in-camera favorite rating (`xmp:Rating`) from a
/// photo's bytes. The M10's firmware writes the XMP packet into both DNG
/// and JPEG files; rating 0 = unstarred, >0 = starred.
public enum XmpRating {

    /// Finds `xmp:Rating="N"` in the file's XMP region and returns N.
    /// Returns nil when no rating attribute exists.
    public static func extract(from data: Data) -> Int? {
        // Search the whole file: the XMP packet is plain XML text and the
        // attribute is unambiguous. Files are <= ~40MB; this is a fast
        // memchr-style scan and keeps us independent of container format.
        let key: [UInt8] = Array("xmp:Rating=\"".utf8)
        guard let first = data.firstRange(of: key) else { return nil }
        var idx = first.upperBound
        var digits: [UInt8] = []
        while idx < data.endIndex, digits.count < 4 {
            let c = data[idx]
            guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { break }
            digits.append(c)
            idx = data.index(after: idx)
        }
        guard !digits.isEmpty, let value = Int(String(decoding: digits, as: UTF8.self)) else {
            return nil
        }
        return value
    }

    public static func isStarred(_ data: Data) -> Bool {
        (extract(from: data) ?? 0) > 0
    }
}

private extension Data {
    func firstRange(of needle: [UInt8]) -> Range<Data.Index>? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        let buf = self
        let first = needle[0]
        var i = startIndex
        let limit = index(endIndex, offsetBy: -(needle.count - 1))
        while i < limit {
            if buf[i] == first {
                var j = i
                var matched = true
                for n in needle {
                    if buf[j] != n { matched = false; break }
                    j = index(after: j)
                }
                if matched { return i..<j }
            }
            i = index(after: i)
        }
        return nil
    }
}
