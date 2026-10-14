import Foundation
import Testing
@testable import MedicBarCore

// Installs into a throwaway home, never the real one.
private func sandbox() throws -> (CommandLineTool, URL) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("medic-cli-\(UUID().uuidString)")
    let bundled = home.appendingPathComponent("Medic.app/Contents/Helpers/medic")
    try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("binary github.com/f-bahesna/medic".utf8).write(to: bundled)
    return (CommandLineTool(bundled: bundled, home: home, shell: "/bin/zsh", zdotdir: nil), home)
}

private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

@Test func installLinksAndAddsThePathLineOnce() throws {
    let (cli, home) = try sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(!cli.installed)
    let zshrc = home.appendingPathComponent(".zshrc")
    try "alias ll='ls -l'".write(to: zshrc, atomically: true, encoding: .utf8)

    #expect(try cli.install() == .added(profile: zshrc.path))
    #expect(cli.installed)
    #expect(read(zshrc) == "alias ll='ls -l'\n\n# Added by the medic installer\nexport PATH=\"$HOME/.local/bin:$PATH\"\n")

    #expect(try cli.install() == .alreadyThere(profile: zshrc.path))
    #expect(read(zshrc).components(separatedBy: "Added by the medic installer").count == 2)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/bin/.medic.new").path))
}

@Test func installReplacesMedicFromInstallScript() throws {
    let (cli, home) = try sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: cli.link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("an older medic, github.com/f-bahesna/medic".utf8).write(to: cli.link)
    _ = try cli.install()
    #expect(cli.installed)
}

@Test func installLeavesSomethingElseAlone() throws {
    let (cli, home) = try sandbox()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: cli.link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\necho another tool\n".write(to: cli.link, atomically: true, encoding: .utf8)
    #expect(throws: CommandLineTool.Failure.notMedic(cli.link.path)) { try cli.install() }
    #expect(read(cli.link) == "#!/bin/sh\necho another tool\n")
}

@Test func profileFollowsTheShellLikeInstallScript() throws {
    let home = URL(fileURLWithPath: "/Users/me")
    let bundled = URL(fileURLWithPath: "/Applications/Medic.app/Contents/Helpers/medic")
    #expect(CommandLineTool(bundled: bundled, home: home, shell: "/bin/zsh", zdotdir: nil).profile?.path == "/Users/me/.zshrc")
    #expect(CommandLineTool(bundled: bundled, home: home, shell: "/bin/zsh", zdotdir: "/Users/me/.config/zsh").profile?.path == "/Users/me/.config/zsh/.zshrc")
    #expect(CommandLineTool(bundled: bundled, home: home, shell: "/opt/homebrew/bin/bash", zdotdir: nil).profile?.path == "/Users/me/.bash_profile")
    #expect(CommandLineTool(bundled: bundled, home: home, shell: "/opt/homebrew/bin/fish", zdotdir: nil).profile == nil)
}
