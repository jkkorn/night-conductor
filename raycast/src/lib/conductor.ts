import { execFile } from "child_process";
import { existsSync, statSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

const DB_PATH = join(
  homedir(),
  "Library/Application Support/com.conductor.app/conductor.db",
);

const MAX_STALL_AGE_MS = 48 * 3600 * 1000;

export type StallKind = "usage_limit" | "transient";

export interface StalledSession {
  sessionId: string;
  claudeSessionId: string;
  title: string;
  workspacePath: string;
  workspaceName: string;
  errorText: string;
  kind: StallKind;
  stalledAt: Date;
}

// Last result message per session, kept only if it's a 429 error — mirrors
// the macOS app's scanner so both surfaces agree on what's "stalled".
const QUERY = `
WITH results AS (
  SELECT session_id, content, created_at,
         ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY created_at DESC, id DESC) AS rn
  FROM session_messages
  WHERE json_valid(content) AND json_extract(content,'$.type')='result'
)
SELECT s.id, s.claude_session_id, s.title, w.workspace_path, r.content, r.created_at
FROM results r
JOIN sessions s ON s.id = r.session_id
JOIN workspaces w ON w.id = s.workspace_id
WHERE r.rn = 1 AND w.state != 'archived' AND s.status != 'working'
  AND json_extract(r.content,'$.is_error') = 1
  AND json_extract(r.content,'$.api_error_status') = 429`;

function classify(text: string): StallKind {
  return /temporarily limiting|not your usage limit/i.test(text)
    ? "transient"
    : "usage_limit";
}

function parseTimestamp(raw: string): Date {
  // Conductor writes ISO with a trailing Z and ms; tolerate a space too.
  const cleaned = raw.replace(" ", "T").replace(/\.\d+/, "");
  return new Date(cleaned.endsWith("Z") ? cleaned : cleaned + "Z");
}

export async function findStalledSessions(): Promise<StalledSession[]> {
  if (!existsSync(DB_PATH)) return [];
  const { stdout } = await execFileAsync(
    "/usr/bin/sqlite3",
    ["-readonly", "-json", DB_PATH, QUERY],
    { maxBuffer: 64 * 1024 * 1024 },
  );
  const rows: Array<Record<string, string>> = stdout.trim() ? JSON.parse(stdout) : [];
  const now = Date.now();
  const out: StalledSession[] = [];
  for (const row of rows) {
    if (!row.claude_session_id || !row.workspace_path) continue;
    let payload: { result?: string };
    try {
      payload = JSON.parse(row.content);
    } catch {
      continue;
    }
    try {
      if (!statSync(row.workspace_path).isDirectory()) continue;
    } catch {
      continue; // workspace removed
    }
    const stalledAt = parseTimestamp(row.created_at);
    if (Number.isNaN(stalledAt.getTime())) continue; // fail closed
    if (now - stalledAt.getTime() > MAX_STALL_AGE_MS) continue;
    const errorText = String(payload.result ?? "");
    out.push({
      sessionId: row.id,
      claudeSessionId: row.claude_session_id,
      title: row.title || "Untitled",
      workspacePath: row.workspace_path,
      workspaceName: row.workspace_path.split("/").pop() ?? "",
      errorText,
      kind: classify(errorText),
      stalledAt,
    });
  }
  return out;
}
