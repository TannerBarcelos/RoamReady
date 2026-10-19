#if canImport(CoreData) && canImport(CloudKit)
import Foundation
@preconcurrency import CloudKit
import CampCore

public struct CloudSyncReport: Sendable {
    public let downloaded: Int
    public let uploaded: Int
    public let hasPendingUploads: Bool
    public let waitingForRelatedRecords: Bool
}

/// Explicit transport: SQLite saves/outbox work with no account or network.
/// Physical CloudKit records use stable document keys. Same-field edits resolve by
/// logical version; independent fields merge; immutable note revisions retain text.
public actor CloudKitReplicator {
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "RoamReadyLibrary", ownerName: CKCurrentUserDefaultName)
    private var running = false
    private var generation = 0
    private var operations: [UUID: CKOperation] = [:]
    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
    }
    public func cancel() {
        generation += 1
        for op in operations.values { op.cancel() }
    }
    public func enable(store: SQLiteStore) async throws {
        let identity = try await verifiedIdentity(store: store)
        // Binding is permanent for this local library. No automatic account rebinding.
        try await store.setMetadata("cloudAccount", value: Data(identity.utf8))
        _ = try await verifiedIdentity(store: store)
        try await store.setMetadata("cloudEnabled", value: Data([1]))
    }
    public func disable(store: SQLiteStore) async throws {
        cancel(); try await store.setMetadata("cloudEnabled", value: nil)
    }
    public func sync(store: SQLiteStore) async throws -> CloudSyncReport {
        guard !running else { return CloudSyncReport(downloaded: 0, uploaded: 0, hasPendingUploads: true, waitingForRelatedRecords: false) }
        guard try await store.metadata("cloudEnabled") != nil else { return CloudSyncReport(downloaded: 0, uploaded: 0, hasPendingUploads: false, waitingForRelatedRecords: false) }
        running = true; defer { running = false }
        let epoch = generation
        _ = try await verifiedIdentity(store: store)
        try check(epoch)
        if try await store.metadata("cloudZoneReady") == nil { try await createZone(store: store, epoch: epoch) }
        var downloaded = 0, uploaded = 0
        var restarted = false
        while true {
            do {
                let data = try await store.metadata("cloudToken")
                let token = try data.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
                let page = try await fetchPage(previous: token ?? nil, epoch: epoch)
                _ = try await verifiedIdentity(store: store)
                try check(epoch)
                let tokenData = try page.token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                try await store.receive(page.changes, deletedKeys: page.deletedKeys, token: tokenData)
                downloaded += page.changes.count
                if !page.more { break }
            } catch let error as CKError where !restarted && (error.code == .changeTokenExpired || error.code == .zoneNotFound || error.code == .userDeletedZone) {
                restarted = true
                try await store.setMetadata("cloudToken", value: nil)
                if error.code != .changeTokenExpired {
                    try await createZone(store: store, epoch: epoch)
                    try await store.markAllForUpload()
                }
            }
        }
        // Bound foreground work; further batches resume on the next scheduled pass.
        for _ in 0..<8 {
            try check(epoch)
            var pending = try await store.pending()
            if pending.isEmpty { break }
            let ids = pending.map { CKRecord.ID(recordName: $0.record.key, zoneID: zoneID) }
            let existing = try await fetchRecords(ids, epoch: epoch)
            _ = try await verifiedIdentity(store: store)
            try check(epoch)
            for item in pending {
                let id = CKRecord.ID(recordName: item.record.key, zoneID: zoneID)
                if let result = existing[id] {
                    switch result {
                    case .success(let record):
                        let change = try Self.unpack(record)
                        try await store.receive([change])
                    case .failure(let error):
                        if (error as? CKError)?.code != .unknownItem { throw error }
                    }
                }
            }
            let desiredKeys = Set(pending.map { $0.record.key })
            pending = try await store.pending().filter { desiredKeys.contains($0.record.key) }
            if pending.isEmpty { continue }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("RoamReadyUpload-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            var records: [CKRecord] = []
            for item in pending {
                let id = CKRecord.ID(recordName: item.record.key, zoneID: zoneID)
                let record: CKRecord
                if case .success(let server) = existing[id] { record = server }
                else { record = CKRecord(recordType: "RoamReadyRecord", recordID: id) }
                var outgoing = item.record
                var outgoingAsset = item.asset
                if case .success(let server) = existing[id] {
                    let remote = try Self.unpack(server)
                    outgoing = try outgoing.merging(remote.0)
                    if outgoing.fields["checksum"] == remote.0.fields["checksum"], let bytes = remote.1 { outgoingAsset = bytes }
                }
                record["payload"] = try JSONEncoder().encode(outgoing) as CKRecordValue
                if outgoing.kind == .asset, outgoing.deletion == nil {
                    guard let bytes = outgoingAsset else { throw ReplicationError.missingAsset }
                    let path = temp.appendingPathComponent(UUID().uuidString + ".jpg")
                    try bytes.write(to: path, options: .atomic)
                    record["image"] = CKAsset(fileURL: path)
                } else { record["image"] = nil }
                records.append(record)
            }
            // Recheck identity immediately before upload. Account-change notifications also cancel operations.
            _ = try await verifiedIdentity(store: store); try check(epoch)
            let results = try await upload(records, epoch: epoch)
            var mustRetry = false
            for item in pending {
                let id = CKRecord.ID(recordName: item.record.key, zoneID: zoneID)
                switch results[id] {
                case .success:
                    try await store.acknowledge(key: item.record.key, kind: item.record.kind, revision: item.revision)
                    uploaded += 1
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .serverRecordChanged { mustRetry = true }
                    else { throw error }
                case nil: mustRetry = true
                }
            }
            if mustRetry { break } // Durable outbox retries with fresh server change tags.
        }
        let pending = try await store.pending(limit: 1)
        try await store.setMetadata("cloudLastCheck", value: try JSONEncoder().encode(Date()))
        return CloudSyncReport(downloaded: downloaded, uploaded: uploaded, hasPendingUploads: !pending.isEmpty, waitingForRelatedRecords: try await store.hasStagedDownloads())
    }
    private func verifiedIdentity(store: SQLiteStore) async throws -> String {
        try Task.checkCancellation()
        guard try await container.accountStatus() == .available else { throw CKError(.notAuthenticated) }
        let identity = try await container.userRecordID().recordName
        if let data = try await store.metadata("cloudAccount"), String(data: data, encoding: .utf8) != identity { throw ReplicationError.accountChanged }
        return identity
    }
    private func check(_ epoch: Int) throws { try Task.checkCancellation(); if epoch != generation { throw CancellationError() } }
    private func createZone(store: SQLiteStore, epoch: Int) async throws {
        _ = try await verifiedIdentity(store: store); try check(epoch)
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        try check(epoch)
        try await store.setMetadata("cloudZoneReady", value: Data([1]))
    }
    private struct Page: @unchecked Sendable {
        var changes: [(ReplicaRecord, Data?)] = []
        var deletedKeys: [String] = []
        var token: CKServerChangeToken?
        var more = false
    }
    private final class PageBox: @unchecked Sendable {
        let lock = NSLock()
        var page = Page()
        var failure: (any Error)?
        func change(_ record: CKRecord) {
            lock.lock(); defer { lock.unlock() }
            do { page.changes.append(try CloudKitReplicator.unpack(record)) } catch { failure = error }
        }
        func deleted(_ id: CKRecord.ID) { lock.lock(); defer { lock.unlock() }; page.deletedKeys.append(id.recordName) }
        func result(_ result: Result<(serverChangeToken: CKServerChangeToken, clientChangeTokenData: Data?, moreComing: Bool), any Error>) {
            lock.lock(); defer { lock.unlock() }
            switch result {
            case .success(let r): page.token = r.serverChangeToken; page.more = r.moreComing
            case .failure(let error): failure = error
            }
        }
        func finish(_ result: Result<Void, any Error>) throws -> Page {
            lock.lock(); defer { lock.unlock() }
            try result.get(); if let failure { throw failure }; return page
        }
    }
    private static func unpack(_ record: CKRecord) throws -> (ReplicaRecord, Data?) {
        guard record.recordType == "RoamReadyRecord", let payload = record["payload"] as? Data else { throw ReplicationError.invalidRecord }
        let document = try JSONDecoder().decode(ReplicaRecord.self, from: payload).validated()
        guard document.key == record.recordID.recordName else { throw ReplicationError.invalidRecord }
        let data = try (record["image"] as? CKAsset)?.fileURL.map { try Data(contentsOf: $0) }
        if document.kind == .asset && document.deletion == nil && data == nil { throw ReplicationError.missingAsset }
        return (document, data)
    }
    private func configure(_ operation: CKOperation) { operation.configuration.timeoutIntervalForRequest = 30; operation.configuration.timeoutIntervalForResource = 60 }
    private func fetchPage(previous: CKServerChangeToken?, epoch: Int) async throws -> Page {
        try check(epoch)
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(); config.previousServerChangeToken = previous; config.resultsLimit = 100
        let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: config])
        op.fetchAllChanges = false; configure(op)
        let box = PageBox(); let id = UUID(); operations[id] = op; defer { operations.removeValue(forKey: id) }
        op.recordWasChangedBlock = { _, result in
            switch result { case .success(let record): box.change(record); case .failure(let e): box.lock.lock(); box.failure = e; box.lock.unlock() }
        }
        op.recordWithIDWasDeletedBlock = { id, _ in box.deleted(id) }
        op.recordZoneFetchResultBlock = { _, result in box.result(result) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                op.fetchRecordZoneChangesResultBlock = { result in continuation.resume(with: Result { try box.finish(result) }) }
                database.add(op)
            }
        } onCancel: { op.cancel() }
    }
    private final class RecordsBox: @unchecked Sendable {
        let lock = NSLock()
        var records: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        func set(_ id: CKRecord.ID, _ result: Result<CKRecord, any Error>) { lock.lock(); defer { lock.unlock() }; records[id] = result }
        func finish(_ result: Result<Void, any Error>) throws -> RecordsBox {
            lock.lock(); defer { lock.unlock() }
            // Partial failures are handled per record; global transport errors retry the whole durable batch.
            if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure { throw error }
            return self
        }
    }
    private func fetchRecords(_ ids: [CKRecord.ID], epoch: Int) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        try check(epoch)
        let op = CKFetchRecordsOperation(recordIDs: ids); configure(op)
        let box = RecordsBox(); let id = UUID(); operations[id] = op; defer { operations.removeValue(forKey: id) }
        op.perRecordResultBlock = { id, result in box.set(id, result) }
        let result: RecordsBox = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                op.fetchRecordsResultBlock = { result in continuation.resume(with: Result { try box.finish(result) }) }; database.add(op)
            }
        } onCancel: { op.cancel() }
        return result.records
    }
    private func upload(_ records: [CKRecord], epoch: Int) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        try check(epoch)
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .ifServerRecordUnchanged; op.isAtomic = false; configure(op)
        let box = RecordsBox(); let id = UUID(); operations[id] = op; defer { operations.removeValue(forKey: id) }
        op.perRecordSaveBlock = { id, result in box.set(id, result) }
        let result: RecordsBox = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                op.modifyRecordsResultBlock = { result in continuation.resume(with: Result { try box.finish(result) }) }; database.add(op)
            }
        } onCancel: { op.cancel() }
        try check(epoch)
        return result.records
    }
}
#endif
