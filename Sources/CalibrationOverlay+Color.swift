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
        let saved = "已保存\(levelName(sessionLevel))，共 \(calibration.runs(at: sessionLevel).count) 轮"
        if let next = levelQueue.first {
            show(flash: saved + "。接下来是\(levelName(next))。")
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
        show(flash: "已清除 \(m.name) 的颜色校准")
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
            default: return false
            }
        }
        return true
    }

    // MARK: - Text

    func renderColor() {
        guard let engine else { return }
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
        let tab = multiple ? "  ·  Tab 换一台" : ""
        var lines: [String] = []

        if let m {
            let saved = engine.colorCalibration(for: m.key)
            let what = levelName(sessionLevel)
            if let s = session {
                var head = "颜色校准 · \(m.name) · \(what)  ·  第 \(s.answered + 1) 题（一轮约 \(s.expectedQuestions) 题）"
                if !levelQueue.isEmpty { head += "  ·  之后还有 \(levelQueue.count) 档" }
                lines.append(head)
                lines.append(question(s.axis, level: sessionLevel))
                if s.answered == 0 {
                    lines.append("两块屏轮流看，不要盯着一块看太久；拿不准就按 ↓。")
                }
                lines.append("Esc 放弃" + tab)
            } else if let run = pendingRun {
                lines.append("颜色校准 · \(m.name) · \(what)  ·  这一轮完成")
                let grey = sessionLevel < 1
                var result = "这一轮：\(describe(run.shift, grey: grey))。"
                if saved.runs(at: sessionLevel).isEmpty {
                    result += "\n这是这一档的第一轮。换个时间再测一两轮，平均后更可靠。"
                } else {
                    result += saved.disagrees(with: run, at: sessionLevel)
                        ? "和之前的结果差别较大，建议多测几轮再看。"
                        : "和之前的结果一致。"
                    result += "\n和之前 \(saved.runs(at: sessionLevel).count) 轮平均后：\(describe(saved.shift(at: sessionLevel, adding: run), grey: grey))。外屏现在显示的就是平均后的效果。"
                }
                lines.append(result + sdrNote(m))
                let save = levelQueue.isEmpty ? "⏎ 保存" : "⏎ 保存并继续\(levelName(levelQueue[0]))"
                lines.append("\(save)  ·  R 重测这一轮  ·  Esc 不保存退出" + tab)
            } else {
                lines.append("颜色校准 · \(m.name)")
                if confirmClear {
                    lines.append("再按一次 ⌫，清除 \(m.name) 的全部颜色校准。")
                } else {
                    lines.append(summary(saved) + (saved.points.isEmpty ? "" : sdrNote(m)))
                }
                lines.append("W 测白色（约 1 分钟）  ·  G 测灰阶（\(ColorCalibration.greyLevels.count) 档，约 3 分钟）  ·  ⌫ 清除颜色校准  ·  Esc 完成" + tab)
            }
        } else {
            lines.append("没有找到支持 DDC/CI 的外接显示器。")
            lines.append("Esc 退出")
        }
        if let m, session != nil || pendingRun != nil, engine.colorCompensationFallsShort(m.key) {
            let builtin = Int((engine.nits ?? 0).rounded())
            lines.insert("⚠️ 内屏现在 \(builtin) nit，外屏调色后补不到这么亮，两块屏亮度不同会影响颜色判断。先用亮度键把内屏调暗一些再答题。", at: 1)
        }
        if let flash { lines.insert(flash, at: 1) }
        builtinPanel?.caption.stringValue = lines.joined(separator: "\n\n")

        for (key, panel) in externalPanels {
            let name = engine.monitors.first { $0.key == key }?.name ?? "外接显示器"
            panel.surround = 0
            if key == selectedKey {
                panel.dimmed = false
                panel.patchGray = patch
                panel.innerGray = inner
                panel.caption.stringValue = session != nil ? "\(name)\n\n和内屏比较" : name
            } else {
                panel.dimmed = true
                panel.patchGray = nil
                panel.innerGray = nil
                panel.caption.stringValue = "\(name)\n\n按 Tab 切换到这台"
            }
        }
        builtinPanel?.needsLayout = true
        externalPanels.values.forEach { $0.needsLayout = true }
    }

    private func levelName(_ level: Double) -> String {
        level >= 1 ? "白色" : "\(Int((level * 100).rounded()))% 灰"
    }

    private func question(_ axis: ColorSession.Axis, level: Double) -> String {
        let what = level >= 1 ? "白色" : "灰色"
        switch axis {
        case .lightness: return "和内屏比，外屏中间的灰色（对照它周围的白框）显得更亮还是更暗？\n← 更亮        → 更暗        ↓ 看不出差别"
        case .warmth: return "和内屏比，外屏的\(what)更偏哪边？\n← 偏黄（暖）        → 偏蓝（冷）        ↓ 看不出差别"
        case .tint: return "和内屏比，外屏的\(what)更偏哪边？\n← 偏绿        → 偏紫红        ↓ 看不出差别"
        }
    }

    /// One line per level: what is saved, or that it isn't measured yet.
    private func summary(_ saved: ColorCalibration) -> String {
        guard !saved.points.isEmpty else { return "还没有颜色校准。先测白色，再测灰阶。" }
        let rows = ColorCalibration.levels.map { level -> String in
            let runs = saved.runs(at: level).count
            guard let shift = saved.shift(at: level) else { return "\(levelName(level))：未测" }
            return "\(levelName(level))：\(runs) 轮，\(describe(shift, grey: level < 1))"
        }
        return rows.joined(separator: "\n") + "\n换个时间再测一轮，平均后会更准。"
    }

    /// The correction in words, e.g. "调暖约 300 K，往紫红方向一点".
    private func describe(_ shift: WhiteShift, grey: Bool = false) -> String {
        let k = Int((abs(shift.kelvinChange) / 10).rounded() * 10)
        let warmth = k < 50 ? "冷暖不变" : (shift.mired > 0 ? "调暖约 \(k) K" : "调冷约 \(k) K")
        let tint: String
        switch shift.duv {
        case ..<(-0.003): tint = "往紫红方向较多"
        case ..<(-0.0008): tint = "往紫红方向一点"
        case 0.003...: tint = "往绿方向较多"
        case 0.0008...: tint = "往绿方向一点"
        default: tint = "无绿紫偏差"
        }
        guard grey else { return "\(warmth)，\(tint)" }
        let percent = Int((abs(pow(2, shift.lightness) - 1) * 100).rounded())
        let light = percent < 2 ? "明暗不变" : (shift.lightness > 0 ? "调亮约 \(percent)%" : "调暗约 \(percent)%")
        return "\(warmth)，\(tint)，\(light)"
    }

    /// In SDR the correction lowers the backlit white a little and the brightness mapping
    /// does not make that up, so the brightness calibration should be redone afterwards.
    private func sdrNote(_ m: MonitorInfo) -> String {
        engine?.isHDR(m.key) == false ? "\nSDR 模式下颜色调整会让外屏略暗，做完后建议重新做一次亮度校准。" : ""
    }
}
