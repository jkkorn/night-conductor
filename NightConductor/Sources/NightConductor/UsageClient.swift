import Foundation

enum UsageError: LocalizedError {
    case keychain(String)
    case network(String)
    case rateLimited
    case badPayload

    var errorDescription: String? {
        switch self {
        case .keychain(let m): return "Keychain: \(m)"
        case .network(let m): return "Network: \(m)"
        case .rateLimited: return "Usage endpoint rate-limited (429)"
        case .badPayload: return "Unexpected usage API payload"
        }
    }

    var isRateLimited: Bool { if case .rateLimited = self { return true }; return false }
}

/// Reads the OAuth token Claude Code stores in the macOS Keychain and asks
/// the official usage endpoint for live 5-hour / weekly utilization — the
/// same numbers `/usage` shows. Read-only; the token never touches disk.
enum UsageClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func readOAuthToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw UsageError.keychain("cannot run security: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageError.keychain("no Claude Code credentials found (is Claude Code logged in?)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else {
            throw UsageError.keychain("unexpected credential format")
        }
        return token
    }

    static func parseWindow(_ raw: Any?) -> UsageWindow {
        guard let dict = raw as? [String: Any] else {
            return UsageWindow(utilization: 0, resetsAt: nil)
        }
        let utilization = (dict["utilization"] as? NSNumber)?.doubleValue ?? 0
        let resetsAt = (dict["resets_at"] as? String).flatMap(ISO.parse)
        return UsageWindow(utilization: utilization, resetsAt: resetsAt)
    }

    static func fetchUsage(now: Date = Date()) async throws -> UsageSnapshot {
        let token = try readOAuthToken()
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 429 { throw UsageError.rateLimited }
        guard code == 200 else {
            throw UsageError.network("usage endpoint returned \(code)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badPayload
        }
        return UsageSnapshot(
            fiveHour: parseWindow(object["five_hour"]),
            sevenDay: parseWindow(object["seven_day"]),
            fetchedAt: now
        )
    }
}
