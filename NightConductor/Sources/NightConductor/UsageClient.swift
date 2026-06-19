import Foundation

enum UsageError: LocalizedError {
    case keychain(String)
    case network(String)
    case rateLimited
    case signInExpired
    case badPayload

    var errorDescription: String? {
        switch self {
        case .keychain(let m): return "Keychain: \(m)"
        case .network(let m): return "Network: \(m)"
        case .rateLimited: return "Usage endpoint rate-limited (429)"
        case .signInExpired: return "Claude sign-in expired"
        case .badPayload: return "Unexpected usage API payload"
        }
    }

    var isRateLimited: Bool { if case .rateLimited = self { return true }; return false }
    var isSignInExpired: Bool { if case .signInExpired = self { return true }; return false }
}

/// Reads the OAuth token Claude Code stores in the macOS Keychain and asks
/// the official usage endpoint for live 5-hour / weekly utilization — the
/// same numbers `/usage` shows. Strictly read-only: it never writes the
/// credential back, so it can't disturb Claude Code's own sign-in.
enum UsageClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct OAuthCredential {
        let token: String
        let expiresAt: Date?
    }

    /// A token is treated as expired a little early (clock-skew buffer) so we
    /// skip a call that's just going to 401, which also spares a needless
    /// request. A nil expiry means "unknown" — let the call itself decide.
    static func isExpired(_ expiresAt: Date?, now: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt.addingTimeInterval(-skew)
    }

    static func readOAuthCredential() throws -> OAuthCredential {
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
        // `expiresAt` is epoch milliseconds (values now are ~1.7e12).
        var expiresAt: Date?
        if let raw = (oauth["expiresAt"] as? NSNumber)?.doubleValue, raw > 0 {
            let seconds = raw > 1e11 ? raw / 1000 : raw
            expiresAt = Date(timeIntervalSince1970: seconds)
        }
        return OAuthCredential(token: token, expiresAt: expiresAt)
    }

    /// Back-compat: just the access token.
    static func readOAuthToken() throws -> String { try readOAuthCredential().token }

    static func parseWindow(_ raw: Any?) -> UsageWindow {
        guard let dict = raw as? [String: Any] else {
            return UsageWindow(utilization: 0, resetsAt: nil)
        }
        let utilization = (dict["utilization"] as? NSNumber)?.doubleValue ?? 0
        let resetsAt = (dict["resets_at"] as? String).flatMap(ISO.parse)
        return UsageWindow(utilization: utilization, resetsAt: resetsAt)
    }

    static func fetchUsage(now: Date = Date()) async throws -> UsageSnapshot {
        let cred = try readOAuthCredential()
        // If the sign-in is already expired, don't fire a call that will just
        // 401. Surface it so the UI can tell the user to refresh, instead of
        // silently holding (and without hammering the endpoint).
        if isExpired(cred.expiresAt, now: now) { throw UsageError.signInExpired }

        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
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
        if code == 401 || code == 403 { throw UsageError.signInExpired } // revoked / clock skew
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
