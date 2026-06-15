import { execFile } from "child_process";
import { existsSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

const RESUME_PROMPT =
  "Continue where you left off. Finish the task you were working on. " +
  "If everything is already done, reply DONE and stop.";

function findClaudeBinary(): string | null {
  const candidates = [
    join(homedir(), ".claude/local/claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    join(homedir(), ".local/bin/claude"),
  ];
  return candidates.find((p) => existsSync(p)) ?? null;
}

/// Resume a stalled session headlessly. (Raycast can't drive Conductor's UI,
/// so this is the headless path; the macOS app does the in-Conductor resume.)
export async function resumeHeadless(
  claudeSessionId: string,
  workspacePath: string,
): Promise<string> {
  const bin = findClaudeBinary();
  if (!bin) throw new Error("claude CLI not found — install Claude Code");
  const { stdout } = await execFileAsync(
    bin,
    ["--resume", claudeSessionId, "-p", RESUME_PROMPT, "--permission-mode", "acceptEdits"],
    { cwd: workspacePath, timeout: 60 * 60 * 1000, maxBuffer: 64 * 1024 * 1024 },
  );
  return stdout.trim().slice(-300);
}
