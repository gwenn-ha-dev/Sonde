import SwiftUI
import AppKit

// MARK: - Menu bar panel

struct MenuView: View {
    @Bindable var amp: AmpController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if amp.lastError != nil { ErrorBanner(amp: amp) }
            Divider()
            nowPlaying
            transport
            volume
            Divider()
            FavoritesSection(amp: amp, openCatalog: openCatalog)
            Divider()
            SoundSection(amp: amp)
            if !amp.sources.isEmpty {
                Divider()
                sourcePicker
            }
            Divider()
            HStack {
                Spacer()
                Button("Quitter") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func openCatalog() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "catalog")
    }

    private func openStats() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "stats")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(amp.deviceName).font(.headline).lineLimit(1)
            if !amp.powerOn {
                Text("veille").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            sleepTimerMenu
            powerButton
        }
    }

    private var powerButton: some View {
        Button(action: amp.togglePower) {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(amp.powerOn ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(amp.status != .connected)
        .help(amp.powerOn ? "Mettre en veille" : "Sortir de veille")
    }

    private var sleepTimerMenu: some View {
        Menu {
            if amp.sleepTimerEndsAt != nil {
                Button("Annuler le minuteur", action: amp.cancelSleepTimer)
                Divider()
            }
            ForEach([15, 30, 60, 90], id: \.self) { m in
                Button("Veille dans \(m) min") { amp.startSleepTimer(minutes: m) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: amp.sleepTimerEndsAt != nil ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 11))
                    .foregroundStyle(amp.sleepTimerEndsAt != nil ? Color.accentColor : Color.secondary)
                if let ends = amp.sleepTimerEndsAt {
                    Text(timerInterval: Date.now...ends, countsDown: true)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(amp.status != .connected || !amp.powerOn)
        .help("Minuteur de mise en veille")
    }

    private var statusColor: Color {
        switch amp.status {
        case .connected: return .green
        case .searching: return .yellow
        case .offline:   return .red
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            Artwork(url: amp.artworkURL, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(amp.title.isEmpty ? "—" : amp.title)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                if let icy = amp.icyTitle {
                    Text("♪ " + icy).font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(2)
                } else if !amp.subtitle.isEmpty {
                    Text(amp.subtitle).font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                qualityBadge
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Button(action: amp.addCurrentToFavorites) {
                    Image(systemName: amp.currentIsFavorite ? "star.fill" : "star")
                        .foregroundStyle(amp.currentIsFavorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(amp.currentIsFavorite || !amp.upnpReady)
                .help("Ajouter la radio en cours aux favoris")

                Button(action: openStats) {
                    Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Statistiques du flux")
            }
        }
    }

    @ViewBuilder private var qualityBadge: some View {
        HStack(spacing: 6) {
            if let badge = amp.qualityBadge {
                Text(badge).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let reading = amp.currentLoudness {
                LoudnessBadge(reading: reading)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Spacer()
            Button(action: amp.previous) { Image(systemName: "backward.fill").font(.system(size: 16)) }
            Button(action: amp.togglePlayPause) {
                Image(systemName: amp.isPlaying
                      ? (amp.canPause ? "pause.circle.fill" : "stop.circle.fill")
                      : "play.circle.fill")
                    .font(.system(size: 34))
            }
            Button(action: amp.next) { Image(systemName: "forward.fill").font(.system(size: 16)) }
            Spacer()
        }
        .buttonStyle(.plain)
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Button(action: amp.toggleMute) {
                    Image(systemName: amp.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(amp.muted ? Color.red : Color.primary)

                VolumeSlider(value: $amp.volume,
                             cap: amp.volumeCapEnabled ? amp.volumeCap : nil,
                             onDrag: amp.beginVolumeDrag, onCommit: amp.commitVolume)
                    .frame(height: 20)

                Text("\(Int(amp.volume))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(overCap ? Color.red : .secondary)
                    .frame(width: 26, alignment: .trailing)
            }
            if let notice = amp.lastNotice {
                Text(notice).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    private var overCap: Bool { amp.volumeCapEnabled && amp.volume > amp.volumeCap }

    private var sourcePicker: some View {
        HStack {
            Text("Source").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Menu(amp.sources.first { $0.id == amp.currentSourceID }?.name ?? "—") {
                ForEach(amp.sources) { src in
                    Button(src.name) { amp.selectSource(src.id) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

// MARK: - Favorites

struct FavoritesSection: View {
    @Bindable var amp: AmpController
    let openCatalog: () -> Void
    @State private var showAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Favoris").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { showAdd.toggle() } label: {
                    Image(systemName: showAdd ? "minus.circle" : "plus.circle").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .help("Ajouter une radio par son URL de flux")
                Button(action: openCatalog) {
                    Label("Catalogue", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .disabled(!amp.upnpReady)
            }

            if showAdd {
                AddRadioForm(amp: amp) { showAdd = false }
            }

            SearchField(text: $amp.favSearch, prompt: "Filtrer les favoris…")

            if amp.filteredFavorites.isEmpty {
                Text(amp.allFavorites.isEmpty ? "Aucun favori. Ouvre le catalogue ou ajoute la radio en cours (★)."
                                              : "Aucun favori ne correspond.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(amp.filteredFavorites) { fav in
                            FavoriteRow(fav: fav,
                                        loudness: amp.loudness(for: fav.streamURI),
                                        play: { amp.playFavorite(fav) },
                                        remove: { amp.removeFavorite(fav) })
                        }
                    }
                }
                // A ScrollView has no intrinsic height; inside the self-sizing menu it
                // would collapse to ~0 px (the "empty list" bug). Give it a concrete
                // height that grows with the count and caps so it scrolls when long.
                .frame(height: min(CGFloat(amp.filteredFavorites.count) * 36, 180))
            }
        }
    }
}

/// Manual "add radio by stream URL" mini-form, for stations no directory knows.
struct AddRadioForm: View {
    @Bindable var amp: AmpController
    let dismiss: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var site = ""
    @State private var error: String?

    private var incomplete: Bool {
        name.trimmingCharacters(in: .whitespaces).isEmpty
            || url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Nom", text: $name)
                .textFieldStyle(.roundedBorder).controlSize(.small).font(.system(size: 12))
            TextField("URL du flux (http…)", text: $url)
                .textFieldStyle(.roundedBorder).controlSize(.small).font(.system(size: 12))
            TextField("Site web (optionnel, pour le logo)", text: $site)
                .textFieldStyle(.roundedBorder).controlSize(.small).font(.system(size: 12))
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
            HStack {
                Spacer()
                Button("Annuler", action: dismiss).controlSize(.small)
                Button("Ajouter") {
                    if let e = amp.addManualFavorite(name: name, streamURI: url, website: site) {
                        error = e
                    } else {
                        dismiss()
                    }
                }
                .controlSize(.small).buttonStyle(.borderedProminent)
                .disabled(incomplete)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FavoriteRow: View {
    let fav: Favorite
    let loudness: LoudnessReading?
    let play: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) {
                HStack(spacing: 8) {
                    Artwork(url: fav.artURI.flatMap(URL.init(string:)), size: 28)
                    Text(fav.title).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let loudness { LoudnessBadge(reading: loudness) }
                    Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hover {
                Button(action: remove) { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(hover ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
    }
}

// MARK: - Sound (DEAP read-only + tone EQ)

struct SoundSection: View {
    @Bindable var amp: AmpController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Son").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)

            if !amp.deapLabel.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(amp.deapLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("Profil DEAP").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }

            ToneRow(label: "Grave", value: $amp.bass, range: amp.bassRange, commit: amp.commitBass)
            ToneRow(label: "Aigu", value: $amp.treble, range: amp.trebleRange, commit: amp.commitTreble)

            Divider().padding(.vertical, 2)

            HStack(spacing: 8) {
                Toggle(isOn: $amp.volumeCapEnabled) {
                    Text("Plafond de volume").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                Spacer()
                Stepper(value: $amp.volumeCap, in: 5...100, step: 5) {
                    Text("\(Int(amp.volumeCap))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 24, alignment: .trailing)
                }
                .disabled(!amp.volumeCapEnabled)
            }

            Text(amp.volumeCapEnabled
                 ? "Tout dépassement est ramené à \(Int(amp.volumeCap)), y compris depuis la télécommande physique ou l'app officielle."
                 : "Désactivé : plus aucun bridage du volume.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Measured programme loudness. Informational: the app reports the level and never
/// corrects it, so switching to a hot station is a surprise you can see coming.
struct LoudnessBadge: View {
    let reading: LoudnessReading

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 8))
            Text(reading.pretty).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(reading.isHot ? Color.orange : Color.secondary)
        .help(help)
    }

    private var help: String {
        let base = String(format: "Loudness mesurée : %.1f LUFS (%@ par rapport à la référence broadcast −18 LUFS), sur %d échantillon(s).",
                          reading.lufs, reading.offsetPretty, reading.samples)
        return reading.isHot
            ? base + " Cette station joue nettement plus fort : baisse le volume avant d'y passer."
            : base
    }
}

struct ToneRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let commit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            Stepper("", value: $value, in: range, step: 1)
                .labelsHidden()
                .onChange(of: value) { _, _ in commit() }
            Text(String(format: "%+d", Int(value)))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 28, alignment: .trailing)
            Spacer()
        }
    }
}

// MARK: - Catalogue window (global search + browse)

struct CatalogView: View {
    @Bindable var amp: AmpController
    @State private var tab: Tab = .radios

    enum Tab { case radios, podcasts }

    private var catalog: CatalogController { amp.catalog }

    var body: some View {
        VStack(spacing: 0) {
            if amp.lastError != nil { ErrorBanner(amp: amp).padding([.horizontal, .top], 10) }
            Picker("", selection: $tab) {
                Text("Radios").tag(Tab.radios)
                Text("Podcasts").tag(Tab.podcasts)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding([.horizontal, .top], 10)
            if tab == .radios { radiosPane } else { PodcastsPane(amp: amp) }
        }
        .frame(minWidth: 380, minHeight: 440)
        .onAppear { catalog.ensureIndexReady() }
        .onChange(of: catalog.search) { _, _ in catalog.scheduleWebSearch() }
    }

    private var radiosPane: some View {
        VStack(spacing: 0) {
            SearchField(text: Binding(get: { catalog.search }, set: { catalog.search = $0 }),
                        prompt: "Rechercher dans le catalogue…")
                .padding(10)
            indexBar
            Divider()
            if catalog.isSearching { searchResults } else { browser }
        }
    }

    // Index status + actions
    private var indexBar: some View {
        HStack(spacing: 8) {
            if catalog.indexBuilding {
                ProgressView().controlSize(.small)
                Text(catalog.indexProgress.total > 0
                     ? "Indexation… \(catalog.indexProgress.done)/\(catalog.indexProgress.total)"
                     : "Indexation…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "magnifyingglass.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(catalog.indexedCount) stations indexées")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if catalog.currentFolderIsStationList && !catalog.isSearching {
                    Button(catalog.currentFolderIndexed ? "Réindexer ce dossier" : "Indexer ce dossier pour la recherche",
                           action: catalog.indexCurrentFolder)
                }
                if !catalog.indexRoots.isEmpty {
                    Button("Réindexer tout", action: catalog.rebuildIndex)
                    Button("Vider l'index", role: .destructive, action: catalog.clearIndex)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(catalog.indexBuilding)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    // Global grep results: world-wide Radio Browser first, local vTuner index below
    private var searchResults: some View {
        Group {
            if catalog.results.isEmpty && catalog.webResults.isEmpty
                && !catalog.webSearching && !catalog.webSearchFailed {
                if catalog.indexedCount == 0 {
                    emptyIndexHint
                } else {
                    CenteredHint(text: "Aucune station ne correspond.")
                }
            } else {
                List {
                    Section("Radio Browser") {
                        if catalog.webSearching && catalog.webResults.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Recherche…").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        } else if catalog.webSearchFailed {
                            Text("Réseau indisponible — réessaie.")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        } else if catalog.webResults.isEmpty {
                            Text("Aucun résultat.").font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            ForEach(catalog.webResults) { st in stationRow(st) }
                        }
                    }
                    if !catalog.results.isEmpty {
                        Section("Catalogue de l'ampli (vTuner)") {
                            ForEach(catalog.results) { st in stationRow(st) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func stationRow(_ st: IndexedStation) -> some View {
        StationRow(title: st.title, genre: st.genre, artURI: st.artURI,
                   isFavorite: amp.isFavoriteURI(st.streamURI),
                   play: { amp.playStation(st) },
                   addFav: { amp.addStationToFavorites(st) })
    }

    private var emptyIndexHint: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Le catalogue n'est pas encore indexé.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Indexer les radios") { Task { await catalog.buildDefaultIndex() } }
                .disabled(catalog.indexBuilding || !amp.upnpReady)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // Hierarchical browser (when not searching)
    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: catalog.back) { Image(systemName: "chevron.left") }
                    .disabled(catalog.crumbs.count <= 1)
                Text(catalog.crumbs.map(\.title).joined(separator: " › "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if catalog.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            List(catalog.entries) { entry in
                if entry.isContainer {
                    FolderRow(title: entry.title) { catalog.enterFolder(entry) }
                } else {
                    StationRow(title: entry.title, genre: entry.genre, artURI: entry.artURI,
                               isFavorite: entry.streamURI.map(amp.isFavoriteURI) ?? false,
                               play: { amp.playEntry(entry) },
                               addFav: { amp.addToFavorites(entry) })
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Podcasts pane

struct PodcastsPane: View {
    @Bindable var amp: AmpController

    private var podcasts: PodcastsController { amp.podcasts }

    var body: some View {
        VStack(spacing: 0) {
            if let show = podcasts.show {
                episodes(of: show)
            } else {
                SearchField(text: Binding(get: { podcasts.search }, set: { podcasts.search = $0 }),
                            prompt: "Rechercher un podcast, ou coller une URL RSS…")
                    .padding(10)
                    .onChange(of: podcasts.search) { _, _ in podcasts.scheduleSearch() }
                Divider()
                showList
            }
        }
    }

    private var isSearching: Bool {
        !podcasts.search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder private var showList: some View {
        if isSearching {
            if podcasts.searching && podcasts.results.isEmpty {
                CenteredHint(text: "Recherche…")
            } else if podcasts.searchFailed {
                CenteredHint(text: "Réseau indisponible — réessaie.")
            } else if podcasts.results.isEmpty {
                CenteredHint(text: "Aucun podcast trouvé.")
            } else {
                List(podcasts.results) { show in showRow(show) }.listStyle(.inset)
            }
        } else if podcasts.favorites.isEmpty {
            CenteredHint(text: "Cherche un podcast, puis ★ pour le suivre ici.")
        } else {
            List {
                Section("Podcasts suivis") {
                    ForEach(podcasts.favorites) { show in showRow(show) }
                }
            }
            .listStyle(.inset)
        }
    }

    private func showRow(_ show: PodcastShow) -> some View {
        HStack(spacing: 10) {
            Button { podcasts.open(show) } label: {
                HStack(spacing: 10) {
                    Artwork(url: show.artURI.flatMap(URL.init(string:)), size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(show.title).font(.system(size: 12)).lineLimit(1)
                        if let a = show.author {
                            Text(a).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { podcasts.toggleFavorite(show) } label: {
                Image(systemName: podcasts.isFavorite(show) ? "star.fill" : "star")
                    .foregroundStyle(podcasts.isFavorite(show) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func episodes(of show: PodcastShow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: podcasts.close) { Image(systemName: "chevron.left") }
                Artwork(url: show.artURI.flatMap(URL.init(string:)), size: 24)
                Text(show.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { podcasts.toggleFavorite(show) } label: {
                    Image(systemName: podcasts.isFavorite(show) ? "star.fill" : "star")
                        .foregroundStyle(podcasts.isFavorite(show) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                if podcasts.episodesLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if podcasts.episodes.isEmpty && !podcasts.episodesLoading {
                CenteredHint(text: "Aucun épisode lisible dans ce flux.")
            } else {
                List(podcasts.episodes) { ep in
                    Button { amp.playPodcastEpisode(ep) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ep.title).font(.system(size: 12)).lineLimit(2)
                                if !ep.subtitle.isEmpty {
                                    Text(ep.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
    }
}

struct FolderRow: View {
    let title: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 28)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StationRow: View {
    let title: String
    let genre: String?
    let artURI: String?
    let isFavorite: Bool
    let play: () -> Void
    let addFav: () -> Void

    var body: some View {
        // Two sibling buttons: the content plays, the star favorites. Keeping them
        // as separate buttons (not a button nested inside an onTapGesture) is what
        // makes the star reliably receive its own click on macOS.
        HStack(spacing: 10) {
            Button(action: play) {
                HStack(spacing: 10) {
                    Artwork(url: artURI.flatMap(URL.init(string:)), size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12)).lineLimit(1)
                        if let g = genre {
                            Text(g).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: addFav) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain).disabled(isFavorite)
        }
    }
}

struct CenteredHint: View {
    let text: String
    var body: some View {
        VStack { Spacer(); Text(text).font(.system(size: 12)).foregroundStyle(.secondary); Spacer() }
            .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    @Bindable var amp: AmpController
    var body: some View {
        if let err = amp.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.system(size: 11))
                Text(err).font(.system(size: 11)).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 0)
                Button(action: amp.dismissError) { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Stream statistics window

struct StatsView: View {
    @Bindable var amp: AmpController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                qualityCard
                healthCard
            }
            .padding(16)
        }
        .frame(minWidth: 320, minHeight: 380)
        .onAppear { amp.startStats() }
        .onDisappear { amp.stopStats() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Artwork(url: amp.artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(amp.title.isEmpty ? "—" : amp.title)
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("À l'écoute depuis \(amp.elapsedPretty)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // Static stream quality
    private var qualityCard: some View {
        StatCard(title: "Qualité du flux") {
            StatLine("Codec", amp.codecPretty ?? "—")
            StatLine("Débit", amp.streamBitrate.map { "\($0 / 1000) kbps" } ?? "—")
            StatLine("Échantillonnage", amp.streamSampleRate.map { amp.sampleRatePretty($0) } ?? "—")
            StatLine("Résolution", amp.streamBitDepth.map { "\($0) bits" } ?? "—")
            StatLine("Canaux", amp.channelsPretty ?? "—")
            StatLine("Format", amp.streamMime ?? "—")
        }
    }

    // Live network / buffer health
    private var healthCard: some View {
        StatCard(title: "Réseau & tampon (en direct)") {
            HStack {
                StatLine("Tampon", amp.currentBufferedSeconds.map { String(format: "%.1f s", $0) } ?? "—")
                Spacer()
                healthDot
            }
            Sparkline(values: amp.statsSamples.map { Double($0.buffered_time) / 1000 }, tint: .blue)
                .frame(height: 34)

            StatLine("Débit réseau", amp.currentThroughputKbps.map { "\($0) kbps" } ?? "—")
            Sparkline(values: amp.statsSamples.map { Double($0.bytes_per_second) }, tint: .green)
                .frame(height: 34)

            StatLine("Taux d'alimentation", amp.currentRatePercent.map { "\($0) %" } ?? "—")
            if amp.statsSamples.isEmpty {
                Text("En attente de données…").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var healthDot: some View {
        let ok = (amp.currentRatePercent ?? 100) >= 100
        return HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(ok ? "stable" : "sous tension")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct StatCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StatLine: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .rounded))
        }
    }
}

/// Minimal line sparkline over a series, auto-scaled.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = max(hi - lo, 1)
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let y = size.height - CGFloat((v - lo) / span) * size.height
            return CGPoint(x: CGFloat(i) * stepX, y: y)
        }
    }
}

// MARK: - Shared bits

struct Artwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.quaternary)
            .overlay(Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.secondary))
    }
}

/// Volume slider on the full 0...100 scale. When a cap is set, the zone above it is
/// drawn in red and the drag cannot cross it; a higher value set from elsewhere still
/// displays, so it can be seen and lowered.
struct VolumeSlider: View {
    @Binding var value: Double         // 0...100
    let cap: Double?                   // e.g. 50, or nil when the ceiling is off
    let onDrag: () -> Void
    let onCommit: () -> Void

    private let trackH: CGFloat = 5
    private let thumb: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = min(max(value, 0), 100)
            let capX = cap.map { w * CGFloat($0 / 100) }
            let valX = w * CGFloat(clamped / 100)
            let over = cap.map { value > $0 } ?? false

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(height: trackH)
                // Forbidden zone (cap…100)
                if let capX {
                    Capsule().fill(Color.red.opacity(0.18))
                        .frame(width: max(0, w - capX), height: trackH)
                        .offset(x: capX)
                }
                // Filled portion up to the current value
                Capsule().fill(over ? Color.red : Color.accentColor)
                    .frame(width: valX, height: trackH)
                // Cap marker
                if let capX {
                    Rectangle().fill(Color.red.opacity(0.55))
                        .frame(width: 1.5, height: 11).offset(x: capX)
                }
                // Thumb
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                    .frame(width: thumb, height: thumb)
                    .shadow(radius: 1, y: 0.5)
                    .offset(x: min(max(valX - thumb / 2, 0), w - thumb))
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onDrag()
                        let x = min(max(g.location.x, 0), w)
                        value = min((Double(x / w) * 100).rounded(), cap ?? 100)
                    }
                    .onEnded { _ in onCommit() }
            )
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}
