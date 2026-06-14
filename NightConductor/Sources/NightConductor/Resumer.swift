import Foundation

struct ResumeResult {
    let ok: Bool
    let detail: String
}

/// Thread-safe accumulator for a pipe drained on a background queue.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Resumes a stalled session headlessly via `claude --resume` in the
/// session's workspace directory.
enum Resumer {
    static let timeoutSeconds: TimeInterval = 3600 // one long agentic run, never forever

    /// GUI apps get a minimal PATH, so discover the claude binary the way a
    /// terminal would: common install locations first, then a login shell
    /// (which picks up nvm/asdf setups).
    static func findClaudeBinary() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = output, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    static func resume(
        session: StalledSession,
        claudePath: String,
        config: PolicyConfig
    ) -> ResumeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = [
            "--resume", session.claudeSessionID,
            "-p", config.resumePrompt,
            "--permission-mode", config.permissionMode,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: session.workspacePath)

        // claude is typically a node script; make sure its interpreter is
        // reachable by prepending the binary's own directory to PATH.
        var environment = ProcessInfo.processInfo.environment
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        let basePath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "\(claudeDir):/opt/homebrew/bin:/usr/local/bin:\(basePath)"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ResumeResult(ok: false, detail: "cannot launch claude: \(error.localizedDescription)")
        }

        // Drain BOTH pipes concurrently while the process runs. A long
        // agentic run emits enough stderr to fill the 64KB pipe buffer; if
        // we only read after exit, the child blocks writing and never exits.
        let outBox = OutputBox()
        let errBox = OutputBox()
        let readers = DispatchGroup()
        let queue = DispatchQueue(label: "nightconductor.resume.read", attributes: .concurrent)
        for (pipe, box) in [(stdout, outBox), (stderr, errBox)] {
            readers.enter()
            queue.async {
                box.append(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }

        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            readers.wait() // pipes hit EOF once the child is gone
            return ResumeResult(ok: false, detail: "timed out after 1h")
        }
        readers.wait()

        let combined = (outBox.string + errBox.string).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            return ResumeResult(ok: false, detail: "exit \(process.terminationStatus): \(combined.suffix(200))")
        }
        return ResumeResult(ok: true, detail: String(outBox.string.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))
    }
}
