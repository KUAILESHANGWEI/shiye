import Foundation
import CoreData
import CloudKit
import CryptoKit

struct LibrarySnapshot {
    var groups: [[String: Any]] = []
    var notes: [[String: Any]] = []
    var files: [[String: Any]] = []

    var object: [String: Any] { ["groups": groups, "notes": notes, "files": files] }

    func records() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for (position, group) in groups.enumerated() {
            guard let id = group["id"] as? String else { continue }
            var metadata = group
            let sites = metadata.removeValue(forKey: "sites") as? [[String: Any]] ?? []
            metadata["_order"] = position
            result["group:" + id] = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
            for (index, site) in sites.enumerated() {
                guard let siteID = site["id"] as? String else { continue }
                var value = site
                value["_groupID"] = id
                value["_order"] = index
                result["site:" + siteID] = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            }
        }
        for (kind, items) in [("note", notes), ("file", files)] {
            for item in items {
                guard let id = item["id"] as? String else { continue }
                result[kind + ":" + id] = try JSONSerialization.data(withJSONObject: item, options: .sortedKeys)
            }
        }
        return result
    }

    static func decode(_ records: [String: Data]) throws -> LibrarySnapshot {
        var groups: [[String: Any]] = [], sites: [[String: Any]] = []
        var snapshot = LibrarySnapshot()
        for (key, data) in records {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch key.split(separator: ":").first {
            case "group": groups.append(object)
            case "site": sites.append(object)
            case "note": snapshot.notes.append(object)
            case "file": snapshot.files.append(object)
            default: break
            }
        }
        func ordered(_ first: [String: Any], _ second: [String: Any]) -> Bool {
            let a = first["_order"] as? Int ?? 0, b = second["_order"] as? Int ?? 0
            return a == b ? (first["id"] as? String ?? "") < (second["id"] as? String ?? "") : a < b
        }
        let groupIDs = Set(groups.compactMap { $0["id"] as? String })
        let orphaned = sites.filter { !groupIDs.contains($0["_groupID"] as? String ?? "") }
        if !orphaned.isEmpty { groups.append(["id": "shiye-recovered", "name": "恢复的收藏", "_order": Int.max]) }
        snapshot.groups = groups.sorted(by: ordered).map { group in
            var value = group
            let id = value["id"] as? String ?? ""
            value.removeValue(forKey: "_order")
            let children = sites.filter { $0["_groupID"] as? String == id } + (id == "shiye-recovered" ? orphaned : [])
            value["sites"] = children.sorted(by: ordered).map { site in
                var item = site
                item.removeValue(forKey: "_groupID")
                item.removeValue(forKey: "_order")
                return item
            }
            return value
        }
        snapshot.notes.sort { ($0["createdAt"] as? String ?? "", $0["id"] as? String ?? "") < ($1["createdAt"] as? String ?? "", $1["id"] as? String ?? "") }
        snapshot.files.sort { ($0["createdAt"] as? String ?? "", $0["id"] as? String ?? "") < ($1["createdAt"] as? String ?? "", $1["id"] as? String ?? "") }
        return snapshot
    }
}

/// A single logical entry per group, website, note or file. Tombstones retain deletions
/// while another device is offline. CloudKit transfers binary payloads as assets.
@MainActor final class CloudLibrary {
    static let containerID = "iCloud.com.shangweiqiu.shiye"
    let container: NSPersistentCloudKitContainer
    private let directory: URL
    private var observers: [NSObjectProtocol] = []
    private var cachedRecords: [String: Data] = [:]
    private var cachedSnapshot: LibrarySnapshot?
    private var publishTask: Task<Void, Never>?
    var onChange: ((LibrarySnapshot) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var status = "iCloud 正在连接"

    init(directory: URL, cloudEnabled: Bool) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entity = NSEntityDescription()
        entity.name = "LibraryEntry"
        entity.managedObjectClassName = "NSManagedObject"
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = true
            return attribute
        }
        let payload = attribute("payload", .binaryDataAttributeType)
        payload.allowsExternalBinaryDataStorage = true
        let deleted = attribute("isTombstone", .booleanAttributeType)
        deleted.defaultValue = false
        entity.properties = [attribute("logicalID", .stringAttributeType), payload, attribute("modifiedAt", .dateAttributeType), deleted]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        container = NSPersistentCloudKitContainer(name: "ShiyeLibrary", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("ShiyeCloud.sqlite"))
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if cloudEnabled { description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerID) }
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.transactionAuthor = "Shiye"
        try migrateJSON()
        observers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedulePublish() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in
                guard let self else { return }
                if event.endDate == nil { self.setStatus("iCloud 正在同步") }
                else if event.succeeded { self.setStatus("iCloud 已同步"); self.schedulePublish() }
                else { self.setStatus("iCloud 同步暂不可用，已保存在本机") }
            }
        })
        if cloudEnabled {
            CKContainer(identifier: Self.containerID).accountStatus { [weak self] account, _ in
                Task { @MainActor in self?.setStatus(account == .available ? "iCloud 正在同步" : "请在系统设置中登录 iCloud") }
            }
        } else { setStatus("本机保存") }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func setStatus(_ value: String) { status = value; onStatus?(value) }

    private func rows() throws -> [String: NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryEntry")
        request.predicate = NSPredicate(format: "NOT (logicalID BEGINSWITH %@)", "blob:")
        let fetched = try container.viewContext.fetch(request)
        var result: [String: NSManagedObject] = [:]
        for row in fetched {
            guard let id = row.value(forKey: "logicalID") as? String else { continue }
            if let previous = result[id] {
                let oldDate = previous.value(forKey: "modifiedAt") as? Date ?? .distantPast
                let newDate = row.value(forKey: "modifiedAt") as? Date ?? .distantPast
                let oldHash = SHA256.hash(data: previous.value(forKey: "payload") as? Data ?? Data()).description
                let newHash = SHA256.hash(data: row.value(forKey: "payload") as? Data ?? Data()).description
                if newDate < oldDate || (newDate == oldDate && newHash <= oldHash) { continue }
            }
            result[id] = row
        }
        return result
    }

    func snapshot() throws -> LibrarySnapshot {
        let active = try rows().filter { !($0.value.value(forKey: "isTombstone") as? Bool ?? false) }
        let records = active.compactMapValues { $0.value(forKey: "payload") as? Data }
        if let cachedSnapshot, records == cachedRecords { return cachedSnapshot }
        let result = try LibrarySnapshot.decode(records)
        cachedRecords = records
        cachedSnapshot = result
        return result
    }

    /// Compare only edits made by this editor against its last displayed snapshot.
    /// Remote-only entries are retained even when a local editor has stale data.
    func commit(baseline: LibrarySnapshot, next: LibrarySnapshot) throws -> LibrarySnapshot {
        let before = try baseline.records(), after = try next.records()
        let current = try rows()
        let maximumDate = current.values.compactMap { $0.value(forKey: "modifiedAt") as? Date }.max() ?? .distantPast
        let date = max(Date(), maximumDate.addingTimeInterval(0.001))
        do {
            for id in Set(before.keys).union(after.keys) where before[id] != after[id] {
                let row = current[id] ?? NSEntityDescription.insertNewObject(forEntityName: "LibraryEntry", into: container.viewContext)
                row.setValue(id, forKey: "logicalID")
                if let data = after[id] {
                    let merged = try mergeFields(base: before[id], local: data, remote: row.value(forKey: "payload") as? Data)
                    row.setValue(merged, forKey: "payload")
                    row.setValue(false, forKey: "isTombstone")
                } else { row.setValue(true, forKey: "isTombstone"); row.setValue(nil, forKey: "payload") }
                row.setValue(date, forKey: "modifiedAt")
            }
            if container.viewContext.hasChanges { try container.viewContext.save() }
        } catch { container.viewContext.rollback(); throw error }
        let result = try snapshot()
        onChange?(result)
        return result
    }

    private func mergeFields(base: Data?, local: Data, remote: Data?) throws -> Data {
        guard let base, let remote, remote != base,
              let old = try JSONSerialization.jsonObject(with: base) as? [String: Any],
              let edited = try JSONSerialization.jsonObject(with: local) as? [String: Any],
              var merged = try JSONSerialization.jsonObject(with: remote) as? [String: Any] else { return local }
        func data(_ value: Any?) throws -> Data { try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed]) }
        var changed = try Set(old.keys).union(edited.keys).filter { try data(old[$0]) != data(edited[$0]) }
        if changed.contains("body") || changed.contains("content") { changed.formUnion(["body", "content"]) }
        for key in changed { merged[key] = edited[key] }
        return try JSONSerialization.data(withJSONObject: merged, options: .sortedKeys)
    }

    private func migrateJSON() throws {
        // Only the first migration seeds records. An empty cloud library after deletion
        // must not resurrect items from a previous JSON snapshot.
        let marker = directory.appendingPathComponent("CloudMigration-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        func read(_ name: String) throws -> [[String: Any]] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        let legacy = try LibrarySnapshot(groups: read("bookmarks.json"), notes: read("notes.json"), files: read("files.json"))
        _ = try commit(baseline: LibrarySnapshot(), next: legacy)
        try Data("1".utf8).write(to: marker, options: .atomic)
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish() {
        container.viewContext.refreshAllObjects()
        do { onChange?(try snapshot()) }
        catch { setStatus("无法读取本机资料库") }
    }
}

/// Immutable binary pieces keep attachments out of JSON snapshots and web messages.
final class BinaryAttachments: @unchecked Sendable {
    static let chunkSize = 8 * 1024 * 1024
    private let container: NSPersistentContainer
    let cacheDirectory: URL

    init(container: NSPersistentContainer, directory: URL) {
        self.container = container
        cacheDirectory = directory.appendingPathComponent("AttachmentCache", isDirectory: true)
    }

    private static func key(_ version: String, _ index: Int) -> String { "blob:\(version):\(index)" }

    func storeFile(at url: URL, metadata: [String: Any]) async throws -> [String: Any] {
        let context = container.newBackgroundContext()
        return try await context.perform {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let version = UUID().uuidString
            var digest = SHA256(), size = 0, count = 0
            do {
                while true {
                    let length = try autoreleasepool { () throws -> Int in
                        guard let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty else { return 0 }
                        try Task.checkCancellation()
                        digest.update(data: data)
                        size += data.count
                        let row = NSEntityDescription.insertNewObject(forEntityName: "LibraryEntry", into: context)
                        row.setValue(Self.key(version, count), forKey: "logicalID")
                        row.setValue(data, forKey: "payload")
                        row.setValue(false, forKey: "isTombstone")
                        row.setValue(Date(), forKey: "modifiedAt")
                        try context.save()
                        context.reset()
                        count += 1
                        return data.count
                    }
                    if length == 0 { break }
                }
                guard size == metadata["size"] as? Int else { throw CocoaError(.fileReadCorruptFile) }
                var result = metadata
                result.removeValue(forKey: "data")
                result.removeValue(forKey: "native")
                result.removeValue(forKey: "thumbnail")
                result["storage"] = "chunks-v1"
                result["contentVersion"] = version
                result["chunkCount"] = count
                result["sha256"] = digest.finalize().map { String(format: "%02x", $0) }.joined()
                return result
            } catch {
                context.rollback()
                try? Self.discard(version: version, context: context)
                throw error
            }
        }
    }

    func materialize(_ metadata: [String: Any]) async throws -> URL {
        guard let version = metadata["contentVersion"] as? String, UUID(uuidString: version) != nil,
              let count = metadata["chunkCount"] as? Int, count >= 0,
              let expectedSize = metadata["size"] as? Int, expectedSize >= 0,
              let expectedHash = metadata["sha256"] as? String,
              count == (expectedSize + Self.chunkSize - 1) / Self.chunkSize else { throw CocoaError(.fileReadCorruptFile) }
        let context = container.newBackgroundContext()
        let directory = cacheDirectory.appendingPathComponent(version, isDirectory: true)
        return try await context.perform {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = URL(fileURLWithPath: metadata["name"] as? String ?? "file").lastPathComponent
            guard name != ".", name != "..", !name.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.fileSizeKey])
                if values.fileSize == expectedSize { return destination }
            }
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
            var hash = SHA256(), size = 0
            for index in 0..<count {
                try autoreleasepool {
                try Task.checkCancellation()
                let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryEntry")
                request.predicate = NSPredicate(format: "logicalID == %@", Self.key(version, index))
                request.sortDescriptors = [NSSortDescriptor(key: "modifiedAt", ascending: false)]
                guard let row = try context.fetch(request).first,
                      !(row.value(forKey: "isTombstone") as? Bool ?? false),
                      let data = row.value(forKey: "payload") as? Data else {
                    throw NSError(domain: "ShiyeAttachment", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件正在从 iCloud 下载，请稍后重试。"])
                }
                let length = min(Self.chunkSize, expectedSize - size)
                guard data.count == length else { throw CocoaError(.fileReadCorruptFile) }
                hash.update(data: data)
                try output.write(contentsOf: data)
                size += data.count
                context.reset()
                }
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard size == expectedSize, actual == expectedHash else { throw CocoaError(.fileReadCorruptFile) }
            try output.synchronize()
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
    }

    func discard(_ metadata: [String: Any]) async throws {
        guard let version = metadata["contentVersion"] as? String, UUID(uuidString: version) != nil else { return }
        let context = container.newBackgroundContext()
        try await context.perform { try Self.discard(version: version, context: context) }
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(version, isDirectory: true))
    }

    private static func discard(version: String, context: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryEntry")
        request.predicate = NSPredicate(format: "logicalID BEGINSWITH %@", "blob:\(version):")
        for row in try context.fetch(request) {
            row.setValue(nil, forKey: "payload")
            row.setValue(true, forKey: "isTombstone")
            row.setValue(Date(), forKey: "modifiedAt")
        }
        if context.hasChanges { try context.save() }
        context.reset()
    }
}
