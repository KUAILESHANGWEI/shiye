import Foundation

/// One atomic snapshot keeps file contents and their metadata consistent.
final class FileCollectionStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func read() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let records = value as? [[String: Any]] else {
            throw failure("文件资料库格式不正确")
        }
        return records
    }

    func validate(_ record: [String: Any]) throws {
        guard let id = record["id"] as? String, UUID(uuidString: id) != nil,
              let name = record["name"] as? String, !name.isEmpty,
              ![".", ".."].contains(URL(fileURLWithPath: name).lastPathComponent),
              record["type"] is String,
              record["createdAt"] is String,
              record["note"] is String,
              let rating = record["rating"] as? Int, (0...3).contains(rating),
              let encoded = record["data"] as? String,
              let contents = Data(base64Encoded: encoded),
              let size = record["size"] as? Int, size == contents.count else {
            throw failure("文件数据不完整")
        }
    }

    @discardableResult
    func merge(_ incoming: [[String: Any]]) throws -> [[String: Any]] {
        var ids = Set<String>()
        for record in incoming {
            try validate(record)
            guard let id = record["id"] as? String, ids.insert(id).inserted else {
                throw failure("文件 ID 重复")
            }
        }
        var records = try read()
        for record in incoming {
            let id = record["id"] as? String
            if let index = records.firstIndex(where: { $0["id"] as? String == id }) {
                records[index] = record
            } else {
                records.append(record)
            }
        }
        try write(records)
        return records
    }

    func delete(id: String) throws {
        let records = try read().filter { $0["id"] as? String != id }
        try write(records)
    }

    private func write(_ records: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: records)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ShiyeFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
