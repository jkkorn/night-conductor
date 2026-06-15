import { execFile } from "child_process";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

export interface Usage {
  fiveHour: number; // 0..100
  weekly: number;
  fiveHourResetsAt?: string;
  weeklyResetsAt?: string;
}

async function readToken(): Promise<string> {
  const { stdout } = await execFileAsync("/usr/bin/security", [
    "find-generic-password",
    "-s",
    "Claude Code-credentials",
    "-w",
  ]);
  const creds = JSON.parse(stdout) as { claudeAiOauth?: { accessToken?: string } };
  const token = creds.claudeAiOauth?.accessToken;
  if (!token) throw new Error("No Claude credentials found (is Claude Code logged in?)");
  return token;
}

export async function fetchUsage(): Promise<Usage> {
  const token = await readToken();
  const res = await fetch("https://api.anthropic.com/api/oauth/usage", {
    headers: { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
  });
  if (!res.ok) throw new Error(`Usage endpoint returned ${res.status}`);
  const j = (await res.json()) as {
    five_hour?: { utilization?: number; resets_at?: string };
    seven_day?: { utilization?: number; resets_at?: string };
  };
  return {
    fiveHour: j.five_hour?.utilization ?? 0,
    weekly: j.seven_day?.utilization ?? 0,
    fiveHourResetsAt: j.five_hour?.resets_at,
    weeklyResetsAt: j.seven_day?.resets_at,
  };
}

export function usageColor(pct: number): string {
  if (pct < 60) return "#34c759"; // green
  if (pct < 85) return "#ff9500"; // amber
  return "#ff3b30"; // red
}
