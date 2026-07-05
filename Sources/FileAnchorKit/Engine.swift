import Foundation

/// Dispatches one decoded `Request` to the right metadata operation and shapes
/// the `Response`. Pure and synchronous — the stdio loop lives in the
/// executable; this is what the tests drive directly.
public struct Engine {
    private let meta: Meta

    public init(syncName: String?) {
        self.meta = Meta(syncName: syncName)
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Compact, one object per line; keep slashes raw so paths read cleanly.
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// Handle one raw input line, returning one JSON response line (no newline).
    /// Never throws: protocol/op failures become `{"ok":false,"error":...}` so a
    /// bad line never halts the batch.
    public func handle(line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return encode(.failure("empty input line")) }
        guard let data = trimmed.data(using: .utf8),
              let request = try? JSONDecoder().decode(Request.self, from: data) else {
            return encode(.failure("invalid request json"))
        }
        do {
            return encode(try dispatch(request))
        } catch let error as EngineError {
            return encode(.failure(error.description))
        } catch {
            return encode(.failure(String(describing: error)))
        }
    }

    private func dispatch(_ req: Request) throws -> Response {
        switch req.op {
        case "save":
            let path = try require(req.path, "path")
            var r = Response(ok: true)
            r.blob = try Bookmarks.save(path: path)
            return r

        case "resolve":
            // Unresolvable / empty blob is a valid negative, not a hard error.
            guard let resolved = Bookmarks.resolve(blob: req.blob ?? "") else {
                return .failure("unresolvable")
            }
            var r = Response(ok: true)
            r.path = resolved.path
            if resolved.stale { r.stale = true }
            return r

        case "tag":
            let path = try require(req.path, "path")
            let value = try require(req.value, "value")
            var r = Response(ok: true)
            r.action = try Tags.add(path: path, value: value)
            return r

        case "untag":
            let path = try require(req.path, "path")
            let value = try require(req.value, "value")
            var r = Response(ok: true)
            r.action = try Tags.remove(path: path, value: value)
            return r

        case "tags":
            let path = try require(req.path, "path")
            var r = Response(ok: true)
            r.tags = try Tags.get(path: path)
            return r

        case "set_meta":
            let path = try require(req.path, "path")
            let key = try require(req.key, "key")
            let value = try require(req.value, "value")
            var r = Response(ok: true)
            r.action = try meta.set(path: path, key: key, value: value, mode: req.mode, requestName: req.name)
            return r

        case "get_meta":
            let path = try require(req.path, "path")
            let key = try require(req.key, "key")
            return try meta.get(path: path, key: key, requestName: req.name)

        case "query":
            let byRaw = try require(req.by, "by")
            guard let selector = Query.Selector(rawValue: byRaw) else {
                throw EngineError.unknownBy(byRaw)
            }
            let value = try require(req.value, "value")
            var r = Response(ok: true)
            r.paths = Query.run(selector: selector, value: value)
            return r

        default:
            throw EngineError.unknownOp(req.op)
        }
    }

    private func require(_ field: String?, _ name: String) throws -> String {
        guard let field else { throw EngineError.missingField(name) }
        return field
    }

    private func encode(_ response: Response) -> String {
        guard let data = try? encoder.encode(response),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"response encoding failed\"}"
        }
        return json
    }
}
