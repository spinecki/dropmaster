//
//  Clipper.swift
//  DropMaster
//
//  An optional stage before the limiter (the panel's Clipper switch), for
//  references that were made loud by clipping. Such a record holds its
//  loudness at its peak level - its peak-to-loudness ratio is small - and
//  a limiter alone cannot get a target there: pushed harder, its release
//  pumps the level down between the peaks (see Matcher, stage 4). A
//  clipper takes peaks off without any release at all, so the loudness a
//  dB of gain brings stays.
//
//  The curve, per channel: straight up to the knee, then a tanh that
//  leaves with slope 1 and bends towards the cap, never reaching it. The
//  knee sits 1.5 dB below the limiter's ceiling and the cap 1.5 dB above
//  it, so the limiter after it has about 1.5 dB left to do - the range
//  where it is transparent (a few tenths more where the low-pass below
//  overshoots the cap; the harness measured about 2 dB against a hard-
//  clipped reference, against 2.6 dB for the limiter alone on a merely
//  loud one). Linked stereo would let a peak on one side
//  pull down the other; a clipper works on each channel's own wave, as
//  the clipped references did.
//
//  How deep it may go is the panel's choice (Off, 1 ... 9 dB, Max). It
//  needs a limit because nothing else stops it: the loudness search in
//  Matcher.finish turns the gain up until the target measures, and where
//  the limiter alone gives up (more gain, no more loudness), the clipper
//  keeps giving - against a loud reference, a dynamic target was clipped
//  7 dB deep and audibly broke up. With a limit, a signal whose loudest
//  peak would be cut deeper has knee and cap raised until that peak is
//  cut exactly that deep; the limiter takes the rest, as it does without
//  the clipper. So every limit lands between Off and Max. Limiting the
//  gain instead was tried first: at 1 dB it came out 1.5 dB quieter than
//  Off, because it held back the limiter too.
//
//  Bending a wave makes harmonics, and at 44.1 kHz the ones above 22 kHz
//  fold back as inharmonic tones. So the curve runs at four times the rate:
//  interpolate, bend, low-pass, take every fourth sample. Only the
//  *difference* the curve makes goes through that round trip:
//
//      out = in + down(curve(up(in)) - up(in))
//
//  Below the knee the difference is exactly zero, so the audio there is
//  the input itself, bit for bit - no filter touches it, there is no seam
//  where clipped passages start, and a song that never reaches the knee
//  comes out unchanged. Blocks whose samples stay 6 dB under the knee
//  (room for peaks between the samples) are not even interpolated.
//
//  The filter is our own windowed sinc (Blackman, 32 taps per phase, 129
//  at the high rate), centred on a sample: phase 0 is the input itself and
//  the round trip has a whole-sample delay, which is taken back out - the
//  result is sample-aligned like the EQ and the limiter. TruePeak has a
//  filter of the same family, but its phases sit between the samples on
//  purpose, which is what a meter wants and a round trip does not.
//
//  Why 32 taps: with 12 (TruePeak's), a 15 kHz tone driven 6 dB past the
//  knee left an alias at 900 Hz only 46 dB down - the interpolator let
//  the tone's image at 29.1 kHz through, and the curve mixed the two. At
//  24 taps it was 86 dB down, at 32 taps 88, at 48 taps 106; without
//  oversampling, 18. A 5-minute match against a clipped reference took
//  1.45, 1.50 and 1.58 s - the filters are not where the time goes.
//

import Foundation
import Accelerate

nonisolated enum Clipper {
    static let factor = 4
    static let tapsPerPhase = 32
    /// The filters reach this many input samples either side.
    private static let reach = tapsPerPhase / 2
    /// Phase p of sample i reads samples i - before ... i + reach.
    private static let before = reach - 1
    /// The cap above the limiter's ceiling: what the limiter is left with.
    static let limiterShareDB = 1.5
    /// The knee, below the cap.
    static let kneeDB = 3.0

    private static func kernel(_ t: Double) -> Double {
        let reachT = Double(reach)
        guard abs(t) < reachT else { return 0 }
        let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
        let w = 0.42 + 0.5 * cos(Double.pi * t / reachT) + 0.08 * cos(2 * Double.pi * t / reachT)
        return sinc * w
    }

    /// Phases 1 to 3 (phase 0 is the sample itself), each scaled to unity
    /// gain at DC; tap k weighs sample i - before + k.
    static let phases: [[Float]] = (1..<factor).map { p in
        let taps = (0..<tapsPerPhase).map { kernel(Double(p) / Double(factor) - Double($0 - before)) }
        let sum = taps.reduce(0, +)
        return taps.map { Float($0 / sum) }
    }

    /// The decimating low-pass at the high rate, `4 × tapsPerPhase + 1`
    /// taps, unity at DC.
    static let lowPass: [Float] = {
        let n = 2 * reach * factor + 1
        let taps = (0..<n).map { kernel(Double($0 - reach * factor) / Double(factor)) }
        let sum = taps.reduce(0, +)
        return taps.map { Float($0 / sum) }
    }()

    /// Knee and cap for a limiter `ceiling` (all linear).
    static func bounds(ceiling: Float) -> (knee: Float, cap: Float) {
        let cap = ceiling * Float(pow(10, limiterShareDB / 20))
        return (cap * Float(pow(10, -kneeDB / 20)), cap)
    }

    /// What one run of the clipper did.
    struct Clipping: Sendable {
        /// The deepest reduction the curve made, in dB (≤ 0).
        var reductionDB: Double
        /// The curve's smallest gain (linear, ≤ 1) in every
        /// `Limiter.reductionChunk` frames, both channels together - the
        /// clipper's counterpart of the limiter's record, for the live
        /// meter's CL bar.
        var record: [Float]
    }

    /// Clips both channels in place under the cap that goes with
    /// `ceiling` (linear).
    ///
    /// `limitDB`: cut no deeper than this. If the loudest peak would go
    /// deeper, the curve is moved up - it is the same shape at any level,
    /// so moving it by the ratio of that peak to the one the limit allows
    /// cuts the peak by exactly the limit.
    static func process(_ audio: StereoAudio, ceiling: Float, limitDB: Double? = nil) throws -> Clipping {
        var raised = ceiling
        if let limitDB {
            let loudest = try peak(audio)
            let allowed = input(forReductionDB: limitDB, ceiling: ceiling)
            if loudest > allowed { raised = ceiling * (loudest / allowed) }
        }
        let (knee, cap) = bounds(ceiling: raised)
        let chunk = Limiter.reductionChunk
        let chunks = (audio.frameCount + chunk - 1) / chunk
        // One record per channel, each written by its own thread.
        let records = UnsafeMutablePointer<Float>.allocate(capacity: 2 * max(chunks, 1))
        defer { records.deallocate() }
        records.initialize(repeating: 1, count: 2 * max(chunks, 1))
        nonisolated(unsafe) let shared = records
        let deepest = try bothChannels(audio) { x, count in
            try clip(x, count: count, knee: knee, cap: cap, record: shared + (x == audio.left ? 0 : chunks))
        }
        var record = [Float](repeating: 1, count: chunks)
        vDSP_vmin(records, 1, records + chunks, 1, &record, 1, vDSP_Length(chunks))
        guard deepest > knee else { return Clipping(reductionDB: 0, record: record) }
        return Clipping(reductionDB: 20 * log10(Double(curve(deepest, knee: knee, cap: cap) / deepest)), record: record)
    }

    /// The largest magnitude of `audio` at the curve's rate - the one
    /// `process` would see - without changing it.
    static func peak(_ audio: StereoAudio) throws -> Float {
        try bothChannels(audio) { try clip($0, count: $1, knee: 0, cap: 0, measureOnly: true) }
    }

    /// The input magnitude at which the curve takes `reductionDB` off.
    /// The curve's gain falls steadily from 1 at the knee towards 0, so a
    /// bisection finds it.
    static func input(forReductionDB reductionDB: Double, ceiling: Float) -> Float {
        let (knee, cap) = bounds(ceiling: ceiling)
        let want = pow(10, -abs(reductionDB) / 20)
        let k = Double(knee), span = Double(cap - knee)
        func gain(_ a: Double) -> Double { (k + span * tanh((a - k) / span)) / a }
        var low = k, high = 2 * k
        while gain(high) > want { low = high; high *= 2 }
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if gain(middle) > want { low = middle } else { high = middle }
        }
        return Float((low + high) / 2)
    }

    /// The curve for a magnitude.
    static func curve(_ a: Float, knee: Float, cap: Float) -> Float {
        a <= knee ? a : knee + (cap - knee) * tanh((a - knee) / (cap - knee))
    }

    /// `work` on each channel, on two cores; the larger of the two results.
    private static func bothChannels(_ audio: StereoAudio,
                                     _ work: @escaping (UnsafeMutablePointer<Float>, Int) throws -> Float) throws -> Float {
        nonisolated(unsafe) let channels = [audio.left, audio.right]
        nonisolated(unsafe) let work = work
        let count = audio.frameCount
        let lock = NSLock()
        nonisolated(unsafe) var largest: Float = 0
        nonisolated(unsafe) var failure: Error?
        DispatchQueue.concurrentPerform(iterations: channels.count) { c in
            do {
                let value = try work(channels[c], count)
                lock.withLock { largest = max(largest, value) }
            } catch {
                lock.withLock { failure = error }
            }
        }
        if let failure { throw failure }
        return largest
    }

    /// One channel, in blocks. Returns the largest interpolated magnitude
    /// that reached the curve (0 if none did) - or, `measureOnly`, the
    /// largest of all, leaving the channel as it is. `record`, if given,
    /// receives the curve's gain at the loudest peak of every
    /// `Limiter.reductionChunk` frames (it starts at 1, and blocks the
    /// curve never reaches leave it there).
    private static func clip(_ x: UnsafeMutablePointer<Float>, count: Int, knee: Float, cap: Float,
                             measureOnly: Bool = false, record: UnsafeMutablePointer<Float>? = nil) throws -> Float {
        let block = 65_536
        let detect = knee / 2
        let span = cap - knee
        // Input of one block with its context: samples a - left ..< b + right.
        let left = reach + before
        let right = reach + tapsPerPhase - before
        var input = [Float](repeating: 0, count: block + left + right)
        let maximumRows = block + 2 * reach
        var phase = [Float](repeating: 0, count: maximumRows)
        var high = [Float](repeating: 0, count: maximumRows * factor)
        var bent = [Float](repeating: 0, count: maximumRows * factor)
        var excess = [Float](repeating: 0, count: maximumRows * factor)
        var correction = [Float](repeating: 0, count: block)
        var largest: Float = 0

        var a = 0
        while a < count {
            try Task.checkCancellation()
            let b = min(a + block, count)
            let n = b - a
            let rows = n + 2 * reach

            // Context, zero beyond either end of the song.
            let length = n + left + right
            for i in 0..<length {
                let source = a - left + i
                input[i] = source >= 0 && source < count ? x[source] : 0
            }
            var loudest: Float = 0
            vDSP_maxmgv(input, 1, &loudest, vDSP_Length(length))
            if !measureOnly && loudest < detect { a = b; continue }

            // Up: row r is input sample a - reach + r, at four phases.
            input.withUnsafeBufferPointer { inp in
                high.withUnsafeMutableBufferPointer { h in
                    let base = inp.baseAddress!
                    // Phase 0: the samples themselves.
                    cblas_scopy(Int32(rows), base + before, 1, h.baseAddress!, Int32(factor))
                    for p in 1..<factor {
                        phases[p - 1].withUnsafeBufferPointer { f in
                            vDSP_conv(base, 1, f.baseAddress!, 1, &phase, 1,
                                      vDSP_Length(rows), vDSP_Length(tapsPerPhase))
                        }
                        cblas_scopy(Int32(rows), phase, 1, h.baseAddress! + p, Int32(factor))
                    }
                }
            }

            // Bend: what the curve takes off, zero below the knee.
            let total = rows * factor
            var top: Float = 0
            vDSP_maxmgv(high, 1, &top, vDSP_Length(total))
            if measureOnly { largest = max(largest, top); a = b; continue }
            if top <= knee { a = b; continue }
            largest = max(largest, top)
            // The block starts on a chunk boundary (65 536 = 64 × 1024);
            // chunk c's frames are rows reach + c × 1024 onwards.
            if let record {
                let chunk = Limiter.reductionChunk
                var start = 0
                while start < n {
                    let frames = min(chunk, n - start)
                    var loudest: Float = 0
                    high.withUnsafeBufferPointer { h in
                        vDSP_maxmgv(h.baseAddress! + (reach + start) * factor, 1, &loudest, vDSP_Length(frames * factor))
                    }
                    if loudest > knee {
                        record[(a + start) / chunk] = curve(loudest, knee: knee, cap: cap) / loudest
                    }
                    start += frames
                }
            }
            var negativeKnee = -knee, zero: Float = 0, inverse = 1 / span, scale = span
            var n32 = Int32(total)
            vDSP_vabs(high, 1, &excess, 1, vDSP_Length(total))
            vDSP_vsadd(excess, 1, &negativeKnee, &excess, 1, vDSP_Length(total))
            vDSP_vthres(excess, 1, &zero, &excess, 1, vDSP_Length(total))      // above the knee, ≥ 0
            vDSP_vsmul(excess, 1, &inverse, &bent, 1, vDSP_Length(total))
            vvtanhf(&bent, bent, &n32)
            vDSP_vsmul(bent, 1, &scale, &bent, 1, vDSP_Length(total))          // what is left of it
            vDSP_vsub(bent, 1, excess, 1, &excess, 1, vDSP_Length(total))      // taken off, ≥ 0
            vvcopysignf(&bent, excess, high, &n32)                             // with the wave's sign

            // Down: low-pass at the high rate, every fourth sample. Output j
            // is centred on row reach + j, which is input sample a + j.
            vDSP_desamp(bent, factor, lowPass, &correction, vDSP_Length(n), vDSP_Length(lowPass.count))
            for j in 0..<n where correction[j] != 0 {
                x[a + j] -= correction[j]
            }
            a = b
        }
        return largest
    }
}
