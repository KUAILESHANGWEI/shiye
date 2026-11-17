import XCTest
import CryptoKit
@testable import ShiyePhone

@MainActor final class StorageTests: XCTestCase {
    private func hash(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            digest.update(data: data)
            return true
        }) {}
        return digest.finalize().description
    }

    func testLargeFileIntegrityAndEncryptedBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyeStorageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for megabytes in [10, 50, 100, 250, 500] {
            let directory = root.appendingPathComponent(String(megabytes), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("random.bin")
            FileManager.default.createFile(atPath: source.path, contents: nil)
            let output = try FileHandle(forWritingTo: source)
            for _ in 0..<megabytes {
                try autoreleasepool {
                    var data = Data(count: 1024 * 1024)
                    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
                    try output.write(contentsOf: data)
                }
            }
            try output.close()
            let expected = try hash(source)
            let store = try CloudLibrary(directory: directory.appendingPathComponent("store"), cloudEnabled: false)
            let attachments = BinaryAttachments(container: store.container, directory: directory)
            let original: [String: Any] = ["id": UUID().uuidString, "name": "random.bin", "type": "application/octet-stream", "size": megabytes * 1024 * 1024, "note": "Synthetic test", "rating": 0, "createdAt": "2026-11-14"]
            let metadata = try await attachments.storeFile(at: source, metadata: original)
            let snapshot = try store.commit(baseline: LibrarySnapshot(), next: LibrarySnapshot(files: [metadata]))
            XCTAssertLessThan(try JSONSerialization.data(withJSONObject: snapshot.object).count, 2048)
            let restored = try await attachments.materialize(metadata)
            XCTAssertEqual(try hash(restored), expected)
            let archive = directory.appendingPathComponent("backup.shiye")
            try BackupArchive.write(to: archive, password: "synthetic-test-password", groups: [], notes: [], files: [(metadata, restored)])
            let recovered = try BackupArchive.read(from: archive, password: "synthetic-test-password", directory: directory.appendingPathComponent("restored"))
            XCTAssertEqual(try hash(recovered.files[0].1), expected)
            XCTAssertThrowsError(try BackupArchive.read(from: archive, password: "wrong", directory: directory.appendingPathComponent("wrong")))
            try await attachments.discard(metadata)
            let empty = try store.commit(baseline: snapshot, next: LibrarySnapshot())
            XCTAssertTrue(empty.files.isEmpty)
            print("SHIYE DEVICE PASS \(megabytes) MB import/export, encrypted restore and deletion")
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testCancelledImportDoesNotCreateFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyeCancelTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CloudLibrary(directory: root, cloudEnabled: false)
        let session = try LibrarySession(store: store)
        let metadata: [String: Any] = ["id": UUID().uuidString, "name": "cancel.bin", "type": "application/octet-stream", "size": 10 * 1024 * 1024, "note": "", "rating": 0, "createdAt": "2026-11-14"]
        let token = try await session.fileRequest("beginImport", value: metadata) as! String
        _ = try await session.fileRequest("appendImport", value: ["token": token, "offset": 0, "data": Data(repeating: 7, count: 1024 * 1024).base64EncodedString()])
        _ = try await session.fileRequest("cancelImport", value: token)
        XCTAssertTrue(try store.snapshot().files.isEmpty)
    }
}
