# autoconduct

Auto-resume Conductor sessions that hit Claude usage limits — while you sleep,
without blowing your weekly budget.

## How it works

A launchd agent runs every 10 minutes during your configured sleep window:

1. **Scan** Conductor's session DB (read-only) for sessions stalled on a
   429 "usage limit reached" error.
2. **Check budget** via the official OAuth usage endpoint (same data as
   `/usage` in Claude Code): 5-hour window + weekly window utilization.
3. **Gate** with a budget policy: if weekly utilization is high relative to
   days remaining until reset, don't resume. Plenty of headroom → resume.
4. **Resume** stalled sessions one at a time via headless
   `claude --resume <session-id>`, re-checking the budget between each.

## Install

```bash
python3 -m autoconduct install   # writes launchd plist + default config
python3 -m autoconduct status    # show usage, stalled sessions, decision
python3 -m autoconduct run --once  # single tick (dry-run with --dry-run)
```

## Config

`~/.config/autoconduct/config.json`:

```json
{
  "active_hours": [23, 7],
  "five_hour_ceiling": 85.0,
  "weekly_ceiling": 90.0,
  "max_resumes_per_session": 3,
  "max_sessions_per_night": 10,
  "permission_mode": "acceptEdits",
  "resume_prompt": "Continue where you left off. Finish the task you were working on."
}
```

## Caveats

- Resumed turns run headless; they won't appear in Conductor's chat UI, but
  all file changes/commits land in the workspace (visible in Conductor's
  diff view and git).
- Reads Conductor's DB strictly read-only. Never writes to it.
- **Your Mac must be awake overnight.** launchd's `StartInterval` does not
  wake a sleeping machine. Either keep it plugged in with
  `sudo pmset -c sleep 0`, or schedule wakes:
  `sudo pmset repeat wakeorpoweron MTWRFSU 23:00:00`.
