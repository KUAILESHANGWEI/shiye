import Foundation
import CryptoKit
import CommonCrypto

/// Each authenticated frame is bounded, so a backup can contain large files.
struct BackupArchive {
    struct Contents {
        var groups: [[String: Any]]
        var notes: [[String: Any]]
        var files: [([String: Any], URL)]
        var directory: URL
    }
    private static let magic = Data("SHIYE-A1\n".utf8)
    private static let blockSize = 1024 * 1024

    private static func key(password: String, salt: Data) throws -> SymmetricKey {
        guard !password.isEmpty else { throw CocoaError(.coderInvalidValue) }
        let passwordBytes = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let result = passwordBytes.withUnsafeBytes { secret in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress!.assumingMemoryBound(to: Int8.self), secret.count, saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &output, output.count)
            }
        }
        guard result == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return SymmetricKey(data: output)
    }

    private static func exact(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            data.append(part)
        }
        return data
    }

    private static func aad(_ header: Data, index: UInt64) -> Data {
        var value = index.bigEndian
        return header + withUnsafeBytes(of: &value) { Data($0) }
    }

    static func write(to destination: URL, password: String, groups: [[String: Any]], notes: [[String: Any]], files: [([String: Any], URL)]) throws {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let header = magic + salt
        let secret = try key(password: password, salt: salt)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        do {
            try output.write(contentsOf: header)
            var index: UInt64 = 0
            func frame(_ plaintext: Data) throws {
                let sealed = try AES.GCM.seal(plaintext, using: secret, authenticating: aad(header, index: index)).combined!
                guard sealed.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
                var length = UInt32(sealed.count).bigEndian
                try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
                try output.write(contentsOf: sealed)
                index += 1
            }
            func json(_ object: Any) throws { try frame(JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) }
            try json(["groups": groups.count, "notes": notes.count, "files": files.count])
            for group in groups { try autoreleasepool { try json(group) } }
            for note in notes { try autoreleasepool { try json(note) } }
            for (metadata, url) in files {
                var item = metadata
                for field in ["data", "native", "storage", "contentVersion", "chunkCount", "sha256"] { item.removeValue(forKey: field) }
                try json(item)
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                var remaining = metadata["size"] as? Int ?? -1
                guard remaining >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                while remaining > 0 {
                    let count = min(blockSize, remaining)
                    try autoreleasepool { try frame(exact(input, count: count)) }
                    remaining -= count
                }
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            }
            try json(["finished": true, "frames": index])
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func read(from source: URL, password: String, directory: URL) throws -> Contents {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try exact(input, count: magic.count + 16)
        guard header.prefix(magic.count) == magic else { throw CocoaError(.fileReadCorruptFile) }
        let secret = try key(password: password, salt: header.suffix(16))
        var index: UInt64 = 0
        func frame() throws -> Data {
            let prefix = try exact(input, count: 4)
            let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 28, length <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let box = try AES.GCM.SealedBox(combined: exact(input, count: Int(length)))
            let data = try AES.GCM.open(box, using: secret, authenticating: aad(header, index: index))
            index += 1
            return data
        }
        func json() throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: frame()) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            return object
        }
        let counts = try json()
        guard let groupCount = counts["groups"] as? Int, (0...1_000_000).contains(groupCount),
              let noteCount = counts["notes"] as? Int, (0...1_000_000).contains(noteCount),
              let fileCount = counts["files"] as? Int, (0...1_000_000).contains(fileCount) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var groups: [[String: Any]] = [], notes: [[String: Any]] = [], files: [([String: Any], URL)] = []
            for _ in 0..<groupCount { groups.append(try json()) }
            for _ in 0..<noteCount { notes.append(try json()) }
            var ids = Set<String>()
            for _ in 0..<fileCount {
                let metadata = try json()
                guard let id = metadata["id"] as? String, UUID(uuidString: id) != nil, ids.insert(id).inserted,
                      let size = metadata["size"] as? Int, size >= 0,
                      let name = metadata["name"] as? String, !name.isEmpty,
                      metadata["type"] is String, metadata["note"] is String, metadata["createdAt"] is String,
                      let rating = metadata["rating"] as? Int, (0...3).contains(rating) else { throw CocoaError(.fileReadCorruptFile) }
                let url = directory.appendingPathComponent(UUID().uuidString)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: url)
                defer { try? output.close() }
                var remaining = size
                while remaining > 0 {
                    let count = min(blockSize, remaining)
                    try autoreleasepool {
                        let data = try frame()
                        guard data.count == count else { throw CocoaError(.fileReadCorruptFile) }
                        try output.write(contentsOf: data)
                    }
                    remaining -= count
                }
                try output.synchronize()
                files.append((metadata, url))
            }
            let frameCount = index
            let end = try json()
            guard end["finished"] as? Bool == true, end["frames"] as? UInt64 == frameCount,
                  (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return Contents(groups: groups, notes: notes, files: files, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
