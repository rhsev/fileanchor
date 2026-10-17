import Foundation

/// Write-through of the Finder comment to Finder's own store.
///
/// Finder keeps its authoritative comment copy in Desktop Services (persisted
/// via .DS_Store) and never reads the kMDItemFinderComment xattr — that xattr
/// is a one-way export *from* Finder for Spotlight. So an xattr-only write is
/// found by Spotlight but never shows in Get Info, no matter how long you wait
/// (verified empirically 2026-07: fresh folder, xattr set before Finder ever
/// saw it, forced mdimport — Finder stays blank; a Finder-set comment appears
/// instantly and writes the xattr itself). The only way in is asking Finder.
///
/// One NSAppleScript, compiled once, called per write as a subroutine via a
/// raw Apple Event — no osascript child process. Strictly best effort: no
/// Finder, denied automation, or a timeout must never fail the metadata
/// operation, because the xattr (the engine's truth) is already written.
public enum FinderComment {
    /// Escape hatch for tests: XCTest runs must not talk to Finder.
    public static var isEnabled = true

    // The alias coercion happens OUTSIDE the Finder tell (inside it, POSIX
    // file fails with -1728); the timeout keeps a hung Finder from wedging
    // the engine's serial loop.
    private static let source = """
    on setcomment(p, c)
        set f to POSIX file p as alias
        with timeout of 3 seconds
            tell application "Finder" to set comment of f to c
        end timeout
    end setcomment
    """

    private static let script: NSAppleScript? = {
        guard let s = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        return s.compileAndReturnError(&error) ? s : nil
    }()

    private static func code(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// Tell Finder the comment changed (empty string clears it). Returns
    /// whether Finder took it; callers may ignore the result.
    @discardableResult
    public static func sync(path: String, comment: String) -> Bool {
        guard isEnabled, let script else { return false }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: path), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: comment), at: 2)
        // A subroutine call: class 'ascr', id 'psbr', handler name in 'snam',
        // arguments as the direct object. returnID -1 = auto, transaction 0 = any.
        let event = NSAppleEventDescriptor(
            eventClass: code("ascr"), eventID: code("psbr"),
            targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setDescriptor(NSAppleEventDescriptor(string: "setcomment"),
                            forKeyword: code("snam"))
        event.setDescriptor(arguments, forKeyword: code("----"))
        var error: NSDictionary?
        script.executeAppleEvent(event, error: &error)
        return error == nil
    }
}
