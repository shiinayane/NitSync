import CoreGraphics
import simd

/// Turns matched levels into gamma tables. Saved calibrations reach the display through
/// their ICC profile's `vcgt` (`DisplayProfiles`); this class only sets a table directly
/// while calibration previews a change, and reports how much luminance each monitor's
/// correction costs so the HDR path can make it up.
final class ColorCorrector {
    typealias Table = (r: [Float], g: [Float], b: [Float], luminance: Double)

    private var primaries: [CGDirectDisplayID: double3x3] = [:]
    private var cache: [CGDirectDisplayID: (points: [ColorPoint], table: Table)] = [:]
    private var previewing: CGDirectDisplayID?
    /// Corrected white luminance relative to uncorrected, per monitor key (absent = 1).
    private(set) var luminanceFactor: [String: Double] = [:]

    /// Forget cached profiles, e.g. after displays were reconfigured.
    func reset() {
        primaries = [:]
        cache = [:]
    }

    /// The table for `points` on display `id` (nil when there is nothing to correct).
    func table(_ points: [ColorPoint], on id: CGDirectDisplayID) -> Table? {
        if let hit = cache[id], hit.points == points { return hit.table }
        if primaries[id] == nil { primaries[id] = ColorMath.primaries(of: id) }
        let n = Int(max(2, CGDisplayGammaTableCapacity(id)))
        guard let m = primaries[id], let t = ColorMath.table(points: points, primaries: m, count: n) else { return nil }
        cache[id] = (points, t)
        return t
    }

    /// Recomputes the luminance factors for `curves` (matched levels per monitor key).
    func update(_ curves: [String: [ColorPoint]], keys: [CGDirectDisplayID: String]) {
        var factors: [String: Double] = [:]
        for (id, key) in keys {
            if let points = curves[key], !points.isEmpty, let t = table(points, on: id) { factors[key] = t.luminance }
        }
        luminanceFactor = factors
    }

    /// Shows `points` on display `id` right away, over whatever its profile loaded.
    func preview(_ points: [ColorPoint], on id: CGDirectDisplayID) {
        let n = Int(max(2, CGDisplayGammaTableCapacity(id)))
        let ramp = (0..<n).map { Float($0) / Float(n - 1) }
        let t = table(points, on: id) ?? (ramp, ramp, ramp, 1)
        if CGSetDisplayTransferByTable(id, UInt32(t.r.count), t.r, t.g, t.b) == .success { previewing = id }
    }

    /// Ends a preview: the system reloads every display's table from its profile.
    func endPreview() {
        guard previewing != nil else { return }
        previewing = nil
        CGDisplayRestoreColorSyncSettings()
    }
}
