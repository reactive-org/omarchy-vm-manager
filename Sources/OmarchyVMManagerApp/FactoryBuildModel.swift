import DevVMProvisioningCore
import Foundation
import SwiftUI
import OmarchyProvisioningTerminalUI
import OmarchyVMManagerCore

@MainActor final class FactoryBuildModel: ObservableObject {
    let service: any FactoryBuildControlling
    let terminal = ProvisioningTerminalScreen()
    @Published var showingBuild = false
    @Published var jobs: [FactoryBuildJob] = []
    @Published var review: FactoryBuildReview?
    @Published var checking = false
    @Published var submitting = false
    @Published var error: String?
    @Published var selectedID: UUID?
    private var generation = UUID()
    private var outputID: UUID?
    private var cursor: UInt64 = 0
    var current: FactoryBuildJob? { jobs.first { $0.id == selectedID } ?? jobs.first { $0.active || $0.cleanupRequired } ?? jobs.first }
    init(service: any FactoryBuildControlling) { self.service = service }
    func check(name: String, size: Int, channel: FactoryChannel = .stable) async {
        let generation = UUID(); self.generation = generation
        checking = true; review = nil; error = nil
        defer { if self.generation == generation { checking = false } }
        do {
            let result = try await service.review(name: name, sizeGiB: size, channel: channel)
            guard generation == self.generation, !Task.isCancelled else { return }
            review = result
        } catch { if generation == self.generation, !Task.isCancelled { self.error = Self.message(error) } }
    }
    func start() async {
        guard let review, !submitting else { return }
        submitting = true; defer { submitting = false }
        do {
            let job = try await service.start(reviewID: review.id)
            jobs.removeAll { $0.id == job.id }; jobs.insert(job, at: 0)
            selectedID = job.id; showingBuild = false; error = nil; self.review = nil
        } catch { self.review = nil; self.error = Self.message(error) }
    }
    func observe() async {
        guard service.enabled else { return }
        while !Task.isCancelled {
            do {
                jobs = try await service.jobs()
                if let job = current {
                    if outputID != job.id { outputID = job.id; cursor = 0; terminal.resetScreen(); terminal.follow = true }
                    let page = try await service.output(job.id, after: cursor)
                    if page.reset { terminal.resetScreen(); terminal.render(Data("[Earlier build output is unavailable.]\r\n".utf8)) }
                    if !page.bytes.isEmpty { terminal.render(page.bytes) }
                    cursor = page.sequence
                }
            } catch { self.error = Self.message(error) }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }
    func cancel() async {
        guard let job = current else { return }
        do { try await service.cancel(job.id) } catch { self.error = Self.message(error) }
    }
    func recover() async {
        guard let job = current, !submitting else { return }
        submitting = true; defer { submitting = false }
        do { try await service.recover(job.id); error = nil } catch { self.error = Self.message(error) }
    }
    /// Move finished builds' retained files to Trash, one job at a time.
    func remove(_ ids: [UUID]) async {
        guard !submitting else { return }
        submitting = true; defer { submitting = false }
        do {
            for id in ids { try await service.remove(id) }
            if let selectedID, ids.contains(selectedID) { self.selectedID = nil }
            jobs = try await service.jobs(); error = nil
        } catch { self.error = Self.message(error) }
    }
    static func message(_ error: any Error) -> String {
        if let failure = error as? FactoryBuildFailure { return failure.explanation }
        if let failure = error as? VMFailure { return failure.message }
        return "Readiness could not be confirmed. Check the verified runtime, Docker and available disk space."
    }
    static func title(_ job: FactoryBuildJob) -> String {
        switch job.stage {
        case .preparing: "Preparing reviewed inputs"
        case .downloading: "Downloading build inputs"
        case .packages: "Preparing the Linux build environment"
        case .image: "Building the factory image"
        case .verifying: "Checking the sealed image"
        case .importing: "Adding to the factory library"
        case .succeeded: "Your factory is ready"
        case .cancelled: "Build cancelled"
        case .failed: "Build could not finish"
        case .cleanupRequired: "Build cleanup needs attention"
        }
    }
}
