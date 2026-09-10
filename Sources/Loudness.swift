import Foundation
import AVFoundation

// MARK: - Reading

/// A station's measured programme loudness, kept as a running mean: one 25 s sample
/// of a live stream swings by a few LU depending on what happens to be on air, so
/// each play refines the figure instead of replacing it.
struct LoudnessReading: Codable, Hashable {
    var lufs: Double
    var samples: Int
    var measuredAt: Date

    /// EBU R128 broadcast target. Radio France sits on it; community streams on
    /// AzuraCast routinely run 6–8 LU hotter, which is the whole point of showing this.
    static let broadcastReference: Double = -18

    /// How much louder than the broadcast reference this station plays, in LU.
    var overReference: Double { lufs - Self.broadcastReference }
    /// Loud enough that switching to it noticeably jumps the level.
    var isHot: Bool { overReference >= 4 }

    var pretty: String { String(format: "%.1f LUFS", lufs) }
    var offsetPretty: String { String(format: "%+.0f LU", overReference) }
}

// MARK: - Measurement

/// Integrated loudness to EBU R128 / ITU-R BS.1770-4, computed with Apple frameworks
/// only — no external dependency, in keeping with the rest of the app.
/// Cross-checked against ffmpeg's `ebur128` filter on an identical file:
/// −11.73 LUFS here vs −11.7 LUFS there.
enum Loudness {

    /// K-weighting: a high shelf followed by an RLB high-pass, cascaded into one
    /// 5-tap IIR. Coefficients are derived for the file's actual sample rate rather
    /// than assuming the 48 kHz of the specification tables.
    private struct KWeighting {
        let b: [Double], a: [Double]

        init(rate: Double) {
            let f1 = 1681.974450955533, gain = 3.999843853973347, q1 = 0.7071752369554196
            let k1 = tan(.pi * f1 / rate)
            let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
            let d1 = 1 + k1 / q1 + k1 * k1
            let shelfB = [(vh + vb * k1 / q1 + k1 * k1) / d1,
                          2 * (k1 * k1 - vh) / d1,
                          (vh - vb * k1 / q1 + k1 * k1) / d1]
            let shelfA = [1.0, 2 * (k1 * k1 - 1) / d1, (1 - k1 / q1 + k1 * k1) / d1]

            let f2 = 38.13547087602444, q2 = 0.5003270373238773
            let k2 = tan(.pi * f2 / rate)
            let d2 = 1 + k2 / q2 + k2 * k2
            let hpB = [1.0, -2.0, 1.0]
            let hpA = [1.0, 2 * (k2 * k2 - 1) / d2, (1 - k2 / q2 + k2 * k2) / d2]

            b = KWeighting.convolve(shelfB, hpB)
            a = KWeighting.convolve(shelfA, hpA)
        }

        private static func convolve(_ x: [Double], _ y: [Double]) -> [Double] {
            var r = [Double](repeating: 0, count: x.count + y.count - 1)
            for i in x.indices { for j in y.indices { r[i + j] += x[i] * y[j] } }
            return r
        }

        /// Direct-form I. `past` holds y[n-1] at index 0, so the recursive term reads
        /// `ys[i - 1]` — off-by-one here silently collapses the output below the gate.
        func apply(_ x: UnsafePointer<Float>, count: Int) -> [Double] {
            var y = [Double](repeating: 0, count: count)
            var xs = [Double](repeating: 0, count: b.count)
            var ys = [Double](repeating: 0, count: a.count)
            for n in 0..<count {
                for i in stride(from: xs.count - 1, to: 0, by: -1) { xs[i] = xs[i - 1] }
                xs[0] = Double(x[n])
                var acc = 0.0
                for i in b.indices { acc += b[i] * xs[i] }
                for i in 1..<a.count { acc -= a[i] * ys[i - 1] }
                for i in stride(from: ys.count - 1, to: 0, by: -1) { ys[i] = ys[i - 1] }
                ys[0] = acc
                y[n] = acc
            }
            return y
        }
    }

    /// Integrated loudness of a decoded audio file, or nil when it is too short or
    /// entirely below the −70 LUFS absolute gate (silence).
    static func integrated(fileURL: URL) throws -> Double? {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate > 0, channels > 0, file.length > Int64(rate) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)

        // Mean square per 100 ms sub-block, per channel.
        let step = Int(rate * 0.1)
        let subBlocks = frames / step
        guard step > 0, subBlocks >= 4 else { return nil }

        let weighting = KWeighting(rate: rate)
        var meanSquares = [[Double]](repeating: [Double](repeating: 0, count: subBlocks),
                                     count: channels)
        for c in 0..<channels {
            let filtered = weighting.apply(samples[c], count: frames)
            for s in 0..<subBlocks {
                var acc = 0.0
                for i in (s * step)..<((s + 1) * step) { acc += filtered[i] * filtered[i] }
                meanSquares[c][s] = acc / Double(step)
            }
        }

        // 400 ms gating blocks, 75 % overlap. Channel weights are 1.0 for L/R.
        var blocks: [(loudness: Double, power: [Double])] = []
        for s in 0...(subBlocks - 4) {
            var power = [Double](repeating: 0, count: channels)
            var total = 0.0
            for c in 0..<channels {
                power[c] = (meanSquares[c][s] + meanSquares[c][s + 1]
                          + meanSquares[c][s + 2] + meanSquares[c][s + 3]) / 4
                total += power[c]
            }
            blocks.append((-0.691 + 10 * log10(max(total, 1e-20)), power))
        }

        func mean(of set: [(loudness: Double, power: [Double])]) -> Double {
            var acc = [Double](repeating: 0, count: channels)
            for b in set { for c in 0..<channels { acc[c] += b.power[c] } }
            return -0.691 + 10 * log10(max(acc.reduce(0, +) / Double(set.count), 1e-20))
        }

        let aboveAbsolute = blocks.filter { $0.loudness > -70 }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relativeGate = mean(of: aboveAbsolute) - 10
        let gated = aboveAbsolute.filter { $0.loudness > relativeGate }
        guard !gated.isEmpty else { return nil }
        return mean(of: gated)
    }

    /// Pulls a bounded sample off a live stream and measures it. Returns nil for
    /// formats AVFoundation cannot decode (Ogg/Opus) and for playlist URLs.
    static func measure(stream url: URL, seconds: Double = 25) async throws -> Double? {
        var request = URLRequest(url: url)
        request.setValue("CabasseRemote", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await Net.session(timeout: 20).bytes(for: request)
        defer { bytes.task.cancel() }

        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard let ext = fileExtension(for: contentType) else { return nil }

        // Size the sample from the advertised bitrate, with a hard ceiling so a
        // mis-declared stream can never run away with the network.
        let kbps = http?.value(forHTTPHeaderField: "icy-br").flatMap(Int.init) ?? 160
        let wanted = min(Int(seconds * Double(kbps) * 1000 / 8), 4_000_000)

        var audio = Data()
        audio.reserveCapacity(wanted)
        for try await byte in bytes {
            audio.append(byte)
            if audio.count >= wanted { break }
        }
        guard audio.count > 32_000 else { return nil }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cabasse-loudness-\(UUID().uuidString).\(ext)")
        try audio.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try integrated(fileURL: tmp)
    }

    private static func fileExtension(for contentType: String) -> String? {
        if contentType.contains("mpegurl") || contentType.contains("scpls") { return nil }
        if contentType.contains("aac") || contentType.contains("aacp") { return "aac" }
        if contentType.contains("mp4") || contentType.contains("m4a") { return "m4a" }
        if contentType.contains("flac") { return "flac" }
        if contentType.contains("ogg") || contentType.contains("opus") { return nil }
        if contentType.contains("mpeg") || contentType.contains("mp3") { return "mp3" }
        return "mp3"        // icecast servers that declare nothing useful
    }
}

// MARK: - Store

/// Measured loudness per stream URL, persisted as JSON in Application Support
/// next to the favourites.
final class LoudnessStore {
    private(set) var readings: [String: LoudnessReading] = [:]
    private let url: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CabasseRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("loudness.json")
        if let data = try? Data(contentsOf: url) {
            readings = (try? JSONDecoder().decode([String: LoudnessReading].self, from: data)) ?? [:]
        }
    }

    /// Folds a fresh sample into the running mean for that stream.
    @discardableResult
    func record(_ lufs: Double, for streamURI: String) -> LoudnessReading {
        let updated: LoudnessReading
        if let old = readings[streamURI] {
            let n = Double(old.samples)
            updated = LoudnessReading(lufs: (old.lufs * n + lufs) / (n + 1),
                                      samples: old.samples + 1,
                                      measuredAt: Date())
        } else {
            updated = LoudnessReading(lufs: lufs, samples: 1, measuredAt: Date())
        }
        readings[streamURI] = updated
        save()
        return updated
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(readings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
