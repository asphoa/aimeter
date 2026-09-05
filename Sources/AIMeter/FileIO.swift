import Foundation

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

/// Reads a credential file's raw contents — see Model.swift history note.
func readKey(file: String?) -> String? {
    guard let file else { return nil }
    if file.hasPrefix("env:") {
        return ProcessInfo.processInfo.environment[String(file.dropFirst(4))]
    }
    guard let raw = try? String(contentsOfFile: expand(file), encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Accepts a HOME from the settings file only if it is a directory this user owns.
func trustedHome(_ path: String, marker: String) -> String? {
    let home = expand(path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: home, isDirectory: &isDir), isDir.boolValue,
          FileManager.default.fileExists(atPath: home + "/" + marker),
          let attrs = try? FileManager.default.attributesOfItem(atPath: home),
          (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return nil }
    return home
}

/// Read the last `limit` bytes of a file, skipping a partial first line when mid-file.
func tailBytes(_ path: String, limit: Int = 512 * 1024) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd() else { return nil }
    let start = size > UInt64(limit) ? size - UInt64(limit) : 0
    try? fh.seek(toOffset: start)
    guard let data = try? fh.readToEnd() else { return nil }
    var slice = data[data.startIndex...]
    if start > 0, let nl = slice.firstIndex(of: 0x0A) {
        slice = slice[slice.index(after: nl)...]
    }
    return String(decoding: slice, as: UTF8.self)
}

enum PrivateWriteError: Error {
    case failed(String)
}

enum Diagnostics {
    static func warn(_ message: String, dir: String = Config.dir) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        let path = dir + "/diagnostics.log"
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

func writePrivate(_ data: Data, to path: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    let tmp = dir + "/.tmp-" + UUID().uuidString
    do {
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
        let dest = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: URL(fileURLWithPath: tmp))
        } else {
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch {
        try? FileManager.default.removeItem(atPath: tmp)
        throw PrivateWriteError.failed(path)
    }
}
