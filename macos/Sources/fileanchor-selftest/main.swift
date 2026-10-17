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

// A moved file still resolves; a deleted one does not, but its blob still
// tells where it was.
let movedFile = freshFile()
let movedBlob = (try? Bookmarks.save(path: movedFile)) ?? ""
let movedTo = URL(fileURLWithPath: movedFile).deletingLastPathComponent().appendingPathComponent("moved.txt").path
try? FileManager.default.moveItem(atPath: movedFile, toPath: movedTo)
check("a moved file resolves to its new place",
      Bookmarks.resolve(blob: movedBlob).map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
          == URL(fileURLWithPath: movedTo).resolvingSymlinksInPath().path)
try? FileManager.default.removeItem(atPath: movedTo)
check("a deleted file does not resolve", Bookmarks.resolve(blob: movedBlob) == nil)
check("but its blob still names the path it recorded",
      Bookmarks.recordedPath(blob: movedBlob).map { URL(fileURLWithPath: $0).lastPathComponent } == "sample.txt")
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

// A tag stored decomposed (NFD) — by another tool; the engine itself writes
// NFC — reads back precomposed, byte for byte.
let tagsKey = "com.apple.metadata:_kMDItemUserTags"
func writeRawPlist(_ items: [String], _ key: String, _ path: String) {
    if let data = try? PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0) {
        Xattr.setData(key, data: data, path: path)
    }
}
let nfdTagFile = freshFile()
writeRawPlist(["Geschäft".decomposedStringWithCanonicalMapping], tagsKey, nfdTagFile)
check("an NFD tag reads back as NFC bytes",
      (try? Tags.get(path: nfdTagFile))?.map { Array($0.utf8) } == [Array("Geschäft".precomposedStringWithCanonicalMapping.utf8)])
check("and removing it by its NFC form works",
      try Tags.remove(path: nfdTagFile, value: "Geschäft") == "removed")

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
// Spotlight parses com.apple.metadata attributes as property lists; a raw
// "123 456" is none and was not indexed at all.
check("the ids are stored as a binary plist string",
      Xattr.getData("com.apple.metadata:kMDItemInformation", path: idFile)
          .map { $0.starts(with: Array("bplist".utf8)) } == true)

// An id written raw by an earlier version (a single token is an old-style
// plist string) still reads, and the next write stores it as a plist.
let legacyIDFile = freshFile()
Xattr.set("com.apple.metadata:kMDItemInformation", value: "987654321", path: legacyIDFile)
check("a raw single id from before still reads",
      try idMeta.get(path: legacyIDFile, key: "id", requestName: nil).values == ["987654321"])
check("and a second id joins it",
      try idMeta.set(path: legacyIDFile, key: "id", value: "111", mode: "add", requestName: nil) == "added"
          && (try idMeta.get(path: legacyIDFile, key: "id", requestName: nil).values) == ["987654321", "111"])

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

// MARK: - Meta: an empty set deletes, on every key

section("Meta · empty set")

let clearFile = freshFile()
let clearMeta = Meta(syncName: syncName)

for key in ["groups", "id", "sync"] {
    _ = try? clearMeta.set(path: clearFile, key: key, value: "x", mode: "set", requestName: nil)
    check("\(key): an empty set removes it",
          try clearMeta.set(path: clearFile, key: key, value: "", mode: "set", requestName: nil) == "removed")
    check("\(key): and again is a noop",
          try clearMeta.set(path: clearFile, key: key, value: "", mode: "set", requestName: nil) == "noop")
}
check("no empty #S attribute is left behind", Xattr.get(syncName, path: clearFile) == nil)

// An empty attribute written by an earlier version still counts as present.
Xattr.set(syncName, value: "", path: clearFile)
check("a leftover empty sync attribute is cleaned up",
      try clearMeta.set(path: clearFile, key: "sync", value: "", mode: "set", requestName: nil) == "removed")

check("groups: setting the current value is a noop", try {
    _ = try clearMeta.set(path: clearFile, key: "groups", value: "alpha", mode: "set", requestName: nil)
    return try clearMeta.set(path: clearFile, key: "groups", value: "alpha", mode: "set", requestName: nil) == "noop"
}())

// MARK: - Meta: an id token holds no whitespace

section("Meta · id tokens")

let tokenFile = freshFile()
let tokenMeta = Meta(syncName: syncName)

check("adding a token with a space is refused",
      didThrow { _ = try tokenMeta.set(path: tokenFile, key: "id", value: "a b", mode: "add", requestName: nil) })
check("removing one is refused too",
      didThrow { _ = try tokenMeta.set(path: tokenFile, key: "id", value: "a b", mode: "remove", requestName: nil) })
check("set takes a space-separated list",
      try tokenMeta.set(path: tokenFile, key: "id", value: "a  b", mode: "set", requestName: nil) == "set")
check("which reads back as its tokens",
      try tokenMeta.get(path: tokenFile, key: "id", requestName: nil).values == ["a", "b"])
check("setting the same list again is a noop",
      try tokenMeta.set(path: tokenFile, key: "id", value: "a b", mode: "set", requestName: nil) == "noop")

// MARK: - Values: strict on write, tolerant on removal

section("Values")

let valueFile = freshFile()
let valueMeta = Meta(syncName: syncName)
func refused(_ body: @escaping () throws -> Void) -> Bool { didThrow(body) }

check("a tag with a comma is refused", refused { _ = try Tags.add(path: valueFile, value: "Müller, Hans") })
check("a tag with trailing whitespace is refused", refused { _ = try Tags.add(path: valueFile, value: "work ") })
check("a tag with a newline is refused", refused { _ = try Tags.add(path: valueFile, value: "a\nb") })
check("an empty tag is refused", refused { _ = try Tags.add(path: valueFile, value: "") })
check("a 255-byte tag is fine", try Tags.add(path: valueFile, value: String(repeating: "t", count: 255)) == "added")
check("a 256-byte tag is refused", refused { _ = try Tags.add(path: valueFile, value: String(repeating: "t", count: 256)) })
check("inner spaces and colons are fine in a tag", try Tags.add(path: valueFile, value: "rules:Mail Mate") == "added")
check("an NFD tag is stored NFC", {
    _ = try? Tags.add(path: valueFile, value: "Übersicht".decomposedStringWithCanonicalMapping)
    guard let data = Xattr.getData(tagsKey, path: valueFile),
          let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
    else { return false }
    // An entry is "name" or "name\n<color>"; compare the name part.
    return list.contains {
        Array($0.split(separator: "\n", omittingEmptySubsequences: false)[0].utf8)
            == Array("Übersicht".precomposedStringWithCanonicalMapping.utf8)
    }
}())

check("a group with a comma is refused",
      refused { _ = try valueMeta.set(path: valueFile, key: "groups", value: "a,b", mode: "add", requestName: nil) })
check("a sync id with a space is refused",
      refused { _ = try valueMeta.set(path: valueFile, key: "sync", value: "1 2", mode: "set", requestName: nil) })
check("a sync id of 129 bytes is refused",
      refused { _ = try valueMeta.set(path: valueFile, key: "sync", value: String(repeating: "9", count: 129), mode: "set", requestName: nil) })
check("an id list with a comma token is refused",
      refused { _ = try valueMeta.set(path: valueFile, key: "id", value: "1 2,3", mode: "set", requestName: nil) })
check("a comment may hold a newline",
      try valueMeta.set(path: valueFile, key: "comment", value: "Rechnung\n", mode: "set", requestName: nil) == "set")
check("but not a bell",
      refused { _ = try valueMeta.set(path: valueFile, key: "comment", value: "a\u{07}b", mode: "set", requestName: nil) })
check("a comment over 1 KiB is refused",
      refused { _ = try valueMeta.set(path: valueFile, key: "comment", value: String(repeating: "c", count: 1025), mode: "set", requestName: nil) })

// Tag colors survive: an entry is "name\n<color index>", and adding or
// removing another tag must leave it byte for byte.
let colorFile = freshFile()
writeRawPlist(["Rot\n6", "Eigen\n3"], tagsKey, colorFile)
func storedTags(_ path: String) -> [String] {
    guard let data = Xattr.getData(tagsKey, path: path) else { return [] }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]) ?? []
}
check("adding a tag keeps the others' colors",
      (try? Tags.add(path: colorFile, value: "Neu")) == "added"
          && storedTags(colorFile) == ["Rot\n6", "Eigen\n3", "Neu"])
check("removing a tag keeps the others' colors",
      (try? Tags.remove(path: colorFile, value: "Neu")) == "removed"
          && storedTags(colorFile) == ["Rot\n6", "Eigen\n3"])
check("a colored tag is found by its name",
      (try? Tags.add(path: colorFile, value: "Rot")) == "noop")
check("and removed by it",
      (try? Tags.remove(path: colorFile, value: "Rot")) == "removed" && storedTags(colorFile) == ["Eigen\n3"])
check("tags reads the names without colors", (try? Tags.get(path: colorFile)) == ["Eigen"])

// Values written by other tools stay removable.
let legacyFile = freshFile()
writeRawPlist(["a,b"], tagsKey, legacyFile)
writeRawPlist(["x, y"], "com.apple.metadata:kMDItemProjects", legacyFile)
check("a legacy comma tag can be removed", try Tags.remove(path: legacyFile, value: "a,b") == "removed")
check("a legacy comma group can be removed",
      try valueMeta.set(path: legacyFile, key: "groups", value: "x, y", mode: "remove", requestName: nil) == "removed")

// MARK: - Query: an id matches whole tokens only

section("Query · id")

// Spotlight is not reachable in a temp dir (not indexed), so this drives the
// filter the query applies to Spotlight's substring hits.
let shortIDFile = freshFile()
let longIDFile = freshFile()
_ = try? Meta(syncName: nil).set(path: shortIDFile, key: "id", value: "rechnung-1", mode: "add", requestName: nil)
_ = try? Meta(syncName: nil).set(path: longIDFile, key: "id", value: "rechnung-10", mode: "add", requestName: nil)

check("rechnung-1 does not match the file carrying rechnung-10",
      Query.keepingWholeToken("rechnung-1", in: [shortIDFile, longIDFile]) == [shortIDFile])
check("rechnung-10 still finds its own file",
      Query.keepingWholeToken("rechnung-10", in: [shortIDFile, longIDFile]) == [longIDFile])

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

let missing = URL(fileURLWithPath: wireFile).deletingLastPathComponent().appendingPathComponent("gone.txt").path
for line in [#"{"op":"get_meta","path":"\#(missing)","key":"groups"}"#,
             #"{"op":"set_meta","path":"\#(missing)","key":"id","value":"","mode":"set"}"#,
             #"{"op":"tags","path":"\#(missing)"}"#] {
    let out = engine().handle(line: line)
    check("a missing file is an error, not empty metadata: \(line.prefix(22))…",
          out.contains("\"ok\":false") && out.contains("no such file"))
}

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
