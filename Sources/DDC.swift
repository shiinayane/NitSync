import Foundation
import IOKit

/// DDC/CI on Apple Silicon through IOAVService. The IOAVService calls are private
/// IOKit symbols, so they are looked up at runtime instead of linked.
enum DDC {
    struct Monitor {
        let service: CFTypeRef
        let entryID: UInt64
        let maxValue: Int
        let edid: EDID?

        /// Calibration key: from the EDID, so it survives reconnects and port changes.
        var key: String { edid?.key ?? "unknown" }
        var name: String { edid?.name ?? L("External Display") }
    }

    static let brightnessVCP: UInt8 = 0x10

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias EDIDFn = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let createFn: CreateFn? = symbol("IOAVServiceCreateWithService")
    private static let writeFn: I2CFn? = symbol("IOAVServiceWriteI2C")
    private static let readFn: I2CFn? = symbol("IOAVServiceReadI2C")
    private static let edidFn: EDIDFn? = symbol("IOAVServiceCopyEDID")

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// External AV services that answer a DDC brightness read.
    static func discover() -> [Monitor] {
        guard let create = createFn else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var found: [Monitor] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let location = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let svc = create(kCFAllocatorDefault, s)?.takeRetainedValue(),
                  let reply = read(svc, vcp: brightnessVCP), reply.max > 0 else { continue }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &id)
            found.append(Monitor(service: svc, entryID: id, maxValue: reply.max, edid: edid(svc)))
        }
        return found
    }

    /// The EDID the display pipeline already holds for this service; no DDC traffic.
    static func edid(_ svc: CFTypeRef) -> EDID? {
        guard let copy = edidFn else { return nil }
        var out: Unmanaged<CFData>?
        guard copy(svc, &out) == kIOReturnSuccess, let data = out?.takeRetainedValue() else { return nil }
        return EDID(data as Data)
    }

    static func read(_ svc: CFTypeRef, vcp: UInt8) -> (current: Int, max: Int)? {
        guard let write = writeFn, let read = readFn else { return nil }
        var request: [UInt8] = [0x82, 0x01, vcp, 0]
        request[3] = request[0..<3].reduce(0x6E ^ 0x51, ^)
        for _ in 0..<3 {
            usleep(10_000)
            guard write(svc, chipAddress, dataAddress, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var buf = [UInt8](repeating: 0, count: 12)
            guard read(svc, chipAddress, dataAddress, &buf, UInt32(buf.count)) == kIOReturnSuccess else { continue }
            // VCP reply: 0x02, result, vcp, type, maxH, maxL, curH, curL
            for i in 0..<(buf.count - 7) where buf[i] == 0x02 && buf[i + 1] == 0x00 && buf[i + 2] == vcp {
                return (Int(buf[i + 6]) << 8 | Int(buf[i + 7]), Int(buf[i + 4]) << 8 | Int(buf[i + 5]))
            }
        }
        return nil
    }

    static func write(_ svc: CFTypeRef, vcp: UInt8, value: Int) -> Bool {
        guard let write = writeFn else { return false }
        let v = UInt16(clamping: value)
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(v >> 8), UInt8(v & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ 0x51, ^)
        for attempt in 0..<2 {
            if attempt > 0 { usleep(20_000) }
            if write(svc, chipAddress, dataAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess { return true }
        }
        return false
    }
}
