# 🌙 Night Conductor

**Your [Conductor](https://conductor.build) sessions hit the Claude usage limit at
11pm. Night Conductor resumes them while you sleep — without blowing your
weekly budget.**

A tiny macOS menu bar app. A moon lives in your menu bar. While you sleep, it
watches your stalled Conductor sessions and your live Claude usage, and resumes
work the moment there's budget headroom. You wake up to finished tasks.

## How it works

Every 10 minutes during your sleep window (default 23:00–07:00):

1. **Scan** — reads Conductor's session database (strictly read-only) for
   sessions whose last message is a 429 *"You've hit your usage limit"* error.
2. **Budget check** — queries the official usage endpoint (the same numbers
   `/usage` shows in Claude Code) for your live 5-hour and weekly utilization,
   using the OAuth token Claude Code already keeps in your Keychain.
3. **Gate** — resumes only when it's actually safe:
   - 5-hour window below the ceiling (default 85%)
   - weekly window below the stop line (default 90%)
   - **weekly pacing**: if you've consumed more of your week than the time
     that has elapsed (plus a 15-point margin), it holds. 70% used with five
     days left? It won't make that worse overnight.
   - **morning protection**: you tell it when you're back at your computer
     (default 7:00). It never starts a session within 5 hours of that — a
     6am resume would anchor a usage window that locks *you* out until 11am.
     The night shift stands down at 2:00 so your window is fresh at 7:00.
4. **Resume** — runs `claude --resume` headlessly in each session's workspace,
   one at a time, re-checking the budget after every run. Caps: 3 retries per
   session, 10 resumes per night. If usage can't be determined, it never
   resumes (fail closed).

## Install (the for-dummies path)

Requirements: macOS 14+, [Conductor](https://conductor.build), and
[Claude Code](https://claude.com/claude-code) logged in with a subscription.

```bash
git clone https://github.com/jkkorn/night-conductor.git
cd night-conductor/NightConductor
./build-app.sh
```

Drag `dist/Night Conductor.app` into **Applications** and open it.
That's the whole install. Then:

1. Click the 🌙 in your menu bar.
2. Flip the switch to arm the night watch.
3. In settings (⚙): enable **Launch at login**.
4. First run only: macOS asks to allow Keychain access — click **Always Allow**.

One thing the app can't do for you — your Mac must be awake at night:

```bash
sudo pmset repeat wakeorpoweron MTWRFSU 23:00:00
```

(or keep it plugged in with `sudo pmset -c sleep 0`)

## The interface

- **Two meters** — your live 5-hour window and weekly budget, with reset times.
- **Decision line** — exactly why it will or won't resume right now
  ("Wiggle room: 29% of week used, 1.6 days to reset").
- **Stalled sessions** — every session waiting at the limit, and a
  **Resume now** button that skips the schedule but never the budget gates.
- **Activity log** — what got conducted last night.

## Headless / CLI version

The same logic ships as a zero-dependency Python package for servers and
tinkerers — see [`autoconduct/`](autoconduct/):

```bash
python3 -m autoconduct status     # usage, stalled sessions, decision
python3 -m autoconduct install    # launchd agent, ticks every 10 min
```

## Good to know

- **Read-only by design.** Night Conductor never writes to Conductor's
  database. Resumed turns run headlessly, so they won't appear in Conductor's
  chat UI — but every file change and commit lands in the workspace, visible
  in Conductor's diff view.
- Overnight runs use Claude Code's `acceptEdits` permission mode: edit files
  yes, arbitrary unapproved commands no.
- Your OAuth token is read from the Keychain per-request and never stored or
  logged.
- Not affiliated with [Conductor](https://conductor.build) or Anthropic —
  just built with love by a heavy user.

## License

MIT
