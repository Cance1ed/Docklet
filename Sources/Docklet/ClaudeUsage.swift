import Foundation

/// Claude's 5-hour and 7-day limits as last reported to Claude Code.
struct ClaudeUsage: Equatable {
    let fiveHour: CodexWindow?
    let sevenDay: CodexWindow?
    /// When Claude Code last refreshed its status line with these numbers.
    let capturedAt: Date

    var windows: [CodexWindow] {
        [fiveHour, sevenDay].compactMap { $0 }
    }

    /// The window closest to exhaustion, which is the one worth showing at tile size.
    var headline: CodexWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// Accounts for any window resets that have happened since the snapshot was recorded.
    func current(at now: Date) -> ClaudeUsage {
        ClaudeUsage(
            fiveHour: fiveHour?.current(at: now),
            sevenDay: sevenDay?.current(at: now),
            capturedAt: capturedAt
        )
    }
}

enum ClaudeError: LocalizedError, Equatable {
    case notInstalled
    case noUsageRecorded
    /// Another status line command is configured, so Claude Code never hands Docklet its limits.
    case statusLineOccupied
    /// Claude Code's saved login is missing or expired; running `claude` renews it.
    case loginExpired
    /// The Keychain refused access to the login, or the user declined the prompt.
    case loginUnavailable
    /// Anthropic's usage endpoint did not answer usefully (offline, or the response changed).
    case liveUnavailable

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "未找到 Claude Code"
        case .noUsageRecorded: return "使用一次 Claude Code 后显示额度"
        case .statusLineOccupied: return "Claude Code 已配置其他 statusline，Docklet 无法接收额度"
        case .loginExpired: return "Claude Code 登录已过期，在终端运行一次 claude 即可恢复实时额度"
        case .loginUnavailable: return "无法读取钥匙串中的 Claude Code 登录，实时额度不可用"
        case .liveUnavailable: return "暂时无法获取实时额度"
        }
    }
}

/// Where Docklet keeps the snapshot and the status line shim.
enum ClaudePaths {
    static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var settingsFile: URL {
        claudeDirectory.appendingPathComponent("settings.json")
    }

    /// Kept free of spaces so it can be used verbatim as a shell command.
    static var dockletDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docklet")
    }

    static var snapshotFile: URL {
        dockletDirectory.appendingPathComponent("claude-usage.json")
    }

    static var statusLineScript: URL {
        dockletDirectory.appendingPathComponent("claude-statusline.sh")
    }

    static var isClaudeInstalled: Bool {
        FileManager.default.fileExists(atPath: claudeDirectory.path)
    }
}

/// Reads the snapshot written by `ClaudeStatusLine`.
///
/// Claude Code exposes plan limits to status line commands only, so the numbers are as fresh as
/// the last time Claude Code was in use; `capturedAt` is surfaced alongside them.
enum ClaudeUsageReader {
    static func latest() throws -> ClaudeUsage {
        guard ClaudePaths.isClaudeInstalled else { throw ClaudeError.notInstalled }
        guard let data = try? Data(contentsOf: ClaudePaths.snapshotFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatusLineInstaller.state == .occupied ? ClaudeError.statusLineOccupied : ClaudeError.noUsageRecorded
        }

        let fiveHour = window(from: root["five_hour"], minutes: 300)
        let sevenDay = window(from: root["seven_day"], minutes: 10080)
        guard fiveHour != nil || sevenDay != nil else { throw ClaudeError.noUsageRecorded }

        let captured = (root["captured_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        return ClaudeUsage(fiveHour: fiveHour, sevenDay: sevenDay, capturedAt: captured)
    }

    private static func window(from value: Any?, minutes: Int) -> CodexWindow? {
        guard let dict = value as? [String: Any],
              let used = (dict["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        return CodexWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: ClaudeStatusLine.date(from: dict["resets_at"])
        )
    }
}

/// The status line command Claude Code runs. Records the plan limits it is handed and prints a
/// short line for Claude Code's footer, since installing it replaces the default empty one.
enum ClaudeStatusLine {
    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }

        var parts: [String] = []
        if let model = root["model"] as? [String: Any], let name = model["display_name"] as? String {
            parts.append(name)
        }

        if let limits = root["rate_limits"] as? [String: Any] {
            var snapshot: [String: Any] = ["captured_at": Date().timeIntervalSince1970]
            for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
                guard let window = limits[key] as? [String: Any],
                      let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { continue }
                var entry: [String: Any] = ["used_percentage": used]
                if let resets = date(from: window["resets_at"]) {
                    entry["resets_at"] = resets.timeIntervalSince1970
                }
                snapshot[key] = entry
                parts.append("\(label) \(Int(used.rounded()))%")
            }
            if snapshot.count > 1 { write(snapshot) }
        }

        print(parts.joined(separator: " · "))
    }

    /// Accepts epoch seconds, epoch milliseconds or an ISO 8601 string.
    static func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        guard let string = value as? String else { return nil }
        if let seconds = Double(string) { return date(from: NSNumber(value: seconds)) }
        return Formatters.parseISO8601(string)
    }

    private static func write(_ snapshot: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: ClaudePaths.dockletDirectory, withIntermediateDirectories: true)
        try? data.write(to: ClaudePaths.snapshotFile, options: .atomic)
    }
}

/// Registers Docklet as Claude Code's status line command without disturbing any other setup.
enum ClaudeStatusLineInstaller {
    enum State: Equatable {
        case notInstalled
        case missing
        case installed
        /// The user has their own status line; Docklet leaves it alone.
        case occupied
    }

    private static var command: String { ClaudePaths.statusLineScript.path }

    static var state: State {
        guard ClaudePaths.isClaudeInstalled else { return .notInstalled }
        guard let line = readSettings()?["statusLine"] as? [String: Any] else { return .missing }
        return (line["command"] as? String) == command ? .installed : .occupied
    }

    /// Installs the shim if no status line is configured. Returns the resulting state.
    @discardableResult
    static func installIfPossible() -> State {
        let current = state
        guard current == .missing || current == .installed else { return current }
        writeScript()
        guard current == .missing else { return current }

        var settings = readSettings() ?? [:]
        backupSettings()
        settings["statusLine"] = ["type": "command", "command": command, "padding": 0]
        return writeSettings(settings) ? .installed : .missing
    }

    /// Removes Docklet's status line, leaving anyone else's untouched.
    static func uninstall() {
        guard state == .installed, var settings = readSettings() else { return }
        backupSettings()
        settings.removeValue(forKey: "statusLine")
        writeSettings(settings)
    }

    /// The shim points at whichever Docklet is running, and does nothing once Docklet is gone,
    /// so removing the app never leaves Claude Code with a failing status line.
    private static func writeScript() {
        let executable = Bundle.main.executablePath ?? "/Applications/Docklet.app/Contents/MacOS/Docklet"
        let script = """
        #!/bin/sh
        # Installed by Docklet: records Claude's plan usage for the Dock tile.
        DOCKLET="\(executable)"
        if [ -x "$DOCKLET" ]; then exec "$DOCKLET" --claude-statusline; fi
        cat >/dev/null

        """
        let url = ClaudePaths.statusLineScript
        try? FileManager.default.createDirectory(at: ClaudePaths.dockletDirectory, withIntermediateDirectories: true)
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try? script.write(to: url, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: ClaudePaths.settingsFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @discardableResult
    private static func writeSettings(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return false }
        return (try? data.write(to: ClaudePaths.settingsFile, options: .atomic)) != nil
    }

    private static func backupSettings() {
        let source = ClaudePaths.settingsFile
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let backup = source.appendingPathExtension("docklet-backup")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: source, to: backup)
    }
}
