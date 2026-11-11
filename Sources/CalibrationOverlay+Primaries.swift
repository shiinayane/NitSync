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
        guard let engine, let key = selectedKey,
              let id = Screens.monitorKeys(engine.monitors).first(where: { $0.value == key })?.key,
              let data = DisplayProfiles.factoryProfileData(id),
              let colourants = PrimaryMath.colourants(ofICC: data),
              let active = externalPanels[key]?.window?.screen?.colorSpace?.cgColorSpace else {
            show(flash: "读不到这台显示器的颜色描述文件，没法测原色。")
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
        show(flash: "已保存原色，共 \(calibration.primaryRuns.count) 轮。")
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
        let tab = engine.monitors.count > 1 ? "  ·  Tab 换一台" : ""
        var builtinColor: NSColor?
        var externalColor: NSColor?

        let stripes: [NSColor]? = primaryCheck ? Primary.allCases.map { NSColor(srgbRed: $0.srgb.0, green: $0.srgb.1, blue: $0.srgb.2, alpha: 1) } : nil
        if primaryCheck {
            lines.append("颜色校准 · \(m.name) · 原色  ·  保存后的实际效果")
            lines.append("现在两块屏都按各自的描述文件正常显示红、绿、蓝。和内屏比，三种颜色还一致吗？\n一致就按 Esc 完成；不一致可以按 R 再测一轮。")
            lines.append("⏎ 返回  ·  R 再测一轮  ·  Esc 完成" + tab)
        } else if let s = primarySession {
            let (p, axis) = s.current
            let (r, g, b) = p.srgb
            builtinColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            externalColor = previewColor(p, shifts: s.shown)
            lines.append("颜色校准 · \(m.name) · 原色  ·  第 \(s.answered + 1) 题（一轮约 \(PrimarySession.expectedQuestions) 题）")
            switch axis {
            case .hue:
                lines.append("和内屏比，外屏的\(p.name)色更偏哪边？\n← 偏\(p.positiveHueName)        → 偏\(p.negativeHueName)        ↓ 看不出差别")
            case .saturation:
                lines.append("和内屏比，外屏的\(p.name)色更鲜艳还是更淡？\n← 更鲜艳        → 更淡        ↓ 看不出差别")
            }
            if s.answered == 0 { lines.append("颜色每题都会换，两块屏轮流看；拿不准就按 ↓。") }
            lines.append("Esc 放弃" + tab)
        } else if let run = pendingPrimary {
            let saved = engine.colorCalibration(for: m.key)
            lines.append("颜色校准 · \(m.name) · 原色  ·  这一轮完成")
            var result = "这一轮：\(describe(run.shifts))。"
            if saved.primaryRuns.isEmpty {
                result += "\n这是第一轮。换个时间再测一两轮，平均后更可靠。"
            } else {
                result += saved.disagrees(with: run) ? "和之前的结果差别较大，建议多测几轮再看。" : "和之前的结果一致。"
                result += "\n和之前 \(saved.primaryRuns.count) 轮平均后：\(describe(saved.primaries(adding: run)))。"
            }
            lines.append(result + "\n保存后会写进外屏的颜色描述文件，所有 App 的颜色都会按新的原色显示。")
            lines.append("⏎ 保存  ·  R 重测这一轮  ·  Esc 不保存退出" + tab)
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
            panel.caption.stringValue = isSelected ? m.name + (primarySession != nil ? "\n\n和内屏比较" : "") : "\(engine.monitors.first { $0.key == key }?.name ?? "外接显示器")\n\n按 Tab 切换到这台"
        }
        builtinPanel?.needsLayout = true
        externalPanels.values.forEach { $0.needsLayout = true }
    }

    /// The correction in words, one primary per clause.
    func describe(_ shifts: [Primary: PrimaryShift]) -> String {
        func amount(_ v: Double) -> String? {
            switch abs(v) {
            case ..<0.002: return nil
            case ..<0.006: return "一点"
            default: return "较多"
            }
        }
        return Primary.allCases.map { p -> String in
            let s = shifts[p] ?? PrimaryShift()
            var parts: [String] = []
            if let a = amount(s.hue) { parts.append("往\(s.hue > 0 ? p.positiveHueName : p.negativeHueName)调\(a)") }
            if let a = amount(s.saturation) { parts.append("\(s.saturation > 0 ? "更鲜艳" : "更淡")\(a)") }
            return "\(p.name)：" + (parts.isEmpty ? "不变" : parts.joined(separator: "、"))
        }.joined(separator: "；")
    }
}
