import Foundation

/// Whether `query` would find a file under a path if one were there. On macOS
/// that is whether Spotlight indexes the volume the path lies on.
///
/// A consumer asks this before it reads "no file carries this id" as a fact:
/// fileregister calls a bookmark dead only then, and dead is the verdict an
/// entry may be deleted on. So the answer is yes only when the index is known
/// to be on; a wrong no costs a withheld verdict, a wrong yes can cost an entry.
///
/// The question is answered for the volume the nearest existing ancestor of the
/// path lies on, since the file asked about is usually gone. A path on a volume
/// that is not mounted therefore gets the answer for the volume above its mount
/// point; a consumer asks only about places it has found mounted.
final class SpotlightCoverage {
    /// One mdutil run per volume and process: a store of a few hundred entries
    /// would otherwise spawn it a few hundred times.
    private var byVolume: [String: Bool] = [:]

    func searchable(path: String) -> Bool {
        guard let volume = Self.volumeRoot(of: path) else { return false }
        if let known = byVolume[volume] { return known }
        let answer = Self.indexed(volume: volume)
        byVolume[volume] = answer
        return answer
    }

    /// The root of the volume the nearest existing ancestor of `path` lies on.
    static func volumeRoot(of path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
    }

    /// `mdutil -s` on the volume root. Only "Indexing enabled." counts. mdutil
    /// also reports "Indexing disabled.", "Indexing and searching disabled." (a
    /// CCC clone, measured) and "Server search enabled." (an SMB share); none of
    /// them is known to answer a query by id. fileregister used to test for the
    /// text "Indexing disabled" instead, which the clones' line does not contain,
    /// so it took them for indexed. Asked on a folder below the root mdutil says
    /// "unknown indexing state", which is why the root is asked. If mdutil
    /// cannot run or fails, the answer is no.
    static func indexed(volume: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", volume]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        return String(decoding: data, as: UTF8.self).contains("Indexing enabled.")
    }
}
