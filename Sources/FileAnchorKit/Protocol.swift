import Foundation

// The wire protocol: one JSON object per line in, one per line out, in input
// order. The shapes here are deliberately OS-neutral — no `kMDItem*` names, no
// `#S`, no Spotlight syntax leak onto the wire. Operations name *intent*
// (`save`, `tag`, `query by:tag`); the macOS mechanism lives behind them in the
// engine, so a future Linux implementation can honor the same contract.

/// A single request line. Fields are op-specific; unknown fields are ignored,
/// absent fields decode to nil and are validated per-op by the engine.
public struct Request: Decodable {
    public let op: String

    public let path: String?
    public let blob: String?
    public let value: String?
    public let key: String?     // set_meta/get_meta: groups | id | sync | comment
    public let mode: String?    // set_meta: add | remove | set
    public let by: String?      // query: tag | subject | id | filename
    public let name: String?    // optional per-request override of the alias xattr name
}

/// A single response line. Only the fields relevant to the op are populated;
/// nil fields are omitted by the encoder, keeping lines lean.
public struct Response: Encodable {
    public var ok: Bool
    public var error: String?
    public var blob: String?
    public var path: String?
    public var action: String?      // added | removed | noop | set
    public var tags: [String]?
    public var value: String?       // get_meta single-valued (alias)
    public var values: [String]?    // get_meta multi-valued (subject/description)
    public var paths: [String]?     // query results
    public var stale: Bool?         // resolve: blob is stale, caller should re-save

    public init(ok: Bool) { self.ok = ok }

    public static func failure(_ message: String) -> Response {
        var r = Response(ok: false)
        r.error = message
        return r
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case missingField(String)
    case unknownOp(String)
    case unknownKey(String)
    case unknownBy(String)
    case invalidMode(String)
    case syncNameNotConfigured
    case writeFailed(String)

    public var description: String {
        switch self {
        case .missingField(let f):   return "missing required field: \(f)"
        case .unknownOp(let o):      return "unknown op: \(o)"
        case .unknownKey(let k):     return "unknown meta key: \(k) (expected groups|id|sync|comment)"
        case .unknownBy(let b):      return "unknown query selector: \(b) (expected tag|groups|id|filename)"
        case .invalidMode(let m):    return "invalid mode: \(m) (expected add|remove|set)"
        case .syncNameNotConfigured:
            return "sync key used but no sync name set (pass --sync-name or a per-request \"name\")"
        case .writeFailed(let what):  return "write failed: \(what)"
        }
    }
}
