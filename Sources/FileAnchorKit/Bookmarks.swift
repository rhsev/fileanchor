import Foundation

/// Durable, move-resilient file identity via Foundation bookmark data — the
/// in-process replacement for shelling out to the `bookmark` CLI.
///
/// The blob is the base64 of a plain (non security-scoped) bookmark. This is the
/// same byte format the vendored ttscoff/bookmark tool emits (magic `book`), so
/// blobs already stored in fileregister's `bookmarks.json` resolve unchanged — the
/// engine swap is migration-safe.
///
/// The engine is **stateless about the id↔blob map**: it only does
/// `save(path) → blob` and `resolve(blob) → path`. The consumer keeps the map.
public enum Bookmarks {
    /// Create a bookmark blob for `path`. Throws if the file cannot be read.
    public static func save(path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try url.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        return data.base64EncodedString()
    }

    public struct Resolved {
        public let path: String
        public let stale: Bool
    }

    /// Resolve a blob to a path. Returns nil when the blob is empty or cannot be
    /// resolved (the move-resilient negative — not an error). `stale` signals the
    /// bookmark resolved but should be regenerated with a fresh `save`.
    public static func resolve(blob: String) -> Resolved? {
        guard !blob.isEmpty, let data = Data(base64Encoded: blob) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            return nil
        }
        return Resolved(path: url.path, stale: stale)
    }
}
