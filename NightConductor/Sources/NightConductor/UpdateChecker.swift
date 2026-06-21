import Foundation

/// Checks GitHub Releases for a newer version. Unauthenticated and read-only:
/// it sends no user data, just reads the public latest-release tag. Throttled
/// so it can't rate-limit GitHub's API (60 req/hr/IP unauthenticated).
enum UpdateChecker {
    static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/jkkorn/Night-Conductor/releases/latest")!
    static let releasesPage = "https://github.com/jkkorn/Night-Conductor/releases/latest"
    static let minCheckInterval: TimeInterval = 6 * 3600 // at most every 6h (auto)

    struct Release: Equatable {
        let version: String   // normalized, no leading "v"
        let url: String       // release page to open
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Is `latest` a newer semantic version than `current`? Compares numeric
    /// components left to right, tolerating a "v" prefix and missing parts.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { !$0.isNumber })
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Fetch the latest published release, or nil on any failure (offline,
    /// rate-limited, malformed). Never throws — a failed check is a no-op.
    static func fetchLatest() async -> Release? {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let url = (object["html_url"] as? String) ?? releasesPage
        return Release(version: version, url: url)
    }
}
