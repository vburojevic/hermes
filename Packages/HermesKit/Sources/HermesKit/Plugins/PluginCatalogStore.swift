import Foundation

/// The catalog feed, fetched and kept on this device (`docs/plugins.md` §4). Like Hermes's own
/// client (`hermes_cli/plugin_catalog.py`): a copy younger than six hours is used as it is; an older
/// one is refreshed, and kept when the refresh fails. A failed fetch isn't retried for a minute.
public actor PluginCatalogStore {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let feed = URL(string: "https://hermes-agent.nousresearch.com/docs/api/plugin-catalog.json")!

    private let url: URL
    private let cacheFile: URL?
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var cached: (catalog: PluginCatalog, at: Date)?
    private var failedAt: Date?

    static let fresh: TimeInterval = 6 * 3600
    static let retryAfterFailure: TimeInterval = 60

    public init(url: URL = PluginCatalogStore.feed, cacheFile: URL?, now: @escaping @Sendable () -> Date = { .now },
                fetch: @escaping Fetch) {
        self.url = url
        self.cacheFile = cacheFile
        self.fetch = fetch
        self.now = now
    }

    /// The catalog, from memory, the file, or the feed; nil when none of them has it.
    public func catalog(refresh: Bool = false) async -> PluginCatalog? {
        if cached == nil, let cacheFile, let data = try? Data(contentsOf: cacheFile), let catalog = try? PluginCatalog(data: data) {
            let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            cached = (catalog, modified)
        }
        if let cached, !refresh, now().timeIntervalSince(cached.at) < Self.fresh { return cached.catalog }
        if let failedAt, now().timeIntervalSince(failedAt) < Self.retryAfterFailure { return cached?.catalog }
        do {
            let data = try await fetch(url)
            let catalog = try PluginCatalog(data: data)
            cached = (catalog, now())
            failedAt = nil
            if let cacheFile {
                try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheFile, options: .atomic)
            }
            return catalog
        } catch {
            failedAt = now()
            return cached?.catalog
        }
    }
}
