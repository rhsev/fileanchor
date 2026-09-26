import Foundation
import FileAnchorKit

// fileanchor — a batch stdio metadata engine. One JSON request object per
// stdin line, one JSON response object per stdout line, in input order. The
// process handles a batch then exits; it is not a daemon.
//
// Usage:
//   fileanchor [--sync-name <xattr-name>]
//
// --sync-name sets the default xattr name for the single-valued cross-device
// `sync` key (e.g. com.fileregister.id#S). A per-request "name" field
// overrides it. groups/id/comment map to fixed Apple keys and need no flag.

// Anything else on the command line is refused at startup: a typo like
// --sync_name would otherwise pass silently and only surface later, as a
// confusing "no sync name set" on the first sync op.
func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fileanchor: \(message)\nusage: fileanchor [--sync-name <xattr-name>]\n".utf8))
    exit(2)
}

func parseSyncName(_ args: [String]) -> String? {
    var syncName: String?
    var iterator = args.dropFirst().makeIterator()
    while let arg = iterator.next() {
        if arg == "--sync-name" {
            guard let value = iterator.next() else { usageError("--sync-name needs a value") }
            syncName = value
        } else if arg.hasPrefix("--sync-name=") {
            syncName = String(arg.dropFirst("--sync-name=".count))
        } else {
            usageError("unknown argument: \(arg)")
        }
    }
    return syncName
}

let engine = Engine(syncName: parseSyncName(CommandLine.arguments))

// Read → handle → write, line by line. Flush after every response so a consumer
// holding a persistent pipe (one engine subprocess for the whole run, request/
// response interleaved) never deadlocks waiting on a block-buffered stdout.
while let line = readLine(strippingNewline: true) {
    print(engine.handle(line: line))
    fflush(stdout)
}
