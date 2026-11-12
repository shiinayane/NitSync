import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = SyncEngine()
    private let calibration = CalibrationOverlay()
    private var statusItem: NSStatusItem!

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let noteLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// One line per external monitor, right after `statusLine`.
    private var monitorLines: [NSMenuItem] = []
    private let syncItem = NSMenuItem(title: L("Follow Built-in Brightness"), action: #selector(toggleSync), keyEquivalent: "")
    private let calibrateItem = NSMenuItem(title: L("Brightness Calibration…"), action: #selector(openCalibration), keyEquivalent: "")
    private let colorItem = NSMenuItem(title: L("Color Calibration…"), action: #selector(openColorCalibration), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: L("Open at Login"), action: #selector(toggleLogin), keyEquivalent: "")
    private var shownSymbol = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        noteLine.isEnabled = false
        for item in [syncItem, calibrateItem, colorItem, loginItem] { item.target = self }
        menu.items = [
            statusLine, noteLine, .separator(),
            syncItem, calibrateItem, colorItem, .separator(),
            loginItem,
            NSMenuItem(title: L("Quit NitSync"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        menu.delegate = self
        statusItem.menu = menu

        calibration.engine = engine
        engine.onUpdate = { [weak self] in self?.refresh() }
        engine.start()

        // `open NitSync.app --args --calibrate` goes straight to calibration once monitors are found.
        if CommandLine.arguments.contains("--calibrate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.calibration.show(.brightness) }
        }
        // `--reset-color` removes all colour calibration and NitSync's display profiles, then quits.
        if CommandLine.arguments.contains("--reset-color") {
            resetColorWhenReady(deadline: Date().addingTimeInterval(15))
        }
        // `--calibrate-color` does the same for colour calibration; `--calibrate-grey` also
        // starts the grey levels (for checking that screen without a keyboard).
        if ["--calibrate-color", "--calibrate-grey", "--calibrate-primaries"].contains(where: CommandLine.arguments.contains) {
            let grey = CommandLine.arguments.contains("--calibrate-grey")
            let primaries = CommandLine.arguments.contains("--calibrate-primaries")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.calibration.show(.color)
                if primaries { self?.calibration.startPrimarySession() }
                if grey {
                    let levels = ColorCalibration.greyLevels
                    self?.calibration.startColorSession(level: levels[0], then: Array(levels.dropFirst()))
                }
            }
        }
    }

    /// `--reset-color`: once monitors are found (at least 2 s, so displays have settled), remove
    /// every colour calibration and quit. A display that isn't connected keeps its profile entry
    /// (it can only be put back while connected); retried until `deadline`, then reported.
    private func resetColorWhenReady(deadline: Date, started: Date = Date()) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if (self.engine.searching || Date().timeIntervalSince(started) < 2), Date() < deadline {
                return self.resetColorWhenReady(deadline: deadline, started: started)
            }
            let skipped = self.engine.resetAllColor()
            if !skipped.isEmpty, Date() < deadline {
                return self.resetColorWhenReady(deadline: deadline, started: .distantPast)
            }
            if !skipped.isEmpty {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("Some color profiles were left in place")
                alert.informativeText = L("Couldn’t put back the original color profile of: %@. Make sure these displays are connected, then run this again.", skipped.joined(separator: ", "))
                alert.runModal()
            }
            NSApp.terminate(nil)
        }
    }

    /// The menu's lines are only rebuilt while it is open (or about to open).
    private var menuOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func refresh() {
        let symbol = engine.enabled ? "sun.max" : "sun.min"
        if symbol != shownSymbol {
            shownSymbol = symbol
            statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NitSync")
        }
        calibration.refresh()
        guard menuOpen else { return }

        statusLine.title = L("Built-in: %@", engine.nits.map { String(format: "%.0f nit", $0) } ?? "—")

        let lines: [String]
        if engine.monitors.isEmpty {
            lines = [L("External: %@", engine.searching ? L("searching…") : "—")]
        } else {
            lines = engine.monitors.map { m in
                if engine.isHDR(m.key) {
                    return "→  \(m.name)  HDR · " + (engine.effectiveHDRNits(m.key).map { String(format: "%.0f nit", $0) } ?? "—")
                }
                return "→  \(m.name)  SDR · " + (engine.sentPercent[m.key].map { "\(Int($0))" } ?? "—")
            }
        }
        setMonitorLines(lines)

        // HDR monitors match by nits and need no calibration.
        let uncalibrated = engine.monitors.filter { !engine.isHDR($0.key) && !engine.calibration(for: $0.key).isCalibrated }
        var note: String?
        if engine.monitorCount == 0 && !engine.searching {
            note = L("No external display with DDC/CI found")
        } else if !engine.builtinAvailable {
            note = L("Built-in display is off or asleep; external keeps its brightness")
        } else if uncalibrated.count == 1, engine.monitorCount == 1 {
            note = L("Not calibrated yet; brightness is estimated")
        } else if !uncalibrated.isEmpty {
            note = L("%@: not calibrated yet; brightness is estimated", uncalibrated.map(\.name).joined(separator: L(", ")))
        }
        noteLine.title = note ?? ""
        noteLine.isHidden = note == nil

        syncItem.state = engine.enabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func setMonitorLines(_ titles: [String]) {
        guard let menu = statusItem.menu else { return }
        if monitorLines.count != titles.count {
            monitorLines.forEach(menu.removeItem)
            monitorLines = titles.map { _ in
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            }
            let start = menu.index(of: statusLine) + 1
            for (i, item) in monitorLines.enumerated() { menu.insertItem(item, at: start + i) }
        }
        for (item, title) in zip(monitorLines, titles) where item.title != title { item.title = title }
    }

    @objc private func toggleSync() {
        engine.enabled.toggle()
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Couldn’t change the login item")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }

    @objc private func openCalibration() {
        calibration.show(.brightness)
    }

    @objc private func openColorCalibration() {
        calibration.show(.color)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
