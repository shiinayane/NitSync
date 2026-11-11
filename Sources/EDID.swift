import Foundation

/// The parts of a monitor's EDID that NitSync uses: who the monitor is, and the luminance
/// figures from the CTA-861 HDR static metadata block.
///
/// The luminance figures describe HDR content the monitor wants (peak and full-frame average),
/// not what its SDR white measures at a given DDC value, so they only seed the estimate used
/// before the monitor is calibrated.
struct EDID: Equatable {
    /// Three-letter PNP manufacturer ID, e.g. "DEL".
    let vendor: String
    /// The same ID as the raw EDID number, which is what `CGDisplayVendorNumber` returns.
    let vendorNumber: UInt32
    let productCode: UInt16
    /// The EDID's numeric serial (0 if unset), as `CGDisplaySerialNumber` returns it.
    let numericSerial: UInt32
    /// Serial from the monitor serial descriptor, else the numeric serial, else nil.
    let serial: String?
    /// From the display product name descriptor.
    let name: String?
    /// Desired content max luminance (nits).
    let maxLuminance: Double?
    /// Desired content max frame-average luminance (nits).
    let maxFrameAverageLuminance: Double?
    /// Desired content min luminance (nits).
    let minLuminance: Double?

    /// Stable across reconnects and ports; identical monitors differ by serial.
    var key: String {
        var parts = [vendor, String(format: "%04X", productCode)]
        if let serial { parts.append(serial) }
        return parts.joined(separator: "-")
    }

    /// The brightest full-screen white the monitor says it targets, for the uncalibrated estimate.
    var estimatedFullWhiteNits: Double? {
        switch (maxFrameAverageLuminance, maxLuminance) {
        case let (fall?, max?): return min(fall, max)
        case let (fall?, nil): return fall
        case let (nil, max?): return max
        default: return nil
        }
    }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 128, b[0..<8].elementsEqual([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]) else { return nil }

        let v = UInt16(b[8]) << 8 | UInt16(b[9])
        let letters = [(v >> 10) & 0x1F, (v >> 5) & 0x1F, v & 0x1F]
        guard letters.allSatisfy({ (1...26).contains($0) }) else { return nil }
        vendor = String(letters.map { Character(UnicodeScalar(UInt8($0) + 64)) })
        vendorNumber = UInt32(v)
        productCode = UInt16(b[10]) | UInt16(b[11]) << 8
        let numericSerial = UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24
        self.numericSerial = numericSerial

        var name: String?
        var serialText: String?
        for offset in stride(from: 54, through: 108, by: 18) where b[offset] == 0 && b[offset + 1] == 0 {
            let text = Self.descriptorText(b[(offset + 5)..<(offset + 18)])
            switch b[offset + 3] {
            case 0xFC: name = text
            case 0xFF: serialText = text
            default: break
            }
        }
        self.name = name
        serial = serialText ?? (numericSerial != 0 ? String(numericSerial) : nil)

        var hdr: (max: Double?, fall: Double?, min: Double?) = (nil, nil, nil)
        let blocks = min(Int(b[126]), b.count / 128 - 1)
        if blocks > 0 {
            for i in 1...blocks {
                if let found = Self.hdrStaticMetadata(Array(b[(i * 128)..<(i * 128 + 128)])) {
                    hdr = found
                    break
                }
            }
        }
        maxLuminance = hdr.max
        maxFrameAverageLuminance = hdr.fall
        minLuminance = hdr.min
    }

    private static func descriptorText(_ bytes: ArraySlice<UInt8>) -> String? {
        let raw = bytes.prefix { $0 != 0x0A && $0 != 0x00 }
        let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Reads the HDR static metadata data block from a CTA-861 extension block.
    private static func hdrStaticMetadata(_ e: [UInt8]) -> (max: Double?, fall: Double?, min: Double?)? {
        guard e[0] == 0x02, e[1] >= 3 else { return nil }
        let end = min(Int(e[2]), 127)
        var i = 4
        while i < end {
            let tag = e[i] >> 5, length = Int(e[i] & 0x1F)
            guard i + length < 128 else { return nil }
            // Extended tag 6: payload is ext tag, EOTFs, metadata types, then optional max, max-FALL, min.
            if tag == 7, length >= 1, e[i + 1] == 6 {
                let p = Array(e[(i + 1)...(i + length)])
                func nits(_ cv: UInt8) -> Double { 50 * pow(2, Double(cv) / 32) }
                let max = p.count > 3 && p[3] != 0 ? nits(p[3]) : nil
                let fall = p.count > 4 && p[4] != 0 ? nits(p[4]) : nil
                let min = p.count > 5 ? max.map { $0 * pow(Double(p[5]) / 255, 2) / 100 } : nil
                return (max, fall, min)
            }
            i += length + 1
        }
        return nil
    }
}
