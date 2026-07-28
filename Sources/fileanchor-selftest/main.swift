import Foundation
import FileAnchorKit

// A framework-free check harness — the former XCTest suite, one assertion for
// one check. See Package.swift for why this is not a `.testTarget`. Exits
// non-zero when anything fails, so it gates a commit like a test run would.
//
// The checks run against the real filesystem in a temp dir: genuine round-trips
// through Foundation/CoreServices, the only way to verify the hard-won facts
// (★ codepoint, umlaut tag, underscore key, #S naming) actually hold.

// Comment writes would otherwise send Apple Events to Finder — slow, and a TCC
// automation prompt on a fresh machine.
FinderComment.isEnabled = false

let syncName = "com.fileregister.id#S"

var checksRun = 0
var failures: [String] = []
var scratchDirs: [URL] = []

/// An unexpected throw counts as a failure rather than killing the run, so one
/// broken op cannot hide the checks behind it.
func check(_ label: String, _ condition: @autoclosure () throws -> Bool) {
    checksRun += 1
    do {
        if try !condition() { failures.append(label) }
    } catch {
        failures.append("\(label) — threw: \(error)")
    }
}

func section(_ title: String) {
    print("\n\(title)")
}

func didThrow(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

/// A fresh file in its own temp dir — the old setUp/tearDown pair. Every group
/// of checks starts on untouched xattrs.
func freshFile() -> String {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fileanchor-selftest-\(UUID().uuidString)")
    let file = dir.appendingPathComponent("sample.txt")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
    } catch {
        print("no scratch dir, nothing can be checked: \(error)")
        exit(1)
    }
    scratchDirs.append(dir)
    return file.path
}

func engine() -> Engine { Engine(syncName: syncName) }

// MARK: - Bookmarks

section("Bookmarks")

let bookmarkFile = freshFile()
let blob = (try? Bookmarks.save(path: bookmarkFile)) ?? ""

check("save yields a blob", !blob.isEmpty)

check("resolve returns the file it was saved from",
      Bookmarks.resolve(blob: blob).map {
          URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
      } == URL(fileURLWithPath: bookmarkFile).resolvingSymlinksInPath().path)

check("an empty blob is a negative, not a crash", Bookmarks.resolve(blob: "") == nil)
check("a malformed blob is a negative too", Bookmarks.resolve(blob: "not-base64-!!!") == nil)

// MARK: - Tags, including the ★ marker and an umlaut

section("Tags")

let tagFile = freshFile()

check("★ is added", try Tags.add(path: tagFile, value: "★") == "added")
check("adding ★ again is a noop", try Tags.add(path: tagFile, value: "★") == "noop")
check("an umlaut tag is added", try Tags.add(path: tagFile, value: "Geschäft") == "added")
check("★ reads back", try Tags.get(path: tagFile).contains("★"))
check("the umlaut tag reads back", try Tags.get(path: tagFile).contains("Geschäft"))
check("★ is removed", try Tags.remove(path: tagFile, value: "★") == "removed")
check("removing ★ again is a noop", try Tags.remove(path: tagFile, value: "★") == "noop")
check("★ is gone afterwards", try !Tags.get(path: tagFile).contains("★"))

// MARK: - Meta: groups is a real array

section("Meta · groups")

let groupsFile = freshFile()
let groupsMeta = Meta(syncName: syncName)

check("alpha is added",
      try groupsMeta.set(path: groupsFile, key: "groups", value: "alpha", mode: "add", requestName: nil) == "added")
check("beta is added",
      try groupsMeta.set(path: groupsFile, key: "groups", value: "beta", mode: "add", requestName: nil) == "added")
check("adding alpha again is a noop",
      try groupsMeta.set(path: groupsFile, key: "groups", value: "alpha", mode: "add", requestName: nil) == "noop")
check("both groups read back in order",
      try groupsMeta.get(path: groupsFile, key: "groups", requestName: nil).values == ["alpha", "beta"])
check("alpha is removed",
      try groupsMeta.set(path: groupsFile, key: "groups", value: "alpha", mode: "remove", requestName: nil) == "removed")
check("beta survives the removal",
      try groupsMeta.get(path: groupsFile, key: "groups", requestName: nil).values == ["beta"])

// MARK: - Meta: id is space-separated multi-valued

section("Meta · id")

let idFile = freshFile()
let idMeta = Meta(syncName: syncName)

check("the first id is added",
      try idMeta.set(path: idFile, key: "id", value: "123", mode: "add", requestName: nil) == "added")
check("a second id joins it",
      try idMeta.set(path: idFile, key: "id", value: "456", mode: "add", requestName: nil) == "added")
check("both ids read back",
      try idMeta.get(path: idFile, key: "id", requestName: nil).values == ["123", "456"])

// MARK: - Meta: sync is single-valued, under the #S name

section("Meta · sync")

let syncFile = freshFile()
let syncMeta = Meta(syncName: syncName)

check("the sync id is written",
      try syncMeta.set(path: syncFile, key: "sync", value: "789", mode: "set", requestName: nil) == "set")
check("writing the same value again is a noop",
      try syncMeta.set(path: syncFile, key: "sync", value: "789", mode: "set", requestName: nil) == "noop")
check("it reads back",
      try syncMeta.get(path: syncFile, key: "sync", requestName: nil).value == "789")
check("a new value replaces it rather than appending",
      try syncMeta.set(path: syncFile, key: "sync", value: "999", mode: "set", requestName: nil) == "set")
check("the replacement reads back",
      try syncMeta.get(path: syncFile, key: "sync", requestName: nil).value == "999")

// The #S is part of the stored name: reading the base name must miss it.
check("the value sits under the #S name",
      Xattr.get("com.fileregister.id#S", path: syncFile) != nil)
check("and not under the base name",
      Xattr.get("com.fileregister.id", path: syncFile) == nil)

check("sync without a configured name is refused",
      didThrow { _ = try Meta(syncName: nil).set(path: syncFile, key: "sync", value: "1", mode: "set", requestName: nil) })
check("a per-request name satisfies it without a launch flag",
      try Meta(syncName: nil).set(path: syncFile, key: "sync", value: "1", mode: "set",
                                  requestName: "com.example.sync#S") == "set")

// MARK: - Meta: the comment is a binary-plist-wrapped string

section("Meta · comment")

let commentFile = freshFile()
let commentMeta = Meta(syncName: syncName)
let comment = "Original im Schließfach"

check("a fresh file has no comment",
      try commentMeta.get(path: commentFile, key: "comment", requestName: nil).value == nil)
check("the comment is written",
      try commentMeta.set(path: commentFile, key: "comment", value: comment, mode: "set", requestName: nil) == "set")
check("writing it again is a noop",
      try commentMeta.set(path: commentFile, key: "comment", value: comment, mode: "set", requestName: nil) == "noop")
check("it reads back",
      try commentMeta.get(path: commentFile, key: "comment", requestName: nil).value == comment)

// Stored under the Finder comment key as a binary-plist string, so the raw
// bytes decode back to the same string (the Finder/backup shape).
check("the raw bytes are the shape Finder and backups use", {
    guard let data = Xattr.getData("com.apple.metadata:kMDItemFinderComment", path: commentFile),
          let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    else { return false }
    return (object as? String) == comment
}())

check("an empty value clears it",
      try commentMeta.set(path: commentFile, key: "comment", value: "", mode: "set", requestName: nil) == "removed")
check("a cleared comment reads back as nothing",
      try commentMeta.get(path: commentFile, key: "comment", requestName: nil).value == nil)

// MARK: - Protocol-level dispatch

section("Wire protocol")

let wireFile = freshFile()

let unknownOp = engine().handle(line: #"{"op":"frobnicate"}"#)
check("an unknown op is a soft error", unknownOp.contains("\"ok\":false"))
check("and says so", unknownOp.contains("unknown op"))

check("invalid json is a soft error too",
      engine().handle(line: "{not json").contains("\"ok\":false"))

let saveOut = engine().handle(line: #"{"op":"save","path":"\#(wireFile)"}"#)
check("save over the wire succeeds", saveOut.contains("\"ok\":true"))

struct BlobLine: Decodable { let blob: String? }
let wireBlob = (try? JSONDecoder().decode(BlobLine.self, from: Data(saveOut.utf8)))?.blob ?? ""
let resolveOut = engine().handle(line: #"{"op":"resolve","blob":"\#(wireBlob)"}"#)

check("the blob resolves back over the wire", resolveOut.contains("\"ok\":true"))
check("and names the file it came from", resolveOut.contains("sample.txt"))

// MARK: - Verdict

for dir in scratchDirs { try? FileManager.default.removeItem(at: dir) }

print("")
print(String(repeating: "=", count: 60))
if failures.isEmpty {
    print("\(checksRun) checks, all passed")
} else {
    print("\(checksRun) checks, \(failures.count) failed:")
    for failure in failures { print("  ✗ \(failure)") }
    exit(1)
}
