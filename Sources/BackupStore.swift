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
