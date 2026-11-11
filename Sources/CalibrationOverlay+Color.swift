import AppKit

/// Colour mode: match the external monitor's white, and then its greys, to the built-in panel's.
///
/// Instead of one free adjustment (noisy, and pulled towards wherever it started), each run
/// asks forced-choice questions ("is the external's white more yellow or more blue?") and
/// lets two interleaved staircases close in on the point where the user can no longer tell
/// (`ColorSession`). Between questions both patches go dark for half a second while the next
/// colour is set, so each judgement starts fresh and the change itself is never seen (a grey
/// patch would show the tint moving). No numbers are shown during a run. Saved runs are
/// averaged per level.
///
/// The surround is black here (not the brightness mode's dark grey): on OLED panels black is
/// the one level that is identical on both, so it cannot tint the eye's adaptation.
extension CalibrationOverlay {
    static let blankDuration = 0.5

    /// Starts a run at `level`; `then` are levels to run after it (grey sequence).
    func startColorSession(level: Double = 1, then queue: [Double] = []) {
        guard let engine, let key = selectedKey else {
            render()
            return
        }
        confirmClear = false
        pendingRun = nil
        sessionLevel = level
        levelQueue = queue
        let saved = engine.colorCalibration(for: key)
        // Greys start around white's colour when they have no correction of their own yet.
        var base = saved.shift(at: level) ?? saved.shift ?? .zero
        if level >= 1 || saved.shift(at: level) == nil { base.lightness = 0 }
        session = ColorSession(around: base, grey: level < 1)
        blank()
    }

    /// Drops any run in progress and puts the saved correction back on screen.
    func endColorSession() {
        endPrimarySession()
        session = nil
        pendingRun = nil
        levelQueue = []
        blanking = false
        blankToken += 1
        if engine?.colorPreview != nil { engine?.colorPreview = nil }
    }

    /// Patches dark for a moment while the next colour is set.
    private func blank() {
        guard session != nil else { return }
        blanking = true
        render()
        blankToken += 1
        let token = blankToken
        // Change the colour only once the dark patch is on screen, so the step is never visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.blankToken == token, let key = self.selectedKey, let s = self.session else { return }
            self.engine?.colorPreview = (key, self.sessionLevel, s.shown)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.blankDuration) { [weak self] in
            guard let self, self.blankToken == token, self.isShowing else { return }
            // Write the preview again while still dark: if a profile was just installed (save
            // and continue to the next grey), its table may have loaded over the first write.
            if let key = self.selectedKey, let s = self.session { self.engine?.colorPreview = (key, self.sessionLevel, s.shown) }
            self.blanking = false
            self.render()
        }
    }

    private func answer(_ a: Staircase.Answer) {
        guard !blanking, var s = session else { return }
        s.answer(a)
        session = s
        if s.isDone { finishSession() } else { blank() }
    }

    private func finishSession() {
        guard let engine, let key = selectedKey, let s = session else { return }
        let run = s.result
        pendingRun = run
        session = nil
        // Show what saving would give: this run averaged with the level's earlier ones.
        engine.colorPreview = (key, sessionLevel, engine.colorCalibration(for: key).shift(at: sessionLevel, adding: run))
        render()
    }

    private func savePendingRun() {
        guard let engine, let key = selectedKey, let run = pendingRun else { return }
        var calibration = engine.colorCalibration(for: key)
        calibration.add(run, at: sessionLevel)
        engine.setColorCalibration(calibration, for: key)
        pendingRun = nil
        engine.colorPreview = nil
        let saved = L("Saved %1$@ (runs so far: %2$ld).", levelName(sessionLevel), calibration.runs(at: sessionLevel).count)
        if let next = levelQueue.first {
            show(flash: saved + " " + L("Next: %@.", levelName(next)))
            startColorSession(level: next, then: Array(levelQueue.dropFirst()))
        } else {
            show(flash: saved)
            render()
        }
    }

    private func clearColor() {
        guard let engine, let m = selected else { return }
        guard confirmClear else {
            confirmClear = true
            render()
            return
        }
        confirmClear = false
        endColorSession()
        engine.setColorCalibration(ColorCalibration(), for: m.key)
        show(flash: L("Cleared the color calibration of %@", m.name))
        render()
    }

    // MARK: - Input

    func handleColor(_ event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53 {                                   // esc
            close()
            return true
        }
        if event.keyCode == 48 {                                   // tab
            selectNext()
            return true
        }
        if primarySession != nil || pendingPrimary != nil || primaryCheck { return handlePrimary(event) }
        if session != nil {
            switch event.keyCode {
            case 123: answer(.positive)                            // ← warmer / greener
            case 124: answer(.negative)                            // → cooler / more magenta
            case 125, 49: answer(.same)                            // ↓, space
            default: return false
            }
            return true
        }
        if pendingRun != nil {
            switch event.keyCode {
            case 36, 76: savePendingRun()                          // return
            default:
                guard key == "r" else { return false }
                startColorSession(level: sessionLevel, then: levelQueue)
            }
            return true
        }
        switch event.keyCode {
        case 51: clearColor()                                      // delete
        default:
            switch key {
            case "w", "r": startColorSession(level: 1)
            case "g":
                let greys = ColorCalibration.greyLevels
                startColorSession(level: greys[0], then: Array(greys.dropFirst()))
            case "p": startPrimarySession()
            default: return false
            }
        }
        return true
    }

    // MARK: - Text

    func renderColor() {
        guard let engine else { return }
        if primarySession != nil || pendingPrimary != nil || primaryCheck {
            renderPrimary()
            return
        }
        builtinPanel?.patchColor = nil
        builtinPanel?.stripes = nil
        externalPanels.values.forEach {
            $0.patchColor = nil
            $0.stripes = nil
        }
        let m = selected
        // Black when dark, not grey: a table change scales black to black, so nothing shifts.
        // A grey level shows as a grey square inside a white frame: each screen's own white is
        // the reference, so lightness is judged as grey-to-white, not across the two screens.
        let patch: CGFloat? = blanking ? 0 : nil
        let inner: CGFloat? = !blanking && (session != nil || pendingRun != nil) && sessionLevel < 1 ? CGFloat(sessionLevel) : nil
        builtinPanel?.surround = 0
        builtinPanel?.patchGray = patch
        builtinPanel?.innerGray = inner

        let multiple = engine.monitors.count > 1
        let tab = multiple ? L("  ·  Tab next display") : ""
        var lines: [String] = []

        if let m {
            let saved = engine.colorCalibration(for: m.key)
            let what = levelName(sessionLevel)
            if let s = session {
                var head = L("Color calibration · %1$@ · %2$@  ·  question %3$ld (about %4$@ per run)", m.name, what, s.answered + 1, s.expectedQuestions)
                if !levelQueue.isEmpty { head += L("  ·  levels left after this: %ld", levelQueue.count) }
                lines.append(head)
                lines.append(question(s.axis, level: sessionLevel))
                if s.answered == 0 {
                    lines.append(L("Look at the two screens in turn rather than staring at one; when unsure, press ↓."))
                }
                lines.append(L("Esc give up") + tab)
            } else if let run = pendingRun {
                lines.append(L("Color calibration · %1$@ · %2$@  ·  run finished", m.name, what))
                let grey = sessionLevel < 1
                var result = L("This run: %@.", describe(run.shift, grey: grey))
                if saved.runs(at: sessionLevel).isEmpty {
                    result += "\n" + L("This is the first run for this level. Do another one or two at a different time; the average is more reliable.")
                } else {
                    result += saved.disagrees(with: run, at: sessionLevel)
                        ? " " + L("Quite different from earlier runs; do a few more before trusting it.")
                        : " " + L("Consistent with earlier runs.")
                    result += "\n" + L("Averaged with earlier runs (%1$ld): %2$@. The external display now shows the average.", saved.runs(at: sessionLevel).count, describe(saved.shift(at: sessionLevel, adding: run), grey: grey))
                }
                lines.append(result + sdrNote(m))
                let save = levelQueue.isEmpty ? L("⏎ save") : L("⏎ save and continue with %@", levelName(levelQueue[0]))
                lines.append(save + L("  ·  R redo this run  ·  Esc quit without saving") + tab)
            } else {
                lines.append(L("Color calibration · %@", m.name))
                if confirmClear {
                    lines.append(L("Press ⌫ again to clear all color calibration of %@.", m.name))
                } else {
                    lines.append(summary(saved) + (saved.points.isEmpty ? "" : sdrNote(m)))
                }
                lines.append(L("W white (about 1 min)  ·  G grays (%ld levels, about 4 min)  ·  P primaries (about 3 min)  ·  ⌫ clear color calibration  ·  Esc done", ColorCalibration.greyLevels.count) + tab)
            }
        } else {
            lines.append(L("No external display with DDC/CI found."))
            lines.append(L("Esc quit"))
        }
        if let m, session != nil || pendingRun != nil, engine.colorCompensationFallsShort(m.key) {
            let builtin = Int((engine.nits ?? 0).rounded())
            lines.insert(L("⚠️ The built-in display is at %ld nit, brighter than the external can reach with this color correction. Different brightness skews color judgments; dim the built-in display with the brightness keys first.", builtin), at: 1)
        }
        if let flash { lines.insert(flash, at: 1) }
        builtinPanel?.caption.stringValue = lines.joined(separator: "\n\n")

        for (key, panel) in externalPanels {
            let name = engine.monitors.first { $0.key == key }?.name ?? L("External Display")
            panel.surround = 0
            if key == selectedKey {
                panel.dimmed = false
                panel.patchGray = patch
                panel.innerGray = inner
                panel.caption.stringValue = session != nil ? name + "\n\n" + L("Compare with the built-in display") : name
            } else {
                panel.dimmed = true
                panel.patchGray = nil
                panel.innerGray = nil
                panel.caption.stringValue = name + "\n\n" + L("Press Tab to switch to this display")
            }
        }
        builtinPanel?.needsLayout = true
        externalPanels.values.forEach { $0.needsLayout = true }
    }

    private func levelName(_ level: Double) -> String {
        level >= 1 ? L("White") : L("%ld%% Gray", Int((level * 100).rounded()))
    }

    private func question(_ axis: ColorSession.Axis, level: Double) -> String {
        let grey = level < 1
        switch axis {
        case .lightness: return L("Compared with the built-in display, does the external’s gray (against its white frame) look lighter or darker?\n← Lighter        → Darker        ↓ Can’t tell")
        case .warmth: return grey
            ? L("Compared with the built-in display, which way does the external’s gray lean?\n← Yellower (warmer)        → Bluer (cooler)        ↓ Can’t tell")
            : L("Compared with the built-in display, which way does the external’s white lean?\n← Yellower (warmer)        → Bluer (cooler)        ↓ Can’t tell")
        case .tint: return grey
            ? L("Compared with the built-in display, which way does the external’s gray lean?\n← Greener        → More magenta        ↓ Can’t tell")
            : L("Compared with the built-in display, which way does the external’s white lean?\n← Greener        → More magenta        ↓ Can’t tell")
        }
    }

    /// One line per level: what is saved, or that it isn't measured yet.
    private func summary(_ saved: ColorCalibration) -> String {
        guard !saved.isEmpty else { return L("No color calibration yet. Suggested order: white, grays, primaries.") }
        let rows = ColorCalibration.levels.map { level -> String in
            let runs = saved.runs(at: level).count
            guard let shift = saved.shift(at: level) else { return L("%@: not measured", levelName(level)) }
            return L("%1$@: %3$@ (runs: %2$ld)", levelName(level), runs, describe(shift, grey: level < 1))
        }
        let primaries = saved.primaries.map { L("%1$@: %3$@ (runs: %2$ld)", L("Primaries"), saved.primaryRuns.count, describe($0)) } ?? L("%@: not measured", L("Primaries"))
        return (rows + [primaries]).joined(separator: "\n") + "\n" + L("Another run at a different time makes the average more accurate.")
    }

    /// The correction in words, e.g. "about 300 K warmer, slightly more magenta".
    private func describe(_ shift: WhiteShift, grey: Bool = false) -> String {
        let k = Int((abs(shift.kelvinChange) / 10).rounded() * 10)
        let warmth = k < 50 ? L("warmth unchanged") : (shift.mired > 0 ? L("about %ld K warmer", k) : L("about %ld K cooler", k))
        let tint: String
        switch shift.duv {
        case ..<(-0.003): tint = L("noticeably more magenta")
        case ..<(-0.0008): tint = L("slightly more magenta")
        case 0.003...: tint = L("noticeably greener")
        case 0.0008...: tint = L("slightly greener")
        default: tint = L("no green/magenta change")
        }
        guard grey else { return [warmth, tint].joined(separator: L(", ")) }
        let percent = Int((abs(pow(2, shift.lightness) - 1) * 100).rounded())
        let light = percent < 2 ? L("lightness unchanged") : (shift.lightness > 0 ? L("about %ld%% lighter", percent) : L("about %ld%% darker", percent))
        return [warmth, tint, light].joined(separator: L(", "))
    }

    /// In SDR the correction lowers the backlit white a little and the brightness mapping
    /// does not make that up, so the brightness calibration should be redone afterwards.
    private func sdrNote(_ m: MonitorInfo) -> String {
        engine?.isHDR(m.key) == false ? "\n" + L("In SDR the color correction makes the external slightly darker; redo the brightness calibration afterwards.") : ""
    }
}
