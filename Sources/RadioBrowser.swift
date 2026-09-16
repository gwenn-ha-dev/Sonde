import Foundation

/// Client for the community radio-browser.info directory (~50k stations, free, no
/// auth). Used as a world-wide complement to the vTuner index: stations that vTuner
/// dropped (or never had) can still be found here, and the amp plays their direct
/// stream URL via AVTransport just like any vTuner station.
enum RadioBrowser {

    /// Public API mirrors, tried in order until one answers.
    private static let mirrors = [
        "de1.api.radio-browser.info",
        "de2.api.radio-browser.info",
        "fi1.api.radio-browser.info",
    ]

    private static let session = Net.session(timeout: 8)

    private struct Station: Decodable {
        let name: String
        let url_resolved: String
        let favicon: String?
        let homepage: String?
        let tags: String?
        let codec: String?
        let bitrate: Int?
    }

    /// Name search, most-voted first; stations whose stream fails the directory's
    /// health check are filtered out server-side (`hidebroken`).
    static func search(_ query: String, limit: Int = 50) async throws -> [IndexedStation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }

        var lastError: Error = URLError(.cannotConnectToHost)
        for host in mirrors {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = host
            comps.path = "/json/stations/search"
            comps.queryItems = [
                .init(name: "name", value: q),
                .init(name: "limit", value: String(limit)),
                .init(name: "hidebroken", value: "true"),
                .init(name: "order", value: "votes"),
                .init(name: "reverse", value: "true"),
            ]
            var req = URLRequest(url: comps.url!)
            // The API asks clients to identify themselves.
            req.setValue("Sonde/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, resp) = try await session.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let stations = try JSONDecoder().decode([Station].self, from: data)
                return stations.compactMap(indexedStation)
            } catch is CancellationError {
                throw CancellationError()       // a newer search superseded us
            } catch {
                lastError = error               // this mirror is down; try the next
            }
        }
        throw lastError
    }

    private static func indexedStation(_ s: Station) -> IndexedStation? {
        guard !s.url_resolved.isEmpty else { return nil }
        var genreBits: [String] = []
        if let c = s.codec, !c.isEmpty {
            let br = (s.bitrate ?? 0) > 0 ? " \(s.bitrate!) kbps" : ""
            genreBits.append(c.uppercased() + br)
        }
        if let tag = s.tags?.split(separator: ",").first.map(String.init), !tag.isEmpty {
            genreBits.append(tag)
        }
        return IndexedStation(
            title: s.name.trimmingCharacters(in: .whitespacesAndNewlines),
            streamURI: s.url_resolved,
            artURI: (s.favicon?.isEmpty == false) ? s.favicon : websiteIcon(s.homepage),
            genre: genreBits.isEmpty ? nil : genreBits.joined(separator: " · "))
    }

    /// Station logo derived from its website via DuckDuckGo's icon service (serves
    /// the site icon full-size). Also used for manually added favorites.
    static func websiteIcon(_ website: String?) -> String? {
        guard var h = website?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        if !h.contains("://") { h = "https://" + h }
        guard let host = URL(string: h)?.host, !host.isEmpty else { return nil }
        return "https://icons.duckduckgo.com/ip3/\(host).ico"
    }
}
