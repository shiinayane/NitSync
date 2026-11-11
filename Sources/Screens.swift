import AppKit

/// Links DDC monitors to the screens macOS shows them as.
enum Screens {
    /// Pairs external screens with DDC monitors through the EDID numbers CoreGraphics reports.
    static func monitorKeys(_ monitors: [MonitorInfo]) -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        var unmatchedScreens: [CGDirectDisplayID] = []
        var unmatched = monitors

        for screen in NSScreen.screens {
            guard let id = screen.displayID, CGDisplayIsBuiltin(id) == 0 else { continue }
            if let i = unmatched.firstIndex(where: { m in
                guard let e = m.edid else { return false }
                return e.vendorNumber == CGDisplayVendorNumber(id)
                    && UInt32(e.productCode) == CGDisplayModelNumber(id)
                    && (e.numericSerial == 0 || e.numericSerial == CGDisplaySerialNumber(id))
            }) {
                result[id] = unmatched.remove(at: i).key
            } else {
                unmatchedScreens.append(id)
            }
        }
        // One screen and one monitor left over (no usable EDID numbers): they are each other.
        if unmatchedScreens.count == 1, unmatched.count == 1 {
            result[unmatchedScreens[0]] = unmatched[0].key
        }
        return result
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
