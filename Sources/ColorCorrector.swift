import CoreGraphics
import simd

/// Applies each monitor's colour correction as a gamma table, and reports how much
/// luminance the correction costs so the HDR path can make it up.
///
/// Gamma tables belong to the process that set them: macOS puts the display's ColorSync
/// settings back when NitSync quits, so nothing is left behind.
final class ColorCorrector {
    private struct Table: Equatable {
        var points: [ColorPoint]
        var r: [Float], g: [Float], b: [Float]
        var luminance: Double
    }

    private var primaries: [CGDirectDisplayID: double3x3] = [:]
    private var applied: [CGDirectDisplayID: Table] = [:]
    /// Corrected white luminance relative to uncorrected, per monitor key (absent = 1).
    private(set) var luminanceFactor: [String: Double] = [:]

    /// Forget cached profiles, e.g. after displays were reconfigured.
    func reset() { primaries = [:] }

    /// Brings every display's gamma table in line with `curves` (matched levels per monitor
    /// key). Also puts back a table that something else (a ColorSync reload, another app)
    /// replaced.
    func apply(_ curves: [String: [ColorPoint]], keys: [CGDirectDisplayID: String]) {
        var wanted: [CGDirectDisplayID: Table] = [:]
        var factors: [String: Double] = [:]
        for (id, key) in keys {
            guard let points = curves[key], !points.isEmpty else { continue }
            if let current = applied[id], current.points == points {
                wanted[id] = current
            } else {
                if primaries[id] == nil { primaries[id] = ColorMath.primaries(of: id) }
                let n = Int(max(2, CGDisplayGammaTableCapacity(id)))
                guard let m = primaries[id], let t = ColorMath.table(points: points, primaries: m, count: n) else { continue }
                wanted[id] = Table(points: points, r: t.r, g: t.g, b: t.b, luminance: t.luminance)
            }
            factors[key] = wanted[id]!.luminance
        }
        luminanceFactor = factors

        // A display that no longer wants a correction: hand all displays back to ColorSync,
        // then set the others again.
        if applied.keys.contains(where: { wanted[$0] == nil }) {
            CGDisplayRestoreColorSyncSettings()
            applied = [:]
        }
        for (id, table) in wanted where applied[id] != table || !isInPlace(table, on: id) {
            let err = CGSetDisplayTransferByTable(id, UInt32(table.r.count), table.r, table.g, table.b)
            applied[id] = err == .success ? table : nil
        }
    }

    private func isInPlace(_ table: Table, on id: CGDirectDisplayID) -> Bool {
        let capacity = CGDisplayGammaTableCapacity(id)
        var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success,
              Int(count) == table.r.count else { return false }
        for i in [Int(count) / 8, Int(count) / 2, Int(count) - 1] {
            if abs(r[i] - table.r[i]) > 0.002 || abs(g[i] - table.g[i]) > 0.002 || abs(b[i] - table.b[i]) > 0.002 { return false }
        }
        return true
    }
}
