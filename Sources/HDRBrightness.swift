import CoreGraphics
import Foundation
import IOKit

/// Brightness of an external display that macOS drives in HDR.
///
/// In HDR the signal is PQ, which encodes absolute luminance, and the display locks its own
/// brightness setting (it ignores DDC). macOS decides where SDR white sits inside the signal;
/// that is what the system brightness slider moves for such a display. The display's
/// framebuffer reports the result in nits (`IOMFBBrightnessLevel`, as for the built-in panel),
/// so NitSync sets the level through DisplayServices and corrects it from that reading.
enum HDRBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = symbol("DisplayServicesGetBrightness")
    private static let setFn: SetFn? = symbol("DisplayServicesSetBrightness")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static var isAvailable: Bool { getFn != nil && setFn != nil }

    /// The system brightness level (0–1) of the display.
    static func level(_ id: CGDirectDisplayID) -> Double? {
        guard let get = getFn else { return nil }
        var value: Float = 0
        return get(id, &value) == 0 ? Double(value) : nil
    }

    @discardableResult
    static func setLevel(_ level: Double, for id: CGDirectDisplayID) -> Bool {
        guard let set = setFn else { return false }
        return set(id, Float(min(1, max(0, level)))) == 0
    }

    /// SDR white in nits at each system level, measured on macOS 27 with an AW2725Q.
    /// Only the shape matters: each write is corrected from the framebuffer's reading.
    private static let table: [(level: Double, nits: Double)] = [
        (0, 4), (0.1, 10), (0.25, 20.4), (0.4, 35.9), (0.5, 50),
        (0.6, 68), (0.75, 104.4), (0.9, 155.5), (1, 200),
    ]

    /// Level expected to give `nits`, from the table, interpolated in log luminance.
    static func estimatedLevel(forNits nits: Double) -> Double {
        let t = table
        if nits <= t[0].nits { return 0 }
        if nits >= t[t.count - 1].nits { return 1 }
        let i = t.firstIndex { $0.nits >= nits }!
        let a = t[i - 1], b = t[i]
        let f = log(nits / a.nits) / log(b.nits / a.nits)
        return a.level + f * (b.level - a.level)
    }

    /// The framebuffer of an external display, matched by the product attributes macOS stores
    /// on it. Returns a retained service; the caller releases it.
    static func framebuffer(for id: CGDirectDisplayID) -> io_service_t? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        let vendor = Int(CGDisplayVendorNumber(id)), model = Int(CGDisplayModelNumber(id)), serial = Int(CGDisplaySerialNumber(id))
        while case let s = IOIteratorNext(it), s != 0 {
            if let attributes = IORegistryEntryCreateCFProperty(s, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any],
               product["LegacyManufacturerID"] as? Int == vendor,
               product["ProductID"] as? Int == model,
               serial == 0 || product["SerialNumber"] as? Int == serial {
                return s
            }
            IOObjectRelease(s)
        }
        return nil
    }

    /// SDR white currently shown by the display, in nits.
    static func nits(_ framebuffer: io_service_t) -> Double? {
        BuiltinDisplay.nits(framebuffer)
    }
}
