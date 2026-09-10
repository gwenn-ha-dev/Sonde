import Foundation
import Observation

/// Podcast browsing: Apple-catalogue search (with the Radio France feed recovery
/// and pasted-RSS escape hatch), followed shows, and the opened show's episode
/// list. Owns data only — playing an episode is AmpController's job.
@MainActor
@Observable
final class PodcastsController {

    var search: String = ""
    private(set) var results: [PodcastShow] = []
    private(set) var searching = false
    private(set) var searchFailed = false

    private(set) var favorites: [PodcastShow] = []
    private(set) var show: PodcastShow?            // opened show, nil = list
    private(set) var episodes: [PodcastEpisode] = []
    private(set) var episodesLoading = false

    /// Error reporting, wired to AmpController's transient banner.
    var onError: ((String) -> Void)?

    private let store = PodcastStore()
    private let debounce = Debounced()

    init() { favorites = store.items }

    /// Debounced search in the Apple catalogue; a pasted RSS URL is parsed
    /// directly. Network failures are surfaced (`searchFailed`) instead of
    /// reading as "no results".
    func scheduleSearch() {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else {
            debounce.cancel()
            results = []
            searching = false
            searchFailed = false
            return
        }
        let isFeedURL = q.hasPrefix("http://") || q.hasPrefix("https://")
        searching = true
        debounce.run { [weak self] in
            guard let self else { return }
            do {
                let found: [PodcastShow]
                if isFeedURL {
                    found = await Podcasts.show(fromFeed: q).map { [$0] } ?? []
                } else {
                    found = try await Podcasts.search(q)
                }
                guard !Task.isCancelled else { return }
                self.results = found
                self.searchFailed = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.results = []
                self.searchFailed = true
                dlog("podcast search failed: \(error)")
            }
            self.searching = false
        }
    }

    func open(_ s: PodcastShow) {
        show = s
        episodes = []
        episodesLoading = true
        Task { [weak self] in
            let eps = (try? await Podcasts.episodes(of: s)) ?? []
            guard let self, self.show?.feedURL == s.feedURL else { return }
            self.episodes = eps
            self.episodesLoading = false
            if eps.isEmpty { self.onError?("Flux RSS illisible pour « \(s.title) ».") }
        }
    }

    func close() {
        show = nil
        episodes = []
        episodesLoading = false
    }

    func isFavorite(_ s: PodcastShow) -> Bool { store.contains(s) }

    func toggleFavorite(_ s: PodcastShow) {
        store.toggle(s)
        favorites = store.items
    }
}
