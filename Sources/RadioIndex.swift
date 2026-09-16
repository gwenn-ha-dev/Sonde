import Foundation

/// A station in the local search index (a flattened slice of the vTuner catalogue).
struct IndexedStation: Codable, Identifiable, Hashable {
    let title: String
    let streamURI: String
    let artURI: String?
    let genre: String?

    var id: String { streamURI }

    var searchKey: String {
        (title + " " + (genre ?? ""))
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
    }
}

/// Local, greppable index of catalogue stations. The amp's UPnP `Search` is a no-op
/// for vTuner, so we crawl flat "all stations" lists via Browse and search them here.
/// Persisted so it survives launches; rebuilt on demand.
final class RadioIndex {
    private(set) var stations: [IndexedStation] = []
    private(set) var roots: [Root] = []           // which catalogue folders are indexed
    private(set) var updatedAt: Date?

    struct Root: Codable, Hashable { var objectID: String; var name: String; var count: Int }

    private let url: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sonde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("vtuner-index.json")
        load()
    }

    var isEmpty: Bool { stations.isEmpty }
    var count: Int { stations.count }

    func hasRoot(_ objectID: String) -> Bool { roots.contains { $0.objectID == objectID } }

    /// Stations contributed by roots other than `objectID` (for live merge while re-crawling one root).
    func stations(excludingRoot objectID: String) -> [IndexedStation] {
        stations.filter { !belongs($0, toRoot: objectID) }
    }

    /// Replaces (or adds) the slice contributed by one catalogue root, de-duplicating by URI.
    func setRoot(objectID: String, name: String, stations newOnes: [IndexedStation]) {
        var byURI = [String: IndexedStation]()
        // Keep stations from other roots…
        for s in stations where !belongs(s, toRoot: objectID) { byURI[s.streamURI] = s }
        // …and merge the fresh crawl.
        for s in newOnes { byURI[s.streamURI] = s }
        stations = Array(byURI.values).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        roots.removeAll { $0.objectID == objectID }
        roots.append(Root(objectID: objectID, name: name, count: newOnes.count))
        rootMembership[objectID] = Set(newOnes.map(\.streamURI))
        touch()
        save()
    }

    func clear() {
        stations = []; roots = []; rootMembership = [:]; updatedAt = nil
        save()
    }

    func filtered(_ query: String) -> [IndexedStation] {
        let terms = query.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return stations.filter { st in let k = st.searchKey; return terms.allSatisfy { k.contains($0) } }
    }

    // MARK: Root membership (which URIs came from which root), for clean re-indexing

    private var rootMembership: [String: Set<String>] = [:]
    private func belongs(_ s: IndexedStation, toRoot root: String) -> Bool {
        rootMembership[root]?.contains(s.streamURI) ?? false
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var stations: [IndexedStation]
        var roots: [Root]
        var membership: [String: [String]]
        var updatedAt: Date?
    }

    private func touch() { updatedAt = Date() }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        stations = p.stations
        roots = p.roots
        rootMembership = p.membership.mapValues(Set.init)
        updatedAt = p.updatedAt
    }

    private func save() {
        let p = Persisted(stations: stations, roots: roots,
                          membership: rootMembership.mapValues(Array.init), updatedAt: updatedAt)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: url, options: .atomic) }
    }
}

/// Strips vTuner's "all stations" sort-key prefix, e.g. "- 0 0 - Radio Nova" → "Radio Nova".
func cleanStationTitle(_ raw: String) -> String {
    let cleaned = raw.replacingOccurrences(
        of: #"^\s*-\s*\d+\s*\d+\s*-\s*"#, with: "", options: .regularExpression)
    return cleaned.isEmpty ? raw : cleaned
}
