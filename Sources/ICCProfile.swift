import Foundation
import simd

/// Just enough of the ICC format to take a display profile, replace some tags and write it
/// back: the header is kept, the tag table and tag data are laid out again.
struct ICCProfile {
    private var header: [UInt8]
    /// Tags in their original order; signatures that shared data keep sharing it.
    private var tags: [(signature: String, data: [UInt8])]

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 132, String(decoding: b[36..<40], as: UTF8.self) == "acsp" else { return nil }
        func u32(_ o: Int) -> Int { Int(b[o..<o + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) }
        let count = u32(128)
        guard 132 + count * 12 <= b.count else { return nil }
        header = Array(b[0..<128])
        tags = []
        for i in 0..<count {
            let o = 132 + i * 12
            let offset = u32(o + 4), size = u32(o + 8)
            guard offset + size <= b.count else { return nil }
            tags.append((String(decoding: b[o..<o + 4], as: UTF8.self), Array(b[offset..<offset + size])))
        }
    }

    func tag(_ signature: String) -> [UInt8]? { tags.first { $0.signature == signature }?.data }

    mutating func setTag(_ signature: String, _ data: [UInt8]) {
        if let i = tags.firstIndex(where: { $0.signature == signature }) {
            tags[i].data = data
        } else {
            tags.append((signature, data))
        }
    }

    /// The profile as bytes: tag data 4-byte aligned, identical data stored once, size
    /// updated, profile ID cleared (it is optional and would no longer match).
    var data: Data {
        var body: [UInt8] = []
        var table: [(String, Int, Int)] = []
        var stored: [[UInt8]: Int] = [:]
        let dataStart = 128 + 4 + tags.count * 12
        for (signature, data) in tags {
            if let offset = stored[data] {
                table.append((signature, offset, data.count))
                continue
            }
            while body.count % 4 != 0 { body.append(0) }
            let offset = dataStart + body.count
            stored[data] = offset
            body += data
            table.append((signature, offset, data.count))
        }
        while body.count % 4 != 0 { body.append(0) }

        var out = header
        for i in 84..<100 { out[i] = 0 }
        out += Self.u32(tags.count)
        for (signature, offset, size) in table {
            out += Array(signature.utf8.prefix(4)) + Self.u32(offset) + Self.u32(size)
        }
        out += body
        let size = Self.u32(out.count)
        for i in 0..<4 { out[i] = size[i] }
        return Data(out)
    }

    // MARK: - Tag builders

    static func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (24 - 8 * $0)) & 0xFF) } }
    static func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func s15(_ v: Double) -> [UInt8] { u32(Int(Int32((v * 65536).rounded())) & 0xFFFF_FFFF) }

    static func xyzTag(_ v: SIMD3<Double>) -> [UInt8] {
        Array("XYZ ".utf8) + u32(0) + s15(v.x) + s15(v.y) + s15(v.z)
    }

    /// 'vcgt' as a 16-bit table: the per-channel curve the system loads into the display's
    /// gamma table whenever this profile is in use.
    static func vcgtTag(r: [Float], g: [Float], b: [Float]) -> [UInt8] {
        var out = Array("vcgt".utf8) + u32(0) + u32(0) + u16(3) + u16(r.count) + u16(2)
        for channel in [r, g, b] {
            for v in channel { out += u16(Int((Double(min(1, max(0, v))) * 65535).rounded())) }
        }
        return out
    }

    /// Version-2 'desc' (textDescriptionType) with an ASCII name.
    static func descTag(_ name: String) -> [UInt8] {
        let ascii = Array(name.unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "?") }) + [0]
        return Array("desc".utf8) + u32(0) + u32(ascii.count) + ascii
            + u32(0) + u32(0)                              // Unicode language code, count
            + u16(0) + [0] + [UInt8](repeating: 0, count: 67) // ScriptCode code, count, data
    }

    /// Version-4 'mluc' with one en-US record, for profiles whose description uses it.
    static func mlucTag(_ name: String) -> [UInt8] {
        let utf16 = Array(name.utf16)
        var out = Array("mluc".utf8) + u32(0) + u32(1) + u32(12)
        out += Array("en".utf8) + Array("US".utf8) + u32(utf16.count * 2) + u32(28)
        for unit in utf16 { out += u16(Int(unit)) }
        return out
    }
}
