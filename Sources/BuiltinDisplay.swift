import AppKit
import IOKit

/// The built-in panel's current luminance, read from its framebuffer in the IO registry.
/// `IOMFBBrightnessLevel` on the framebuffer under `disp0` is the panel's backlight level in
/// nits (16.16 fixed point): SDR white times the current EDR headroom. It follows the
/// brightness slider, keys and auto-brightness, and also rises when EDR (HDR) content is on
/// screen, while SDR white stays put (measured: 86 nit SDR white read 103 at headroom 1.2 and
/// 1378 at 16; the ratio stays within 2 % while the headroom ramps up over about 2 s).
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

    /// The built-in panel's SDR white in nits: the framebuffer level divided by the screen's
    /// current EDR headroom, so EDR content on screen doesn't read as a brighter panel.
    static func sdrNits(_ framebuffer: io_service_t, display id: CGDirectDisplayID) -> Double? {
        guard let level = nits(framebuffer) else { return nil }
        let headroom = NSScreen.screens.first { $0.displayID == id }?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        return level / max(1, Double(headroom))
    }

    // MARK: - Change notifications

    private typealias Callback = @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, Callback) -> Int32
    private static var onChange: (() -> Void)?

    /// Calls `handler` (on the main queue) whenever the system is about to change the built-in
    /// panel's brightness: keys, Control Center, or anything else that goes through
    /// DisplayServices. Measured: it arrives about 1 ms after the request and 10–20 ms before
    /// `IOMFBBrightnessLevel` starts to move, so sampling can speed up before the fade.
    /// Returns false if the private call is missing.
    static func observeBrightnessChanges(_ handler: @escaping () -> Void) -> Bool {
        guard let id = displayID(),
              let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(lib, "DisplayServicesRegisterForBrightnessChangeNotifications") else { return false }
        onChange = handler
        let register = unsafeBitCast(symbol, to: Register.self)
        return register(id, UnsafeRawPointer(bitPattern: UInt(id)), { _, _, _, _, _ in
            DispatchQueue.main.async { BuiltinDisplay.onChange?() }
        }) == 0
    }
}
