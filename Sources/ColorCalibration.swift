import Foundation

/// One matched grey level: the patch's sRGB value (1 is white) and the shift found for it.
struct ColorPoint: Equatable {
    var level: Double
    var shift: WhiteShift
}

/// A monitor's saved colour correction: for white and for a few grey levels, several matching
/// runs each, averaged. One run is a noisy judgement; averaging runs (ideally on different
/// occasions) evens it out. Grey levels exist because two panels can agree on white and still
/// differ in dark greys, which one scale per channel cannot fix.
struct ColorCalibration: Codable, Equatable {
    struct Run: Codable, Equatable {
        var shift: WhiteShift
        var date: Date
    }

    /// Levels that can be matched, as sRGB grey values. 0.12 is the calibration screens' old
    /// dark-grey surround, where the difference was first noticed.
    static let levels: [Double] = [1, 0.5, 0.25, 0.12]
    static let greyLevels: [Double] = [0.5, 0.25, 0.12]
    static let maxRuns = 5

    /// White's runs (kept under this name so data saved before grey levels still loads).
    private(set) var runs: [Run] = []
    /// Grey levels' runs, keyed by `key(_:)`.
    private(set) var greyRuns: [String: [Run]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runs = try c.decodeIfPresent([Run].self, forKey: .runs) ?? []
        greyRuns = try c.decodeIfPresent([String: [Run]].self, forKey: .greyRuns) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case runs, greyRuns }

    static func key(_ level: Double) -> String { String(format: "%.2f", level) }

    func runs(at level: Double) -> [Run] { level >= 1 ? runs : greyRuns[Self.key(level)] ?? [] }

    /// White's correction: mean of its runs.
    var shift: WhiteShift? { shift(at: 1) }

    func shift(at level: Double) -> WhiteShift? { Self.mean(runs(at: level).map(\.shift)) }

    /// What the level's correction would be with `run` added.
    func shift(at level: Double, adding run: Run) -> WhiteShift {
        Self.mean((runs(at: level) + [run]).suffix(Self.maxRuns).map(\.shift))!
    }

    /// Every level with a saved correction, darkest first.
    var points: [ColorPoint] {
        Self.levels.reversed().compactMap { l in shift(at: l).map { ColorPoint(level: l, shift: $0) } }
    }

    /// Whether `run` lands far from the level's saved runs. Within one run there are too few
    /// answers to tell a steady observer from an erratic one (simulations: even very noisy
    /// observers rarely contradict their own result), so consistency is judged across runs.
    func disagrees(with run: Run, at level: Double) -> Bool {
        guard let mean = shift(at: level) else { return false }
        return abs(run.shift.mired - mean.mired) > 8 || abs(run.shift.duv - mean.duv) > 0.0025
            || abs(run.shift.lightness - mean.lightness) > 0.15
    }

    mutating func add(_ run: Run, at level: Double) {
        var list = runs(at: level) + [run]
        if list.count > Self.maxRuns { list.removeFirst(list.count - Self.maxRuns) }
        if level >= 1 { runs = list } else { greyRuns[Self.key(level)] = list }
    }

    private static func mean(_ shifts: [WhiteShift]) -> WhiteShift? {
        guard !shifts.isEmpty else { return nil }
        let n = Double(shifts.count)
        return WhiteShift(mired: shifts.map(\.mired).reduce(0, +) / n, duv: shifts.map(\.duv).reduce(0, +) / n,
                          lightness: shifts.map(\.lightness).reduce(0, +) / n)
    }
}

/// Adaptive staircase on one axis, driven by forced-choice answers.
///
/// Each answer says on which side of the reference the test currently looks. The value steps
/// the other way; whenever the direction flips (a reversal) the step halves. The point of
/// subjective equality is estimated from the last reversals, which is far steadier than one
/// free adjustment.
struct Staircase {
    enum Answer {
        /// The external looks shifted in this axis's positive direction (warmer / greener).
        case positive
        /// It looks shifted the negative way (cooler / more magenta).
        case negative
        /// No visible difference: the value holds and counts as a reversal. A run may end
        /// near whichever edge of the can't-tell band it entered first, but the start side is
        /// random, so that bias averages out over runs. In simulation this beat both moving
        /// the value by a coin flip and a maximum-likelihood fit over all answers, except for
        /// very noisy observers with a very wide band.
        case same
    }

    private(set) var value: Double
    private(set) var step: Double
    let minStep: Double
    let range: ClosedRange<Double>
    private(set) var reversals: [Double] = []
    private(set) var trials = 0
    private var lastDirection = 0

    static let reversalsNeeded = 6
    static let maxTrials = 18
    /// Reversals used for the estimate (the early ones still carry the start offset).
    static let tail = 4

    init(start: Double, step: Double, minStep: Double, range: ClosedRange<Double>) {
        value = start
        self.step = step
        self.minStep = minStep
        self.range = range
    }

    var isDone: Bool { reversals.count >= Self.reversalsNeeded || trials >= Self.maxTrials }

    mutating func answer(_ a: Answer) {
        trials += 1
        guard a != .same else {
            reversals.append(value)
            step = max(minStep, step / 2)
            return
        }
        let direction = a == .positive ? -1 : 1
        if lastDirection != 0, direction != lastDirection {
            reversals.append(value)
            step = max(minStep, step / 2)
        }
        lastDirection = direction
        value = min(range.upperBound, max(range.lowerBound, value + Double(direction) * step))
    }

    var estimate: Double {
        let tail = reversals.suffix(Self.tail)
        return tail.isEmpty ? value : tail.reduce(0, +) / Double(tail.count)
    }
}

/// One white-point matching run: two staircases (warm/cool and green/magenta) asked in a
/// random interleaved order, each starting on a random side of the previous estimate.
struct ColorSession {
    enum Axis { case warmth, tint, lightness }

    private(set) var warmth: Staircase
    private(set) var tint: Staircase
    /// Only for grey levels.
    private(set) var lightness: Staircase?
    private(set) var axis: Axis = .warmth
    private var rng: SplitMix

    init(around base: WhiteShift, grey: Bool, seed: UInt64 = .random(in: 0...UInt64.max)) {
        var rng = SplitMix(seed: seed)
        func side() -> Double { Bool.random(using: &rng) ? 1 : -1 }
        warmth = Staircase(start: base.mired + side() * 30, step: 16, minStep: 2, range: -90...90)
        tint = Staircase(start: base.duv + side() * 0.008, step: 0.005, minStep: 0.0006, range: -0.025...0.025)
        // Lightness in stops: start ±0.3 (about ±23 %), finest step 0.025 (about 1.7 %).
        lightness = grey ? Staircase(start: base.lightness + side() * 0.3, step: 0.2, minStep: 0.025, range: -1...1) : nil
        self.rng = rng
        axis = openAxes.randomElement(using: &self.rng)!
    }

    private var openAxes: [Axis] {
        var open: [Axis] = []
        if !warmth.isDone { open.append(.warmth) }
        if !tint.isDone { open.append(.tint) }
        if let l = lightness, !l.isDone { open.append(.lightness) }
        return open
    }

    /// The shift the external should show for the current question.
    var shown: WhiteShift { WhiteShift(mired: warmth.value, duv: tint.value, lightness: lightness?.value ?? 0) }

    var isDone: Bool { openAxes.isEmpty }
    var answered: Int { warmth.trials + tint.trials + (lightness?.trials ?? 0) }
    /// Typical length of a run, for the progress line (from simulated runs).
    var expectedQuestions: String { lightness == nil ? "20–30" : "25–35" }

    mutating func answer(_ a: Staircase.Answer) {
        switch axis {
        case .warmth: warmth.answer(a)
        case .tint: tint.answer(a)
        case .lightness: lightness?.answer(a)
        }
        if let next = openAxes.randomElement(using: &rng) { axis = next }
    }

    var result: ColorCalibration.Run {
        ColorCalibration.Run(shift: WhiteShift(mired: warmth.estimate, duv: tint.estimate, lightness: lightness?.estimate ?? 0),
                             date: Date())
    }
}

/// Small seedable generator, so a session's random choices can be replayed in tests.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
