import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = SyncEngine()
    private let calibration = CalibrationOverlay()
    private var statusItem: NSStatusItem!

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let noteLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// One line per external monitor, right after `statusLine`.
    private var monitorLines: [NSMenuItem] = []
    private let syncItem = NSMenuItem(title: "跟随内屏亮度", action: #selector(toggleSync), keyEquivalent: "")
    private let calibrateItem = NSMenuItem(title: "亮度校准…", action: #selector(openCalibration), keyEquivalent: "")
    private let colorItem = NSMenuItem(title: "颜色校准…", action: #selector(openColorCalibration), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
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
            NSMenuItem(title: "退出 NitSync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.engine.resetAllColor()
                NSApp.terminate(nil)
            }
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

    private func refresh() {
        let symbol = engine.enabled ? "sun.max" : "sun.min"
        if symbol != shownSymbol {
            shownSymbol = symbol
            statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NitSync")
        }

        statusLine.title = "内屏 " + (engine.nits.map { String(format: "%.0f nit", $0) } ?? "—")

        let lines: [String]
        if engine.monitors.isEmpty {
            lines = ["外接 " + (engine.searching ? "查找中" : "—")]
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
            note = "没有找到支持 DDC/CI 的外接显示器"
        } else if !engine.builtinAvailable {
            note = "内屏关闭或休眠中，外接屏保持当前亮度"
        } else if uncalibrated.count == 1, engine.monitorCount == 1 {
            note = "尚未校准，亮度是估算值"
        } else if !uncalibrated.isEmpty {
            note = uncalibrated.map(\.name).joined(separator: "、") + " 尚未校准，亮度是估算值"
        }
        noteLine.title = note ?? ""
        noteLine.isHidden = note == nil

        syncItem.state = engine.enabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        calibration.refresh()
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
            alert.messageText = "无法更改登录项"
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
