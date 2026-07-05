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

func parseSyncName(_ args: [String]) -> String? {
    var iterator = args.dropFirst().makeIterator()
    while let arg = iterator.next() {
        if arg == "--sync-name" {
            return iterator.next()
        } else if arg.hasPrefix("--sync-name=") {
            return String(arg.dropFirst("--sync-name=".count))
        }
    }
    return nil
}

let engine = Engine(syncName: parseSyncName(CommandLine.arguments))

// Read → handle → write, line by line. Flush after every response so a consumer
// holding a persistent pipe (one engine subprocess for the whole run, request/
// response interleaved) never deadlocks waiting on a block-buffered stdout.
while let line = readLine(strippingNewline: true) {
    print(engine.handle(line: line))
    fflush(stdout)
}
