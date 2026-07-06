// XCTest ships with Xcode, not the bare Command Line Tools. Guarding the whole
// file lets `swift test` pass (0 tests) on a CLT-only machine while running the
// full suite under Xcode/CI. Local verification of the live wire protocol is
// done by scripts/smoke.py against the built binary.
#if canImport(XCTest)
import XCTest
@testable import FileAnchorKit

/// Exercises the engine against the real filesystem in a temp dir — these are
/// genuine round-trips through Foundation/CoreServices, the only way to verify
/// the verified-facts (★ codepoint, underscore key, #S naming) actually hold.
final class EngineTests: XCTestCase {
    var dir: URL!
    var file: String!
    let syncName = "com.fileregister.id#S"

    override func setUpWithError() throws {
        // Comment writes would otherwise send Apple Events to Finder — slow,
        // and a TCC automation prompt on a fresh test runner.
        FinderComment.isEnabled = false
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fileanchor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("sample.txt")
        try "hello".write(to: f, atomically: true, encoding: .utf8)
        file = f.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func engine() -> Engine { Engine(syncName: syncName) }

    // MARK: bookmarks

    func testBookmarkSaveResolveRoundTrip() throws {
        let blob = try Bookmarks.save(path: file)
        XCTAssertFalse(blob.isEmpty)
        let resolved = try XCTUnwrap(Bookmarks.resolve(blob: blob))
        XCTAssertEqual(URL(fileURLWithPath: resolved.path).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: file).resolvingSymlinksInPath().path)
    }

    func testResolveEmptyBlobIsNegativeNotCrash() {
        XCTAssertNil(Bookmarks.resolve(blob: ""))
        XCTAssertNil(Bookmarks.resolve(blob: "not-base64-!!!"))
    }

    // MARK: tags — including the ★ marker and an umlaut tag

    func testTagRoundTripStarAndUmlaut() throws {
        XCTAssertEqual(try Tags.add(path: file, value: "★"), "added")
        XCTAssertEqual(try Tags.add(path: file, value: "★"), "noop")
        XCTAssertEqual(try Tags.add(path: file, value: "Geschäft"), "added")

        let tags = try Tags.get(path: file)
        XCTAssertTrue(tags.contains("★"))
        XCTAssertTrue(tags.contains("Geschäft"))

        XCTAssertEqual(try Tags.remove(path: file, value: "★"), "removed")
        XCTAssertEqual(try Tags.remove(path: file, value: "★"), "noop")
        XCTAssertFalse(try Tags.get(path: file).contains("★"))
    }

    // MARK: meta — groups (array), id (multi), sync (#S, single)

    func testGroupsArray() throws {
        let m = Meta(syncName: syncName)
        XCTAssertEqual(try m.set(path: file, key: "groups", value: "alpha", mode: "add", requestName: nil), "added")
        XCTAssertEqual(try m.set(path: file, key: "groups", value: "beta", mode: "add", requestName: nil), "added")
        XCTAssertEqual(try m.set(path: file, key: "groups", value: "alpha", mode: "add", requestName: nil), "noop")
        XCTAssertEqual(try m.get(path: file, key: "groups", requestName: nil).values, ["alpha", "beta"])

        XCTAssertEqual(try m.set(path: file, key: "groups", value: "alpha", mode: "remove", requestName: nil), "removed")
        XCTAssertEqual(try m.get(path: file, key: "groups", requestName: nil).values, ["beta"])
    }

    func testIdMultiValue() throws {
        let m = Meta(syncName: syncName)
        XCTAssertEqual(try m.set(path: file, key: "id", value: "123", mode: "add", requestName: nil), "added")
        XCTAssertEqual(try m.set(path: file, key: "id", value: "456", mode: "add", requestName: nil), "added")
        XCTAssertEqual(try m.get(path: file, key: "id", requestName: nil).values, ["123", "456"])
    }

    func testSyncSyncableNameRoundTrip() throws {
        let m = Meta(syncName: syncName)
        XCTAssertEqual(try m.set(path: file, key: "sync", value: "789", mode: "set", requestName: nil), "set")
        XCTAssertEqual(try m.set(path: file, key: "sync", value: "789", mode: "set", requestName: nil), "noop")
        XCTAssertEqual(try m.get(path: file, key: "sync", requestName: nil).value, "789")

        // Overwrite with a new value (single-valued: replaces, not appends).
        XCTAssertEqual(try m.set(path: file, key: "sync", value: "999", mode: "set", requestName: nil), "set")
        XCTAssertEqual(try m.get(path: file, key: "sync", requestName: nil).value, "999")

        // The #S is part of the stored name: reading the base name must miss it.
        XCTAssertNotNil(Xattr.get("com.fileregister.id#S", path: file))
        XCTAssertNil(Xattr.get("com.fileregister.id", path: file))
    }

    func testCommentBinaryPlistRoundTrip() throws {
        let m = Meta(syncName: syncName)
        XCTAssertNil(try m.get(path: file, key: "comment", requestName: nil).value)
        XCTAssertEqual(try m.set(path: file, key: "comment", value: "Original im Schließfach", mode: "set", requestName: nil), "set")
        XCTAssertEqual(try m.set(path: file, key: "comment", value: "Original im Schließfach", mode: "set", requestName: nil), "noop")
        XCTAssertEqual(try m.get(path: file, key: "comment", requestName: nil).value, "Original im Schließfach")

        // Stored as a binary-plist string under the Finder comment key, so the
        // raw bytes decode back to the same string (the Finder/backup shape).
        let data = Xattr.getData("com.apple.metadata:kMDItemFinderComment", path: file)
        let decoded = try XCTUnwrap(data).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? String
        }
        XCTAssertEqual(decoded, "Original im Schließfach")

        // Empty value clears it; cleared comment reads back as nil.
        XCTAssertEqual(try m.set(path: file, key: "comment", value: "", mode: "set", requestName: nil), "removed")
        XCTAssertNil(try m.get(path: file, key: "comment", requestName: nil).value)
    }

    func testSyncRequiresConfiguredName() {
        let m = Meta(syncName: nil)
        XCTAssertThrowsError(try m.set(path: file, key: "sync", value: "1", mode: "set", requestName: nil))
        // A per-request name satisfies it without a launch flag.
        XCTAssertNoThrow(try m.set(path: file, key: "sync", value: "1", mode: "set", requestName: "com.example.sync#S"))
    }

    // MARK: protocol-level dispatch

    func testHandleUnknownOpIsSoftError() {
        let out = engine().handle(line: #"{"op":"frobnicate"}"#)
        XCTAssertTrue(out.contains("\"ok\":false"))
        XCTAssertTrue(out.contains("unknown op"))
    }

    func testHandleInvalidJsonIsSoftError() {
        let out = engine().handle(line: "{not json")
        XCTAssertTrue(out.contains("\"ok\":false"))
    }

    func testHandleSaveThenResolveViaWire() {
        let saveOut = engine().handle(line: #"{"op":"save","path":"\#(file!)"}"#)
        XCTAssertTrue(saveOut.contains("\"ok\":true"))
        // pull the blob back out and resolve it through the wire
        struct R: Decodable { let blob: String? }
        let blob = (try? JSONDecoder().decode(R.self, from: saveOut.data(using: .utf8)!))?.blob
        let resolveOut = engine().handle(line: #"{"op":"resolve","blob":"\#(blob!)"}"#)
        XCTAssertTrue(resolveOut.contains("\"ok\":true"))
        XCTAssertTrue(resolveOut.contains("sample.txt"))
    }
}
#endif
