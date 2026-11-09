import Foundation

/// Codex's weekly/5-hour rate-limit window as reported by OpenAI.
struct CodexWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
    /// True when the recorded window has already reset and these figures are inferred.
    var hasRolledOver = false

    var usedFraction: Double { max(0, min(1, usedPercent / 100)) }

    /// The window as it stands at `now`. The transcript only records usage as of the last Codex
    /// turn, so once its reset time passes the recorded figure is known to be stale: usage is
    /// back at zero and the next reset is a whole number of windows later.
    func current(at now: Date) -> CodexWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        var next = resetsAt
        if windowMinutes > 0 {
            let length = TimeInterval(windowMinutes * 60)
            let elapsed = now.timeIntervalSince(resetsAt)
            next = resetsAt.addingTimeInterval((floor(elapsed / length) + 1) * length)
        }
        return CodexWindow(usedPercent: 0, windowMinutes: windowMinutes, resetsAt: next, hasRolledOver: true)
    }

    /// "每周" / "5 小时" — the window length is the only label OpenAI gives these.
    var windowName: String {
        switch windowMinutes {
        case 0: return "限额"
        case ..<60: return "\(windowMinutes) 分钟"
        case ..<1440:
            let hours = windowMinutes / 60
            return "\(hours) 小时"
        case 10080: return "每周"
        default:
            let days = windowMinutes / 1440
            return "\(days) 天"
        }
    }
}

/// A snapshot of Codex's limits, read from the transcript Codex itself writes on every turn.
struct CodexUsage: Equatable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let planType: String?
    /// When Codex recorded this — the data is only as fresh as your last Codex turn.
    let capturedAt: Date

    /// The window closest to exhaustion, which is the one worth showing at tile size.
    var headline: CodexWindow? {
        [primary, secondary].compactMap { $0 }.max { $0.usedPercent < $1.usedPercent }
    }

    var windows: [CodexWindow] {
        [primary, secondary].compactMap { $0 }
    }

    /// Accounts for any window resets that have happened since the snapshot was recorded.
    func current(at now: Date) -> CodexUsage {
        CodexUsage(
            primary: primary?.current(at: now),
            secondary: secondary?.current(at: now),
            planType: planType,
            capturedAt: capturedAt
        )
    }
}

enum CodexError: LocalizedError, Equatable {
    case notInstalled
    case noUsageRecorded

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "未找到 Codex"
        case .noUsageRecorded: return "暂无 Codex 用量记录"
        }
    }
}

/// Reads Codex's rate limits out of its own session transcripts.
///
/// OpenAI returns these limits as response headers and Codex records them in a `token_count`
/// event on every turn. Reading that local record is exact, free, and needs no credentials —
/// unlike calling the private ChatGPT backend, which sits behind bot protection and would burn
/// quota just to ask how much quota is left. The tradeoff is freshness: the numbers are from your
/// most recent Codex turn, so `capturedAt` is surfaced alongside them.
enum CodexUsageReader {
    private static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: sessionsDirectory.path)
    }

    /// How many of the most recently touched transcripts to inspect.
    private static let filesToScan = 12
    /// Only the tail of each transcript is read; entries are appended, so the newest are at the end.
    private static let tailBytes = 512 * 1024

    static func latest() throws -> CodexUsage {
        guard isInstalled else { throw CodexError.notInstalled }

        var best: CodexUsage?
        let transcripts = recentTranscripts()
        cache.prune(keeping: transcripts.map(\.url))
        for file in transcripts {
            guard let usage = cache.usage(for: file, orRead: lastUsage(in:)) else { continue }
            if best == nil || usage.capturedAt > best!.capturedAt {
                best = usage
            }
        }
        guard let best else { throw CodexError.noUsageRecorded }
        return best
    }

    /// Transcript files ordered by modification time, newest first.
    private static func recentTranscripts() -> [TranscriptStamp] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [TranscriptStamp] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            candidates.append(TranscriptStamp(
                url: url,
                modified: values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0
            ))
        }
        return Array(candidates
            .sorted { $0.modified > $1.modified }
            .prefix(filesToScan))
    }

    /// Remembers what each transcript yielded, so an unchanged file is never re-read. Without it
    /// every poll pulled up to 12 × 512 KB off disk and re-parsed it, though Codex was idle.
    private static let cache = TranscriptCache()

    /// The newest usable rate-limit entry in one transcript, scanning backwards.
    private static func lastUsage(in url: URL) -> CodexUsage? {
        guard let text = tail(of: url) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            let primary = window(from: limits["primary"])
            let secondary = window(from: limits["secondary"])
            // Newer entries can carry a credits-only payload with no windows; keep looking back.
            guard primary != nil || secondary != nil else { continue }

            let timestamp = (root["timestamp"] as? String).flatMap(parseTimestamp) ?? Date.distantPast
            return CodexUsage(
                primary: primary,
                secondary: secondary,
                planType: limits["plan_type"] as? String,
                capturedAt: timestamp
            )
        }
        return nil
    }

    private static func window(from value: Any?) -> CodexWindow? {
        guard let dict = value as? [String: Any],
              let used = dict["used_percent"] as? Double else { return nil }
        let resets = (dict["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return CodexWindow(
            usedPercent: used,
            windowMinutes: (dict["window_minutes"] as? Int) ?? 0,
            resetsAt: resets
        )
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        Formatters.parseISO8601(string)
    }

    /// Reads only the end of a transcript — these files grow to many megabytes.
    private static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Identity of a transcript at one moment: if neither field changed, neither did its contents.
private struct TranscriptStamp {
    let url: URL
    let modified: Date
    let size: Int
}

/// Per-file results keyed by path and stamped with the file's mtime and size.
private final class TranscriptCache: @unchecked Sendable {
    private var entries: [URL: (modified: Date, size: Int, usage: CodexUsage?)] = [:]
    private let lock = NSLock()

    func usage(for file: TranscriptStamp, orRead read: (URL) -> CodexUsage?) -> CodexUsage? {
        lock.lock()
        let cached = entries[file.url]
        lock.unlock()
        if let cached, cached.modified == file.modified, cached.size == file.size {
            return cached.usage
        }
        let usage = read(file.url)
        lock.lock()
        entries[file.url] = (file.modified, file.size, usage)
        lock.unlock()
        return usage
    }

    func prune(keeping urls: [URL]) {
        let keep = Set(urls)
        lock.lock()
        entries = entries.filter { keep.contains($0.key) }
        lock.unlock()
    }
}
