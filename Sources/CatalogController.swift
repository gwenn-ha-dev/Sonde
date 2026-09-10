import Foundation
import Observation

/// Radio catalogue: vTuner browsing, the local searchable index crawled from the
/// amp, and the world-wide Radio Browser complement. Owns data and searches only;
/// playing (and radio favorites) remain AmpController's job.
@MainActor
@Observable
final class CatalogController {

    /// Live UPnP services — set by AmpController on (re)connection, nil when offline.
    var upnp: UPnPServices?

    // Hierarchical browsing
    private(set) var entries: [MediaEntry] = []
    private(set) var crumbs: [(id: String, title: String)] = []
    private(set) var loading = false

    // Search: grep over the local index + Radio Browser world-wide complement
    var search: String = ""
    private(set) var webResults: [IndexedStation] = []
    private(set) var webSearching = false
    private(set) var webSearchFailed = false

    // Local index (crawled flat vTuner lists, cached on disk)
    private(set) var indexedStations: [IndexedStation] = []
    private(set) var indexRoots: [RadioIndex.Root] = []
    private(set) var indexUpdatedAt: Date?
    private(set) var indexBuilding = false
    private(set) var indexProgress: (done: Int, total: Int) = (0, 0)

    private let vtunerRoot = "csp/vTuner"
    private let radioIndex = RadioIndex()
    private let webDebounce = Debounced()
    private var indexAutoTried = false

    init() { syncIndex() }

    var results: [IndexedStation] { grepFilter(indexedStations, search) { $0.searchKey } }
    var indexedCount: Int { indexedStations.count }
    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The folder currently shown; used for the "index this folder" action.
    var currentFolder: (id: String, title: String)? { crumbs.last }
    /// True when the current folder looks like a flat list of stations.
    var currentFolderIsStationList: Bool {
        !entries.isEmpty && entries.contains { !$0.isContainer && $0.streamURI != nil }
    }
    var currentFolderIndexed: Bool { currentFolder.map { radioIndex.hasRoot($0.id) } ?? false }

    // MARK: - Browsing

    func loadRoot() async {
        crumbs = [(vtunerRoot, "Radios")]
        await load(id: vtunerRoot)
    }

    func enterFolder(_ entry: MediaEntry) {
        guard entry.isContainer else { return }
        crumbs.append((entry.id, entry.title))
        search = ""
        Task { await load(id: entry.id) }
    }

    func back() {
        guard crumbs.count > 1 else { return }
        crumbs.removeLast()
        search = ""
        if let dest = crumbs.last {
            Task { await load(id: dest.id) }
        }
    }

    private func load(id: String) async {
        guard let upnp else { return }
        loading = true
        entries = []
        defer { loading = false }
        if let found = try? await UPnP.browse(upnp, objectID: id) {
            entries = found
            dlog("catalog[\(id)] -> \(found.count) entries; first: \(found.first?.title ?? "-")")
        }
    }

    // MARK: - World-wide search (Radio Browser)

    /// Debounced search on radio-browser.info, run alongside the local index grep.
    /// Network failures are surfaced (`webSearchFailed`) instead of reading as
    /// "no results".
    func scheduleWebSearch() {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else {
            webDebounce.cancel()
            webResults = []
            webSearching = false
            webSearchFailed = false
            return
        }
        webSearching = true
        webDebounce.run { [weak self] in
            guard let self else { return }
            do {
                let results = try await RadioBrowser.search(q)
                guard !Task.isCancelled else { return }
                // Same stream already surfaced by the local index → keep the local one.
                let localURIs = Set(self.results.map(\.streamURI))
                self.webResults = results.filter { !localURIs.contains($0.streamURI) }
                self.webSearchFailed = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.webResults = []
                self.webSearchFailed = true
                dlog("radio browser search failed: \(error)")
            }
            self.webSearching = false
        }
    }

    // MARK: - Local index (crawl + grep)

    private func syncIndex() {
        indexedStations = radioIndex.stations
        indexRoots = radioIndex.roots
        indexUpdatedAt = radioIndex.updatedAt
    }

    /// Called when the catalogue window opens: builds a default index once (the
    /// user's country "all stations" list) so search works out of the box.
    func ensureIndexReady() {
        guard !indexAutoTried, radioIndex.isEmpty, upnp != nil, !indexBuilding else { return }
        indexAutoTried = true
        Task { await buildDefaultIndex() }
    }

    /// The default searchable set: the user's country (France) plus the United Kingdom.
    /// Each root is crawled once and cached; already-indexed roots are skipped so this
    /// is cheap to call on every launch.
    func buildDefaultIndex() async {
        func hasAllStations(_ marker: String) -> Bool {
            radioIndex.roots.contains { $0.objectID.contains(marker) && $0.objectID.contains("AllStations") }
        }
        let hasFrance = hasAllStations("Europe-France")
        let hasUK = hasAllStations("United%20Kingdom")
        if hasFrance && hasUK { return }

        if !hasFrance, let fr = await defaultAllStationsRoot(), !radioIndex.hasRoot(fr.id) {
            await buildIndex(rootID: fr.id, name: fr.name)
        }
        if !hasUK, let uk = await findAllStationsRoot(countryMatches: ["united kingdom", "royaume"]),
           !radioIndex.hasRoot(uk.id) {
            await buildIndex(rootID: uk.id, name: uk.name)
        }
    }

    /// Adds the folder the user is currently viewing to the search index.
    func indexCurrentFolder() {
        guard let folder = currentFolder else { return }
        Task { await buildIndex(rootID: folder.id, name: folder.title) }
    }

    func rebuildIndex() {
        Task {
            let roots = indexRoots
            for r in roots { await buildIndex(rootID: r.objectID, name: r.name) }
        }
    }

    func clearIndex() {
        radioIndex.clear()
        indexAutoTried = false
        syncIndex()
    }

    /// Locates the user's country "all stations" flat list under vTuner.
    private func defaultAllStationsRoot() async -> (id: String, name: String)? {
        guard let upnp else { return nil }
        guard let roots = try? await UPnP.browse(upnp, objectID: vtunerRoot) else { return nil }
        let country = roots.first { $0.isContainer && $0.id.contains("LocationLevelFour") }
            ?? roots.first { $0.isContainer }
        guard let country else { return nil }
        guard let kids = try? await UPnP.browse(upnp, objectID: country.id) else { return nil }
        if let all = kids.first(where: { $0.id.contains("AllStations") }) {
            return (all.id, "\(country.title) · toutes les stations")
        }
        return nil
    }

    /// Locates a country's "all stations" list by navigating Pays → continents → country.
    /// `countryMatches` are lowercased substrings tested against the country id and title.
    private func findAllStationsRoot(countryMatches terms: [String]) async -> (id: String, name: String)? {
        guard let upnp else { return nil }
        guard let continents = try? await UPnP.browse(upnp, objectID: "\(vtunerRoot)/LocationLevelTwo") else { return nil }
        for continent in continents where continent.isContainer {
            guard let countries = try? await UPnP.browse(upnp, objectID: continent.id) else { continue }
            for c in countries where c.isContainer {
                let hay = (c.id.removingPercentEncoding ?? c.id).lowercased() + " " + c.title.lowercased()
                guard terms.contains(where: hay.contains) else { continue }
                if let kids = try? await UPnP.browse(upnp, objectID: c.id),
                   let all = kids.first(where: { $0.id.contains("AllStations") }) {
                    return (all.id, "\(c.title) · toutes les stations")
                }
            }
        }
        return nil
    }

    private func buildIndex(rootID: String, name: String) async {
        guard let upnp, !indexBuilding else { return }
        indexBuilding = true
        indexProgress = (0, 0)
        defer { indexBuilding = false }

        let others = radioIndex.stations(excludingRoot: rootID)
        var seen = Set<String>()
        var collected: [IndexedStation] = []

        // Stream pages in; make each batch searchable immediately.
        await UPnP.crawlAll(upnp, objectID: rootID) { entries, done, total in
            for e in entries {
                guard !e.isContainer, let uri = e.streamURI, !seen.contains(uri) else { continue }
                seen.insert(uri)
                collected.append(IndexedStation(title: cleanStationTitle(e.title), streamURI: uri,
                                                artURI: e.artURI, genre: e.genre))
            }
            indexProgress = (done, total)
            indexedStations = others + collected      // live, greppable during the crawl
        }

        radioIndex.setRoot(objectID: rootID, name: name, stations: collected)
        syncIndex()
        dlog("indexed '\(name)': \(collected.count) stations; total \(radioIndex.count)")
    }
}
