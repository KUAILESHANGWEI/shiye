import Foundation

/// Writes only already encrypted backup envelopes. Existing backups are never
/// pruned until a new file has been written successfully.
struct BackupStore {
    static func write(_ data: Data, to directory: URL, retain: Int = 30, now: Date = Date()) throws -> URL {
        guard retain > 0 else { throw NSError(domain: "BackupStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "保留数量必须大于零"]) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object?["format"] as? String == "shiyu-encrypted", object?["version"] as? Int == 1 else { throw NSError(domain: "BackupStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "备份数据格式错误"]) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let destination = directory.appendingPathComponent("shiyu-backup-\(formatter.string(from: now))-\(UUID().uuidString).json")
        try data.write(to: destination, options: .atomic)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter { $0.lastPathComponent.hasPrefix("shiyu-backup-") && $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files.dropFirst(retain) { try FileManager.default.removeItem(at: file) }
        return destination
    }
}

extension BackupStore {
    #if os(macOS)
    static func exportFile(_ source: URL, to destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        // Export sources are completed, immutable local files. Mapping keeps large
        // archives off the heap. Foundation handles the authorized atomic save.
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        try data.write(to: destination, options: .atomic)
    }
    #endif

    static func writeArchive(_ source: URL, to directory: URL, retain: Int = 30) throws -> URL {
        let input = try FileHandle(forReadingFrom: source)
        let header = try input.read(upToCount: 9)
        try input.close()
        guard header == Data("SHIYE-A1\n".utf8), retain > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let destination = directory.appendingPathComponent("shiyu-backup-\(formatter.string(from: Date()))-\(UUID().uuidString).shiye")
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter {
            $0.lastPathComponent.hasPrefix("shiyu-backup-") && ["json", "shiye"].contains($0.pathExtension)
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files.dropFirst(retain) { try FileManager.default.removeItem(at: file) }
        return destination
    }

    #if os(macOS)
    static func directory(for target: String) throws -> URL {
        guard ["icloud", "google"].contains(target) else { throw CocoaError(.coderInvalidValue) }
        if let bookmark = UserDefaults.standard.data(forKey: "backup-bookmark-" + target) {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { UserDefaults.standard.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "backup-bookmark-" + target) }
            return url
        }
        guard let path = UserDefaults.standard.string(forKey: "backup-directory-" + target) else { throw CocoaError(.fileNoSuchFile) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    #endif
}
