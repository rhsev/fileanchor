import Foundation
import Darwin

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
    ///
    /// A symlink is followed to its target first, as every metadata op
    /// follows it: a bookmark made of the link itself would name the link
    /// while tags and ids sit on the target, and would go on resolving, to
    /// the link, after the target is gone.
    public static func save(path: String) throws -> String {
        let url = URL(fileURLWithPath: onDiskPath(path))
        let data = try url.bookmarkData(options: [],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        return data.base64EncodedString()
    }

    public struct Resolved {
        public let path: String
        public let stale: Bool
        /// Another file that lies where the bookmark was saved, while the
        /// bookmarked file itself was found elsewhere. nil in every other case.
        public let atOldPath: String?
    }

    /// Resolve a blob to a path. Returns nil when the blob is empty or cannot be
    /// resolved (the move-resilient negative — not an error). `stale` signals the
    /// bookmark resolved but should be regenerated with a fresh `save`.
    ///
    /// The path comes back as the file system holds it (SPEC.md): byte for
    /// byte the names on the volume, see `onDiskPath`.
    ///
    /// Resolving never mounts a volume or shows UI: an engine call must not
    /// block on an unreachable server, and a file on a volume that is not
    /// mounted is not "found" by mounting it behind the caller's back. The
    /// caller learns where it was from `recordedPath`.
    public static func resolve(blob: String) -> Resolved? {
        guard !blob.isEmpty, let data = Data(base64Encoded: blob) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withoutMounting, .withoutUI],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            return nil
        }
        let path = onDiskPath(url.path)
        // Foundation looks at the recorded path first and takes whatever lies
        // there. When that is another file and the bookmarked one still
        // exists, the bookmarked one is the answer (SPEC.md, "The file comes
        // before the path").
        if let original = movedOriginal(data: data, resolved: path) {
            return Resolved(path: original, stale: true, atOldPath: path)
        }
        return Resolved(path: path, stale: stale, atOldPath: nil)
    }

    /// The key under which bookmark data gives out the file's inode number.
    /// Foundation has no public name for it. When it stops answering, resolve
    /// falls back to what Foundation resolved, and the selftest fails.
    static let recordedFileIDKey = URLResourceKey("_NSURLFileIDKey")

    /// The inode number a blob recorded, or nil.
    public static func recordedFileID(data: Data) -> UInt64? {
        guard let values = URL.resourceValues(forKeys: [recordedFileIDKey], fromBookmarkData: data),
              let number = values.allValues[recordedFileIDKey] as? NSNumber
        else { return nil }
        return number.uint64Value
    }

    /// Where the bookmarked file is now, when `resolved` is a different file
    /// that lies at the recorded path. nil when `resolved` is the bookmarked
    /// file, or when that file is gone.
    ///
    /// The file is looked up by its inode number on the volume `resolved` lies
    /// on, with fsgetpath(2), which opens nothing. A file system that reuses
    /// inode numbers could hand back a newer file under the old number, so the
    /// creation date the bookmark recorded has to match as well.
    static func movedOriginal(data: Data, resolved: String) -> String? {
        guard let fileID = recordedFileID(data: data) else { return nil }
        var st = stat()
        guard stat(resolved, &st) == 0, UInt64(st.st_ino) != fileID else { return nil }
        var fs = statfs()
        guard statfs(resolved, &fs) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fsgetpath(&buffer, buffer.count, &fs.f_fsid, fileID) > 0 else { return nil }
        let original = onDiskPath(String(cString: buffer))
        var found = stat()
        guard original != resolved, stat(original, &found) == 0,
              UInt64(found.st_ino) == fileID else { return nil }
        if let created = URL.resourceValues(forKeys: [.creationDateKey], fromBookmarkData: data)?.creationDate {
            let birth = Double(found.st_birthtimespec.tv_sec) + Double(found.st_birthtimespec.tv_nsec) / 1e9
            guard abs(birth - created.timeIntervalSince1970) < 1 else { return nil }
        }
        return original
    }

    /// The path in the bytes the file system holds. Foundation hands a resolved
    /// bookmark back with every name decomposed (NFD), whatever the volume
    /// holds: measured on APFS, an NFC directory and an NFC file both came back
    /// NFD. realpath(3) reads each name back off the volume and changes nothing
    /// else, since the resolved path has its symlinks resolved already
    /// (/var → /private/var both ways). It opens nothing, so a FIFO cannot block
    /// it. When it fails — the file went away in between — the resolved path is
    /// the best answer there is.
    static func onDiskPath(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The path a blob recorded when it was saved, read from the bookmark
    /// data without resolving it. For an unresolvable blob this tells a file
    /// that is gone from one on a volume that is simply not mounted.
    public static func recordedPath(blob: String) -> String? {
        guard !blob.isEmpty, let data = Data(base64Encoded: blob),
              let values = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)
        else { return nil }
        return values.path
    }
}
