import AppKit
import MedicBarCore
import ServiceManagement

/// The medic command line tool inside the app, Contents/Helpers/medic.
let bundledCLI = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/medic")

enum Actions {
    /// Files copied out of a downloaded DMG keep the quarantine flag. Once
    /// someone has opened Medic, they trust it, so its own command line tool
    /// should run from Terminal without asking again.
    static func clearHelperQuarantine() {
        removexattr(bundledCLI.path, "com.apple.quarantine", 0)
    }

    /// Runs medic with these arguments in a new Terminal window, through a
    /// .command file, which Terminal opens without asking for automation access.
    static func runInTerminal(_ args: [String]) {
        guard FileManager.default.isExecutableFile(atPath: bundledCLI.path) else {
            return alert("The medic command line tool is missing from Medic.app.", "Download Medic again from the medic releases page.")
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "medic", isDirectory: true)
        // Terminal shows the file name as the window title: "medic clean".
        let script = dir.appendingPathComponent((["medic"] + args).joined(separator: " ") + ".command")
        let command = ([bundledCLI.path] + args).map(shellQuote).joined(separator: " ")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "#!/bin/sh\nclear\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return alert("Cannot start medic in Terminal.", error.localizedDescription)
        }
        NSWorkspace.shared.open(script)
    }

    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }

    // MARK: Command line tool

    static let cli = CommandLineTool(
        bundled: bundledCLI,
        home: FileManager.default.homeDirectoryForCurrentUser,
        shell: ProcessInfo.processInfo.environment["SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "",
        zdotdir: ProcessInfo.processInfo.environment["ZDOTDIR"])

    static func installCLI() {
        let change: CommandLineTool.PathChange
        do {
            change = try cli.install()
        } catch CommandLineTool.Failure.notMedic(let path) {
            return alert("\(tilde(path)) already exists and is not medic.", "Medic left it alone. Move it away and try again.")
        } catch CommandLineTool.Failure.io(let reason) {
            return alert("Cannot install the medic command.", reason)
        } catch {
            return alert("Cannot install the medic command.", error.localizedDescription)
        }
        let note: String
        switch change {
        case .added(let profile): note = "Added ~/.local/bin to PATH in \(tilde(profile))."
        case .alreadyThere(let profile): note = "\(tilde(profile)) already puts ~/.local/bin on PATH."
        case .unknownShell(let line): note = "To run it from any folder, add this line to your shell profile:\n\(line)"
        case .cannotWrite(let profile, let line): note = "To run it from any folder, add this line to \(tilde(profile)):\n\(line)"
        }
        alert("The medic command is installed.", "Open a new Terminal window and run: medic\n\n\(note)", style: .informational)
    }

    // MARK: Open at login, macOS 13 and newer

    static var loginItemSupported: Bool {
        if #available(macOS 13, *) { return true }
        return false
    }

    static var opensAtLogin: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func setOpensAtLogin(_ on: Bool) {
        guard #available(macOS 13, *) else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            alert(on ? "Cannot open Medic at login." : "Cannot stop opening Medic at login.",
                  "\(error.localizedDescription)\n\nYou can change this in System Settings > General > Login Items.")
        }
    }

    // MARK: Helpers

    static func alert(_ message: String, _ info: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = style
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
