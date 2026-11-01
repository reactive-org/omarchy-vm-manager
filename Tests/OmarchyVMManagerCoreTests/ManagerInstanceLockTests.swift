import Darwin
import Foundation
import Testing
@testable import OmarchyVMManagerCore

@Suite("Single application instance")
struct ManagerInstanceLockTests {
    @Test("only one owner is admitted and normal exit permits reopening")
    func exclusiveLifetime() throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let directory = fixture.support.appendingPathComponent("application")
        var owner = try ManagerInstanceLock.acquire(in: directory)
        try #require(owner != nil)
        let file = directory.appendingPathComponent(".application.lock")
        var original = stat()
        #expect(lstat(file.path, &original) == 0)
        #expect(original.st_mode & 0o7777 == 0o600)
        #expect(try ManagerInstanceLock.acquire(in: directory) == nil)
        withExtendedLifetime(owner) {}
        owner = nil
        let reopened = try #require(try ManagerInstanceLock.acquire(in: directory))
        var current = stat()
        #expect(lstat(file.path, &current) == 0 && current.st_ino == original.st_ino)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("registry.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("VMs").path))
        withExtendedLifetime(reopened) {}
    }

    @Test("a terminated process leaves no stale ownership")
    func processExit() throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let file = fixture.support.appendingPathComponent(".application.lock")
        let process = Process(), ready = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import fcntl, os, signal, sys
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.write(1, b'1')
        signal.pause()
        """, file.path]
        process.standardOutput = ready
        try process.run()
        try ready.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("1".utf8))
        #expect(try ManagerInstanceLock.acquire(in: fixture.support) == nil)
        process.terminate(); process.waitUntilExit()
        let reopened = try #require(try ManagerInstanceLock.acquire(in: fixture.support))
        withExtendedLifetime(reopened) {}
    }

    @Test("unsafe lock files are refused and preserved", arguments: ["permissions", "symlink", "hardlink"])
    func unsafe(kind: String) throws {
        let fixture = try RegistryFixture(); defer { fixture.cleanup() }
        let target = fixture.support.appendingPathComponent("preserved")
        let file = fixture.support.appendingPathComponent(".application.lock")
        try PrivateFiles.write(Data("preserve".utf8), name: "preserved", in: fixture.support)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        case "hardlink": #expect(link(target.path, file.path) == 0)
        default:
            try PrivateFiles.write(Data("preserve".utf8), name: ".application.lock", in: fixture.support)
            #expect(chmod(file.path, 0o644) == 0)
        }
        #expect(throws: VMFailure.self) { try ManagerInstanceLock.acquire(in: fixture.support) }
        #expect(try Data(contentsOf: target) == Data("preserve".utf8))
        #expect(try Data(contentsOf: file) == Data("preserve".utf8))
    }
}
