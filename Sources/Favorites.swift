import Foundation

/// A saved web radio. Playable via UPnP AVTransport from its `streamURI`.
struct Favorite: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var streamURI: String
    var artURI: String?
    var genre: String?
    var addedAt: Date

    /// Lower-cased, diacritic-folded haystack for grep-style matching.
    var searchKey: String {
        (title + " " + (genre ?? ""))
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
    }
}

/// Unlimited favorites persisted as JSON in Application Support. No 9-slot cap.
final class FavoritesStore {
    private(set) var items: [Favorite] = []
    private let url: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sonde", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("favorites.json")
        load()
    }

    func contains(streamURI: String) -> Bool {
        items.contains { $0.streamURI == streamURI }
    }

    @discardableResult
    func add(title: String, streamURI: String, artURI: String?, genre: String?) -> Bool {
        guard !streamURI.isEmpty, !contains(streamURI: streamURI) else { return false }
        items.insert(Favorite(title: title, streamURI: streamURI, artURI: artURI,
                              genre: genre, addedAt: Date()), at: 0)
        save()
        return true
    }

    func remove(_ favorite: Favorite) {
        items.removeAll { $0.id == favorite.id }
        save()
    }

    func rename(_ favorite: Favorite, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == favorite.id }) else { return }
        items[i].title = title
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        items = (try? JSONDecoder().decode([Favorite].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
