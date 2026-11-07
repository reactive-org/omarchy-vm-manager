#if DEBUG
import AppKit
import DevVMProvisioningCore
import Foundation
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore
import SwiftUI

/// No process runner, Docker client, downloader, catalog or real runtime exists
/// in this fixture. Replies are synthetic metadata, not execution capabilities.
@MainActor private final class FactoryScreenService: FactoryBuildControlling {
    nonisolated let enabled = true
    var rows: [FactoryBuildJob] = []
    var blocked = false
    var starts = 0, cancellations = 0, recoveries = 0
    var pending: FactoryBuildReview?
    let outputBuffer = FactoryBuildOutput()
    func jobs() -> [FactoryBuildJob] { rows }
    func review(name: String, sizeGiB: Int, channel: FactoryChannel) throws -> FactoryBuildReview {
        if blocked { throw FactoryBuildFailure.dockerMissing }
        let value = FactoryBuildReview(id: UUID(), plan: try .init(name: name, sizeGiB: sizeGiB, channel: channel), availableBytes: 100 * 1_073_741_824, context: "synthetic-local")
        pending = value; return value
    }
    func start(reviewID: UUID) throws -> FactoryBuildJob {
        guard let pending, pending.id == reviewID else { throw FactoryBuildFailure.invalidRequest }
        starts += 1
        let job = FactoryBuildJob(id: reviewID, plan: pending.plan, stage: .downloading)
        rows = [job]; self.pending = nil
        outputBuffer.append(Data("Synthetic factory build — no Docker or download\r\n\u{1b}[32mVerified fixture inputs\u{1b}[0m\r\n".utf8))
        return job
    }
    func cancel(_ id: UUID) throws { cancellations += 1; rows[0].stage = .cancelled; rows[0].failure = "cancelled" }
    func recover(_ id: UUID) throws { recoveries += 1; rows[0].stage = .failed; rows[0].failure = "cleanup-verified" }
    func output(_ id: UUID, after sequence: UInt64) -> FactoryBuildOutputPage { outputBuffer.page(after: sequence) }
    func cancelAndWait() -> Bool { true }
    func resumeAfterCancelledQuit() {}
    func advance(_ stage: FactoryBuildStage) { rows[0].stage = stage; outputBuffer.append(Data(("Synthetic stage: " + stage.rawValue + "\r\n").utf8)) }
    func finish() throws {
        rows[0].stage = .succeeded; rows[0].finishedAt = Date()
        let data = try JSONSerialization.data(withJSONObject: ["kind": "custom", "name": rows[0].plan.name, "manifestSHA256": String(repeating: "d", count: 64), "diskSHA256": String(repeating: "e", count: 64)])
        rows[0].factory = try JSONDecoder().decode(FactoryIdentity.self, from: data)
    }
}
@MainActor enum FactoryScreenAcceptance {
    static func run(output: URL) throws {
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == temporary || parent.hasPrefix(temporary + "/"), !FileManager.default.fileExists(atPath: output.path) else { throw AcceptanceFailure.check }
        try PrivateFiles.directory(output, create: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws { guard condition() else { throw AcceptanceFailure.check }; checks.append(label) }
        var captures: [String: [String: Double]] = [:]
        func capture(_ host: SetupScreenAcceptance.Host, _ url: URL, screen: ProvisioningTerminalScreen? = nil) throws {
            try host.capture(url, screen: screen)
            captures[url.lastPathComponent] = ["widthPoints": Double(host.view.bounds.width), "heightPoints": Double(host.view.bounds.height)]
        }
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light", service = FactoryScreenService(), runtime = FakeRuntime()
            let manager = VMManager(runtime: runtime, profiles: [], applicationSupport: output)
            var saved: GuestConfigurationPatch?
            let model = AppModel(isolatedManager: manager, support: output, snapshots: [], service: nil) { config, _ in
                saved = config; return VMProfile(id: UUID(), name: config.name ?? "Fixture")
            }
            model.isolatedFactoryBuildService = service
            var selected: FactoryIdentity?
            let driver = SetupUIAcceptanceDriver()
            model.officialFactorySource = OfficialFactorySource.acceptanceFixture()
            let host = SetupScreenAcceptance.Host(ScrollView { FactoryImagesView(model: model) { selected = $0; model.builtFactoryAvailable($0) }.padding(24) }, driver: driver, width: 1200, height: 960, dark: dark)
            defer { host.window.close() }
            try SetupScreenAcceptance.until { driver.scopes["factory"] != nil }
            try check(driver.state("factory", "stage") == "none", suffix + "-library")
            try check(driver.state("factory", "cardsFit") == "true", suffix + "-library-cards-fit")
            try capture(host, output.appendingPathComponent("factory-library-" + suffix + ".png"))
            // #27: the reported window (about 1,165 pt with the sidebar) leaves
            // about 894 pt for three narrow columns, with two custom factories.
            let narrowDriver = SetupUIAcceptanceDriver()
            let narrow = SetupScreenAcceptance.Host(ScrollView { FactoryImagesView(model: model) { _ in }.padding(24) }, driver: narrowDriver, width: 942, height: 1100, dark: dark)
            defer { narrow.window.close() }
            for digit in ["a", "b"] {
                let data = try JSONSerialization.data(withJSONObject: ["kind": "custom", "name": "Custom fixture " + digit, "manifestSHA256": String(repeating: digit, count: 64), "diskSHA256": String(repeating: "c", count: 64)])
                model.builtFactoryAvailable(try JSONDecoder().decode(FactoryIdentity.self, from: data))
            }
            try SetupScreenAcceptance.until { narrowDriver.state("factory", "cards") == "4" }
            try check(narrowDriver.state("factory", "cardsFit") == "true", suffix + "-narrow-library-cards-fit")
            try check((Int(narrowDriver.state("factory", "minCardWidth")) ?? 0) >= 280, suffix + "-narrow-library-card-width")
            try capture(narrow, output.appendingPathComponent("factory-library-narrow-" + suffix + ".png"))
            narrow.window.close()
            service.blocked = true
            let sheetDriver = SetupUIAcceptanceDriver()
            let sheet = SetupScreenAcceptance.Host(FactoryBuildSheet(builder: model.factoryBuilder), driver: sheetDriver, width: 640, height: 850, dark: dark)
            defer { sheet.window.close() }
            try SetupScreenAcceptance.until { sheetDriver.state("factory-sheet", "error").contains("Docker is not installed") }
            try check(sheetDriver.state("factory-sheet", "ready") == "false", suffix + "-missing-docker-blocks")
            try capture(sheet, output.appendingPathComponent("factory-missing-docker-" + suffix + ".png"))
            service.blocked = false
            try sheetDriver.send("factory-sheet", .name("Reviewed UI foundation"))
            try SetupScreenAcceptance.until { sheetDriver.state("factory-sheet", "ready") == "true" }
            try check(service.starts == 0, suffix + "-readiness-does-not-build")
            try check(sheetDriver.state("factory-sheet", "channel") == "stable", suffix + "-stable-by-default")
            try check(service.pending?.plan.channel == .stable, suffix + "-stable-review")
            try capture(sheet, output.appendingPathComponent("factory-build-sheet-" + suffix + ".png"))
            try sheetDriver.send("factory-sheet", .save)
            try SetupScreenAcceptance.until { driver.state("factory", "stage") == "downloading" }
            try check(service.starts == 1, suffix + "-one-explicit-build")
            try check(driver.state("factory", "follow") == "true", suffix + "-follow-default")
            for stage in [FactoryBuildStage.packages, .image, .verifying, .importing] {
                service.advance(stage)
                try SetupScreenAcceptance.until { driver.state("factory", "stage") == stage.rawValue }
                try check(service.starts == 1, suffix + "-" + stage.rawValue)
            }
            try check(runtime.startRequests.isEmpty, suffix + "-no-vm-start")
            try check(model.factoryBuilder.terminal.search("Synthetic factory build") > 0, suffix + "-actual-terminal-render")
            model.factoryBuilder.terminal.jumpToLatest()
            try capture(host, output.appendingPathComponent("factory-build-running-" + suffix + ".png"), screen: model.factoryBuilder.terminal)
            try service.finish()
            try SetupScreenAcceptance.until { driver.state("factory", "stage") == "succeeded" }
            try capture(host, output.appendingPathComponent("factory-ready-" + suffix + ".png"), screen: model.factoryBuilder.terminal)
            try driver.send("factory", .save)
            try check(selected != nil, suffix + "-use-built-factory")
            let editorDriver = SetupUIAcceptanceDriver()
            let editor = SetupScreenAcceptance.Host(VMEditor(model: model, profile: nil, initialFactory: selected!.selector, saved: { _ in }), driver: editorDriver, width: 640, height: 900, dark: dark)
            defer { editor.window.close() }
            try SetupScreenAcceptance.until { editorDriver.scopes["editor"] != nil }
            try check(editorDriver.state("editor", "factory") == selected!.selector, suffix + "-newvm-factory-handoff")
            try editorDriver.send("editor", .name("Synthetic factory guest"))
            try editorDriver.send("editor", .save)
            try SetupScreenAcceptance.until { saved != nil }
            try check(saved?.factory == selected!.selector, suffix + "-newvm-save-selection")
            try check(runtime.startRequests.isEmpty, suffix + "-newvm-never-launches")
            service.rows[0].stage = .cleanupRequired; service.rows[0].factory = nil
            try SetupScreenAcceptance.until { driver.state("factory", "stage") == "cleanupRequired" }
            try capture(host, output.appendingPathComponent("factory-cleanup-" + suffix + ".png"))
            try driver.send("factory", .inspect)
            try SetupScreenAcceptance.until { service.recoveries == 1 }
            try check(service.starts == 1, suffix + "-cleanup-does-not-rebuild")
        }
        try JSONSerialization.data(withJSONObject: ["checks": checks, "screenshots": captures.count, "captures": captures, "runtimeStarts": 0, "dockerCommands": 0], options: [.sortedKeys]).write(to: output.appendingPathComponent("result.json"))
        print("factory-screen-acceptance: PASS (\(checks.count) checks; \(captures.count) PNGs; fake services only)")
    }
}
#endif
