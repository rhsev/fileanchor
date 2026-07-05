import Foundation
import CoreServices

/// Spotlight lookup via the synchronous `MDQuery` C API — no NSMetadataQuery
/// runloop to spin. The op is the *recovery* path (a consumer's own index
/// answers most enumeration); it mirrors the four lookups fileregister's repair
/// flow needs, but stays OS-neutral on the wire by naming the *selector*
/// (`tag`/`subject`/`id`/`filename`), not the Spotlight key. The macOS mapping
/// from selector to `kMDItem*` key lives here; a Linux backend would map the
/// same selectors to its own index.
///
/// Note the verified asymmetry: tags are *written* under `_kMDItemUserTags` but
/// *queried* under `kMDItemUserTags` (no underscore) — handled below.
public enum Query {
    public enum Selector: String {
        case tag        // Finder tag (★ marker or binder tag)
        case groups     // binder membership (kMDItemProjects)
        case id         // recovery id token (kMDItemInformation, substring)
        case filename   // exact on-disk basename

        func expression(for value: String) -> String {
            let v = Query.escape(value)
            switch self {
            case .tag:      return "kMDItemUserTags == \"\(v)\""
            case .groups:   return "kMDItemProjects == \"\(v)\""
            case .id:       return "kMDItemInformation == \"*\(v)*\""
            case .filename: return "kMDItemFSName == \"\(v)\""
            }
        }
    }

    /// Escape a value for embedding in a double-quoted MDQuery string.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Run a synchronous Spotlight query, returning absolute paths in no
    /// particular order. Empty on no match or query-construction failure.
    public static func run(selector: Selector, value: String) -> [String] {
        let expression = selector.expression(for: value)
        guard let query = MDQueryCreate(kCFAllocatorDefault, expression as CFString, nil, nil) else {
            return []
        }
        let flags = CFOptionFlags(kMDQuerySynchronous.rawValue)
        guard MDQueryExecute(query, flags) else { return [] }

        let count = MDQueryGetResultCount(query)
        var paths: [String] = []
        paths.reserveCapacity(count)
        for i in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                paths.append(path)
            }
        }
        return paths
    }
}
