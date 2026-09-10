import Foundation

// MARK: - Networking

enum Net {
    /// Ephemeral, cache-less session — all the app's HTTP goes through these.
    static func session(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = timeout
        return URLSession(configuration: cfg)
    }
}

// MARK: - Debounce

/// Debounced single-flight job: each `run` cancels the previous pending one.
@MainActor
final class Debounced {
    private var task: Task<Void, Never>?

    func run(after milliseconds: Int = 400, _ body: @escaping () async -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            await body()
        }
    }

    func cancel() { task?.cancel() }
}

// MARK: - grep

/// Every whitespace-separated term must appear (AND), case/diacritic-insensitive.
func grepFilter<T>(_ items: [T], _ query: String, key: (T) -> String) -> [T] {
    let terms = query.folding(options: .diacriticInsensitive, locale: .current)
        .lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return items }
    return items.filter { item in
        let k = key(item)
        return terms.allSatisfy { k.contains($0) }
    }
}

// MARK: - Preferences

/// The handful of settings that must survive a relaunch. Everything else the app
/// shows is read back from the amp itself.
enum Defaults {
    private static let store = UserDefaults.standard
    private static let capEnabledKey = "volumeCapEnabled"
    private static let capKey = "volumeCap"

    static var volumeCapEnabled: Bool {
        get { store.object(forKey: capEnabledKey) as? Bool ?? true }
        set { store.set(newValue, forKey: capEnabledKey) }
    }

    /// Kept in 5...100 so a corrupted preference can never mute the amp outright.
    static var volumeCap: Double {
        get { min(max(store.object(forKey: capKey) as? Double ?? 50, 5), 100) }
        set { store.set(min(max(newValue, 5), 100), forKey: capKey) }
    }
}
