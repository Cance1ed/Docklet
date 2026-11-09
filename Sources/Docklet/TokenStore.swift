import Foundation
import Security

/// Resolves the GitHub OAuth token used to query Copilot quota.
/// Lookup order: Docklet keychain item -> environment -> `gh auth token` -> gh hosts.yml.
enum TokenStore {
    static let keychainService = "com.docklet.github-token"
    static let keychainAccount = "default"

    struct ResolvedToken {
        let value: String
        let source: String
    }

    static func resolve() -> ResolvedToken? {
        if let t = readKeychain(), !t.isEmpty {
            return ResolvedToken(value: t, source: "Keychain")
        }
        for key in ["DOCKLET_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"] {
            if let t = ProcessInfo.processInfo.environment[key], !t.isEmpty {
                return ResolvedToken(value: t, source: key)
            }
        }
        if let t = readFromGHCLI(), !t.isEmpty {
            return ResolvedToken(value: t, source: "gh CLI")
        }
        if let t = readFromHostsFile(), !t.isEmpty {
            return ResolvedToken(value: t, source: "gh hosts.yml")
        }
        return nil
    }

    // MARK: - Keychain

    static func saveKeychain(_ token: String) {
        deleteKeychain()
        guard !token.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(token.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - gh CLI

    private static func ghExecutableCandidates() -> [String] {
        var paths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]
        let caches = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: caches.path) {
            for entry in entries where entry.hasPrefix("copilot-desktop-gh-") {
                paths.append(caches.appendingPathComponent("\(entry)/gh").path)
            }
        }
        return paths.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func readFromGHCLI() -> String? {
        for path in ghExecutableCandidates() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["auth", "token"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { continue }
                let token = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - hosts.yml

    private static func readFromHostsFile() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gh/hosts.yml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("oauth_token:") else { continue }
            let value = trimmed.dropFirst("oauth_token:".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }
}
