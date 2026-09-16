import Foundation

// MARK: - Models

/// A podcast show from the Apple catalogue (the de-facto world podcast directory).
struct PodcastShow: Codable, Identifiable, Hashable {
    let title: String
    let author: String?
    let feedURL: String
    let artURI: String?
    var id: String { feedURL }
}

/// One episode parsed from the show's RSS feed. `enclosureURL` is a plain
/// http(s) audio file the amp plays via AVTransport like any stream.
struct PodcastEpisode: Identifiable, Hashable {
    let title: String
    let enclosureURL: String
    let pubDate: Date?
    let durationSeconds: Int?
    let artURI: String?
    var id: String { enclosureURL }

    var subtitle: String {
        var parts: [String] = []
        if let d = pubDate { parts.append(d.formatted(.dateTime.day().month(.wide).year())) }
        if let s = durationSeconds, s > 0 {
            parts.append(s >= 3600 ? "\(s / 3600) h \((s % 3600) / 60) min" : "\(max(1, s / 60)) min")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Directory (iTunes Search API) + feed parsing

enum Podcasts {

    private static let session = Net.session(timeout: 12)

    private struct ITunesResponse: Decodable { let results: [ITunesShow] }
    private struct ITunesShow: Decodable {
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let artworkUrl100: String?
    }

    /// Show search in the Apple catalogue (free, no key). Results without a
    /// public RSS feed are normally unplayable — except Radio France, whose
    /// feeds still exist on its own site and are recovered automatically.
    static func search(_ query: String, limit: Int = 30) async throws -> [PodcastShow] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "media", value: "podcast"),
            .init(name: "term", value: query),
            .init(name: "limit", value: String(limit)),
            .init(name: "country", value: Locale.current.region?.identifier ?? "FR"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Sonde/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        let resp = try JSONDecoder().decode(ITunesResponse.self, from: data)

        var shows: [(Int, PodcastShow)] = []
        var withheld: [(Int, ITunesShow)] = []      // Radio France entries without a feed
        for (i, s) in resp.results.enumerated() {
            guard let name = s.collectionName else { continue }
            if let feed = s.feedUrl, !feed.isEmpty {
                shows.append((i, PodcastShow(title: name, author: s.artistName, feedURL: feed,
                                             artURI: s.artworkUrl600 ?? s.artworkUrl100)))
            } else if RadioFrance.isBrand(s.artistName) {
                withheld.append((i, s))
            }
        }

        if !withheld.isEmpty {
            let recovered = await withTaskGroup(of: (Int, PodcastShow)?.self) { group in
                for (i, s) in withheld.prefix(5) {          // bounded page scrapes per search
                    group.addTask {
                        guard let name = s.collectionName,
                              let feed = await RadioFrance.resolveFeed(title: name, author: s.artistName)
                        else { return nil }
                        return (i, PodcastShow(title: name, author: s.artistName, feedURL: feed,
                                               artURI: s.artworkUrl600 ?? s.artworkUrl100))
                    }
                }
                var acc: [(Int, PodcastShow)] = []
                for await r in group { if let r { acc.append(r) } }
                return acc
            }
            shows.append(contentsOf: recovered)
        }

        var seen = Set<String>()
        return shows.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0.feedURL).inserted }
    }

    // MARK: Radio France feed recovery

    /// Radio France withholds its RSS feeds from the Apple catalogue (app-first
    /// strategy) but still publishes them: each show page on radiofrance.fr
    /// embeds its `radiofrance-podcast.net` feed URL. We rebuild the page URL
    /// from the show's name (their slugs are predictable) and scrape it out.
    enum RadioFrance {
        private static let brandPaths: [(needle: String, path: String)] = [
            ("france inter", "franceinter"),
            ("france culture", "franceculture"),
            ("france musique", "francemusique"),
            ("franceinfo", "franceinfo"),
            ("france info", "franceinfo"),
            ("fip", "fip"),
            ("mouv", "mouv"),
        ]

        static func isBrand(_ author: String?) -> Bool {
            guard let a = author?.lowercased() else { return false }
            return a.contains("radio france") || brandPaths.contains { a.contains($0.needle) }
        }

        private static func stationPaths(for author: String?) -> [String] {
            let a = (author ?? "").lowercased()
            let direct = brandPaths.filter { a.contains($0.needle) }.map(\.path)
            // Generic "Radio France" (or unknown): try the main antennas.
            return direct.isEmpty ? ["franceinter", "franceculture", "franceinfo", "francemusique"]
                                  : direct
        }

        /// "Quand les dieux rôdaient sur la Terre" → "quand-les-dieux-rodaient-sur-la-terre"
        static func slug(_ title: String) -> String {
            title.replacingOccurrences(of: "œ", with: "oe")
                .replacingOccurrences(of: "æ", with: "ae")
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
                .lowercased()
                .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
                .joined()
                .split(separator: "-")
                .joined(separator: "-")
        }

        static func resolveFeed(title: String, author: String?) async -> String? {
            let s = slug(title)
            guard !s.isEmpty else { return nil }
            for path in stationPaths(for: author) {
                guard let url = URL(string: "https://www.radiofrance.fr/\(path)/podcasts/\(s)") else { continue }
                var req = URLRequest(url: url)
                // Up to 4 antenna pages may be tried in sequence: keep each one
                // short so a slow site can't stall the whole search.
                req.timeoutInterval = 5
                req.setValue("Mozilla/5.0 Sonde/0.1", forHTTPHeaderField: "User-Agent")
                guard let (data, resp) = try? await session.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let html = String(decoding: data, as: UTF8.self)
                if let r = html.range(of: #"https://radiofrance-podcast\.net/podcast09/[^"'<> ]+\.xml"#,
                                      options: .regularExpression) {
                    return String(html[r])
                }
            }
            return nil
        }
    }

    /// Fetches and parses the show's RSS feed into playable episodes,
    /// newest first (feed order), capped to keep huge archives snappy.
    static func episodes(of show: PodcastShow, limit: Int = 150) async throws -> [PodcastEpisode] {
        guard let url = URL(string: show.feedURL) else { return [] }
        let (data, _) = try await session.data(for: request(url))
        return RSSParser.parse(data, fallbackArt: show.artURI, limit: limit).episodes
    }

    /// Builds a show straight from a pasted RSS URL — the escape hatch for feeds
    /// their publisher withholds from the Apple catalogue (Radio France…).
    static func show(fromFeed urlString: String) async -> PodcastShow? {
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https",
              let (data, _) = try? await session.data(for: request(url)) else { return nil }
        let parsed = RSSParser.parse(data, fallbackArt: nil, limit: 1)
        guard let title = parsed.channelTitle, !parsed.episodes.isEmpty else { return nil }
        return PodcastShow(title: title, author: nil, feedURL: urlString, artURI: parsed.channelArt)
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Sonde/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        return req
    }
}

// MARK: - RSS parser

private final class RSSParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data, fallbackArt: String?, limit: Int)
        -> (channelTitle: String?, channelArt: String?, episodes: [PodcastEpisode]) {
        let p = RSSParser(fallbackArt: fallbackArt, limit: limit)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()          // may end via abortParsing once `limit` is reached
        return (p.channelTitle, p.channelArt, p.episodes)
    }

    private let fallbackArt: String?
    private let limit: Int
    private init(fallbackArt: String?, limit: Int) {
        self.fallbackArt = fallbackArt
        self.limit = limit
    }

    private var episodes: [PodcastEpisode] = []
    private var channelTitle: String?
    private var channelArt: String?
    private var inItem = false
    private var text = ""
    private var title: String?
    private var enclosure: String?
    private var duration: String?
    private var pubDate: String?
    private var itemArt: String?

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qn: String?, attributes attrs: [String: String]) {
        let name = qn ?? el
        text = ""
        switch name {
        case "item":
            inItem = true
            title = nil; enclosure = nil; duration = nil; pubDate = nil; itemArt = nil
        case "enclosure" where inItem:
            if enclosure == nil, let u = attrs["url"], !u.isEmpty { enclosure = u }
        case "itunes:image":
            let href = attrs["href"]
            if inItem { itemArt = itemArt ?? href } else { channelArt = channelArt ?? href }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(decoding: block, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName qn: String?) {
        let name = qn ?? el
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title" where inItem:
            if title == nil, !value.isEmpty { title = value }
        case "title":
            // First channel-level title = the show's name (precedes <image><title>).
            if channelTitle == nil, !value.isEmpty { channelTitle = value }
        case "itunes:duration" where inItem:
            duration = value
        case "pubDate" where inItem:
            pubDate = value
        case "item":
            inItem = false
            if let enclosure, let title {
                episodes.append(PodcastEpisode(
                    title: title,
                    enclosureURL: enclosure,
                    pubDate: pubDate.flatMap(Self.parseRFC822),
                    durationSeconds: duration.flatMap(Self.parseDuration),
                    artURI: itemArt ?? channelArt ?? fallbackArt))
                if episodes.count >= limit { parser.abortParsing() }
            }
        default:
            break
        }
        text = ""
    }

    /// "49:24", "01:02:03" or plain seconds.
    private static func parseDuration(_ s: String) -> Int? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    private static let rfc822: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    private static func parseRFC822(_ s: String) -> Date? {
        for f in rfc822 { if let d = f.date(from: s) { return d } }
        return nil
    }
}

// MARK: - Favorite shows store

/// Followed shows, persisted as JSON. Only the feed URL is stored — episodes are
/// re-fetched from the live RSS on open, so the list is always current.
final class PodcastStore {
    private(set) var items: [PodcastShow] = []
    private let url: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sonde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("podcasts.json")
        if let data = try? Data(contentsOf: url) {
            items = (try? JSONDecoder().decode([PodcastShow].self, from: data)) ?? []
        }
    }

    func contains(_ show: PodcastShow) -> Bool { items.contains { $0.feedURL == show.feedURL } }

    func toggle(_ show: PodcastShow) {
        if contains(show) {
            items.removeAll { $0.feedURL == show.feedURL }
        } else {
            items.insert(show, at: 0)
        }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(items) { try? data.write(to: url, options: .atomic) }
    }
}
