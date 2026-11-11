import CoreGraphics
import Foundation
import simd

/// A change to how an external monitor shows one grey level (white included), in the
/// directions people see: warm/cool along the blackbody locus, green/magenta across it, and,
/// for greys, lighter/darker relative to white.
struct WhiteShift: Codable, Equatable {
    /// Positive is warmer (lower colour temperature). Mireds keep steps perceptually even.
    var mired: Double
    /// Positive is greener (above the locus), in CIE 1960 uv distance.
    var duv: Double
    /// Positive is lighter, in stops of luminance at this level. Always 0 for white, whose
    /// luminance is the brightness sync's job.
    var lightness: Double = 0

    static let zero = WhiteShift(mired: 0, duv: 0)

    init(mired: Double, duv: Double, lightness: Double = 0) {
        self.mired = mired
        self.duv = duv
        self.lightness = lightness
    }

    // Data saved before the lightness axis has no such key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mired = try c.decode(Double.self, forKey: .mired)
        duv = try c.decode(Double.self, forKey: .duv)
        lightness = try c.decodeIfPresent(Double.self, forKey: .lightness) ?? 0
    }

    /// Approximate colour-temperature change starting from D65 (negative = warmer).
    var kelvinChange: Double { 1e6 / (ColorMath.d65Mired + mired) - 1e6 / ColorMath.d65Mired }
}

/// Turns a white-point shift into per-channel scales for the display's gamma table.
///
/// The display's own profile says which XYZ its red, green and blue produce; solving for the
/// drive that gives the shifted white, relative to the drive for its native white, gives the
/// gains. They are normalised so the largest is 1 (a gamma table can only reduce), which
/// costs a little peak luminance; `luminanceFactor` says how much.
enum ColorMath {
    static let d65Mired = 1e6 / 6504

    /// Planckian locus in CIE 1960 uv (Krystek 1985), good from 1000 K to 15000 K.
    static func planckUV(_ t: Double) -> SIMD2<Double> {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        return SIMD2(u, v)
    }

    /// Unit vector across the locus at `t`, pointing towards green (+v).
    static func locusNormal(_ t: Double) -> SIMD2<Double> {
        let d = planckUV(t + 1) - planckUV(t - 1)
        var n = simd_normalize(SIMD2(-d.y, d.x))
        if n.y < 0 { n = -n }
        return n
    }

    static func uv(fromXY xy: SIMD2<Double>) -> SIMD2<Double> {
        let d = -2 * xy.x + 12 * xy.y + 3
        return SIMD2(4 * xy.x / d, 6 * xy.y / d)
    }

    static func xy(fromUV uv: SIMD2<Double>) -> SIMD2<Double> {
        let d = 2 * uv.x - 8 * uv.y + 4
        return SIMD2(3 * uv.x / d, 2 * uv.y / d)
    }

    static let d65xy = SIMD2(0.31271, 0.32902)

    /// D65's distance from the locus, so a zero shift lands exactly on D65.
    static let d65Duv: Double = {
        let t = 1e6 / d65Mired
        return simd_dot(uv(fromXY: d65xy) - planckUV(t), locusNormal(t))
    }()

    /// Chromaticity of D65 moved by `shift`.
    static func whiteXY(_ shift: WhiteShift) -> SIMD2<Double> {
        let t = 1e6 / (d65Mired + shift.mired)
        return xy(fromUV: planckUV(t) + (d65Duv + shift.duv) * locusNormal(t))
    }

    static func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> {
        SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
    }

    /// Linear-light gains (largest = 1) that move the display's native white by `shift`.
    static func gains(for shift: WhiteShift, primaries m: double3x3) -> SIMD3<Double> {
        let inverse = m.inverse
        let base = inverse * xyz(whiteXY(.zero))
        let target = inverse * xyz(whiteXY(shift))
        let g = target / base
        return g / g.max()
    }

    /// Luminance of the corrected white relative to the uncorrected one.
    static func luminanceFactor(_ gains: SIMD3<Double>, primaries m: double3x3) -> Double {
        // Row 1 of the primaries matrix is each channel's contribution to Y; white has Y = 1.
        let y = SIMD3(m[0][1], m[1][1], m[2][1])
        return simd_dot(y, gains) / simd_reduce_add(y)
    }

    /// Gamma-table scale per channel. The table works on encoded values, so a linear gain g
    /// becomes g^(1/2.2); the exponent only sets how far one step moves, since the user
    /// judges the result by eye.
    static func tableScales(_ gains: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(pow(gains, SIMD3(repeating: 1 / 2.2)))
    }

    // MARK: - Whole-range table from matched levels

    /// Gamma table (per channel, `count` entries) that applies each matched level's shift at
    /// that level, interpolating the shift between levels (in log grey value) and holding the
    /// end ones beyond them. At every level the colour gains keep luminance, then the level's
    /// lightness change scales it, and one common factor fits white under 1; so apart from the
    /// matched lightness the tone curve keeps its shape, and HDR can make up the common factor
    /// (returned as `luminance`).
    static func table(points: [ColorPoint], primaries m: double3x3, count n: Int)
        -> (r: [Float], g: [Float], b: [Float], luminance: Double)? {
        let sorted = points.sorted { $0.level < $1.level }
        guard let top = sorted.last, n > 1, sorted.contains(where: { $0.shift != .zero }) else { return nil }

        func lumaGains(_ shift: WhiteShift) -> SIMD3<Double> {
            let g = gains(for: shift, primaries: m)
            return g / luminanceFactor(g, primaries: m)
        }
        func shift(at v: Double) -> WhiteShift {
            guard v > sorted[0].level else { return sorted[0].shift }
            guard v < top.level else { return top.shift }
            let i = sorted.firstIndex { $0.level >= v }!
            let a = sorted[i - 1], b = sorted[i]
            let t = log(v / a.level) / log(b.level / a.level)
            return WhiteShift(mired: a.shift.mired + t * (b.shift.mired - a.shift.mired),
                              duv: a.shift.duv + t * (b.shift.duv - a.shift.duv),
                              lightness: a.shift.lightness + t * (b.shift.lightness - a.shift.lightness))
        }

        let common = 1 / lumaGains(top.shift).max()
        var r = [Float](repeating: 0, count: n), g = r, b = r
        for i in 1..<n {
            let v = Double(i) / Double(n - 1)
            let s = shift(at: v)
            let scales = tableScales(lumaGains(s) * common * pow(2, s.lightness))
            // Never above 1, never below the entry before (a table must not fold back).
            r[i] = max(r[i - 1], min(1, Float(v) * scales.x))
            g[i] = max(g[i - 1], min(1, Float(v) * scales.y))
            b[i] = max(b[i - 1], min(1, Float(v) * scales.z))
        }
        return (r, g, b, common)
    }

    // MARK: - Display primaries from its ICC profile

    /// The display's RGB → XYZ matrix (columns are the primaries, white has Y = 1), from the
    /// colourants in its ICC profile, adapted from the profile's D50 back to its own white.
    static func primaries(of id: CGDirectDisplayID) -> double3x3? {
        // The factory profile, not the active one, which may be NitSync's own.
        guard let data = DisplayProfiles.factoryProfileData(id) ?? CGDisplayCopyColorSpace(id).copyICCData() as Data? else { return nil }
        return primaries(icc: data)
    }

    static func primaries(icc data: Data) -> double3x3? {
        guard data.count > 132 else { return nil }
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { bytes[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func s15(_ o: Int) -> Double { Double(Int32(bitPattern: u32(o))) / 65536 }

        var tags: [String: Int] = [:]
        let count = Int(u32(128))
        guard 132 + count * 12 <= bytes.count else { return nil }
        for i in 0..<count {
            let o = 132 + i * 12
            tags[String(decoding: bytes[o..<o + 4], as: UTF8.self)] = Int(u32(o + 4))
        }
        func xyzTag(_ name: String) -> SIMD3<Double>? {
            guard let o = tags[name], o + 20 <= bytes.count else { return nil }
            return SIMD3(s15(o + 8), s15(o + 12), s15(o + 16))
        }
        guard let r = xyzTag("rXYZ"), let g = xyzTag("gXYZ"), let b = xyzTag("bXYZ") else { return nil }
        let white = xyzTag("wtpt") ?? SIMD3(0.9505, 1, 1.089)

        let colourants = double3x3(columns: (r, g, b))
        let d50 = SIMD3(0.9642, 1, 0.8249)
        // Colourants are stated relative to D50; if the white tag is D50 too there is nothing to undo.
        let m = simd_length(white - d50) < 0.002 ? colourants : bradford(from: d50, to: white) * colourants
        let y = m[0][1] + m[1][1] + m[2][1]
        return y > 0 ? m * (1 / y) : nil
    }

    static func bradford(from source: SIMD3<Double>, to destination: SIMD3<Double>) -> double3x3 {
        let mb = double3x3(rows: [
            SIMD3(0.8951, 0.2664, -0.1614),
            SIMD3(-0.7502, 1.7135, 0.0367),
            SIMD3(0.0389, -0.0685, 1.0296),
        ])
        let s = mb * source, d = mb * destination
        return mb.inverse * double3x3(diagonal: d / s) * mb
    }
}
