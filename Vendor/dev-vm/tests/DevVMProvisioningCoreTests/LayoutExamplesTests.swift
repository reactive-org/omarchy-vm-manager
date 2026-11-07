import Foundation
import Testing
@testable import DevVMProvisioningCore

@Test func bundledLayoutExamplesBindTheOriginalLuaFilesAndIllustrations() throws {
    let examples = try LayoutExamples.catalogue()
    #expect(examples.map(\.id) == [.fourTerminals, .terminalBrowser, .vscodeBrowser, .claudeWorkspace,
                                   .multiWorkspace, .claudeBrowserCodeTerminals, .smallScreen])
    #expect(examples.map { $0.windows.count } == [4, 2, 2, 4, 9, 7, 5])
    #expect(examples.map(\.workspaces) == [1, 1, 1, 1, 3, 3, 4])
    // Each multi-workspace layout puts its windows on the workspaces its docs describe.
    #expect(examples[4].windows.map(\.workspaceNumber) == [1, 1, 2, 2, 2, 2, 3, 3, 3])
    #expect(examples[5].windows.map(\.kind) == [.claude, .browser, .editor, .terminal, .terminal, .terminal, .terminal])
    #expect(examples[6].windows.filter { $0.workspaceNumber == 4 }.allSatisfy { $0.kind == .terminal })
    for example in examples {
        let bytes = try LayoutExamples.source(example.id)
        #expect(digest(bytes) == example.sourceSHA256)
        #expect(String(decoding: bytes, as: UTF8.self).contains("o.exec_on_start"))
        #expect(example.file == example.id.rawValue + ".lua")
        #expect(!example.applications.isEmpty)
    }
    #expect(examples[0].applications == ["Foot"])
    #expect(examples[1].windows[0].width < examples[1].windows[1].width)
    #expect(examples[2].windows[0].width > examples[2].windows[1].width)
    let floating = try #require(examples[3].windows.last)
    #expect(floating.kind == .browser && floating.floating == true)
    #expect(floating.x < examples[3].windows[2].x && floating.x + floating.width > examples[3].windows[2].x)
}
@Test(arguments: ["../file", "four-terminals.lua", "unknown", "FOUR-TERMINALS", "https://example.com/layout.lua"])
func layoutExampleIdentifiersCannotNameFilesOrURLs(_ value: String) throws {
    #expect(LayoutExampleID(rawValue: value) == nil)
    #expect(throws: Error.self) { _ = try JSONDecoder().decode(LayoutExampleID.self, from: JSONEncoder().encode(value)) }
}
