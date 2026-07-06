import Foundation

/// The string-metadata layer: `groups` → `kMDItemProjects` (a real CFArray) and
/// `id` → `kMDItemInformation` (space-separated multi-valued string) — both Apple
/// metadata xattrs — plus the cross-device `sync` id (a custom single-valued
/// xattr whose name the consumer supplies), and `comment` → `kMDItemFinderComment`
/// (a single string, but stored as a *binary-plist-wrapped* string, the shape
/// Finder and Brett-Terpstra-style backups use).
///
/// `groups`/`id`/`comment` map to fixed Apple keys — not consumer-specific, so
/// they are baked in. The `sync` name is **not** baked in: it is a consumer
/// concept (fileregister uses `com.fileregister.id#S`), passed via `--sync-name` or
/// a per-request `name`. This keeps the engine free of any one consumer's
/// namespace.
///
/// Comment writes update the xattr and then tell Finder (see FinderComment):
/// Finder keeps its own copy and never reads the xattr back, so without the
/// write-through Get Info would never show the change. Reading goes straight
/// off the xattr, so the engine always sees its own writes immediately.
public struct Meta {
    /// Default alias xattr name from the launch flag; nil if unset.
    public let syncName: String?

    public init(syncName: String?) {
        self.syncName = syncName
    }

    // Binder membership → kMDItemProjects (a real CFArray: Spotlight matches it
    // per element, so a file in many binders is found by `== "<one>"`). The id's
    // Spotlight-recovery copy → kMDItemInformation (string; lower content-collision
    // than Description). Logical keys name the role, not the physical attribute:
    //   groups (membership, array) · id (recovery id, string) · sync (cross-device).
    static let projectsKey = "com.apple.metadata:kMDItemProjects"
    static let informationKey = "com.apple.metadata:kMDItemInformation"
    static let commentKey = "com.apple.metadata:kMDItemFinderComment"

    private struct Resolved {
        let xattr: String
        var multi: Bool = false
        var array: Bool = false
        var plist: Bool = false   // scalar string stored as a binary plist
    }

    private func resolve(key: String, requestName: String?) throws -> Resolved {
        switch key {
        case "groups":      return Resolved(xattr: Self.projectsKey, multi: true, array: true)
        case "id":          return Resolved(xattr: Self.informationKey, multi: true)
        case "comment":     return Resolved(xattr: Self.commentKey, plist: true)
        case "sync":
            guard let name = requestName ?? syncName else {
                throw EngineError.syncNameNotConfigured
            }
            return Resolved(xattr: name)
        default:
            throw EngineError.unknownKey(key)
        }
    }

    private func arrayItems(_ xattr: String, path: String) -> [String] {
        guard let data = Xattr.getData(xattr, path: path), !data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let arr = obj as? [String] else { return [] }
        return arr
    }

    @discardableResult
    private func writeArray(_ xattr: String, _ items: [String], path: String) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: items as NSArray, format: .binary, options: 0) else { return false }
        return Xattr.setData(xattr, data: data, path: path)
    }

    private func tokens(_ xattr: String, path: String) -> [String] {
        guard let raw = Xattr.get(xattr, path: path) else { return [] }
        return raw.split { $0 == " " || $0 == "\t" || $0 == "\n" }.map(String.init)
    }

    // The Finder comment is a single string wrapped in a binary plist — not a
    // raw-UTF-8 xattr (sync) and not a CFArray (groups). Read/written here so it
    // round-trips with Finder and with Markdown backups that use the same shape.
    // Reads are NFC-normalized: Finder re-exports the xattr in decomposed form
    // (NFD) whenever it takes a comment — both via the write-through and when a
    // comment is typed in Get Info — so without normalization the same text
    // would read back byte-different and never compare equal.
    private func readPlistString(_ xattr: String, path: String) -> String? {
        guard let data = Xattr.getData(xattr, path: path), !data.isEmpty,
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let string = obj as? String else { return nil }
        return string.precomposedStringWithCanonicalMapping
    }

    @discardableResult
    private func writePlistString(_ value: String, _ xattr: String, path: String) -> Bool {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: value as NSString, format: .binary, options: 0) else { return false }
        return Xattr.setData(xattr, data: data, path: path)
    }

    // Scalar string, binary-plist encoded. Empty value clears it (an empty
    // Finder comment is no comment).
    private func setPlistString(_ value: String, mode: String, xattr: String, path: String) throws -> String {
        let current = readPlistString(xattr, path: path)
        switch mode {
        case "add", "set":
            if value.isEmpty {
                guard current != nil else { return "noop" }
                guard Xattr.remove(xattr, path: path) else { throw EngineError.writeFailed(xattr) }
                return "removed"
            }
            guard current != value else { return "noop" }
            guard writePlistString(value, xattr, path: path) else { throw EngineError.writeFailed(xattr) }
            return "set"
        case "remove":
            guard current != nil else { return "noop" }
            guard Xattr.remove(xattr, path: path) else { throw EngineError.writeFailed(xattr) }
            return "removed"
        default:
            throw EngineError.invalidMode(mode)
        }
    }

    /// Read a meta value. Multi-valued keys return `values: [...]`; the
    /// single-valued alias returns `value: "..."` (or null when absent).
    public func get(path: String, key: String, requestName: String?) throws -> Response {
        let r = try resolve(key: key, requestName: requestName)
        var resp = Response(ok: true)
        if r.plist {
            resp.value = readPlistString(r.xattr, path: path).flatMap { $0.isEmpty ? nil : $0 }
        } else if r.array {
            resp.values = arrayItems(r.xattr, path: path)
        } else if r.multi {
            resp.values = tokens(r.xattr, path: path)
        } else {
            resp.value = Xattr.get(r.xattr, path: path).flatMap { $0.isEmpty ? nil : $0 }
        }
        return resp
    }

    /// Write a meta value. For multi-valued keys: `add` appends a token
    /// idempotently, `remove` drops it (clearing the xattr when it empties),
    /// `set` replaces the whole value. For the single-valued alias: `add`/`set`
    /// write the value idempotently, `remove` deletes the xattr.
    /// Returns "added" | "removed" | "noop" | "set".
    public func set(path: String, key: String, value: String, mode: String?, requestName: String?) throws -> String {
        let r = try resolve(key: key, requestName: requestName)
        let mode = mode ?? "add"

        if r.plist {
            let action = try setPlistString(value, mode: mode, xattr: r.xattr, path: path)
            // Write through to Finder's own store — also on noop: the xattr
            // may already be current while Finder's copy is not (e.g. a
            // restore over an intact xattr).
            FinderComment.sync(path: path, comment: mode == "remove" ? "" : value)
            return action
        } else if r.array {
            var current = arrayItems(r.xattr, path: path)
            switch mode {
            case "add":
                guard !current.contains(value) else { return "noop" }
                current.append(value)
                guard writeArray(r.xattr, current, path: path) else { throw EngineError.writeFailed(r.xattr) }
                return "added"
            case "remove":
                guard current.contains(value) else { return "noop" }
                current.removeAll { $0 == value }
                if current.isEmpty {
                    guard Xattr.remove(r.xattr, path: path) else { throw EngineError.writeFailed(r.xattr) }
                } else {
                    guard writeArray(r.xattr, current, path: path) else { throw EngineError.writeFailed(r.xattr) }
                }
                return "removed"
            case "set":
                if value.isEmpty {
                    Xattr.remove(r.xattr, path: path)
                } else {
                    guard writeArray(r.xattr, [value], path: path) else { throw EngineError.writeFailed(r.xattr) }
                }
                return "set"
            default:
                throw EngineError.invalidMode(mode)
            }
        } else if r.multi {
            var current = tokens(r.xattr, path: path)
            switch mode {
            case "add":
                guard !current.contains(value) else { return "noop" }
                current.append(value)
                guard Xattr.set(r.xattr, value: current.joined(separator: " "), path: path) else {
                    throw EngineError.writeFailed(r.xattr)
                }
                return "added"
            case "remove":
                guard current.contains(value) else { return "noop" }
                current.removeAll { $0 == value }
                if current.isEmpty {
                    guard Xattr.remove(r.xattr, path: path) else { throw EngineError.writeFailed(r.xattr) }
                } else {
                    guard Xattr.set(r.xattr, value: current.joined(separator: " "), path: path) else {
                        throw EngineError.writeFailed(r.xattr)
                    }
                }
                return "removed"
            case "set":
                if value.isEmpty {
                    Xattr.remove(r.xattr, path: path)
                } else {
                    guard Xattr.set(r.xattr, value: value, path: path) else { throw EngineError.writeFailed(r.xattr) }
                }
                return "set"
            default:
                throw EngineError.invalidMode(mode)
            }
        } else {
            let current = Xattr.get(r.xattr, path: path)
            switch mode {
            case "add", "set":
                guard current != value else { return "noop" }
                guard Xattr.set(r.xattr, value: value, path: path) else { throw EngineError.writeFailed(r.xattr) }
                return "set"
            case "remove":
                guard current != nil else { return "noop" }
                guard Xattr.remove(r.xattr, path: path) else { throw EngineError.writeFailed(r.xattr) }
                return "removed"
            default:
                throw EngineError.invalidMode(mode)
            }
        }
    }
}
