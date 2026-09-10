import Foundation
import Observation
import AppKit

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

    /// Transient note about something the app did on its own. Distinct from an error:
    /// nothing failed, but the user still needs to know why the volume moved.
    private(set) var lastNotice: String?
    private var noticeClearTask: Task<Void, Never>?

    private func setNotice(_ message: String) {
        lastNotice = message
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.lastNotice = nil }
        }
    }

    // Power & sleep timer
    private(set) var powerOn: Bool = true
    private(set) var sleepTimerEndsAt: Date?
    private var sleepTimerTask: Task<Void, Never>?

    // Playback
    private(set) var playbackState: String = "stopped"   // playing | paused | stopped
    // Song currently on air (webradios), sampled from the stream's ICY metadata
    private(set) var icyTitle: String?
    private var icyTask: Task<Void, Never>?
    private var icyURI: String?                          // stream the ICY task watches
    private(set) var title: String = ""
    private(set) var subtitle: String = ""
    private(set) var artworkURL: URL?
    private(set) var allowedActions: Set<String> = []

    // Mixer
    var volume: Double = 0            // 0...100 (real amp volume, shown on the slider)
    private(set) var volumeDragging = false

    /// Volume ceiling, enforced rather than merely drawn: `pollZone` pulls the amp
    /// back down whenever anything else — the physical remote, the official app,
    /// AirPlay, Bluetooth — pushes past it. Turn it off and the slider is free again.
    var volumeCapEnabled: Bool = Defaults.volumeCapEnabled {
        didSet {
            Defaults.volumeCapEnabled = volumeCapEnabled
            enforceVolumeCap()
        }
    }
    var volumeCap: Double = Defaults.volumeCap {
        didSet {
            Defaults.volumeCap = volumeCap
            enforceVolumeCap()
        }
    }
    /// Comfort preset: applied at app launch when nothing is playing, and after an
    /// app-initiated power-on, so the amp never starts loud (its own startup volume
    /// can be as high as 50). Never applied while something is playing.
    private let startupVolume: Double = 4
    private var startupVolumeApplied = false
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

    // Measured programme loudness per stream URL. Informational only: the app
    // reports the level, it never corrects the volume from it.
    private(set) var loudnessByURI: [String: LoudnessReading] = [:]

    func loudness(for streamURI: String) -> LoudnessReading? { loudnessByURI[streamURI] }

    /// Loudness of whatever is on air, when it is a stream we have measured.
    var currentLoudness: LoudnessReading? { currentStreamURI.flatMap { loudnessByURI[$0] } }

    // Favorites (unlimited, app-managed)
    private(set) var allFavorites: [Favorite] = []
    var favSearch: String = ""

    // Sub-controllers: catalogue (vTuner + index + Radio Browser) and podcasts.
    // They own browsing/search data; every action on the amp stays here.
    let catalog = CatalogController()
    let podcasts = PodcastsController()
    private(set) var upnpReady = false

    private var currentStreamURI: String?

    var isPlaying: Bool { playbackState == "playing" }
    /// Live streams refuse Pause (403) — the amp only allows play/stop on them.
    var canPause: Bool { allowedActions.contains("pause") }

    /// grep-style filter: every whitespace term must appear (AND), case/diacritic-insensitive.
    var filteredFavorites: [Favorite] { grepFilter(allFavorites, favSearch) { $0.searchKey } }

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

    // MARK: - Internals

    private let discovery = Discovery()
    private var client: CabasseClient?
    private var loops: [Task<Void, Never>] = []
    private var volumeCommit: Task<Void, Never>?
    private var capEnforceTask: Task<Void, Never>?
    private var bassCommit: Task<Void, Never>?
    private var trebleCommit: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var statsWantedOnReconnect = false

    private let favStore = FavoritesStore()
    private let loudnessStore = LoudnessStore()
    private var loudnessTask: Task<Void, Never>?
    private let systemNP = SystemNowPlaying()
    private var upnp: UPnPServices?

    init() {
        allFavorites = favStore.items
        loudnessByURI = loudnessStore.readings
        podcasts.onError = { [weak self] in self?.setError($0) }
        // Route macOS media keys / Control Center to the amp.
        systemNP.onPlay = { [weak self] in self?.mediaSetPlaying(true) }
        systemNP.onPause = { [weak self] in self?.mediaSetPlaying(false) }
        systemNP.onToggle = { [weak self] in self?.togglePlayPause() }
        systemNP.onNext = { [weak self] in self?.next() }
        systemNP.onPrevious = { [weak self] in self?.previous() }
        observeSystemWake()
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
            await applyStartupVolume(client)
        }

        // Media browsing/playback lives on UPnP, discovered separately.
        Task { @MainActor in
            upnp = await UPnP.discover(host: amp.host)
            upnpReady = (upnp != nil)
            catalog.upnp = upnp
            dlog("upnp ready: \(upnpReady)")
            if upnpReady {
                await catalog.loadRoot()
                // Build the searchable catalogue index in the background;
                // cached afterwards, so later launches are instant.
                await catalog.buildDefaultIndex()
            }
        }

        loops.append(Task { [weak self] in await self?.pollPlayer(client) })
        loops.append(Task { [weak self] in await self?.pollZone(client) })
        loops.append(Task { [weak self] in await self?.pollPower(client) })

        if statsWantedOnReconnect {
            statsWantedOnReconnect = false
            startStats()
        }
    }

    // MARK: - Connection loss & Mac sleep

    /// Drops the current (dead) connection and goes back to Bonjour discovery.
    /// The amp may come back on a different IP after a reboot/DHCP renewal.
    private func reconnect() {
        guard client != nil else { return }
        dlog("connection lost; dropping client and restarting discovery")
        for t in loops { t.cancel() }
        loops = []
        statsWantedOnReconnect = (statsTask != nil)
        stopStats()
        client = nil
        upnp = nil
        upnpReady = false
        catalog.upnp = nil
        stopICY()                  // don't sample a stream we're not driving anymore
        status = .searching
        discovery.stop()
        start()
    }

    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.verifyConnectionAfterWake() }
        }
    }

    /// After the Mac wakes, the long-poll sockets are often silently dead and the
    /// amp may have moved IP. Probe it once (after letting Wi-Fi come back up) and
    /// reconnect if it doesn't answer.
    private func verifyConnectionAfterWake() {
        guard let client else { return }        // still searching; discovery handles it
        dlog("mac woke; probing amp")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))     // let the network settle
            let ok = await Self.probe(client)
            // Ignore a stale probe if we already reconnected elsewhere meanwhile.
            guard let self, self.client?.base == client.base else { return }
            if !ok {
                dlog("probe failed after wake; reconnecting")
                self.reconnect()
            }
        }
    }

    /// One bounded liveness check against the amp's REST API.
    private static func probe(_ client: CabasseClient, timeout: Double = 5) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await client.deviceInfo()) != nil }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Power & sleep timer

    /// Once per app launch: if the amp is idle (or in standby) when we connect,
    /// preset a low volume so the next power-on/play doesn't blast. Skipped
    /// entirely when something is already playing.
    private func applyStartupVolume(_ client: CabasseClient) async {
        guard !startupVolumeApplied else { return }
        startupVolumeApplied = true
        guard let st = try? await client.playerState(),
              st.metaplayer.playback.state != "playing" else { return }
        try? await client.setVolume(Int(startupVolume))
        volume = startupVolume
        dlog("startup volume preset to \(Int(startupVolume))")
    }

    func togglePower() {
        let target = !powerOn
        powerOn = target                        // optimistic
        if !target { cancelSleepTimer() }
        run { [startupVolume] client in
            try await client.setPower(target)
            if target {
                // Wake up quiet: override the amp's own (loud) startup volume.
                try? await client.setVolume(Int(startupVolume))
            }
        }
        if target { volume = startupVolume }
    }

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerEndsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard let self, !Task.isCancelled else { return }
            self.sleepTimerEndsAt = nil
            self.powerOn = false
            // The amp may be mid-reconnection right now: retry for a while
            // instead of silently dropping the power-off.
            for _ in 0..<6 {
                if let client = self.client, (try? await client.setPower(false)) != nil { return }
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
            }
            self.setError("Minuteur : impossible d'éteindre l'ampli (injoignable).")
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
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

    /// Manual favorite by direct stream URL, for stations absent from every
    /// directory (vTuner and Radio Browser). Returns a user-facing error
    /// message, or nil on success.
    func addManualFavorite(name: String, streamURI: String, website: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let uri = streamURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return "Donne un nom à la radio." }
        guard let u = URL(string: uri), u.scheme == "http" || u.scheme == "https", u.host != nil else {
            return "URL de flux invalide (une adresse http(s) directe est attendue)."
        }
        guard !allFavorites.contains(where: { $0.streamURI == uri }) else {
            return "Cette radio est déjà dans les favoris."
        }
        favStore.add(title: n, streamURI: uri, artURI: RadioBrowser.websiteIcon(website), genre: nil)
        allFavorites = favStore.items
        return nil
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

    // MARK: - Catalogue playback

    func playEntry(_ entry: MediaEntry) {
        guard let uri = entry.streamURI else { return }
        play(uri: uri, title: entry.title, art: entry.artURI)
    }

    // MARK: - Podcast playback

    func playPodcastEpisode(_ ep: PodcastEpisode) {
        play(uri: ep.enclosureURL, title: ep.title, art: ep.artURI ?? podcasts.show?.artURI)
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
        var failures = 0
        while !Task.isCancelled {
            do {
                let (data, newEtag) = try await client.longPoll("/Player/State.json", etag: etag)
                etag = newEtag
                if let data {
                    let state = try JSONDecoder().decode(PlayerStateResponse.self, from: data)
                    apply(state)
                    dlog("player: \(playbackState) — \(title) / \(subtitle)")
                }
                failures = 0
                status = .connected
            } catch {
                dlog("player poll error: \(error)")
                status = .offline
                failures += 1
                // Persistent failures usually mean the amp rebooted or moved IP:
                // give up on this address and let Bonjour find it again.
                if failures >= 5 {
                    reconnect()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollPower(_ client: CabasseClient) async {
        var etag: String?
        while !Task.isCancelled {
            let t0 = ContinuousClock.now
            do {
                let (data, newEtag) = try await client.longPoll("/System/PowerState.json", etag: etag)
                etag = newEtag
                if let data, let r = try? JSONDecoder().decode(PowerStateResponse.self, from: data) {
                    // Turned off from elsewhere (remote, timer): a pending sleep
                    // timer no longer makes sense.
                    if powerOn && !r.power.state { cancelSleepTimer() }
                    powerOn = r.power.state
                }
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
            // If this endpoint ignores `Prefer: wait` and answers instantly,
            // don't turn the loop into a hot poll.
            if ContinuousClock.now - t0 < .seconds(1) {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pollZone(_ client: CabasseClient) async {
        var etag: String?
        while !Task.isCancelled {
            let t0 = ContinuousClock.now
            do {
                let (data, newEtag) = try await client.longPoll("/Zone/State.json", etag: etag)
                etag = newEtag
                if let data {
                    let zone = try JSONDecoder().decode(ZoneState.self, from: data)
                    // Show the amp's real volume on the full 0...100 scale. Don't stomp
                    // the slider while the user is dragging / a commit is pending.
                    if volumeCommit == nil, !volumeDragging, let v = zone.volume {
                        volume = Double(v)
                        enforceVolumeCap()
                    }
                    muted = zone.muted
                }
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
            // Same guard as the now-playing loop: if this endpoint ever stops honouring
            // `Prefer: wait`, the loop must not degrade into a hot poll.
            if ContinuousClock.now - t0 < .seconds(1) {
                try? await Task.sleep(for: .seconds(1))
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

        syncICY()
        pushNowPlaying()
    }

    /// System Now Playing: when we know the song on air, it becomes the title and
    /// the station name moves to the artist line.
    private func pushNowPlaying() {
        systemNP.update(title: icyTitle ?? title,
                        artist: icyTitle != nil ? title : subtitle,
                        artworkURL: artworkURL,
                        isPlaying: isPlaying)
    }

    private func stopICY() {
        icyTask?.cancel()
        icyTask = nil
        icyURI = nil
        icyTitle = nil
    }

    /// Keeps one ICY sampling loop alive for the http(s) stream being played,
    /// and none otherwise. Streams without ICY support are given up on until
    /// the station changes.
    private func syncICY() {
        let want: URL? = {
            guard isPlaying, let uri = currentStreamURI, let url = URL(string: uri),
                  url.scheme == "http" || url.scheme == "https" else { return nil }
            return url
        }()
        guard want?.absoluteString != icyURI else { return }

        icyTask?.cancel()
        icyTask = nil
        icyURI = want?.absoluteString
        icyTitle = nil
        guard let url = want else {
            dlog("icy: stopped (no playable http stream)")
            return
        }

        dlog("icy: watching \(url.absoluteString)")
        measureLoudness(of: url)
        icyTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                var sample: String?
                do {
                    sample = try await ICYMetadata.fetchTitle(from: url)
                } catch {
                    dlog("icy: sample error: \(error)")
                }
                guard let self, !Task.isCancelled else { return }
                if let s = sample {
                    misses = 0
                    let clean = s.trimmingCharacters(in: .whitespaces)
                    let new = (clean.isEmpty || clean.caseInsensitiveCompare(self.title) == .orderedSame)
                        ? nil : clean
                    if new != self.icyTitle {
                        self.icyTitle = new
                        dlog("icy: \(new ?? "-")")
                        self.pushNowPlaying()
                    }
                } else {
                    dlog("icy: no metadata (miss \(misses + 1))")
                    misses += 1
                    if misses >= 2 { return }   // stream has no ICY; stop until it changes
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
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
        if isPlaying {
            // Live radio refuses Pause: fall back to Stop (Play resumes the stream).
            if canPause {
                run { try await $0.pause() }
                playbackState = "paused"                    // optimistic
            } else {
                run { try await $0.stop() }
                playbackState = "stopped"
            }
        } else {
            run { try await $0.play() }
            playbackState = "playing"
        }
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

    /// Debounced volume commit so dragging doesn't flood the amp.
    func commitVolume() {
        volumeCommit?.cancel()
        if volumeCapEnabled { volume = min(volume, volumeCap) }
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

    /// Pulls the amp back to the ceiling when something outside the app pushed past
    /// it. Debounced, so holding the physical remote's up key costs one write on
    /// release rather than one per step — and so we never fight our own commit.
    private func enforceVolumeCap() {
        guard volumeCapEnabled, volume > volumeCap,
              volumeCommit == nil, !volumeDragging else { return }
        capEnforceTask?.cancel()
        capEnforceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, let client = self.client,
                  self.volumeCapEnabled, self.volume > self.volumeCap,
                  self.volumeCommit == nil, !self.volumeDragging else { return }
            let ceiling = Int(self.volumeCap.rounded())
            try? await client.setVolume(ceiling)
            self.volume = self.volumeCap
            self.setNotice("Plafond atteint — volume ramené à \(ceiling).")
            self.capEnforceTask = nil
        }
    }

    /// Samples the programme loudness of the stream on air, off the main actor.
    /// Purely informational — nothing here touches the volume. Refines a running
    /// mean up to five samples, then leaves the station alone for three months.
    private func measureLoudness(of url: URL) {
        let key = url.absoluteString
        if let known = loudnessByURI[key], known.samples >= 5,
           known.measuredAt > Date().addingTimeInterval(-90 * 86_400) { return }

        loudnessTask?.cancel()
        loudnessTask = Task { [weak self] in
            // Let the amp latch onto the stream first: sampling it from the Mac at the
            // same instant just adds contention on the station's server.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  let lufs = try? await Loudness.measure(stream: url),
                  let self, !Task.isCancelled else { return }
            let reading = self.loudnessStore.record(lufs, for: key)
            self.loudnessByURI[key] = reading
            dlog("loudness \(key) -> \(reading.pretty) after \(reading.samples) sample(s)")
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
