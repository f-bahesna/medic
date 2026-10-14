import Foundation

/// Puts the medic command that ships inside Medic.app on PATH, the way
/// install.sh does: as ~/.local/bin/medic, with the same PATH line in the
/// shell profile, so either install replaces the other cleanly.
public struct CommandLineTool {
    public enum Failure: Error, Equatable {
        case notMedic(String)  // something else already has the name
        case io(String)
    }

    /// What happened to PATH.
    public enum PathChange: Equatable {
        case added(profile: String)
        case alreadyThere(profile: String)
        case unknownShell(line: String)
        case cannotWrite(profile: String, line: String)
    }

    /// install.sh writes exactly this line, and checks for it before adding it.
    public static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""

    public let bundled: URL  // Medic.app/Contents/Helpers/medic
    public let home: URL
    public let shell: String
    public let zdotdir: String?

    public init(bundled: URL, home: URL, shell: String, zdotdir: String?) {
        self.bundled = bundled
        self.home = home
        self.shell = shell
        self.zdotdir = zdotdir
    }

    public var link: URL { home.appendingPathComponent(".local/bin/medic") }

    public var installed: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == bundled.path
    }

    /// Links ~/.local/bin/medic to the app's copy, so it updates with the app.
    public func install() throws -> PathChange {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: link.path),
           attrs[.type] as? FileAttributeType != .typeSymbolicLink, !Self.isMedic(link.path) {
            throw Failure.notMedic(link.path)
        }
        let dir = link.deletingLastPathComponent()
        // Link next to the target and rename over it, so medic is never missing.
        let temp = dir.appendingPathComponent(".medic.new")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: temp)
            try fm.createSymbolicLink(atPath: temp.path, withDestinationPath: bundled.path)
        } catch {
            throw Failure.io(error.localizedDescription)
        }
        guard rename(temp.path, link.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: temp)
            throw Failure.io(reason)
        }
        return addToPath()
    }

    /// The profile a new terminal reads, as install.sh picks it.
    var profile: URL? {
        if shell.hasSuffix("/zsh") {
            return URL(fileURLWithPath: zdotdir ?? home.path).appendingPathComponent(".zshrc")
        }
        if shell.hasSuffix("/bash") {
            return home.appendingPathComponent(".bash_profile")
        }
        return nil
    }

    func addToPath() -> PathChange {
        guard let profile else { return .unknownShell(line: Self.pathLine) }
        let current = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
        if current.contains(".local/bin") { return .alreadyThere(profile: profile.path) }
        let gap = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        let addition = gap + "\n# Added by the medic installer\n\(Self.pathLine)\n"
        guard FileManager.default.fileExists(atPath: profile.path) || FileManager.default.createFile(atPath: profile.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: profile) else {
            return .cannotWrite(profile: profile.path, line: Self.pathLine)
        }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(Data(addition.utf8))
        return .added(profile: profile.path)
    }

    /// Is the file at path medic: the binary, or the script medic was before 0.5?
    static func isMedic(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return data.range(of: Data("github.com/f-bahesna/medic".utf8)) != nil
            || data.range(of: Data("# medic for macOS".utf8)) != nil
    }
}
