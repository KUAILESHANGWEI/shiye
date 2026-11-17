import Foundation
import WebKit
import ImageIO
import UniformTypeIdentifiers

@MainActor final class LibrarySession {
    let store: CloudLibrary
    private(set) var presented: LibrarySnapshot
    weak var webView: WKWebView?
    let attachments: BinaryAttachments
    private var uploads: [String: (url: URL, metadata: [String: Any], offset: Int)] = [:]
    private var pendingArchives: [String: BackupArchive.Contents] = [:]
    private var sentFiles: [[String: Any]] = []
    private let transferDirectory: URL


    init(store: CloudLibrary) throws {
        self.store = store
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyeTransfers-" + UUID().uuidString, isDirectory: true)
        transferDirectory = root
        attachments = BinaryAttachments(container: store.container, directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Shiye", isDirectory: true))
        presented = try store.snapshot()
        store.onChange = { [weak self] snapshot in self?.send(snapshot) }
        store.onStatus = { [weak self] _ in self?.sendStatus() }
    }

    func configure(_ controller: WKUserContentController) throws {
        let data = try JSONSerialization.data(withJSONObject: ["groups": presented.groups, "notes": presented.notes])
        let json = String(decoding: data, as: UTF8.self)
        let code = "{ const seed=\(json); window.shiyeCloudAvailable=true; window.shiyeNativeFileStreaming=true; window.shiyuNativeLibrary=JSON.stringify(seed.groups); window.shiyeNativeNotes=JSON.stringify(seed.notes); }"
        controller.addUserScript(WKUserScript(source: code, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func acknowledge(_ object: [String: Any]) {
        guard let groups = object["groups"] as? [[String: Any]], let notes = object["notes"] as? [[String: Any]], let files = object["files"] as? [[String: Any]] else { return }
        let restored = files.map { file in sentFiles.first { $0["id"] as? String == file["id"] as? String } ?? file }
        presented = LibrarySnapshot(groups: groups, notes: notes, files: restored)
    }

    func writeGroups(_ groups: [[String: Any]]) throws -> LibrarySnapshot {
        var next = presented
        next.groups = groups
        return try store.commit(baseline: presented, next: next)
    }

    func writeNotes(_ notes: [[String: Any]]) throws -> LibrarySnapshot {
        var next = presented
        next.notes = notes
        return try store.commit(baseline: presented, next: next)
    }

    func mergeFiles(_ files: [[String: Any]]) throws {
        var next = presented
        for file in files {
            if let index = next.files.firstIndex(where: { $0["id"] as? String == file["id"] as? String }) { next.files[index] = file }
            else { next.files.append(file) }
        }
        _ = try store.commit(baseline: presented, next: next)
    }

    func deleteFile(_ id: String) throws {
        let baseline = try store.snapshot()
        var next = baseline
        next.files.removeAll { $0["id"] as? String == id }
        _ = try store.commit(baseline: baseline, next: next)
        if let file = baseline.files.first(where: { $0["id"] as? String == id }) {
            Task { try? await attachments.discard(file) }
        }
    }

    func fileSummaries(_ records: [[String: Any]]) -> [[String: Any]] {
        records.map { record in
            var summary = record
            summary.removeValue(forKey: "data")
            summary["native"] = true
            return summary
        }
    }

    func fileURL(_ id: String) async throws -> URL {
        guard let record = try store.snapshot().files.first(where: { $0["id"] as? String == id }) else { throw CocoaError(.fileNoSuchFile) }
        if record["storage"] as? String == "chunks-v1" { return try await attachments.materialize(record) }
        guard let encoded = record["data"] as? String, let data = Data(base64Encoded: encoded),
              let name = record["name"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        let directory = transferDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        try data.write(to: url, options: .atomic)
        return url
    }

    func exportArchive(password: String) async throws -> URL {
        let snapshot = try store.snapshot()
        var files: [([String: Any], URL)] = []
        for metadata in snapshot.files {
            guard let id = metadata["id"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            files.append((metadata, try await fileURL(id)))
        }
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        let url = transferDirectory.appendingPathComponent("Shiye-" + UUID().uuidString + ".shiye")
        try await Task.detached(priority: .utility) {
            try BackupArchive.write(to: url, password: password, groups: snapshot.groups, notes: snapshot.notes, files: files)
        }.value
        return url
    }

    func fileRequest(_ action: String, value: Any?) async throws -> Any {
        switch action {
        case "getAll": return fileSummaries(try store.snapshot().files)
        case "beginImport":
            guard let metadata = value as? [String: Any], let id = metadata["id"] as? String, UUID(uuidString: id) != nil,
                  let size = metadata["size"] as? Int, size >= 0,
                  let name = metadata["name"] as? String, !name.isEmpty,
                  metadata["type"] is String, metadata["createdAt"] is String, metadata["note"] is String,
                  let rating = metadata["rating"] as? Int, (0...3).contains(rating) else { throw CocoaError(.coderInvalidValue) }
            try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let url = transferDirectory.appendingPathComponent(token)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            uploads[token] = (url, metadata, 0)
            return token
        case "appendImport":
            guard let part = value as? [String: Any], let token = part["token"] as? String,
                  var upload = uploads[token], let offset = part["offset"] as? Int, offset == upload.offset,
                  let encoded = part["data"] as? String, encoded.utf8.count <= 1_500_000,
                  let bytes = Data(base64Encoded: encoded), bytes.count <= 1_048_576,
                  upload.offset + bytes.count <= upload.metadata["size"] as? Int ?? -1 else { throw CocoaError(.coderInvalidValue) }
            let handle = try FileHandle(forWritingTo: upload.url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            upload.offset += bytes.count
            uploads[token] = upload
            return upload.offset
        case "finishImport":
            guard let token = value as? String, let upload = uploads.removeValue(forKey: token),
                  upload.offset == upload.metadata["size"] as? Int else { throw CocoaError(.coderInvalidValue) }
            defer { try? FileManager.default.removeItem(at: upload.url) }
            let metadata = try await attachments.storeFile(at: upload.url, metadata: upload.metadata)
            do { try mergeFiles([metadata]) }
            catch { try? await attachments.discard(metadata); throw error }
            return true
        case "cancelImport":
            if let token = value as? String, let upload = uploads.removeValue(forKey: token) { try? FileManager.default.removeItem(at: upload.url) }
            return true
        case "updateMetadata":
            guard let incoming = value as? [String: Any], let id = incoming["id"] as? String,
                  let note = incoming["note"] as? String, let rating = incoming["rating"] as? Int, (0...3).contains(rating) else { throw CocoaError(.coderInvalidValue) }
            let baseline = try store.snapshot()
            var next = baseline
            guard let index = next.files.firstIndex(where: { $0["id"] as? String == id }) else { throw CocoaError(.fileNoSuchFile) }
            next.files[index]["note"] = note
            next.files[index]["rating"] = rating
            _ = try store.commit(baseline: baseline, next: next)
            return true
        case "readFilePart":
            guard let part = value as? [String: Any], let id = part["id"] as? String,
                  let offset = part["offset"] as? Int, offset >= 0,
                  let length = part["length"] as? Int, (1...1048576).contains(length) else { throw CocoaError(.coderInvalidValue) }
            let url = try await fileURL(id)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return (try handle.read(upToCount: length) ?? Data()).base64EncodedString()
        case "inspectArchive":
            guard let request = value as? [String: String], let token = request["token"], let password = request["password"],
                  let upload = uploads.removeValue(forKey: token), upload.offset == upload.metadata["size"] as? Int else { throw CocoaError(.coderInvalidValue) }
            defer { try? FileManager.default.removeItem(at: upload.url) }
            let directory = transferDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let archive: BackupArchive.Contents
            do {
                archive = try await Task.detached(priority: .utility) {
                    try BackupArchive.read(from: upload.url, password: password, directory: directory)
                }.value
            } catch { throw NSError(domain: "ShiyeBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "密码错误或备份文件已损坏"]) }
            pendingArchives[token] = archive
            return ["token": token, "groups": archive.groups, "notes": archive.notes, "files": archive.files.map { $0.0 }]
        case "cancelArchive":
            if let token = value as? String, let archive = pendingArchives.removeValue(forKey: token) { try? FileManager.default.removeItem(at: archive.directory) }
            return true
        case "commitArchive":
            guard let request = value as? [String: Any], let token = request["token"] as? String,
                  let archive = pendingArchives.removeValue(forKey: token),
                  let groups = request["groups"] as? [[String: Any]], let notes = request["notes"] as? [[String: Any]] else { throw CocoaError(.coderInvalidValue) }
            defer { try? FileManager.default.removeItem(at: archive.directory) }
            let baseline = presented
            var next = baseline
            next.groups = groups
            next.notes = notes
            var prepared: [[String: Any]] = []
            do {
                for (metadata, url) in archive.files {
                    let imported = try await attachments.storeFile(at: url, metadata: metadata)
                    if let existing = baseline.files.first(where: { $0["id"] as? String == imported["id"] as? String && $0["sha256"] as? String == imported["sha256"] as? String }) {
                        try await attachments.discard(imported)
                        var reused = existing
                        for key in ["name", "type", "size", "createdAt", "note", "rating"] { reused[key] = imported[key] }
                        prepared.append(reused)
                    } else { prepared.append(imported) }
                }
                for file in prepared {
                    if let index = next.files.firstIndex(where: { $0["id"] as? String == file["id"] as? String }) { next.files[index] = file }
                    else { next.files.append(file) }
                }
                _ = try store.commit(baseline: baseline, next: next)
            } catch {
                for file in prepared where !baseline.files.contains(where: { $0["contentVersion"] as? String == file["contentVersion"] as? String }) { try? await attachments.discard(file) }
                throw error
            }
            return true
        case "thumbnail":
            guard let id = value as? String else { throw CocoaError(.coderInvalidValue) }
            let url = try await fileURL(id)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return "" }
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return "" }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { return "" }
            return "data:image/png;base64," + (data as Data).base64EncodedString()
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    func sendCurrent() {
        do { send(try store.snapshot()); sendStatus() }
        catch { sendStatus() }
    }

    private func send(_ snapshot: LibrarySnapshot) {
        sentFiles = snapshot.files
        var object = snapshot.object
        object["files"] = fileSummaries(snapshot.files)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let json = String(decoding: data, as: UTF8.self)
        webView?.evaluateJavaScript("window.shiyeReceiveNativeSnapshot?.(\(json))")
    }

    private func sendStatus() {
        guard let data = try? JSONSerialization.data(withJSONObject: [store.status]) else { return }
        webView?.evaluateJavaScript("window.shiyeReceiveSyncStatus?.(\(String(decoding: data, as: UTF8.self))[0])")
    }
}

@MainActor final class SnapshotAcknowledgement: NSObject, WKScriptMessageHandler {
    let session: LibrarySession
    init(session: LibrarySession) { self.session = session }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let object = message.body as? [String: Any] { session.acknowledge(object) }
    }
}
