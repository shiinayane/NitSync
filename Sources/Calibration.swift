import Foundation

/// Maps the built-in panel's luminance (nits) to the external monitor's DDC brightness (0–100 %).
///
/// The user saves match points by eye ("at this built-in level, this DDC value looks the same").
/// Between points the mapping is linear in nits, which holds when the monitor's luminance is
/// roughly affine in its DDC value; extra points absorb any curvature.
struct Calibration: Codable, Equatable {
    struct Point: Codable, Equatable {
        var nits: Double
        var value: Double
    }

    /// Full-screen white assumed for a monitor whose EDID gives no luminance, before any point is saved.
    static let defaultMaxNits = 250.0

    private(set) var points: [Point] = []

    var isCalibrated: Bool { points.count >= 2 }

    /// `uncalibratedMaxNits` is the monitor's assumed white at 100 %, used only with no saved points.
    func value(forNits nits: Double, uncalibratedMaxNits: Double = Calibration.defaultMaxNits) -> Double {
        let p = points
        let v: Double
        switch p.count {
        case 0:
            v = 100 * nits / uncalibratedMaxNits
        case 1:
            v = p[0].value * nits / p[0].nits
        default:
            let i: Int
            if nits <= p[0].nits {
                i = 0
            } else if nits >= p[p.count - 1].nits {
                i = p.count - 2
            } else {
                i = p.firstIndex { $0.nits >= nits }! - 1
            }
            let a = p[i], b = p[i + 1]
            v = a.value + (nits - a.nits) * (b.value - a.value) / (b.nits - a.nits)
        }
        return min(100, max(0, v))
    }

    /// Adds a point, replacing any saved near the same luminance and any that would make
    /// the mapping run backwards.
    mutating func add(nits: Double, value: Double) {
        guard nits > 0 else { return }
        points.removeAll { abs(log($0.nits / nits)) < log(1.25) }
        points.removeAll { ($0.nits < nits && $0.value > value) || ($0.nits > nits && $0.value < value) }
        points.append(Point(nits: nits, value: value))
        points.sort { $0.nits < $1.nits }
    }

    mutating func reset() { points = [] }
}
