import AppKit
import IOKit

/// What the main thread knows about a connected monitor.
struct MonitorInfo: Equatable {
    let key: String
    let name: String
    let edid: EDID?

    /// White at 100 % assumed before the monitor is calibrated: the EDID's full-frame figure if it has one.
    var uncalibratedMaxNits: Double { edid?.estimatedFullWhiteNits ?? Calibration.defaultMaxNits }
}

/// Serialises DDC traffic: one write at a time, at most one every 60 ms (DDC/CI asks for 50),
/// and only the newest
/// requested value per monitor is sent when requests pile up.
final class DDCWriter {
    private let queue = DispatchQueue(label: "nitsync.ddc")
    private var monitors: [DDC.Monitor] = []
    /// Newest requested value (0–100 %) per monitor key.
    private var pending: [String: Double] = [:]
    private var busy = false
    private var lastWrite = DispatchTime(uptimeNanoseconds: 0)
    var onFailure: (() -> Void)?

    func rediscover(_ done: @escaping ([MonitorInfo]) -> Void) {
        queue.async {
            self.monitors = DDC.discover()
            let infos = self.monitors.map { MonitorInfo(key: $0.key, name: $0.name, edid: $0.edid) }
            DispatchQueue.main.async { done(infos) }
        }
    }

    func set(_ percents: [String: Double]) {
        queue.async {
            self.pending.merge(percents) { $1 }
            self.drain()
        }
    }

    private func drain() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        queue.asyncAfter(deadline: max(.now(), lastWrite + .milliseconds(60))) {
            defer {
                self.lastWrite = .now()
                self.busy = false
                self.drain()
            }
            let batch = self.pending
            self.pending = [:]
            var ok = !self.monitors.isEmpty
            for m in self.monitors {
                guard let percent = batch[m.key] else { continue }
                let value = Int((percent / 100 * Double(m.maxValue)).rounded())
                if !DDC.write(m.service, vcp: DDC.brightnessVCP, value: value) { ok = false }
            }
            if !ok, let onFailure = self.onFailure { DispatchQueue.main.async(execute: onFailure) }
        }
    }
}

/// How a monitor's brightness is driven, decided from what macOS is sending it.
enum DriveMode: Equatable {
    /// SDR: the signal is relative, so the monitor's backlight sets the brightness (DDC).
    case sdr
    /// HDR: the signal is absolute (PQ) and the monitor ignores DDC; macOS places SDR white.
    case hdr(CGDirectDisplayID)
}

/// Follows the built-in panel's luminance and drives each external monitor to match:
/// its backlight over DDC in SDR, or the SDR white level macOS renders in HDR.
/// Runs on the main thread. It never touches brightness keys, event taps or on-screen HUDs.
final class SyncEngine {
    /// Sampling while anything moves: fast enough to trace the system's ~250 ms brightness
    /// fade frame by frame, so external monitors follow the same curve.
    private static let activeInterval = 1.0 / 60
    /// Sampling when nothing moves; also bounds how late a change is noticed. Each sample is
    /// one registry property read, so 20 Hz costs next to nothing.
    private static let idleInterval = 0.05
    /// Time constant of the easing toward the built-in level. The system's fade already arrives
    /// as a smooth curve, so this only rounds off the end and adds ~20 ms of lag.
    private static let followTime = 0.02
    /// Fastest change allowed, in log luminance per second. A key-press fade (peaking near 15)
    /// passes untouched; a change that arrives as one jump becomes a ~0.2 s fade.
    private static let maxRate = 20.0

    private let writer = DDCWriter()
    private let defaults = UserDefaults.standard
    private var framebuffer: io_service_t = 0

    /// Connected monitors that answer DDC, one entry per calibration key.
    private(set) var monitors: [MonitorInfo] = []
    var monitorCount: Int { monitors.count }
    private(set) var searching = true
    /// Last luminance read from the built-in panel; kept while it is off or asleep.
    private(set) var nits: Double?
    private(set) var builtinAvailable = false
    /// Last DDC value (0–100 %) sent to each SDR monitor, by key.
    private(set) var sentPercent: [String: Double] = [:]
    /// Current mode per monitor key, refreshed every tick.
    private(set) var modes: [String: DriveMode] = [:]
    /// SDR white each HDR monitor is showing (nits), read back from its framebuffer.
    private(set) var hdrNits: [String: Double] = [:]
    private var hdrFramebuffers: [CGDirectDisplayID: io_service_t] = [:]
    private var lastHDRWrite = Date.distantPast

    /// Luminance each monitor is being driven to (nits), easing toward the built-in panel's.
    private var shownNits: [String: Double] = [:]
    /// Per HDR monitor, how far its level sits from the table's estimate, learned from its
    /// framebuffer once it has settled. Lets each frame be set open-loop during a fade.
    private var hdrOffset: [String: Double] = [:]
    /// Last level written per HDR monitor, to skip identical writes.
    private var hdrLevel: [String: Double] = [:]

    func isHDR(_ key: String) -> Bool {
        if case .hdr = modes[key] { return true }
        return false
    }

    private var lastNitsChange = Date.distantPast
    private var lastTick = Date()
    private var lastModeCheck = Date.distantPast
    private var lastUpdate = Date.distantPast
    private var wasActive = false
    private var lastDiscovery = Date.distantPast
    private var forceNextWrite = true
    private var rediscoverScheduled = false

    /// While true (calibration slider in use) the engine reads but does not write.
    var manualOverride = false

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "enabled")
            if enabled { forceNextWrite = true }
        }
    }

    /// Calibration per monitor key. A monitor without an entry uses its EDID-based estimate.
    private var calibrations: [String: Calibration] {
        didSet {
            if let data = try? JSONEncoder().encode(calibrations) { defaults.set(data, forKey: "calibrations") }
            forceNextWrite = true
        }
    }

    func calibration(for key: String) -> Calibration { calibrations[key] ?? Calibration() }

    func setCalibration(_ calibration: Calibration, for key: String) { calibrations[key] = calibration }

    var onUpdate: (() -> Void)?

    init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        if let data = defaults.data(forKey: "calibrations"),
           let saved = try? JSONDecoder().decode([String: Calibration].self, from: data) {
            calibrations = saved
        } else {
            calibrations = [:]
        }
        writer.onFailure = { [weak self] in self?.scheduleRediscover(after: 3) }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRediscover(after: 2)
            }
        }
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let engine = Unmanaged<SyncEngine>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { engine.scheduleRediscover(after: 2) }
        }, Unmanaged.passUnretained(self).toOpaque())

        refreshHardware()
        tick()
    }

    /// The DDC value the mapping currently asks for on this monitor.
    func predictedPercent(for monitor: MonitorInfo) -> Double? {
        nits.map { calibration(for: monitor.key).value(forNits: $0, uncalibratedMaxNits: monitor.uncalibratedMaxNits) }
    }

    func setManual(percent: Double, for key: String) {
        let v = percent.rounded()
        sentPercent[key] = v
        writer.set([key: v])
    }

    func resync() {
        manualOverride = false
        forceNextWrite = true
        tick(reschedule: false)
    }

    // MARK: - Hardware discovery

    private func refreshHardware() {
        if framebuffer != 0 { IOObjectRelease(framebuffer) }
        framebuffer = BuiltinDisplay.framebuffer() ?? 0
        hdrFramebuffers.values.forEach { IOObjectRelease($0) }
        hdrFramebuffers = [:]
        lastDiscovery = Date()
        searching = true
        writer.rediscover { [weak self] found in
            guard let self else { return }
            var seen = Set<String>()
            self.monitors = found.filter { seen.insert($0.key).inserted }
            self.migrateLegacyCalibration()
            self.searching = false
            self.forceNextWrite = true
            self.onUpdate?()
        }
    }

    /// Versions before per-monitor calibration kept one shared calibration; it goes to the
    /// first monitor seen, since that is the one it was made with.
    private func migrateLegacyCalibration() {
        guard let first = monitors.first, let data = defaults.data(forKey: "calibration") else { return }
        if calibrations[first.key] == nil, let legacy = try? JSONDecoder().decode(Calibration.self, from: data), !legacy.points.isEmpty {
            calibrations[first.key] = legacy
        }
        defaults.removeObject(forKey: "calibration")
    }

    private func scheduleRediscover(after seconds: Double) {
        guard !rediscoverScheduled else { return }
        rediscoverScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.rediscoverScheduled = false
            self.refreshHardware()
        }
    }

    // MARK: - Sync loop

    private func readNits() -> Double? {
        guard framebuffer != 0, let id = BuiltinDisplay.displayID(), CGDisplayIsAsleep(id) == 0 else { return nil }
        return BuiltinDisplay.nits(framebuffer)
    }

    /// Works out which monitors macOS is driving in HDR and reads back their SDR white.
    private func updateModes() {
        var next: [String: DriveMode] = [:]
        for m in monitors { next[m.key] = .sdr }
        if HDRBrightness.isAvailable {
            let keys = Screens.monitorKeys(monitors)
            for screen in NSScreen.screens {
                guard let id = screen.displayID, let key = keys[id],
                      screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01 else { continue }
                next[key] = .hdr(id)
            }
        }
        if next != modes {
            // A monitor coming back to SDR needs its DDC value sent again, one entering HDR its level.
            forceNextWrite = true
            hdrLevel = [:]
            modes = next
        }

        var nits: [String: Double] = [:]
        var live = Set<CGDirectDisplayID>()
        for (key, mode) in next {
            guard case let .hdr(id) = mode else { continue }
            live.insert(id)
            if hdrFramebuffers[id] == nil, let fb = HDRBrightness.framebuffer(for: id) { hdrFramebuffers[id] = fb }
            if let fb = hdrFramebuffers[id], let n = HDRBrightness.nits(fb) { nits[key] = n }
        }
        for (id, fb) in hdrFramebuffers where !live.contains(id) {
            IOObjectRelease(fb)
            hdrFramebuffers[id] = nil
        }
        hdrNits = nits
    }

    private func tick(reschedule: Bool = true) {
        let now = Date()
        // Capped so the first frame after an idle wait doesn't count as a long step.
        let dt = min(1.0 / 30, now.timeIntervalSince(lastTick))
        lastTick = now
        // Modes and HDR read-back change slowly; no need to check them every frame.
        if now.timeIntervalSince(lastModeCheck) >= 0.5 {
            lastModeCheck = now
            updateModes()
            if enabled, !manualOverride { correctHDR(now: now) }
        }

        var easing = false
        let reading = readNits()
        builtinAvailable = reading != nil
        if let reading {
            if let old = nits {
                if abs(reading - old) > max(0.05, old * 0.005) { lastNitsChange = now }
            } else {
                lastNitsChange = now
            }
            nits = reading
            if enabled, !manualOverride, !monitors.isEmpty {
                easing = drive(toward: reading, dt: dt, now: now)
            }
        }
        // With no reading (lid closed, panel asleep) the monitor keeps its last value.

        // Wake and reconfiguration already trigger discovery; this is only a slow fallback.
        if monitorCount == 0, !searching, now.timeIntervalSince(lastDiscovery) > 60 {
            refreshHardware()
        }

        let active = easing || now.timeIntervalSince(lastNitsChange) < 0.5
        // The menu and calibration screen don't need every frame.
        if now.timeIntervalSince(lastUpdate) >= (active ? 0.1 : 1) || active != wasActive || !reschedule {
            lastUpdate = now
            onUpdate?()
        }
        wasActive = active

        guard reschedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (active ? Self.activeInterval : Self.idleInterval)) { [weak self] in
            self?.tick()
        }
    }

    /// Eases every monitor toward `target` (in log luminance) and sends the result.
    /// Returns whether any monitor is still on its way.
    private func drive(toward target: Double, dt: Double, now: Date) -> Bool {
        let fraction = 1 - exp(-dt / Self.followTime)
        let limit = Self.maxRate * dt
        var easing = false
        var ddc: [String: Double] = [:]
        for m in monitors {
            var shown = shownNits[m.key] ?? target
            let gap = log(target / shown)
            // Arriving counts as a change, so the final DDC value is not held back by hysteresis.
            var arrived = false
            if abs(gap) < 0.003 {
                arrived = shown != target
                shown = target
            } else {
                shown *= exp(max(-limit, min(limit, gap * fraction)))
                easing = true
            }
            shownNits[m.key] = shown

            if case let .hdr(id) = modes[m.key] {
                setHDR(nits: shown, key: m.key, display: id, now: now)
                continue
            }
            let value = calibration(for: m.key).value(forNits: shown, uncalibratedMaxNits: m.uncalibratedMaxNits)
            let v = value.rounded()
            let changed = sentPercent[m.key].map { v != $0 && (arrived || abs(value - $0) >= 0.75) } ?? true
            if forceNextWrite || changed {
                sentPercent[m.key] = v
                ddc[m.key] = v
            }
        }
        forceNextWrite = false
        if !ddc.isEmpty { writer.set(ddc) }
        return easing
    }

    /// HDR: put the monitor's SDR white at `nits`. PQ is absolute, so matching nits matches
    /// brightness without calibration. Writes are open-loop (table plus learned offset) so a
    /// fade can be sent frame by frame; `correctHDR` fixes the offset once things settle.
    private func setHDR(nits: Double, key: String, display id: CGDirectDisplayID, now: Date) {
        let level = min(1, max(0, HDRBrightness.estimatedLevel(forNits: nits) + (hdrOffset[key] ?? 0)))
        if let last = hdrLevel[key], abs(last - level) < 0.0005 { return }
        HDRBrightness.setLevel(level, for: id)
        hdrLevel[key] = level
        lastHDRWrite = now
    }

    /// Compares each settled HDR monitor's framebuffer reading with its target and, if they
    /// differ, relearns the offset from the level actually in effect (so a change made in
    /// System Settings is corrected too).
    private func correctHDR(now: Date) {
        guard now.timeIntervalSince(lastHDRWrite) > 0.3 else { return }
        for m in monitors {
            guard case let .hdr(id) = modes[m.key], let target = shownNits[m.key], target == nits,
                  let actual = hdrNits[m.key], abs(actual - target) > max(0.5, target * 0.015),
                  let level = HDRBrightness.level(id) else { continue }
            hdrOffset[m.key] = min(0.3, max(-0.3, level - HDRBrightness.estimatedLevel(forNits: actual)))
            let next = min(1, max(0, HDRBrightness.estimatedLevel(forNits: target) + hdrOffset[m.key]!))
            // At either end of the range the gap cannot be closed; don't keep rewriting.
            guard abs(next - level) > 0.0005 else { continue }
            HDRBrightness.setLevel(next, for: id)
            hdrLevel[m.key] = next
            lastHDRWrite = now
        }
    }
}
