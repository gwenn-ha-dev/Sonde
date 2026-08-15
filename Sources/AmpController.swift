import Foundation
import Observation

/// Owns discovery, the client, and the live device state that the menu renders.
/// Two long-poll loops keep now-playing and volume/mute reflected near-instantly,
/// including changes made from the physical remote or another app.
@MainActor
@Observable
final class AmpController {

    // Connection
    private(set) var status: Status = .searching
    private(set) var deviceName: String = "Cabasse"

    enum Status: Equatable { case searching, connected, offline }

    // Transient, user-visible error banner
    private(set) var lastError: String?
    private var errorClearTask: Task<Void, Never>?

    private func setError(_ message: String) {
        lastError = message
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.lastError = nil }
        }
    }

    func dismissError() {
        errorClearTask?.cancel()
        lastError = nil
    }

    // Playback
    private(set) var playbackState: String = "stopped"   // playing | paused | stopped
    private(set) var title: String = ""
    private(set) var subtitle: String = ""
    private(set) var artworkURL: URL?
    private(set) var allowedActions: Set<String> = []

    // Mixer
    var volume: Double = 0            // 0...100 (real amp volume, shown on the slider)
    private(set) var volumeDragging = false
    /// Hard, non-configurable safety cap: the app never SETS volume above this (of 100).
    /// The slider still displays higher values set physically, so they can be lowered.
    let maxVolume: Double = 50
    private(set) var muted: Bool = false

    // Sources
    private(set) var sources: [SourceSelectionResponse.Source] = []
    private(set) var currentSourceID: Int?

    // Stream quality (from player metadata) + listening position
    private(set) var streamCodec: String?
    private(set) var streamBitrate: Int?       // bps
    private(set) var streamSampleRate: Int?    // Hz
    private(set) var streamBitDepth: Int?
    private(set) var streamChannels: Int?
    private(set) var streamMime: String?
    private(set) var position: Int = 0         // seconds elapsed on current station

    // Live streaming health (/System/AudioHub/Stats.json), polled while the window is open
    private(set) var statsSamples: [AudioHubStats.Sample] = []

    // Sound: DEAP profile (read-only) + classic tone EQ
    private(set) var deapLabel: String = ""
    var bass: Double = 0
    var treble: Double = 0
    private(set) var bassRange: ClosedRange<Double> = -9...9
    private(set) var trebleRange: ClosedRange<Double> = -9...9

    // Favorites (unlimited, app-managed)
    private(set) var allFavorites: [Favorite] = []
    var favSearch: String = ""

    // Catalogue browsing (vTuner via UPnP ContentDirectory)
    private(set) var catalog: [MediaEntry] = []
    private(set) var catalogCrumbs: [(id: String, title: String)] = []
    private(set) var catalogLoading = false
    private(set) var upnpReady = false

    // Global catalogue search (grep over a local index we crawl from the amp)
    var catalogSearch: String = ""
    private(set) var indexedStations: [IndexedStation] = []
    private(set) var indexRoots: [RadioIndex.Root] = []
    private(set) var indexUpdatedAt: Date?
    private(set) var indexBuilding = false
    private(set) var indexProgress: (done: Int, total: Int) = (0, 0)

    private let vtunerRoot = "csp/vTuner"
    private var currentStreamURI: String?
    private var indexAutoTried = false

    var isPlaying: Bool { playbackState == "playing" }

    /// grep-style filter: every whitespace term must appear (AND), case/diacritic-insensitive.
    var filteredFavorites: [Favorite] { Self.grep(allFavorites, favSearch) { $0.searchKey } }

    // MARK: Quality presentation

    /// Compact quality badge for the menu, e.g. "AAC · 238 kbps · 48 kHz".
    var qualityBadge: String? {
        var parts: [String] = []
        if let c = codecPretty { parts.append(c) }
        if let b = streamBitrate { parts.append("\(b / 1000) kbps") }
        if let s = streamSampleRate { parts.append(sampleRatePretty(s)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var codecPretty: String? {
        guard let c = streamCodec?.lowercased() else { return nil }
        if c.contains("aac") { return "AAC" }
        if c.contains("mp3") || c.contains("lame") { return "MP3" }
        if c.contains("flac") { return "FLAC" }
        if c.contains("vorbis") { return "Vorbis" }
        if c.contains("opus") { return "Opus" }
        if c.contains("pcm") || c.contains("wav") { return "PCM" }
        return streamCodec?.replacingOccurrences(of: "lib", with: "").uppercased()
    }

    var channelsPretty: String? {
        switch streamChannels {
        case 1: return "Mono"
        case 2: return "Stéréo"
        case let n?: return "\(n) canaux"
        default: return nil
        }
    }

    func sampleRatePretty(_ hz: Int) -> String {
        let khz = Double(hz) / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }

    var elapsedPretty: String {
        let h = position / 3600, m = (position % 3600) / 60, s = position % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // Latest live-health readings
    var currentBufferedSeconds: Double? { statsSamples.last.map { Double($0.buffered_time) / 1000 } }
    var currentThroughputKbps: Int? { statsSamples.last.map { $0.bytes_per_second * 8 / 1000 } }
    var currentRatePercent: Int? { statsSamples.last?.rate_percent }

    /// Global catalogue search results (over the crawled index).
    var catalogResults: [IndexedStation] { Self.grep(indexedStations, catalogSearch) { $0.searchKey } }
    var indexedCount: Int { indexedStations.count }
    var isSearchingCatalog: Bool { !catalogSearch.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func grep<T>(_ items: [T], _ query: String, key: (T) -> String) -> [T] {
        let terms = query.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return items }
        return items.filter { item in let k = key(item); return terms.allSatisfy { k.contains($0) } }
    }

    // MARK: - Internals

    private let discovery = Discovery()
    private var client: CabasseClient?
    private var loops: [Task<Void, Never>] = []
    private var volumeCommit: Task<Void, Never>?
    private var bassCommit: Task<Void, Never>?
    private var trebleCommit: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    private let favStore = FavoritesStore()
    private let radioIndex = RadioIndex()
    private let systemNP = SystemNowPlaying()
    private var upnp: UPnPServices?

    init() {
        allFavorites = favStore.items
        syncIndex()
        // Route macOS media keys / Control Center to the amp.
        systemNP.onPlay = { [weak self] in self?.mediaSetPlaying(true) }
        systemNP.onPause = { [weak self] in self?.mediaSetPlaying(false) }
        systemNP.onToggle = { [weak self] in self?.togglePlayPause() }
        systemNP.onNext = { [weak self] in self?.next() }
        systemNP.onPrevious = { [weak self] in self?.previous() }
        start()
    }

    private func mediaSetPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        togglePlayPause()
    }

    func start() {
        discovery.start { [weak self] amp in
            Task { @MainActor in self?.connect(to: amp) }
        }
    }

    private func connect(to amp: DiscoveredAmp) {
        guard client == nil else { return }        // first one wins for the MVP
        let client = CabasseClient(base: amp.base)
        self.client = client
        deviceName = amp.id
        status = .connected
        dlog("connecting to \(amp.base)")

        Task { @MainActor in
            if let info = try? await client.deviceInfo() {
                dlog("deviceInfo ok: \(info.device_info.friendly_name ?? info.device_info.ProductName ?? "?")")
                deviceName = info.device_info.friendly_name?.isEmpty == false
                    ? info.device_info.friendly_name!
                    : (info.device_info.ProductName ?? amp.id)
            }
            await refreshSources()
            await refreshSound()
        }

        // Media browsing/playback lives on UPnP, discovered separately.
        Task { @MainActor in
            upnp = await UPnP.discover(host: amp.host)
            upnpReady = (upnp != nil)
            dlog("upnp ready: \(upnpReady)")
            if upnpReady {
                await loadCatalogRoot()
                // Build the searchable catalogue index in the background;
                // cached afterwards, so later launches are instant.
                await buildDefaultIndex()
            }
        }

        loops.append(Task { [weak self] in await self?.pollPlayer(client) })
        loops.append(Task { [weak self] in await self?.pollZone(client) })
    }

    // MARK: - Sound (DEAP read-only + tone EQ)

    private func refreshSound() async {
        guard let client else { return }
        if let eq = try? await client.eq() {
            if let b = eq.system_mixer_eq.bass {
                bass = Double(b.value); bassRange = Double(b.data_min)...Double(b.data_max)
            }
            if let t = eq.system_mixer_eq.treble {
                treble = Double(t.value); trebleRange = Double(t.data_min)...Double(t.data_max)
            }
        }
        if let deap = try? await client.deapSettings() {
            deapLabel = deap.currentLabel ?? ""
        }
        dlog("sound: deap='\(deapLabel)' bass=\(Int(bass)) treble=\(Int(treble))")
    }

    func commitBass() {
        bassCommit?.cancel()
        let v = Int(bass.rounded())
        bassCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            try? await self.client?.setBass(v)
        }
    }

    func commitTreble() {
        trebleCommit?.cancel()
        let v = Int(treble.rounded())
        trebleCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            try? await self.client?.setTreble(v)
        }
    }

    // MARK: - Streaming health (live)

    /// Starts polling AudioHub stats ~1×/s. Call when the stats window is shown.
    func startStats() {
        guard statsTask == nil, let client else { return }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                if let s = try? await client.audioHubStats() {
                    self?.statsSamples = s.stat_values
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopStats() {
        statsTask?.cancel()
        statsTask = nil
    }

    // MARK: - Favorites

    var currentIsFavorite: Bool {
        guard let uri = currentStreamURI else { return false }
        return allFavorites.contains { $0.streamURI == uri }
    }

    func addCurrentToFavorites() {
        guard let uri = currentStreamURI, !uri.isEmpty else { return }
        favStore.add(title: title.isEmpty ? (subtitle.isEmpty ? "Radio" : subtitle) : title,
                     streamURI: uri, artURI: artworkURL?.absoluteString, genre: nil)
        allFavorites = favStore.items
    }

    func addToFavorites(_ entry: MediaEntry) {
        guard let uri = entry.streamURI else { return }
        favStore.add(title: entry.title, streamURI: uri, artURI: entry.artURI, genre: entry.genre)
        allFavorites = favStore.items
    }

    func removeFavorite(_ fav: Favorite) {
        favStore.remove(fav)
        allFavorites = favStore.items
    }

    func playFavorite(_ fav: Favorite) {
        play(uri: fav.streamURI, title: fav.title, art: fav.artURI)
    }

    private func play(uri: String, title: String, art: String?) {
        guard let upnp else {
            setError("Lecture indisponible : média non prêt.")
            return
        }
        Task {
            do {
                try await UPnP.play(upnp, uri: uri, title: title, artURI: art)
            } catch {
                setError("Lecture impossible : « \(title) ».")
                return
            }
            // The amp accepts the command even for a dead stream; the failure only
            // shows up as the transport status a moment later.
            try? await Task.sleep(for: .seconds(2))
            if let info = try? await UPnP.transportInfo(upnp),
               info.status == "ERROR_OCCURRED" || info.state == "STOPPED" {
                setError("Flux indisponible : « \(title) » ne répond pas.")
            }
        }
    }

    // MARK: - Catalogue (vTuner)

    func loadCatalogRoot() async {
        catalogCrumbs = [(vtunerRoot, "Radios")]
        await loadCatalog(id: vtunerRoot)
    }

    func enterFolder(_ entry: MediaEntry) {
        guard entry.isContainer else { return }
        catalogCrumbs.append((entry.id, entry.title))
        catalogSearch = ""
        Task { await loadCatalog(id: entry.id) }
    }

    func catalogBack() {
        guard catalogCrumbs.count > 1 else { return }
        catalogCrumbs.removeLast()
        catalogSearch = ""
        if let dest = catalogCrumbs.last {
            Task { await loadCatalog(id: dest.id) }
        }
    }

    func playEntry(_ entry: MediaEntry) {
        guard let uri = entry.streamURI else { return }
        play(uri: uri, title: entry.title, art: entry.artURI)
    }

    private func loadCatalog(id: String) async {
        guard let upnp else { return }
        catalogLoading = true
        catalog = []
        defer { catalogLoading = false }
        if let entries = try? await UPnP.browse(upnp, objectID: id) {
            catalog = entries
            dlog("catalog[\(id)] -> \(entries.count) entries; first: \(entries.first?.title ?? "-")")
        }
    }

    // MARK: - Global catalogue index (crawl + grep)

    /// The folder currently shown; used for the "index this folder" action.
    var currentFolder: (id: String, title: String)? { catalogCrumbs.last }
    /// True when the current folder looks like a flat list of stations.
    var currentFolderIsStationList: Bool {
        !catalog.isEmpty && catalog.contains { !$0.isContainer && $0.streamURI != nil }
    }
    var currentFolderIndexed: Bool { currentFolder.map { radioIndex.hasRoot($0.id) } ?? false }

    private func syncIndex() {
        indexedStations = radioIndex.stations
        indexRoots = radioIndex.roots
        indexUpdatedAt = radioIndex.updatedAt
    }

    /// Called when the catalogue window opens: builds a default index once (the
    /// user's country "all stations" list) so search works out of the box.
    func ensureIndexReady() {
        guard !indexAutoTried, radioIndex.isEmpty, upnpReady, !indexBuilding else { return }
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

    func isFavoriteURI(_ uri: String) -> Bool { allFavorites.contains { $0.streamURI == uri } }

    func playStation(_ s: IndexedStation) { play(uri: s.streamURI, title: s.title, art: s.artURI) }

    func addStationToFavorites(_ s: IndexedStation) {
        favStore.add(title: s.title, streamURI: s.streamURI, artURI: s.artURI, genre: s.genre)
        allFavorites = favStore.items
    }

    // MARK: - Poll loops

    private func pollPlayer(_ client: CabasseClient) async {
        var etag: String?
        while !Task.isCancelled {
            do {
                let (data, newEtag) = try await client.longPoll("/Player/State.json", etag: etag)
                etag = newEtag
                if let data {
                    let state = try JSONDecoder().decode(PlayerStateResponse.self, from: data)
                    apply(state)
                    dlog("player: \(playbackState) — \(title) / \(subtitle)")
                }
                status = .connected
            } catch {
                dlog("player poll error: \(error)")
                status = .offline
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollZone(_ client: CabasseClient) async {
        var etag: String?
        while !Task.isCancelled {
            do {
                let (data, newEtag) = try await client.longPoll("/Zone/State.json", etag: etag)
                etag = newEtag
                if let data {
                    let zone = try JSONDecoder().decode(ZoneState.self, from: data)
                    // Show the amp's real volume on the full 0...100 scale (it may be
                    // above the cap if set from the physical remote). Don't stomp the
                    // slider while the user is dragging / a commit is pending.
                    if volumeCommit == nil, !volumeDragging, let v = zone.volume {
                        volume = Double(v)
                    }
                    muted = zone.muted
                }
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func apply(_ s: PlayerStateResponse) {
        playbackState = s.metaplayer.playback.state
        allowedActions = Set(s.metaplayer.playback.allowed_actions ?? [])
        position = s.metaplayer.playback.position ?? 0
        currentSourceID = sources.first { $0.name == s.metaplayer.source }?.id

        let md = s.metaplayer.metadata
        currentStreamURI = md?.uri?.nonEmpty
        streamCodec = md?.ca; streamMime = md?.mt
        streamBitrate = md?.br; streamSampleRate = md?.sf
        streamBitDepth = md?.bs; streamChannels = md?.ac
        title = md?.ti?.nonEmpty ?? s.metaplayer.source ?? deviceName
        subtitle = md?.ar?.nonEmpty
            ?? md?.al?.nonEmpty
            ?? md?.mp?.nonEmpty
            ?? s.metaplayer.source
            ?? ""
        artworkURL = md?.thumbnail_uri.flatMap(URL.init(string:))

        systemNP.update(title: title, artist: subtitle, artworkURL: artworkURL, isPlaying: isPlaying)
    }

    /// Sources we never want to surface in the UI.
    private static let hiddenSources = ["tidal", "qobuz", "alexa"]

    private func refreshSources() async {
        guard let client else { return }
        if let s = try? await client.sources() {
            sources = s.available_source.filter { src in
                let name = src.name.lowercased()
                return !Self.hiddenSources.contains { name.contains($0) }
            }
            currentSourceID = s.current_source?.id
        }
    }

    // MARK: - User actions (optimistic where it helps)

    func togglePlayPause() {
        run { client in
            if self.isPlaying { try await client.pause() } else { try await client.play() }
        }
        playbackState = isPlaying ? "paused" : "playing"    // optimistic
    }

    func next()     { run { try await $0.next() } }
    func previous() { run { try await $0.previous() } }
    func stop()     { run { try await $0.stop() }; playbackState = "stopped" }

    func toggleMute() {
        let target = !muted
        muted = target
        run { try await $0.setMuted(target) }
    }

    func selectSource(_ id: Int) {
        currentSourceID = id
        run { try await $0.selectSource(id: id) }
    }

    /// Marks the slider as being actively dragged so the poll loop won't overwrite it.
    func beginVolumeDrag() { volumeDragging = true }

    /// Debounced volume commit so dragging doesn't flood the amp. The written value is
    /// hard-capped at maxVolume; releasing above the cap snaps the slider back to it.
    func commitVolume() {
        volumeCommit?.cancel()
        volume = min(volume, maxVolume)                 // enforce the cap on release
        let target = Int(volume.rounded())
        volumeCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, let client = self.client else {
                self?.volumeDragging = false; return
            }
            try? await client.setVolume(target)
            try? await Task.sleep(for: .milliseconds(400))   // let the amp/poll settle
            self.volumeDragging = false
            self.volumeCommit = nil
        }
    }

    private func run(_ body: @escaping (CabasseClient) async throws -> Void) {
        guard let client else { return }
        Task { try? await body(client) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
