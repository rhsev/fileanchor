import Foundation

/// The value rules of the contract (PLATFORMS.md). Every fileanchor engine,
/// whatever its OS, accepts exactly these values — so a value one engine
/// wrote can be written again by any other, onto its own attributes.
///
/// Strict on write, tolerant on read and removal: only `tag` and
/// `set_meta add|set` validate. Removal takes whatever is there, so values
/// written by Finder or an older engine can still be cleaned up.
///
/// Values are rejected, never repaired — with one exception: they are stored
/// NFC-precomposed, because the same text must be the same bytes on every
/// platform (macOS filesystems don't normalize xattr values, Linux ones
/// don't normalize anything).
public enum Values {
    public enum Kind {
        /// Tags and groups: a name a person reads. fileregister stores a
        /// binder as either, so both follow one rule.
        case label
        /// id and sync: one machine token.
        case token
        /// The comment: free text, as Finder lets people type it.
        case text
    }

    static let maxLabelBytes = 255
    static let maxTokenBytes = 128
    static let maxTextBytes = 1024

    /// Validate `value` for `kind` and return it NFC-normalized, or throw
    /// `invalidValue` naming the broken rule.
    public static func validate(_ value: String, as kind: Kind, key: String) throws -> String {
        let v = value.precomposedStringWithCanonicalMapping
        func reject(_ why: String) -> EngineError { .invalidValue("\(key) \(why)") }

        guard !v.isEmpty else { throw reject("is empty") }
        // Control characters break storage on both sides: a newline ends a
        // Finder tag name (the color index follows it), NUL ends a C string.
        let allowed: Set<Unicode.Scalar> = kind == .text ? ["\n", "\t"] : []
        if v.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !allowed.contains($0) }) {
            throw reject("contains a control character")
        }

        switch kind {
        case .label:
            // Linux desktops keep tags in user.xdg.tags as a comma-separated
            // list, with no escaping.
            if v.contains(",") { throw reject("contains a comma") }
            if v.first!.isWhitespace || v.last!.isWhitespace {
                throw reject("has leading or trailing whitespace")
            }
            if v.utf8.count > maxLabelBytes { throw reject("is longer than \(maxLabelBytes) bytes") }
        case .token:
            if v.contains(where: \.isWhitespace) { throw reject("contains whitespace") }
            if v.contains(",") { throw reject("contains a comma") }
            if v.utf8.count > maxTokenBytes { throw reject("is longer than \(maxTokenBytes) bytes") }
        case .text:
            // All of a file's xattrs share ~4 KiB on ext4.
            if v.utf8.count > maxTextBytes { throw reject("is longer than \(maxTextBytes) bytes") }
        }
        return v
    }
}
