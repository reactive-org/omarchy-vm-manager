import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private func journalRecord() -> ProvisioningJobRecord {
    let pin = String(repeating: "b", count: 64)
    return ProvisioningJobRecord(jobID: UUID(), vmID: UUID(), sessionID: UUID(), reviewDigest: pin,
        planDigest: pin, inputDigest: pin, engineDigest: pin, dependencyDigest: pin, bindingDigest: pin, mode: .apply)
}
private final class JournalFixture {
    let root: URL
    var directory: URL { root.appendingPathComponent("journal") }
    var file: URL { directory.appendingPathComponent("jobs.json") }
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/provisioning-journal-test-" + UUID().uuidString)
        try PrivateFiles.directory(root, create: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func seed() throws -> ProvisioningJobRecord {
        let store = try ProvisioningJobJournal(directory: directory)
        _ = try store.load()
        let record = journalRecord(); try store.save([record]); return record
    }
}

@Suite("Provisioning private job journal — disposable metadata only") struct ProvisioningJournalTests {
    @Test func atomicPrivateRoundTripAndExclusiveWriter() throws {
        let f = try JournalFixture()
        var store: ProvisioningJobJournal? = try ProvisioningJobJournal(directory: f.directory)
        #expect(try store!.load().isEmpty)
        var record = journalRecord(); try store!.save([record])
        #expect(throws: ProvisioningJobFailure.self) { _ = try ProvisioningJobJournal(directory: f.directory) }
        var info = stat(); #expect(lstat(f.file.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1)
        record.sequence += 1; record.state = .interrupted
        try store!.save([record]); store = nil
        let reopened = try ProvisioningJobJournal(directory: f.directory)
        #expect(try reopened.load() == [record])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: f.directory.path)) == ["jobs.json", ".journal.lock"])
    }
    @Test(arguments: ["malformed", "schema", "field", "duplicate-key", "duplicate-job", "digest", "mode", "symlink", "oversized", "hardlink", "state", "worker"])
    func corruptJournalsArePreserved(kind: String) throws {
        let f = try JournalFixture(); _ = try f.seed()
        let original = try PrivateFiles.read(f.file, maximum: 1024*1024)
        if kind == "mode" { chmod(f.file.path, 0o644) }
        else if kind == "symlink" {
            try FileManager.default.removeItem(at: f.file)
            let target = f.root.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
        } else if kind == "hardlink" {
            #expect(link(f.file.path, f.root.appendingPathComponent("linked").path) == 0)
        } else {
            var root = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var jobs = root["jobs"] as! [[String: Any]]
            switch kind {
            case "malformed": try Data("{".utf8).write(to: f.file)
            case "oversized": try Data(repeating: 32, count: ProvisioningJobJournal.maximumBytes + 1).write(to: f.file)
            case "duplicate-key": try Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8).write(to: f.file)
            default:
                if kind == "schema" { root["schemaVersion"] = 3 }
                if kind == "field" { jobs[0]["privateKey"] = "never-accept" }
                if kind == "duplicate-job" { jobs.append(jobs[0]) }
                if kind == "digest" { jobs[0]["dependencyDigest"] = "unknown" }
                if kind == "state" { jobs[0]["state"] = "cleanupRequired"; jobs[0]["cleanupRequired"] = false }
                if kind == "worker" { jobs[0]["state"] = "failed"; jobs[0]["workerOutstanding"] = true }
                root["jobs"] = jobs
                try JSONSerialization.data(withJSONObject: root).write(to: f.file)
            }
        }
        let before = try Data(contentsOf: f.file)
        let store = try ProvisioningJobJournal(directory: f.directory)
        #expect(throws: ProvisioningJobFailure.journalUnavailable) { _ = try store.load() }
        #expect(try Data(contentsOf: f.file) == before)
    }
    @Test func changedOrRemovedJournalAndReplacedLockCannotBeOverwritten() throws {
        for mode in ["changed", "removed", "lock", "directory"] {
            let f = try JournalFixture(); _ = try f.seed()
            let store = try ProvisioningJobJournal(directory: f.directory)
            let records = try store.load()
            if mode == "changed" {
                var data = try Data(contentsOf: f.file); data.append(32); try data.write(to: f.file)
            } else if mode == "removed" { try FileManager.default.removeItem(at: f.file) }
            else if mode == "lock" {
                let lock = f.directory.appendingPathComponent(".journal.lock")
                try FileManager.default.moveItem(at: lock, to: f.root.appendingPathComponent("old-lock"))
                try Data().write(to: lock); chmod(lock.path, 0o600)
            } else {
                let old = f.root.appendingPathComponent("old-directory")
                try FileManager.default.moveItem(at: f.directory, to: old)
                try PrivateFiles.directory(f.directory, create: true)
                try FileManager.default.moveItem(at: old.appendingPathComponent(".journal.lock"), to: f.directory.appendingPathComponent(".journal.lock"))
                try FileManager.default.copyItem(at: old.appendingPathComponent("jobs.json"), to: f.file)
            }
            let before = try? Data(contentsOf: f.file)
            #expect(throws: ProvisioningJobFailure.journalUnavailable) { try store.save(records) }
            #expect((try? Data(contentsOf: f.file)) == before)
        }
    }
    @Test func limitsAndDuplicateIDsFailBeforePublication() throws {
        let f = try JournalFixture(), store = try ProvisioningJobJournal(directory: f.directory)
        _ = try store.load()
        let records = (0...ProvisioningJobJournal.maximumJobs).map { _ in journalRecord() }
        #expect(throws: ProvisioningJobFailure.journalUnavailable) { try store.save(records) }
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
    }
    @Test func symlinkedDirectoriesAndInsecureLocksAreRejected() throws {
        let f = try JournalFixture(); _ = try f.seed()
        chmod(f.directory.appendingPathComponent(".journal.lock").path, 0o644)
        #expect(throws: ProvisioningJobFailure.self) { _ = try ProvisioningJobJournal(directory: f.directory) }
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.directory)
        #expect(throws: Error.self) { _ = try ProvisioningJobJournal(directory: alias) }
    }
    @Test func legacyRiskIsPreservedWithoutInventingDurableReferences() throws {
        let f = try JournalFixture()
        var record = journalRecord()
        record.state = .cleanupRequired; record.cleanupRequired = true
        let initial = try ProvisioningJobJournal(directory: f.directory)
        _ = try initial.load(); try initial.save([record]); initial.close()
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [String: Any]
        document["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: document).write(to: f.file)
        let store = try ProvisioningJobJournal(directory: f.directory)
        let rows = try store.load()
        #expect(rows == [record] && rows[0].inputArchiveSHA256 == nil && rows[0].workerToken == nil)
        try store.save(rows)
        let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [String: Any]
        #expect(upgraded["schemaVersion"] as? Int == 2)
        store.close()
        #expect(throws: ProvisioningJobFailure.journalUnavailable) { _ = try store.load() }
    }
    @Test func partialDurableReferencesAndLegacyDurableKeysAreRejected() throws {
        let f = try JournalFixture(), store = try ProvisioningJobJournal(directory: f.directory)
        _ = try store.load()
        var record = journalRecord(); record.workerToken = UUID()
        #expect(throws: ProvisioningJobFailure.journalUnavailable) { try store.save([record]) }
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        let legacy = try JournalFixture(); _ = try legacy.seed()
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: legacy.file)) as! [String: Any]
        document["schemaVersion"] = 1
        var rows = document["jobs"] as! [[String: Any]]; rows[0]["workerToken"] = UUID().uuidString; document["jobs"] = rows
        try JSONSerialization.data(withJSONObject: document).write(to: legacy.file)
        let reader = try ProvisioningJobJournal(directory: legacy.directory)
        #expect(throws: ProvisioningJobFailure.journalUnavailable) { _ = try reader.load() }
    }
}
