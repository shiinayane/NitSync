import AppKit
import simd

/// Colour mode, primaries: match sRGB red, green and blue on the external to the built-in's.
///
/// The questions are like the white and grey ones (forced choice, dark pause, no numbers),
/// but the preview cannot use the gamma table: moving a primary mixes channels. Instead the
/// external's patch is drawn with the device values colour management *would* produce with
/// the candidate primaries (a candidate profile converts the sRGB colour), handed to the
/// screen in its own colour space so they pass through untouched. Saving writes the
/// primaries into the display's profile, after which every app shows the change.
extension CalibrationOverlay {
    func startPrimarySession() {
        guard let engine, let key = selectedKey else { return }
        guard engine.builtinAvailable, builtinPanel != nil else {
            show(flash: L("The built-in display is off or asleep, so calibration isn’t possible."))
            render()
            return
        }
        guard let id = Screens.monitorKeys(engine.monitors).first(where: { $0.value == key })?.key,
              let data = DisplayProfiles.factoryProfileData(id),
              let colourants = PrimaryMath.colourants(ofICC: data),
              let active = externalPanels[key]?.window?.screen?.colorSpace?.cgColorSpace else {
            show(flash: L("Can’t read this display’s color profile, so primaries can’t be calibrated."))
            render()
            return
        }
        endColorSession()
        confirmClear = false
        primaryBase = (data, colourants, active)
        primarySession = PrimarySession(around: engine.colorCalibration(for: key).primaries ?? [:])
        blankPrimary()
    }

    func endPrimarySession() {
        primarySession = nil
        pendingPrimary = nil
        primaryBase = nil
        primaryCheck = false
    }

    /// Dark patches for a moment, then the next question's colours.
    private func blankPrimary() {
        blanking = true
        render()
        blankToken += 1
        let token = blankToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.blankDuration) { [weak self] in
            guard let self, self.blankToken == token, self.isShowing else { return }
            self.blanking = false
            self.render()
        }
    }

    private func answerPrimary(_ a: Staircase.Answer) {
        guard !blanking, var s = primarySession else { return }
        s.answer(a)
        if s.isDone {
            primarySession = nil
            pendingPrimary = s.result
            render()
        } else {
            primarySession = s
            blankPrimary()
        }
    }

    private func savePrimary() {
        guard let engine, let key = selectedKey, let run = pendingPrimary else { return }
        var calibration = engine.colorCalibration(for: key)
        calibration.add(run)
        engine.setColorCalibration(calibration, for: key)
        endPrimarySession()
        // Show the three colours drawn normally, through the newly installed profile, so the
        // user can check the real result against the preview it was matched with.
        primaryCheck = true
        show(flash: L("Primaries saved (runs so far: %ld).", calibration.primaryRuns.count))
        render()
        // The profile switch takes a moment; redraw once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.builtinPanel?.needsDisplay = true
            self?.externalPanels.values.forEach { $0.needsDisplay = true }
            self?.render()
        }
    }

    func handlePrimary(_ event: NSEvent) -> Bool {
        if primaryCheck {
            switch event.keyCode {
            case 36, 76:                                           // return: back to the summary
                primaryCheck = false
                render()
            default:
                guard event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
                startPrimarySession()
            }
            return true
        }
        if primarySession != nil {
            switch event.keyCode {
            case 123: answerPrimary(.positive)                     // ← more orange/yellow/cyan, or more saturated
            case 124: answerPrimary(.negative)                     // → the other way, or paler
            case 125, 49: answerPrimary(.same)                     // ↓, space
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 36, 76: savePrimary()                                 // return
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
            startPrimarySession()
        }
        return true
    }

    // MARK: - Drawing

    /// Device colour the external shows for `primary` with the candidate `shifts`.
    private func previewColor(_ primary: Primary, shifts: [Primary: PrimaryShift]) -> NSColor? {
        guard let base = primaryBase,
              let profile = PrimaryMath.profile(base.data, colourants: PrimaryMath.colourants(base.colourants, shifts: shifts)),
              let candidate = CGColorSpace(iccData: profile as CFData) else { return nil }
        let (r, g, b) = primary.srgb
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let device = CGColor(colorSpace: srgb, components: [r, g, b, 1])?
                .converted(to: candidate, intent: .relativeColorimetric, options: nil)?.components,
              let shown = CGColor(colorSpace: base.active, components: device.map { min(1, max(0, $0)) }) else { return nil }
        return NSColor(cgColor: shown)
    }

    func renderPrimary() {
        guard let engine, let m = selected else { return }
        var lines: [String] = []
        let tab = engine.monitors.count > 1 ? L("  ·  Tab next display") : ""
        var builtinColor: NSColor?
        var externalColor: NSColor?

        let stripes: [NSColor]? = primaryCheck ? Primary.allCases.map { NSColor(srgbRed: $0.srgb.0, green: $0.srgb.1, blue: $0.srgb.2, alpha: 1) } : nil
        if primaryCheck {
            lines.append(L("Color calibration · %1$@ · %2$@  ·  result after saving", m.name, L("Primaries")))
            lines.append(L("Both screens now draw red, green and blue normally through their own profiles. Do the three colors still match the built-in display?\nIf they do, press Esc to finish; if not, press R for another run."))
            lines.append(L("⏎ back  ·  R another run  ·  Esc done") + tab)
        } else if let s = primarySession {
            let (p, axis) = s.current
            let (r, g, b) = p.srgb
            builtinColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            externalColor = previewColor(p, shifts: s.shown)
            lines.append(L("Color calibration · %1$@ · %2$@  ·  question %3$ld (about %4$@ per run)", m.name, L("Primaries"), s.answered + 1, PrimarySession.expectedQuestions))
            switch axis {
            case .hue:
                lines.append(L("Compared with the built-in display, which way does the external’s %1$@ lean?\n← More %2$@        → More %3$@        ↓ Can’t tell", p.name, p.positiveHueName, p.negativeHueName))
            case .saturation:
                lines.append(L("Compared with the built-in display, is the external’s %@ more vivid or paler?\n← More vivid        → Paler        ↓ Can’t tell", p.name))
            }
            if s.answered == 0 { lines.append(L("The color changes with each question. Look at the two screens in turn; when unsure, press ↓.")) }
            lines.append(L("Esc give up"))
        } else if let run = pendingPrimary {
            let saved = engine.colorCalibration(for: m.key)
            lines.append(L("Color calibration · %1$@ · %2$@  ·  run finished", m.name, L("Primaries")))
            var result = L("This run: %@.", describe(run.shifts))
            if saved.primaryRuns.isEmpty {
                result += "\n" + L("This is the first run. Do another one or two at a different time; the average is more reliable.")
            } else {
                result += " " + (saved.disagrees(with: run) ? L("Quite different from earlier runs; do a few more before trusting it.") : L("Consistent with earlier runs."))
                result += "\n" + L("Averaged with earlier runs (%1$ld): %2$@.", saved.primaryRuns.count, describe(saved.primaries(adding: run)))
            }
            lines.append(result + "\n" + L("Saving writes this into the external display’s color profile; color-managed apps will show colors with the new primaries."))
            lines.append(L("⏎ save") + L("  ·  R redo this run  ·  Esc quit without saving"))
        }
        if let flash { lines.insert(flash, at: 1) }

        let dark: CGFloat? = blanking ? 0 : nil
        builtinPanel?.surround = 0
        builtinPanel?.innerGray = nil
        builtinPanel?.patchGray = dark
        builtinPanel?.patchColor = builtinColor
        builtinPanel?.stripes = stripes
        builtinPanel?.caption.stringValue = lines.joined(separator: "\n\n")
        for (key, panel) in externalPanels {
            panel.surround = 0
            panel.innerGray = nil
            let isSelected = key == selectedKey
            panel.dimmed = !isSelected
            panel.patchGray = isSelected ? dark : nil
            panel.patchColor = isSelected ? externalColor : nil
            panel.stripes = isSelected ? stripes : nil
            panel.caption.stringValue = isSelected
                ? m.name + (primarySession != nil ? "\n\n" + L("Compare with the built-in display") : "")
                : (engine.monitors.first { $0.key == key }?.name ?? L("External Display")) + "\n\n" + L("Press Tab to switch to this display")
        }
        builtinPanel?.needsLayout = true
        externalPanels.values.forEach { $0.needsLayout = true }
    }

    /// The correction in words, one primary per clause.
    func describe(_ shifts: [Primary: PrimaryShift]) -> String {
        func noticeable(_ v: Double) -> Bool? {
            switch abs(v) {
            case ..<0.002: return nil
            case ..<0.006: return false
            default: return true
            }
        }
        return Primary.allCases.map { p -> String in
            let s = shifts[p] ?? PrimaryShift()
            var parts: [String] = []
            if let big = noticeable(s.hue) {
                let hue = s.hue > 0 ? p.positiveHueName : p.negativeHueName
                parts.append(big ? L("noticeably more %@", hue) : L("slightly more %@", hue))
            }
            if let big = noticeable(s.saturation) {
                parts.append(s.saturation > 0
                    ? (big ? L("noticeably more vivid") : L("slightly more vivid"))
                    : (big ? L("noticeably paler") : L("slightly paler")))
            }
            return L("%1$@ %2$@", p.name, parts.isEmpty ? L("unchanged") : parts.joined(separator: L(", ")))
        }.joined(separator: L("; "))
    }
}
