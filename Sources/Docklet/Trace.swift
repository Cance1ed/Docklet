import Foundation

/// Opt-in diagnostic log, enabled with `DOCKLET_TRACE=1`. Off by default so the release build
/// never touches the filesystem on a hot path.
enum Trace {
    static let isEnabled = ProcessInfo.processInfo.environment["DOCKLET_TRACE"] == "1"
    private static let url = FileManager.default.temporaryDirectory.appendingPathComponent("docklet-trace.log")
    private static let queue = DispatchQueue(label: "com.docklet.trace")

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = String(format: "%.3f %@\n", CFAbsoluteTimeGetCurrent(), message())
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
