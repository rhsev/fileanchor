import Foundation

/// Finder tags under the canonical `com.apple.metadata:_kMDItemUserTags` key
/// (with the leading underscore). Reads go through `URLResourceValues.tagNames`,
/// which returns clean names; writes edit the stored entries directly so that
/// tag colors survive (see `storedEntries`).
///
/// This is also where the ★ managed marker (U+2605) and any opt-in binder tags
/// live — they are all just Finder tag strings to this layer.
public enum Tags {
    /// Current tags as plain strings (color suffix already stripped by Foundation),
    /// NFC-normalized like comment reads: a tag stored decomposed would otherwise
    /// read back byte-different from the same text precomposed. Swift compares
    /// strings canonically, so add/remove match either form regardless.
    public static func get(path: String) throws -> [String] {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.tagNamesKey])
        return values.tagNames?.map(\.precomposedStringWithCanonicalMapping) ?? []
    }

    /// Add a tag if absent. Returns "added" or "noop". Idempotent. The tag
    /// must pass the label rule (Values); removal takes any tag.
    public static func add(path: String, value: String) throws -> String {
        let value = try Values.validate(value, as: .label, key: "tag")
        let entries = storedEntries(path: path)
        guard !entries.contains(where: { name(of: $0) == value }) else { return "noop" }
        try write(path: path, entries: entries + [value])
        return "added"
    }

    /// Remove a tag if present. Returns "removed" or "noop". Idempotent.
    public static func remove(path: String, value: String) throws -> String {
        let entries = storedEntries(path: path)
        guard entries.contains(where: { name(of: $0) == value }) else { return "noop" }
        try write(path: path, entries: entries.filter { name(of: $0) != value })
        return "removed"
    }

    /// Canonical storage key — with the leading underscore (verified).
    static let storageKey = "com.apple.metadata:_kMDItemUserTags"

    // Writes go to the stored entries, not through `tagNames`. An entry is
    // "name" or "name\n<color index>", and `tagNames` knows only names: a
    // read-modify-write through it drops every other tag's color (the native
    // macOS 26 setter resets them all to 0, verified on macOS 27). Existing
    // entries are kept byte for byte; a new tag goes in as a bare name, which
    // Finder shows and Spotlight indexes (verified since 1.0.0).
    private static func storedEntries(path: String) -> [String] {
        guard let data = Xattr.getData(storageKey, path: path), !data.isEmpty,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list
    }

    private static func name(of entry: String) -> String {
        entry.firstIndex(of: "\n").map { String(entry[..<$0]) } ?? entry
    }

    /// Replace the stored entries. An empty list clears the tag xattr.
    /// Foundation produces the binary-plist array — never hand-rolled.
    private static func write(path: String, entries: [String]) throws {
        if entries.isEmpty {
            guard Xattr.remove(storageKey, path: path) else { throw EngineError.writeFailed(storageKey) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        guard Xattr.setData(storageKey, data: data, path: path) else {
            throw EngineError.writeFailed(storageKey)
        }
    }
}
