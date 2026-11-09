import Foundation
import Security

/// Live Claude plan usage, fetched with the login Claude Code keeps in the Keychain.
///
/// The status line snapshot is only as fresh as the last Claude Code CLI turn, and other Claude
/// clients (the desktop app, the web) never feed it. Asking Anthropic directly with Claude Code's
/// own OAuth token returns the same 5-hour and 7-day figures those clients show.
///
/// Docklet only *reads* the login. It never refreshes it: refreshing rotates the refresh token,
/// and doing that behind Claude Code's back could sign the CLI out. When the token has expired,
/// running `claude` once renews it and live numbers resume.
enum ClaudeLiveUsage {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async throws -> ClaudeUsage {
        let token = try ClaudeLogin.accessToken()

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Docklet", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            // Claude Code may have rotated the token since it was cached.
            ClaudeLogin.forgetCachedToken()
            throw ClaudeError.loginExpired
        }
        guard status == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.liveUnavailable
        }

        let fiveHour = window(from: root["five_hour"], minutes: 300)
        let sevenDay = window(from: root["seven_day"], minutes: 10080)
        guard fiveHour != nil || sevenDay != nil else { throw ClaudeError.liveUnavailable }
        return ClaudeUsage(fiveHour: fiveHour, sevenDay: sevenDay, capturedAt: Date())
    }

    private static func window(from value: Any?, minutes: Int) -> CodexWindow? {
        guard let dict = value as? [String: Any],
              let used = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return CodexWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: ClaudeStatusLine.date(from: dict["resets_at"])
        )
    }
}

/// Reads the OAuth token Claude Code stores under "Claude Code-credentials".
///
/// The token is cached in memory until it expires so the Keychain is not queried on every poll.
enum ClaudeLogin {
    enum Status {
        case missing
        case expired(Date)
        case valid(until: Date)
    }

    private static let service = "Claude Code-credentials"
    private static let lock = NSLock()
    private static var cached: (token: String, expires: Date)?
    /// Set when the user declines the Keychain prompt, so Docklet does not ask again every minute.
    private static var accessDenied = false

    static func accessToken() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached, cached.expires > Date().addingTimeInterval(60) { return cached.token }
        guard !accessDenied else { throw ClaudeError.loginUnavailable }

        let credentials = try readCredentials()
        guard credentials.expires > Date().addingTimeInterval(60) else { throw ClaudeError.loginExpired }
        cached = (credentials.token, credentials.expires)
        return credentials.token
    }

    static func forgetCachedToken() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// For `--diagnose`; never exposes the token itself.
    static var status: Status {
        guard let credentials = try? readCredentials() else { return .missing }
        return credentials.expires > Date() ? .valid(until: credentials.expires) : .expired(credentials.expires)
    }

    private static func readCredentials() throws -> (token: String, expires: Date) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw ClaudeError.loginExpired
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            accessDenied = true
            throw ClaudeError.loginUnavailable
        default:
            throw ClaudeError.loginUnavailable
        }

        guard let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeError.loginExpired
        }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return (token, Date(timeIntervalSince1970: expiresMs / 1000))
    }
}
