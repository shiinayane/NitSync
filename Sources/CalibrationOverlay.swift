import AppKit

/// Full-screen calibration: every screen gets the same dark surround with a white patch of the
/// same physical size, so the user only has to compare the patches and press keys.
///
/// The built-in screen shows the controls (slider and buttons); the keyboard works from any
/// screen. The system brightness keys still change the built-in panel, since they are not
/// key events the app sees.
final class CalibrationOverlay {
    weak var engine: SyncEngine?
    private(set) var isShowing = false

    private var windows: [NSWindow] = []
    private var builtinPanel: PatchView?
    /// Patch views on external screens, by monitor key.
    private var externalPanels: [String: PatchView] = [:]
    private var builtForKeys: [String] = []

    private var selectedKey: String?
    private var value: Double = 50
    /// Set once the user adjusts the value; until then it follows the live mapping.
    private var touched = false
    private var confirmClear = false
    private var flash: String?
    private var flashToken = 0

    private var keyMonitor: Any?
    private var screenObserver: Any?

    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "保存这个点", target: nil, action: nil)
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)
    private lazy var controls: NSStackView = makeControls()

    private var selected: MonitorInfo? { engine?.monitors.first { $0.key == selectedKey } }

    /// The selected monitor is in HDR, where it ignores DDC brightness, so matching is pointless.
    private var selectedIsHDR: Bool {
        guard let engine, let key = selectedKey else { return false }
        return engine.isHDR(key)
    }

    // MARK: - Showing

    func show() {
        guard let engine else { return }
        if isShowing {
            NSApp.activate()
            (builtinPanel?.window ?? windows.first)?.makeKeyAndOrderFront(nil)
            return
        }
        isShowing = true
        touched = false
        confirmClear = false
        flash = nil
        if selected == nil { selectedKey = engine.monitors.first?.key }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShowing else { return event }
            return self.handle(event) ? nil : event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.buildWindows() }

        buildWindows()
        NSApp.activate()
        refresh()
    }

    func close() {
        guard isShowing else { return }
        isShowing = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        keyMonitor = nil
        screenObserver = nil
        tearDownWindows()
        touched = false
        engine?.resync()
    }

    private func tearDownWindows() {
        controls.removeFromSuperview()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        builtinPanel = nil
        externalPanels = [:]
    }

    private func buildWindows() {
        guard isShowing, let engine else { return }
        tearDownWindows()
        builtForKeys = engine.monitors.map(\.key)
        let keys = Screens.monitorKeys(engine.monitors)

        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let key = keys[id]
            guard isBuiltin || key != nil else { continue }

            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.appearance = NSAppearance(named: .darkAqua)

            let mm = CGDisplayScreenSize(id)
            let pointsPerMM = mm.width > 0 ? screen.frame.width / mm.width : 4
            let view = PatchView(frame: NSRect(origin: .zero, size: screen.frame.size))
            // About 9 cm on each screen, but never more than 45 % of its height.
            view.patchSide = min(90 * pointsPerMM, screen.frame.height * 0.45).rounded()
            window.contentView = view

            if isBuiltin {
                builtinPanel = view
                view.controls = controls
            } else if let key {
                externalPanels[key] = view
            }
            windows.append(window)
            window.orderFrontRegardless()
        }
        (builtinPanel?.window ?? windows.first)?.makeKeyAndOrderFront(nil)
        refresh()
    }

    // MARK: - State

    /// Called on every engine update while the overlay is up.
    func refresh() {
        guard isShowing, let engine else { return }
        if engine.monitors.map(\.key) != builtForKeys {
            buildWindows()
            return
        }
        if selected == nil {
            if touched {
                touched = false
                engine.resync()
            }
            selectedKey = engine.monitors.first?.key
        }
        if !touched, let m = selected, let p = engine.predictedPercent(for: m) { value = p.rounded() }
        render()
    }

    private func setValue(_ v: Double) {
        guard let key = selectedKey, let engine, !selectedIsHDR else { return }
        touched = true
        confirmClear = false
        value = min(100, max(0, v.rounded()))
        engine.manualOverride = true
        engine.setManual(percent: value, for: key)
        render()
    }

    private func save() {
        guard let engine, let m = selected, let nits = engine.nits, engine.builtinAvailable, !selectedIsHDR else { return }
        var calibration = engine.calibration(for: m.key)
        calibration.add(nits: nits, value: value)
        engine.setCalibration(calibration, for: m.key)
        show(flash: "已保存：内屏 \(Int(nits.rounded())) nit ↔ \(m.name) \(Int(value))")
        touched = false
        confirmClear = false
        engine.resync()
    }

    private func clear() {
        guard let engine, let m = selected else { return }
        guard confirmClear else {
            confirmClear = true
            render()
            return
        }
        confirmClear = false
        engine.setCalibration(Calibration(), for: m.key)
        show(flash: "已清除 \(m.name) 的校准")
        touched = false
        engine.resync()
    }

    private func selectNext() {
        guard let engine, engine.monitors.count > 1 else { return }
        let keys = engine.monitors.map(\.key)
        let next = keys[((keys.firstIndex { $0 == selectedKey } ?? -1) + 1) % keys.count]
        if touched {
            touched = false
            engine.resync()
        }
        confirmClear = false
        selectedKey = next
        refresh()
    }

    private func show(flash text: String) {
        flash = text
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.flash = nil
            self.render()
        }
    }

    // MARK: - Input

    private func handle(_ event: NSEvent) -> Bool {
        let step: Double = event.modifierFlags.contains(.shift) ? 5 : 1
        switch event.keyCode {
        case 123, 125: setValue(value - step)          // ← ↓
        case 124, 126: setValue(value + step)          // → ↑
        case 36, 76: save()                            // return, enter
        case 53: close()                               // esc
        case 48: selectNext()                          // tab
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": clear()
            default: return false
            }
        }
        return true
    }

    @objc private func sliderMoved() { setValue(slider.doubleValue) }
    @objc private func saveClicked() { save() }
    @objc private func doneClicked() { close() }

    private func makeControls() -> NSStackView {
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 320).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        valueLabel.textColor = NSColor(white: 0.75, alpha: 1)
        valueLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        let stack = NSStackView(views: [slider, valueLabel, saveButton, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        return stack
    }

    // MARK: - Text

    private func render() {
        guard isShowing, let engine else { return }
        let m = selected
        let multiple = engine.monitors.count > 1

        slider.doubleValue = value
        slider.isEnabled = m != nil && !selectedIsHDR
        valueLabel.stringValue = "\(Int(value))"
        saveButton.isEnabled = m != nil && engine.builtinAvailable && !selectedIsHDR

        let keys = "←/→ 调外接亮度（按住 ⇧ 每次 5）  ·  ⏎ 保存这个点  ·  Esc 完成  ·  R 清除这台的校准"
            + (multiple ? "  ·  Tab 换一台" : "")
        let builtinLine = "内屏 " + (engine.nits.map { "\(Int($0.rounded())) nit" } ?? "—")
        let status: String
        if let m {
            status = builtinLine + "  ·  \(m.name) " + reading(for: m.key)
        } else {
            status = builtinLine
        }
        builtinPanel?.caption.stringValue = [status, flash ?? hint(), keys].joined(separator: "\n\n")

        for (key, panel) in externalPanels {
            let monitor = engine.monitors.first { $0.key == key }
            let name = monitor?.name ?? "外接显示器"
            if key == selectedKey {
                panel.caption.stringValue = "\(name)  " + reading(for: key) + "\n\n" + (flash ?? hint())
                panel.dimmed = false
            } else {
                panel.caption.stringValue = "\(name)\n\n按 Tab 切换到这台"
                panel.dimmed = true
            }
        }
        builtinPanel?.needsLayout = true
        externalPanels.values.forEach { $0.needsLayout = true }
    }

    /// "HDR · 70 nit" for an HDR monitor, else the DDC value being shown.
    private func reading(for key: String) -> String {
        guard let engine, engine.isHDR(key) else { return "\(Int(value))" }
        return "HDR · " + (engine.hdrNits[key].map { "\(Int($0.rounded())) nit" } ?? "—")
    }

    private func hint() -> String {
        guard let engine else { return "" }
        guard let m = selected else { return "没有找到支持 DDC/CI 的外接显示器。" }
        guard engine.builtinAvailable, let nits = engine.nits else { return "内屏关闭或休眠中，没法校准。" }
        if confirmClear { return "再按一次 R，清除 \(m.name) 的全部校准点。" }
        if selectedIsHDR {
            return "\(m.name) 开着 HDR：系统直接把它的白色设成和内屏一样的 nit，不需要校准。\n"
                + "如果两块白色看起来还是不一样，可以关掉这台的 HDR，改用 DDC 校准。"
        }

        let points = engine.calibration(for: m.key).points
        let near = points.first { abs(log($0.nits / nits)) < log(1.25) }
        let replaceNote = near.map { "（现在的内屏亮度和已保存的 \(Int($0.nits.rounded())) nit 很接近，保存会替换它。）" } ?? ""

        switch points.count {
        case 0:
            return "第 1 步：调到两块白色看起来一样亮，按 ⏎ 保存。"
        case 1:
            let p = points[0].nits
            let direction = p >= 100
                ? "明显更暗（建议 \(Int((p * 0.5).rounded())) nit 左右）"
                : "明显更亮（建议 \(Int((p * 2).rounded())) nit 左右）"
            return "第 2 步：用键盘的亮度键把内屏调到\(direction)，再对齐、保存。" + replaceNote
        default:
            return "已保存 \(points.count) 个点。中间亮度还不一致的话可以再补一个点，否则按 Esc 完成。" + replaceNote
        }
    }
}

/// Borderless full-screen window that can still take the keyboard.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Dark surround, a centred white patch, and text (plus optional controls) below it.
private final class PatchView: NSView {
    var patchSide: CGFloat = 300 { didSet { needsLayout = true; needsDisplay = true } }
    /// Unselected monitors show a grey patch so it is clear which one is being adjusted.
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    let caption = NSTextField(wrappingLabelWithString: "")
    var controls: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let controls { addSubview(controls) }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        caption.alignment = .center
        caption.font = .systemFont(ofSize: 15)
        caption.textColor = NSColor(white: 0.62, alpha: 1)
        caption.isSelectable = false
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The patch sits a little above centre to leave room for the text.
    private var patchRect: NSRect {
        NSRect(x: (bounds.midX - patchSide / 2).rounded(),
               y: (bounds.midY - patchSide / 2 + bounds.height * 0.08).rounded(),
               width: patchSide, height: patchSide)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        (dimmed ? NSColor(white: 0.3, alpha: 1) : NSColor.white).setFill()
        patchRect.fill()
    }

    override func layout() {
        super.layout()
        let width = min(760, bounds.width - 80)
        caption.preferredMaxLayoutWidth = width
        let height = caption.fittingSize.height
        var y = patchRect.minY - 28 - height
        caption.frame = NSRect(x: (bounds.midX - width / 2).rounded(), y: y.rounded(), width: width, height: height)
        if let controls {
            let size = controls.fittingSize
            y -= 24 + size.height
            controls.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: y.rounded(), width: size.width, height: size.height)
        }
    }
}
