import Foundation

/// Thin wrapper over the POSIX xattr syscalls. Used for the metadata layer
/// (`com.apple.metadata:kMDItemProjects`/`kMDItemInformation`) and the
/// cross-device id whose name carries the `#S` (syncable) flag — the `#S`
/// is part of the literal attribute name, so it is passed straight through to
/// setxattr/getxattr with no special handling (verified, macOS 26.4).
///
/// Values are treated as UTF-8 strings end to end: Foundation never hands us
/// locale-tagged bytes here, and we decode raw xattr bytes as UTF-8 explicitly.
public enum Xattr {
    /// Read an xattr as a UTF-8 string, or nil if it is absent / unreadable.
    public static func get(_ name: String, path: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        if size == 0 { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, 0)
        guard read >= 0 else { return nil }
        return String(decoding: buffer[0..<read], as: UTF8.self)
    }

    /// Read an xattr as raw bytes (e.g. a binary plist array), or nil if absent.
    public static func getData(_ name: String, path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        if size == 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, 0)
        guard read >= 0 else { return nil }
        return Data(buffer[0..<read])
    }

    /// Write a UTF-8 string xattr. Returns false on failure.
    @discardableResult
    public static func set(_ name: String, value: String, path: String) -> Bool {
        let bytes = Array(value.utf8)
        return setxattr(path, name, bytes, bytes.count, 0, 0) == 0
    }

    /// Write raw bytes as an xattr (e.g. a binary plist). Returns false on failure.
    @discardableResult
    public static func setData(_ name: String, data: Data, path: String) -> Bool {
        data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) == 0 }
    }

    /// Remove an xattr. Returns false on failure (including "not present").
    @discardableResult
    public static func remove(_ name: String, path: String) -> Bool {
        return removexattr(path, name, 0) == 0
    }
}
