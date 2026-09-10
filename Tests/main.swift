import Foundation
import AVFoundation

// Minimal harness: the project has no SPM and no Xcode project, so the tests are a
// plain binary built from the same sources by ./test.sh. Run it, read the exit code.

var failures = 0
var current = ""

func suite(_ name: String) { current = name; print("\n\(name)") }

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  ok    \(name)")
    } else {
        failures += 1
        let d = detail()
        print("  ÉCHEC \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

func decodeZone(_ json: String) -> ZoneState? {
    try? JSONDecoder().decode(ZoneState.self, from: Data(json.utf8))
}

// MARK: - Zone state

// The amp OMITS `muted` from the rendering zone when it is false, and only emits it
// when muting is on. Reading that omission as "muted" would invert the icon, so it is
// pinned here against both shapes actually returned by firmware 25.04.10.
suite("État de zone (/Zone/State.json)")

let unmuted = decodeZone(#"{ "rendering_zones": [ { "volume": 27 } ], "generation": 138 }"#)
check("clé muted absente → non muet", unmuted?.muted == false, "obtenu \(String(describing: unmuted?.muted))")
check("volume lu", unmuted?.volume == 27, "obtenu \(String(describing: unmuted?.volume))")

let muted = decodeZone(#"{ "rendering_zones": [ { "volume": 4, "muted": true } ], "generation": 9 }"#)
check("clé muted présente → muet", muted?.muted == true)

let extras = decodeZone(#"{ "rendering_zones": [ { "uuid": "x", "members": [], "volume": 50, "stream_source": "y" } ], "generation": 1 }"#)
check("champs inconnus ignorés", extras?.volume == 50)

let empty = decodeZone(#"{ "rendering_zones": [], "generation": 3 }"#)
check("zone vide → volume nil, non muet", empty?.volume == nil && empty?.muted == false)

// MARK: - Filtre grep

suite("Filtre grep des favoris")

let stations = ["Radio Kerne", "Arvorig FM", "France Bleu Breiz Izel", "FIP Pop HD"]
check("terme unique", grepFilter(stations, "fip", key: { $0.lowercased() }) == ["FIP Pop HD"])
check("multi-termes en ET",
      grepFilter(stations, "radio kerne", key: { $0.lowercased() }) == ["Radio Kerne"])
check("ordre des termes indifférent",
      grepFilter(stations, "kerne radio", key: { $0.lowercased() }) == ["Radio Kerne"])
check("requête vide → tout", grepFilter(stations, "   ", key: { $0.lowercased() }).count == 4)
check("sans correspondance", grepFilter(stations, "zzz", key: { $0.lowercased() }).isEmpty)

let fav = Favorite(title: "Radio Évasion", streamURI: "http://x", artURI: nil,
                   genre: "Généraliste", addedAt: Date())
check("accents repliés dans la clé de recherche",
      grepFilter([fav], "evasion generaliste", key: { $0.searchKey }).count == 1)

// MARK: - Préférences

suite("Préférences (plafond de volume)")

Defaults.volumeCap = 250
check("plafond borné en haut", Defaults.volumeCap == 100, "obtenu \(Defaults.volumeCap)")
Defaults.volumeCap = -5
check("plafond borné en bas", Defaults.volumeCap == 5, "obtenu \(Defaults.volumeCap)")
Defaults.volumeCap = 42
check("valeur valide conservée", Defaults.volumeCap == 42)

// MARK: - Loudness

suite("Loudness — lecture")

let hot = LoudnessReading(lufs: -10.6, samples: 3, measuredAt: Date())
let broadcast = LoudnessReading(lufs: -18.6, samples: 3, measuredAt: Date())
check("écart à la référence", near(hot.overReference, 7.4, 0.001), "obtenu \(hot.overReference)")
check("station chaude signalée", hot.isHot)
check("station au standard non signalée", !broadcast.isHot)
check("seuil à +4 LU exactement",
      LoudnessReading(lufs: -14, samples: 1, measuredAt: Date()).isHot)
check("juste en dessous du seuil",
      !LoudnessReading(lufs: -14.1, samples: 1, measuredAt: Date()).isHot)

suite("Loudness — conformité EBU Tech 3341")

/// Writes a stereo sine to a temporary WAV. `dBFS` is the PEAK amplitude, which is the
/// convention EBU Tech 3341 uses for its test signals: a 1 kHz sine of peak amplitude
/// 10^(−23/20) reads −23.0 LUFS. Reading it as an RMS level instead shifts every
/// expectation by exactly 3.01 dB.
func sineFile(dBFS: Double, hz: Double = 1000, seconds: Double = 10, rate: Double = 48000) throws -> URL {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cabasse-test-\(UUID().uuidString).wav")
    // Spelled out rather than reusing format.settings, which asks for non-interleaved
    // audio that no file format supports and makes AVFoundation log a warning.
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(rate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let amplitude = Float(pow(10, dBFS / 20))
    for c in 0..<2 {
        for i in 0..<Int(frames) {
            buffer.floatChannelData![c][i] = amplitude * Float(sin(2 * .pi * hz * Double(i) / rate))
        }
    }
    try file.write(from: buffer)
    return url
}

do {
    // Tech 3341 case 1: a stereo 1 kHz sine at −23 dBFS peak must read −23.0 LUFS ±0.1.
    // Cross-checked against ffmpeg's ebur128 on the identical file: −23.0 there too.
    let f = try sineFile(dBFS: -23)
    defer { try? FileManager.default.removeItem(at: f) }
    let measured = try Loudness.integrated(fileURL: f)
    check("sinus 1 kHz à −23 dBFS → −23,0 LUFS ±0,1",
          measured.map { near($0, -23, 0.1) } ?? false,
          "obtenu \(measured.map { String(format: "%.2f", $0) } ?? "nil")")

    // Linearity: −10 dB on the input must move the reading by exactly −10 LU.
    let quiet = try sineFile(dBFS: -33)
    defer { try? FileManager.default.removeItem(at: quiet) }
    let quietMeasured = try Loudness.integrated(fileURL: quiet)
    if let a = measured, let b = quietMeasured {
        check("linéarité : −10 dB à l'entrée → −10 LU", near(a - b, 10, 0.05),
              "écart mesuré \(String(format: "%.3f", a - b))")
    } else {
        check("linéarité : −10 dB à l'entrée → −10 LU", false, "mesure nil")
    }

    // Digital silence sits below the −70 LUFS absolute gate and must yield no reading.
    let silent = try sineFile(dBFS: -200)
    defer { try? FileManager.default.removeItem(at: silent) }
    check("silence → aucune mesure", (try Loudness.integrated(fileURL: silent)) == nil)
} catch {
    check("génération des signaux de test", false, "\(error)")
}

print("\n\(failures == 0 ? "TOUT PASSE" : "\(failures) ÉCHEC(S)")")
exit(failures == 0 ? 0 : 1)
