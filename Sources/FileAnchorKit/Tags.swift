import Foundation

/// Finder tags via `URLResourceValues.tagNames` — Foundation reads and writes
/// the canonical `com.apple.metadata:_kMDItemUserTags` key (with the leading
/// underscore) and handles the binary-plist array encoding for us. No
/// hand-rolled plist, no manual color-suffix stripping: `tagNames` already
/// returns clean names.
///
/// This is also where the ★ managed marker (U+2605) and any opt-in binder tags
/// live — they are all just Finder tag strings to this layer.
public enum Tags {
    /// Current tags as plain strings (color suffix already stripped by Foundation).
    public static func get(path: String) throws -> [String] {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.tagNamesKey])
        return values.tagNames ?? []
    }

    /// Add a tag if absent. Returns "added" or "noop". Idempotent.
    public static func add(path: String, value: String) throws -> String {
        var tags = try get(path: path)
        guard !tags.contains(value) else { return "noop" }
        tags.append(value)
        try write(path: path, tags: tags)
        return "added"
    }

    /// Remove a tag if present. Returns "removed" or "noop". Idempotent.
    public static func remove(path: String, value: String) throws -> String {
        var tags = try get(path: path)
        guard tags.contains(value) else { return "noop" }
        tags.removeAll { $0 == value }
        try write(path: path, tags: tags)
        return "removed"
    }

    /// Canonical storage key — with the leading underscore (verified). Used by
    /// the pre-macOS-26 write path; the native setter targets the same key.
    static let storageKey = "com.apple.metadata:_kMDItemUserTags"

    /// Replace the full tag set. An empty array clears the tag xattr.
    ///
    /// The `tagNames` *setter* is annotated macOS 26.0+, so below that we write
    /// the canonical `_kMDItemUserTags` key ourselves — but let Foundation
    /// (`PropertyListSerialization`) produce the binary-plist array. We never
    /// hand-roll the binary format, and both paths hit the identical key, so the
    /// result is Finder-visible and Spotlight-indexed (verified) either way.
    private static func write(path: String, tags: [String]) throws {
        if #available(macOS 26.0, *) {
            var url = URL(fileURLWithPath: path)
            var values = URLResourceValues()
            values.tagNames = tags
            try url.setResourceValues(values)
        } else {
            if tags.isEmpty {
                Xattr.remove(storageKey, path: path)
            } else {
                let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
                guard Xattr.setData(storageKey, data: data, path: path) else {
                    throw EngineError.writeFailed(storageKey)
                }
            }
        }
    }
}
