import CoreGraphics
import Foundation
import IOKit

/// The built-in panel's current luminance, read from its framebuffer in the IO registry.
/// `IOMFBBrightnessLevel` on the framebuffer under `disp0` is the panel's SDR white level
/// in nits (16.16 fixed point). It follows the brightness slider, keys and auto-brightness,
/// and does not change with on-screen content.
enum BuiltinDisplay {
    static func displayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Returns a retained framebuffer service; the caller releases it.
    static func framebuffer() -> io_service_t? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            var parent: io_registry_entry_t = 0
            var name = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetParentEntry(s, kIOServicePlane, &parent) == KERN_SUCCESS {
                IORegistryEntryGetName(parent, &name)
                IOObjectRelease(parent)
                if String(cString: name) == "disp0" { return s }
            }
            IOObjectRelease(s)
        }
        return nil
    }

    static func nits(_ framebuffer: io_service_t) -> Double? {
        guard let value = IORegistryEntryCreateCFProperty(framebuffer, "IOMFBBrightnessLevel" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        let nits = value.doubleValue / 65536
        return nits > 0.05 ? nits : nil
    }
}
