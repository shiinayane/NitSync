import CoreGraphics
import Foundation
import simd

/// The display's red, green and blue primaries, matched by eye against the built-in panel.
///
/// Colour management turns every colour into device RGB using the primaries the display's
/// profile claims. The factory profile's primaries come from the EDID and may be off; when
/// they are, the same colour looks different on the two screens. Moving a claimed primary
/// moves the colours shown the other way (claim red more orange, and colour management adds
/// blue to every red, making it more magenta), so a wanted change of what is *shown* becomes
/// the opposite change of the claimed primary. White stays put: the primaries are rescaled
/// so they still add up to the profile's white.
enum Primary: String, CaseIterable, Codable, CodingKeyRepresentable {
    case red = "r", green = "g", blue = "b"

    var name: String {
        switch self {
        case .red: return L("red")
        case .green: return L("green")
        case .blue: return L("blue")
        }
    }

    /// The hue direction called positive: towards this neighbour.
    var positiveHueName: String {
        switch self {
        case .red: return L("orange")
        case .green: return L("yellow")
        case .blue: return L("cyan")
        }
    }

    var negativeHueName: String {
        switch self {
        case .red: return L("magenta")
        case .green: return L("cyan")
        case .blue: return L("purple")
        }
    }

    /// The primary whose side the positive hue direction points to.
    fileprivate var neighbour: Primary {
        switch self {
        case .red: return .green
        case .green: return .red
        case .blue: return .green
        }
    }

    fileprivate var index: Int { Primary.allCases.firstIndex(of: self)! }

    /// The test colour: this primary of sRGB, well inside both panels' gamuts.
    var srgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .red: return (1, 0, 0)
        case .green: return (0, 1, 0)
        case .blue: return (0, 0, 1)
        }
    }
}

/// How one primary should look different, in CIE 1976 u'v' distance: `hue` across the line
/// from white (positive towards `Primary.positiveHueName`), `saturation` along it (positive
/// is more saturated).
struct PrimaryShift: Codable, Equatable {
    var hue: Double = 0
    var saturation: Double = 0
}

enum PrimaryMath {
    static func uv(_ xyz: SIMD3<Double>) -> SIMD2<Double> {
        let d = xyz.x + 15 * xyz.y + 3 * xyz.z
        return SIMD2(4 * xyz.x / d, 9 * xyz.y / d)
    }

    /// XYZ with Y = 1 for a u'v' chromaticity.
    static func xyz(uv: SIMD2<Double>) -> SIMD3<Double> {
        let d = 6 * uv.x - 16 * uv.y + 12
        let x = 9 * uv.x / d, y = 4 * uv.y / d
        return SIMD3(x / y, 1, (1 - x - y) / y)
    }

    /// The profile colourants (columns, PCS/D50) after moving what is shown by `shifts`.
    static func colourants(_ factory: double3x3, shifts: [Primary: PrimaryShift]) -> double3x3 {
        let white = factory * SIMD3(1, 1, 1)
        let w = uv(white)
        let base = Primary.allCases.map { uv(factory[$0.index]) }
        var moved = base
        for p in Primary.allCases {
            guard let s = shifts[p], s != PrimaryShift() else { continue }
            let radial = simd_normalize(base[p.index] - w)
            var across = SIMD2(-radial.y, radial.x)
            if simd_dot(across, base[p.neighbour.index] - base[p.index]) < 0 { across = -across }
            // Shown moves one way, so the claim moves the other.
            moved[p.index] = base[p.index] - (s.hue * across + s.saturation * radial)
        }
        let columns = double3x3(columns: (xyz(uv: moved[0]), xyz(uv: moved[1]), xyz(uv: moved[2])))
        let scale = columns.inverse * white
        return columns * double3x3(diagonal: scale)
    }

    static func colourants(ofICC data: Data) -> double3x3? {
        guard let p = ICCProfile(data), let r = p.tag("rXYZ"), let g = p.tag("gXYZ"), let b = p.tag("bXYZ") else { return nil }
        func xyz(_ t: [UInt8]) -> SIMD3<Double>? {
            guard t.count >= 20 else { return nil }
            func s15(_ o: Int) -> Double { Double(Int32(bitPattern: t[o..<o + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })) / 65536 }
            return SIMD3(s15(8), s15(12), s15(16))
        }
        guard let rx = xyz(r), let gx = xyz(g), let bx = xyz(b) else { return nil }
        return double3x3(columns: (rx, gx, bx))
    }

    /// Profile bytes with the colourants replaced.
    static func profile(_ data: Data, colourants m: double3x3) -> Data? {
        guard var p = ICCProfile(data) else { return nil }
        p.setTag("rXYZ", ICCProfile.xyzTag(m[0]))
        p.setTag("gXYZ", ICCProfile.xyzTag(m[1]))
        p.setTag("bXYZ", ICCProfile.xyzTag(m[2]))
        return p.data
    }
}

/// One primaries matching run: a staircase for hue and one for saturation per primary, all
/// six asked in random order (the colour on screen changes with the question, which also
/// keeps the eye from settling on one hue).
struct PrimarySession {
    enum Axis { case hue, saturation }

    private(set) var stairs: [Primary: (hue: Staircase, saturation: Staircase)] = [:]
    private(set) var current: (primary: Primary, axis: Axis) = (.red, .hue)
    private var rng: SplitMix

    static let expectedQuestions = "50–70"

    init(around base: [Primary: PrimaryShift], seed: UInt64 = .random(in: 0...UInt64.max)) {
        var rng = SplitMix(seed: seed)
        func side() -> Double { Bool.random(using: &rng) ? 1 : -1 }
        for p in Primary.allCases {
            let b = base[p] ?? PrimaryShift()
            // u'v' units: start ±0.012, finest step 0.001 (about a quarter of a just-noticeable difference).
            stairs[p] = (Staircase(start: b.hue + side() * 0.012, step: 0.008, minStep: 0.001, range: -0.05...0.05),
                         Staircase(start: b.saturation + side() * 0.012, step: 0.008, minStep: 0.001, range: -0.05...0.05))
        }
        self.rng = rng
        current = open.randomElement(using: &self.rng)!
    }

    private var open: [(primary: Primary, axis: Axis)] {
        Primary.allCases.flatMap { p -> [(primary: Primary, axis: Axis)] in
            var out: [(primary: Primary, axis: Axis)] = []
            if !stairs[p]!.hue.isDone { out.append((p, .hue)) }
            if !stairs[p]!.saturation.isDone { out.append((p, .saturation)) }
            return out
        }
    }

    var isDone: Bool { open.isEmpty }
    var answered: Int { stairs.values.map { $0.hue.trials + $0.saturation.trials }.reduce(0, +) }

    /// What every primary should currently show.
    var shown: [Primary: PrimaryShift] {
        stairs.mapValues { PrimaryShift(hue: $0.hue.value, saturation: $0.saturation.value) }
    }

    mutating func answer(_ a: Staircase.Answer) {
        let (p, axis) = current
        switch axis {
        case .hue: stairs[p]!.hue.answer(a)
        case .saturation: stairs[p]!.saturation.answer(a)
        }
        if let next = open.randomElement(using: &rng) { current = next }
    }

    var result: ColorCalibration.PrimaryRun {
        ColorCalibration.PrimaryRun(shifts: stairs.mapValues { PrimaryShift(hue: $0.hue.estimate, saturation: $0.saturation.estimate) },
                                    date: Date())
    }
}
