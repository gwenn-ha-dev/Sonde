import Foundation

// MARK: - UPnP media control (MediaServer ContentDirectory + MediaRenderer AVTransport)
//
// The amp's REST API (:34000) is control-only — no media browsing and no way to
// play an arbitrary station. That lives in UPnP: the ContentDirectory exposes the
// vTuner radio catalogue, and AVTransport plays any stream URI. We reach both via
// SSDP discovery, then plain SOAP over HTTP.

struct UPnPServices: Codable {
    var contentDirectoryControl: URL
    var avTransportControl: URL
}

/// One entry from a ContentDirectory Browse: either a navigable folder or a station.
struct MediaEntry: Identifiable, Hashable {
    let id: String            // ContentDirectory object id
    let title: String
    let isContainer: Bool
    let streamURI: String?    // playable <res> for stations
    let artURI: String?
    let genre: String?
}

enum UPnP {

    // MARK: Discovery

    /// Resolves the UPnP control URLs. Tries SSDP (multicast) first; on success the
    /// result is cached to disk. If SSDP yields nothing — e.g. the OS hasn't granted
    /// Local Network access yet, or multicast is momentarily dropped — falls back to
    /// the last-known cached URLs, validated with a live Browse before trusting them.
    static func discover(host: String, timeout: TimeInterval = 3) async -> UPnPServices? {
        if let found = await discoverViaSSDP(host: host, timeout: timeout) {
            saveCache(found)
            return found
        }
        if let cached = loadCache(), await isReachable(cached) {
            return cached
        }
        return nil
    }

    private static func discoverViaSSDP(host: String, timeout: TimeInterval) async -> UPnPServices? {
        let locations = await Task.detached(priority: .userInitiated) {
            ssdpSearch(host: host, timeout: timeout)
        }.value

        var cd: URL?
        var av: URL?
        for loc in locations {
            guard let xml = try? await fetchString(loc) else { continue }
            if cd == nil, let u = controlURL(in: xml, serviceContains: "ContentDirectory", relativeTo: loc) { cd = u }
            if av == nil, let u = controlURL(in: xml, serviceContains: "AVTransport", relativeTo: loc) { av = u }
            if cd != nil && av != nil { break }
        }
        if let cd, let av { return UPnPServices(contentDirectoryControl: cd, avTransportControl: av) }
        return nil
    }

    private static func isReachable(_ s: UPnPServices) async -> Bool {
        ((try? await browse(s, objectID: "0", count: 1)) != nil)
    }

    // MARK: Cache

    private static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CabasseRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("upnp.json")
    }

    private static func saveCache(_ s: UPnPServices) {
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: cacheURL, options: .atomic) }
    }

    private static func loadCache() -> UPnPServices? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(UPnPServices.self, from: data)
    }

    /// One-shot SSDP M-SEARCH; returns description-document URLs advertised by `host`.
    private static func ssdpSearch(host: String, timeout: TimeInterval) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)

        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"
        let bytes = Array(msg.utf8)
        _ = withUnsafePointer(to: &dest) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var locations = Set<String>()
        var buf = [UInt8](repeating: 0, count: 65535)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            if n <= 0 { continue }
            var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipbuf, socklen_t(INET_ADDRSTRLEN))
            guard String(cString: ipbuf) == host else { continue }
            let resp = String(decoding: buf[0..<Int(n)], as: UTF8.self)
            if let loc = httpHeader(resp, "LOCATION") { locations.insert(loc) }
        }
        return locations.compactMap { URL(string: $0) }
    }

    // MARK: ContentDirectory

    static func browse(_ services: UPnPServices, objectID: String,
                       start: Int = 0, count: Int = 100) async throws -> [MediaEntry] {
        try await browsePage(services, objectID: objectID, start: start, count: count).entries
    }

    /// One Browse page plus the container's total child count (for paging).
    static func browsePage(_ services: UPnPServices, objectID: String,
                           start: Int, count: Int) async throws -> (entries: [MediaEntry], total: Int) {
        let args = "<ObjectID>\(xmlEscape(objectID))</ObjectID>"
            + "<BrowseFlag>BrowseDirectChildren</BrowseFlag>"
            + "<Filter>*</Filter>"
            + "<StartingIndex>\(start)</StartingIndex>"
            + "<RequestedCount>\(count)</RequestedCount>"
            + "<SortCriteria></SortCriteria>"
        let xml = try await soap(services.contentDirectoryControl,
                                 service: "urn:schemas-upnp-org:service:ContentDirectory:1",
                                 action: "Browse", args: args)
        let total = extractTag(xml, "TotalMatches").flatMap { Int($0) } ?? 0
        guard let didl = extractTag(xml, "Result") else { return ([], total) }
        return (DIDLParser.parse(xmlUnescape(didl)), total)
    }

    /// Pages through a large flat container, streaming each page to `onBatch` as it
    /// arrives so search can work on partial data. The device caps RequestedCount at
    /// 100 and serialises SOAP internally, so we page sequentially and retry per page.
    static func crawlAll(_ services: UPnPServices, objectID: String,
                         onBatch: (_ entries: [MediaEntry], _ done: Int, _ total: Int) async -> Void) async {
        let pageSize = 100
        guard let first = try? await browsePage(services, objectID: objectID, start: 0, count: pageSize) else { return }
        let total = first.total
        await onBatch(first.entries, min(first.entries.count, total), total)

        var start = pageSize
        var done = first.entries.count
        while start < total {
            let page = await pageWithRetry(services, objectID: objectID, start: start, count: pageSize)
            done += page.count
            await onBatch(page, min(done, total), total)
            start += pageSize
        }
    }

    private static func pageWithRetry(_ services: UPnPServices, objectID: String,
                                      start: Int, count: Int, attempts: Int = 3) async -> [MediaEntry] {
        for attempt in 0..<attempts {
            if let page = try? await browsePage(services, objectID: objectID, start: start, count: count).entries,
               !page.isEmpty {
                return page
            }
            try? await Task.sleep(for: .milliseconds(200 * (attempt + 1)))
        }
        return []
    }

    // MARK: AVTransport

    /// Current renderer transport state, e.g. ("PLAYING","OK") or ("STOPPED","ERROR_OCCURRED").
    static func transportInfo(_ services: UPnPServices) async throws -> (state: String, status: String) {
        let xml = try await soap(services.avTransportControl,
                                 service: "urn:schemas-upnp-org:service:AVTransport:1",
                                 action: "GetTransportInfo", args: "<InstanceID>0</InstanceID>")
        let state = extractTag(xml, "CurrentTransportState")?.trimmingCharacters(in: .whitespaces) ?? "?"
        let status = extractTag(xml, "CurrentTransportStatus")?.trimmingCharacters(in: .whitespaces) ?? "?"
        return (state, status)
    }

    static func play(_ services: UPnPServices, uri: String, title: String, artURI: String?) async throws {
        let didl = minimalDIDL(uri: uri, title: title, artURI: artURI)
        let setArgs = "<InstanceID>0</InstanceID>"
            + "<CurrentURI>\(xmlEscape(uri))</CurrentURI>"
            + "<CurrentURIMetaData>\(xmlEscape(didl))</CurrentURIMetaData>"
        _ = try await soap(services.avTransportControl,
                           service: "urn:schemas-upnp-org:service:AVTransport:1",
                           action: "SetAVTransportURI", args: setArgs)
        _ = try await soap(services.avTransportControl,
                           service: "urn:schemas-upnp-org:service:AVTransport:1",
                           action: "Play", args: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    // MARK: - SOAP / HTTP plumbing

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    private static func soap(_ control: URL, service: String, action: String, args: String) async throws -> String {
        let envelope = """
        <?xml version="1.0"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
        var req = URLRequest(url: control)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(envelope.utf8)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200...299).contains(code) else {
            throw NSError(domain: "UPnP", code: code,
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    private static func fetchString(_ url: URL) async throws -> String {
        let (data, _) = try await session.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds the `<controlURL>` of the `<service>` whose type contains `serviceContains`,
    /// resolved against the description document's origin.
    private static func controlURL(in xml: String, serviceContains: String, relativeTo loc: URL) -> URL? {
        for block in matches(xml, pattern: "(?s)<service>(.*?)</service>") {
            guard block.contains(serviceContains),
                  let ctrl = extractTag(block, "controlURL") else { continue }
            let trimmed = ctrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if let abs = URL(string: trimmed), abs.scheme != nil { return abs }
            var comps = URLComponents()
            comps.scheme = loc.scheme
            comps.host = loc.host
            comps.port = loc.port
            comps.path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
            return comps.url
        }
        return nil
    }

    private static func minimalDIDL(uri: String, title: String, artURI: String?) -> String {
        let art = artURI.map { "<upnp:albumArtURI>\(xmlEscape($0))</upnp:albumArtURI>" } ?? ""
        return """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
        <item id="0" parentID="-1" restricted="1">\
        <dc:title>\(xmlEscape(title))</dc:title>\
        <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\(art)\
        <res protocolInfo="http-get:*:audio/mpeg:*">\(xmlEscape(uri))</res>\
        </item></DIDL-Lite>
        """
    }
}

// MARK: - DIDL-Lite parser

private final class DIDLParser: NSObject, XMLParserDelegate {
    static func parse(_ didl: String) -> [MediaEntry] {
        let p = DIDLParser()
        let parser = XMLParser(data: Data(didl.utf8))
        parser.delegate = p
        parser.parse()
        return p.entries
    }

    private var entries: [MediaEntry] = []
    private var id = ""
    private var isContainer = false
    private var title = ""
    private var genre: String?
    private var art: String?
    private var res: String?
    private var text = ""
    private var inEntry = false

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qn: String?, attributes attrs: [String: String]) {
        let name = qn ?? el
        text = ""
        switch name {
        case "item", "container":
            inEntry = true
            isContainer = (name == "container")
            id = attrs["id"] ?? ""
            title = ""; genre = nil; art = nil; res = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName qn: String?) {
        let name = qn ?? el
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "dc:title": title = value
        case "upnp:genre": genre = value.isEmpty ? nil : value
        case "upnp:albumArtURI": if art == nil { art = value.isEmpty ? nil : value }
        case "res": if res == nil, !value.isEmpty { res = value }
        case "item", "container":
            entries.append(MediaEntry(id: id, title: title, isContainer: isContainer,
                                      streamURI: res, artURI: art, genre: genre))
            inEntry = false
        default:
            break
        }
        text = ""
    }
}

// MARK: - Small helpers

private func httpHeader(_ response: String, _ name: String) -> String? {
    for line in response.split(separator: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

private func extractTag(_ xml: String, _ tag: String) -> String? {
    guard let r = matches(xml, pattern: "(?s)<\(tag)[^>]*>(.*?)</\(tag)>").first else { return nil }
    return r
}

/// Returns the first capture group of each match.
private func matches(_ s: String, pattern: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
    }
}

private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&apos;")
}

private func xmlUnescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&lt;", with: "<")
     .replacingOccurrences(of: "&gt;", with: ">")
     .replacingOccurrences(of: "&quot;", with: "\"")
     .replacingOccurrences(of: "&apos;", with: "'")
     .replacingOccurrences(of: "&amp;", with: "&")
}
