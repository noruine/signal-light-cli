import Foundation
import Testing

@testable import SignalLightCLICore

@Suite("Source stamp")
struct SourceStampTests {
    @Test("A resolved dependency change invalidates the source stamp")
    func resolvedDependenciesAreIncluded() throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let sources = repository.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        try Data("// package".utf8).write(to: repository.appendingPathComponent("Package.swift"))
        try Data("build:".utf8).write(to: repository.appendingPathComponent("Makefile"))
        try Data("main".utf8).write(to: sources.appendingPathComponent("main.swift"))
        let resolvedDependencies = repository.appendingPathComponent("Package.resolved")
        try Data("dependency version 1".utf8).write(to: resolvedDependencies)
        let originalStamp = try #require(SourceStamp.compute(repoRoot: repository))

        try Data("dependency version 2".utf8).write(to: resolvedDependencies)
        let updatedStamp = try #require(SourceStamp.compute(repoRoot: repository))

        #expect(originalStamp != updatedStamp)
    }
}
