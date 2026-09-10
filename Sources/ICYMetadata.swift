import Foundation

/// Samples the ICY in-stream metadata of a web radio to get the song currently
/// on air ("StreamTitle"), which the amp never surfaces (its title stays the
/// station name). One sample = connect with `Icy-MetaData: 1`, read up to the
/// first metadata block (one audio block, typically 8–32 KB), close. Repeated
/// periodically by the controller this costs a few MB per hour on the Mac side;
/// the amp's own playback connection is untouched.
enum ICYMetadata {

    private static let session = Net.session(timeout: 12)

    /// One sample. Returns `nil` when the server doesn't send ICY metadata at all
    /// (not worth retrying), and an empty string when it does but nothing is tagged.
    static func fetchTitle(from url: URL) async throws -> String? {
        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        let (bytes, response) = try await session.bytes(for: req)
        defer { bytes.task.cancel() }          // never keep downloading the audio

        guard let http = response as? HTTPURLResponse,
              let metaint = http.value(forHTTPHeaderField: "icy-metaint").flatMap(Int.init),
              (1...1_048_576).contains(metaint)
        else { return nil }

        var it = bytes.makeAsyncIterator()
        for _ in 0..<metaint {                 // skip one audio block
            guard try await it.next() != nil else { return nil }
        }
        guard let len = try await it.next() else { return nil }
        var remaining = Int(len) * 16
        var meta: [UInt8] = []
        while remaining > 0, let b = try await it.next() {
            meta.append(b)
            remaining -= 1
        }

        let text = (String(bytes: meta, encoding: .utf8)
                    ?? String(bytes: meta, encoding: .isoLatin1)
                    ?? "")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")   // BOM seen on some streams
        // Payload: StreamTitle='Artist - Title';StreamUrl='…';
        guard let start = text.range(of: "StreamTitle='") else { return "" }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "';") else { return "" }
        return String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
