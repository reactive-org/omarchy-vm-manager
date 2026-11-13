import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

private final class WorkflowJournalFixture {
    let root = URL(fileURLWithPath: "/private/tmp/workflow-journal-" + UUID().uuidString)
    let journal: ProvisioningWorkflowJournal
    var file: URL { root.appendingPathComponent("workflows.json") }
    init() throws { journal = try .init(directory: root); _ = try journal.load() }
    deinit { journal.close(); try? FileManager.default.removeItem(at: root) }
    func row() -> ProvisioningWorkflowRecord {
        .init(id: UUID(), vmID: UUID(), originalSessionID: UUID(), planDigest: String(repeating: "a", count: 64),
              inputDigest: String(repeating: "b", count: 64), engineDigest: String(repeating: "c", count: 64))
    }
}
@Suite("Strict private workflow journal") struct ProvisioningWorkflowJournalTests {
    @Test func exclusiveWriterAndPrivateAtomicRoundTrip() throws {
        let f = try WorkflowJournalFixture(), row = f.row()
        try f.journal.save([row]); #expect(try f.journal.load() == [row])
        #expect(throws: ProvisioningJobFailure.journalUnavailable) { _ = try ProvisioningWorkflowJournal(directory: f.root) }
        var info = stat(); #expect(lstat(f.file.path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
        f.journal.close()
        let reopened = try ProvisioningWorkflowJournal(directory: f.root); defer { reopened.close() }
        #expect(try reopened.load() == [row])
    }
    @Test(arguments: ["schema", "unknown", "duplicate", "null", "marker", "risk", "rows", "large", "symlink", "hardlink", "lock", "directory"])
    func changedOrInvalidMetadataIsPreservedAndPoisonsWriter(kind: String) throws {
        let f = try WorkflowJournalFixture(); try f.journal.save([f.row()])
        if kind == "directory" {
            let moved = f.root.appendingPathExtension("moved")
            try FileManager.default.moveItem(at: f.root, to: moved)
            defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.moveItem(at: moved, to: f.root) }
            try PrivateFiles.directory(f.root, create: true)
            #expect(throws: ProvisioningJobFailure.journalUnavailable) { _ = try f.journal.load() }
            return
        }
        if kind == "lock" {
            let lock = f.root.appendingPathComponent(".workflow.lock")
            try FileManager.default.moveItem(at: lock, to: f.root.appendingPathComponent("original-lock"))
            try PrivateFiles.write(Data(), name: lock.lastPathComponent, in: f.root, exclusively: true)
        } else if kind == "symlink" || kind == "hardlink" {
            let original = f.root.appendingPathComponent("original")
            try FileManager.default.moveItem(at: f.file, to: original)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: original) }
            else { #expect(link(original.path, f.file.path) == 0) }
        } else {
            var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as! [String: Any]
            var rows = doc["workflows"] as! [[String: Any]]
            switch kind {
            case "schema": doc["schemaVersion"] = 99
            case "unknown": rows[0]["savedPID"] = 123
            case "null": rows[0]["reviewDigest"] = NSNull()
            case "marker": rows[0]["restartID"] = UUID().uuidString
            case "risk": rows[0]["stage"] = "succeeded"; rows[0]["cleanupRequired"] = true
            case "rows": rows = Array(repeating: rows[0], count: 129)
            default: break
            }
            doc["workflows"] = rows
            var data = try JSONSerialization.data(withJSONObject: doc)
            if kind == "duplicate" { data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1").utf8) }
            if kind == "large" { data = Data(repeating: 32, count: 256 * 1024 + 1) }
            try data.write(to: f.file)
        }
        let original = try Data(contentsOf: f.file)
        #expect(throws: ProvisioningJobFailure.journalUnavailable) { _ = try f.journal.load() }
        #expect(throws: ProvisioningJobFailure.journalUnavailable) { try f.journal.save([]) }
        #expect(try Data(contentsOf: f.file) == original)
        // Reopen validates the document itself, independently of the live fingerprint.
        if !["lock", "directory"].contains(kind) {
            f.journal.close()
            let reopened = try ProvisioningWorkflowJournal(directory: f.root); defer { reopened.close() }
            #expect(throws: ProvisioningJobFailure.journalUnavailable) { _ = try reopened.load() }
        }
    }
}
