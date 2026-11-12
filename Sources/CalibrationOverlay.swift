import AppKit
import simd

/// Full-screen calibration: every screen gets the same dark surround with a white patch of the
/// same physical size, so the user only has to compare the patches and press keys.
///
/// Two modes share the screens: brightness (match the external's luminance with a slider)
/// and colour (match its white point through forced-choice questions; see
/// `CalibrationOverlay+Color.swift`).
///
/// The built-in screen shows the controls (slider and buttons); the keyboard works from any
/// screen. The system brightness keys still change the built-in panel, since they are not
/// key events the app sees.
final class CalibrationOverlay {
    enum Mode { case brightness, color }

    weak var engine: SyncEngine?
    private(set) var isShowing = false
    private(set) var mode: Mode = .brightness

    private var windows: [NSWindow] = []
    var builtinPanel: PatchView?
    /// Patch views on external screens, by monitor key.
    var externalPanels: [String: PatchView] = [:]
    private var builtForKeys: [String] = []

    // Colour mode state (used by the extension).
    var session: ColorSession?
    /// A finished run waiting to be saved or thrown away.
    var pendingRun: ColorCalibration.Run?
    /// Primaries run in progress, or finished and waiting to be saved.
    var primarySession: PrimarySession?
    var pendingPrimary: ColorCalibration.PrimaryRun?
    /// For drawing the primaries preview: the selected display's factory profile and
    /// colourants, and the colour space its screen currently uses.
    var primaryBase: (data: Data, colourants: double3x3, active: CGColorSpace)?
    /// After saving primaries: showing them drawn normally, to check the installed result.
    var primaryCheck = false

    /// Grey level of the run in progress or waiting to be saved (1 is white).
    var sessionLevel: Double = 1
    /// Grey levels still to run after this one.
    var levelQueue: [Double] = []
    /// True while the patches are dark between questions; answers are ignored then.
    var blanking = false
    var blankToken = 0

    var selectedKey: String?
    private var value: Double = 50
    /// Set once the user adjusts the value; until then it follows the live mapping.
    private var touched = false
    var confirmClear = false
    var flash: String?
    private var flashToken = 0

    private var keyMonitor: Any?
    private var screenObserver: Any?

    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L("Save This Point"), target: nil, action: nil)
    private let doneButton = NSButton(title: L("Done"), target: nil, action: nil)
    private lazy var controls: NSStackView = makeControls()

    var selected: MonitorInfo? { engine?.monitors.first { $0.key == selectedKey } }

    /// The selected monitor is in HDR, where it ignores DDC brightness, so matching is pointless.
    var selectedIsHDR: Bool {
        guard let engine, let key = selectedKey else { return false }
        return engine.isHDR(key)
    }

    // MARK: - Showing

    func show(_ mode: Mode = .brightness) {
        guard let engine else { return }
        if isShowing {
            if mode != self.mode { switchMode(to: mode) }
            NSApp.activate()
            (builtinPanel?.window ?? windows.first)?.makeKeyAndOrderFront(nil)
            return
        }
        isShowing = true
        self.mode = mode
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

    private func switchMode(to mode: Mode) {
        endColorSession()
        if touched {
            touched = false
            engine?.resync()
        }
        confirmClear = false
        self.mode = mode
        controls.isHidden = mode == .color
        refresh()
    }

    func close() {
        guard isShowing else { return }
        endColorSession()
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
                controls.isHidden = mode == .color
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
            endColorSession()
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
        show(flash: L("Saved: built-in %1$ld nit ↔ %2$@ %3$ld", Int(nits.rounded()), m.name, Int(value)))
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
        show(flash: L("Cleared the calibration of %@", m.name))
        touched = false
        engine.resync()
    }

    func selectNext() {
        guard let engine, engine.monitors.count > 1 else { return }
        let keys = engine.monitors.map(\.key)
        let next = keys[((keys.firstIndex { $0 == selectedKey } ?? -1) + 1) % keys.count]
        guard next != selectedKey else { return }
        if touched {
            touched = false
            engine.resync()
        }
        let wasAsking = session != nil, level = sessionLevel, queue = levelQueue
        endColorSession()
        confirmClear = false
        selectedKey = next
        refresh()
        if mode == .color, wasAsking { startColorSession(level: level, then: queue) }
    }

    func show(flash text: String) {
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
        // ⌘-shortcuts aren't ours (⌘R must not start clearing).
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if mode == .color { return handleColor(event) }
        let step: Double = event.modifierFlags.contains(.shift) ? 5 : 1
        switch event.keyCode {
        case 123, 125: setValue(value - step)          // ← ↓ (held: keeps stepping)
        case 124, 126: setValue(value + step)          // → ↑
        // Everything else acts once per press: a held key must not confirm its own "press
        // again" (clearing) or save twice.
        case _ where event.isARepeat: break
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

    func render() {
        guard isShowing, let engine else { return }
        if mode == .color {
            renderColor()
            return
        }
        builtinPanel?.patchGray = nil
        builtinPanel?.patchColor = nil
        builtinPanel?.stripes = nil
        builtinPanel?.innerGray = nil
        builtinPanel?.surround = PatchView.defaultSurround
        externalPanels.values.forEach {
            $0.patchGray = nil
            $0.patchColor = nil
            $0.stripes = nil
            $0.innerGray = nil
            $0.surround = PatchView.defaultSurround
        }
        let m = selected
        let multiple = engine.monitors.count > 1

        slider.doubleValue = value
        slider.isEnabled = m != nil && !selectedIsHDR
        valueLabel.stringValue = "\(Int(value))"
        saveButton.isEnabled = m != nil && engine.builtinAvailable && !selectedIsHDR

        let keys = L("←/→ adjust external brightness (hold ⇧ for steps of 5)  ·  ⏎ save this point  ·  Esc done  ·  R clear this display’s calibration")
            + (multiple ? L("  ·  Tab next display") : "")
        let builtinLine = L("Built-in: %@", engine.nits.map { "\(Int($0.rounded())) nit" } ?? "—")
        let status: String
        if let m {
            status = builtinLine + "  ·  \(m.name) " + reading(for: m.key)
        } else {
            status = builtinLine
        }
        builtinPanel?.caption.stringValue = [status, flash ?? hint(), keys].joined(separator: "\n\n")

        for (key, panel) in externalPanels {
            let monitor = engine.monitors.first { $0.key == key }
            let name = monitor?.name ?? L("External Display")
            if key == selectedKey {
                panel.caption.stringValue = "\(name)  " + reading(for: key) + "\n\n" + (flash ?? hint())
                panel.dimmed = false
            } else {
                panel.caption.stringValue = name + "\n\n" + L("Press Tab to switch to this display")
                panel.dimmed = true
            }
        }
        builtinPanel?.needsLayout = true
        externalPanels.values.forEach { $0.needsLayout = true }
    }

    /// "HDR · 70 nit" for an HDR monitor, else the DDC value being shown.
    private func reading(for key: String) -> String {
        guard let engine, engine.isHDR(key) else { return "\(Int(value))" }
        return "HDR · " + (engine.effectiveHDRNits(key).map { "\(Int($0.rounded())) nit" } ?? "—")
    }

    private func hint() -> String {
        guard let engine else { return "" }
        guard let m = selected else { return L("No external display with DDC/CI found.") }
        guard engine.builtinAvailable, let nits = engine.nits else { return L("The built-in display is off or asleep, so calibration isn’t possible.") }
        if confirmClear { return L("Press R again to clear all calibration points of %@.", m.name) }
        if selectedIsHDR {
            return L("%@ is in HDR: its white is set to the same nits as the built-in display, so no calibration is needed.\nIf the two whites still look different, turn off HDR for this display and calibrate over DDC instead.", m.name)
        }

        let points = engine.calibration(for: m.key).points
        let near = points.first { abs(log($0.nits / nits)) < log(1.25) }
        let replaceNote = near.map { " " + L("(The built-in brightness is close to the saved %ld nit point; saving will replace it.)", Int($0.nits.rounded())) } ?? ""

        switch points.count {
        case 0:
            return L("Step 1: adjust until both whites look equally bright, then press ⏎ to save.")
        case 1:
            let p = points[0].nits
            let direction = p >= 100
                ? L("Step 2: use the keyboard’s brightness keys to make the built-in display clearly darker (around %ld nit), then match and save again.", Int((p * 0.5).rounded()))
                : L("Step 2: use the keyboard’s brightness keys to make the built-in display clearly brighter (around %ld nit), then match and save again.", Int((p * 2).rounded()))
            return direction + replaceNote
        default:
            return L("Points saved: %ld. If brightness in between still doesn’t match, add another point; otherwise press Esc to finish.", points.count) + replaceNote
        }
    }
}

/// Borderless full-screen window that can still take the keyboard.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Dark surround, a centred white patch, and text (plus optional controls) below it.
final class PatchView: NSView {
    var patchSide: CGFloat = 300 { didSet { needsLayout = true; needsDisplay = true } }
    /// Unselected monitors show a grey patch so it is clear which one is being adjusted.
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    /// Overrides the patch with this sRGB grey (colour mode's grey levels and dark pauses).
    var patchGray: CGFloat? { didSet { if patchGray != oldValue { needsDisplay = true } } }
    /// Fills the patch with this colour (primaries).
    var patchColor: NSColor? { didSet { if patchColor != oldValue { needsDisplay = true } } }
    /// Fills the patch with these colours as vertical stripes (checking saved primaries).
    var stripes: [NSColor]? { didSet { if stripes != oldValue { needsDisplay = true } } }
    /// Draws a square of this sRGB grey inside the patch, which stays white around it.
    var innerGray: CGFloat? { didSet { if innerGray != oldValue { needsDisplay = true } } }
    static let defaultSurround: CGFloat = 0.12
    /// Grey of the surround (colour mode uses black).
    var surround: CGFloat = PatchView.defaultSurround { didSet { if surround != oldValue { needsDisplay = true } } }
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
        NSColor(white: surround, alpha: 1).setFill()
        bounds.fill()
        (patchGray.map { NSColor(srgbRed: $0, green: $0, blue: $0, alpha: 1) } ?? patchColor
            ?? (dimmed ? NSColor(white: 0.3, alpha: 1) : NSColor.white)).setFill()
        patchRect.fill()
        if let stripes, patchGray == nil {
            let w = patchRect.width / CGFloat(stripes.count)
            for (i, c) in stripes.enumerated() {
                c.setFill()
                NSRect(x: patchRect.minX + CGFloat(i) * w, y: patchRect.minY, width: w, height: patchRect.height).fill()
            }
        }
        if let innerGray {
            NSColor(srgbRed: innerGray, green: innerGray, blue: innerGray, alpha: 1).setFill()
            patchRect.insetBy(dx: patchSide * 0.22, dy: patchSide * 0.22).fill()
        }
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
