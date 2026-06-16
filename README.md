<p align="center">
  <img src="docs/icon.png" width="104" alt="Night Conductor icon">
</p>

<h1 align="center">Night Conductor</h1>

<p align="center">
  <strong>Your <a href="https://conductor.build">Conductor</a> sessions hit the Claude usage limit at 11pm.<br>
  Night Conductor resumes them while you sleep — without blowing your weekly budget.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-0b0b12?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-5.9-f05138?logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-MIT-6a6ae6" alt="MIT License">
  <img src="https://img.shields.io/badge/menu_bar-native-34c759" alt="Native menu bar app">
</p>

<p align="center">
  <img src="docs/day-cycle.gif" width="340" alt="The Night Conductor popover, its header sky shifting from dusk to midnight to dawn">
</p>
<p align="center"><em>A moon lives in your menu bar. The header is a living sky that follows the real clock.</em></p>

---

It's midnight. You're three prompts deep into something good, and Claude stops:
**"You've hit your session limit · resets 1:30am."** You go to bed. The work
just… sits there until morning.

Night Conductor is a tiny macOS menu bar app that watches for exactly that.
While you sleep, it notices your stalled [Conductor](https://conductor.build)
sessions, checks your live Claude usage, and resumes the work the moment
there's budget headroom — pressing Conductor's own **Retry** so the chat stays
in sync. You wake up to finished tasks instead of a paused cursor.

It is deliberately careful with your tokens. During the day **you're at the
helm**; the night watch only takes over on your schedule, and never spends past
the ceilings and pacing limits you set.

## How it works

Every few minutes inside your watch window (default **23:00–07:00**):

1. **Scan** — reads Conductor's session database (strictly read-only) for
   sessions whose last message is a `429` *"You've hit your usage limit"* error.
2. **Check budget** — queries the official usage endpoint (the same numbers
   `/usage` shows in Claude Code) for your live 5-hour and weekly utilization,
   using the OAuth token Claude Code already keeps in your Keychain.
3. **Decide** — resumes only when it's genuinely safe:
   - 5-hour window below the ceiling (default 85%)
   - weekly window below the stop line (default 90%)
   - **weekly pacing** — if you've burned more of your week than the time
     that's elapsed (plus a margin), it holds. 70% used with five days left?
     It won't make that worse overnight.
   - **morning protection** — you say when you're back (default 7:00); it never
     starts a session within 5 hours of that, so a 6am resume can't anchor a
     usage window that locks *you* out until 11am.
4. **Resume** — presses Conductor's **Retry** via the Accessibility API so the
   work continues right inside the chat. Resumes are **spaced out** across the
   night, re-checking budget after each one. Caps: 3 retries per session,
   10 resumes per night. If usage can't be determined, it never resumes
   (fail-closed).

## Install — the for-dummies path

Requires macOS 15+, [Conductor](https://conductor.build), and
[Claude Code](https://claude.com/claude-code) logged in with a subscription.

```bash
git clone https://github.com/jkkorn/Night-Conductor.git
cd Night-Conductor/NightConductor
./build-app.sh
```

Drag `dist/Night Conductor.app` into **Applications** and open it. That's the
whole install. Then:

1. Click the 🌙 in your menu bar.
2. Flip the switch to **arm the night watch**.
3. In settings (⚙): turn on **Launch at login**.
4. First run only: allow Keychain access (**Always Allow**) and grant
   **Accessibility** so it can press Retry inside Conductor.

> **Staying awake.** While the watch is armed and inside its window, Night
> Conductor keeps your Mac awake by itself (a power assertion — no command, no
> password). If your Mac is *fully* asleep before the window starts, open
> settings and tap **Nightly wake** to schedule a firmware wake at your start
> hour.

## The interface

<p align="center">
  <img src="docs/popover.png" width="330" alt="Popover: live meters, the decision line, and stalled sessions">
  &nbsp;&nbsp;
  <img src="docs/settings.png" width="330" alt="Settings: watch hours, morning protection, budget ceilings">
</p>

- **Menu bar** — a moon beside your live 5-hour usage, so you can glance at how
  much room you have without opening anything.
- **Two meters** — your live 5-hour and weekly windows, with reset times.
- **The decision line** — in plain language, exactly what it's doing and why:
  *"You're at the helm — night watch starts at 23:00"* by day, *"Wiggle room:
  29% of week used, 1.6 days to reset"* when it's clear to go.
- **Stalled sessions** — every session waiting at the limit, with a
  **Resume now** that skips the schedule but never the budget gates.
- **Activity log** — what got conducted last night.

## Works across every harness

Stalled sessions from all three show up in one list, badged by source, each
resumed the faithful way:

| Source | Badge | How it resumes |
|--------|-------|----------------|
| Conductor | `Conductor` | presses Conductor's Retry (UI), headless fallback |
| Claude desktop app (Cowork) | `Claude` | presses Claude Desktop's Retry — stays in its sandbox |
| Standalone Claude Code (terminal) | `Terminal` | headless `claude --resume` (these aren't sandboxed, so it's faithful) |

Sessions that show up in more than one place are de-duplicated by session id.

## Auto-resume by day, too

The night window is the default, but stalls happen during work hours:

- **Pin a session** (the ⟳ on each row) — it auto-resumes **around the clock**,
  budget permitting, not just at night.
- **Resume now** — your explicit call; resumes immediately, bypassing the
  schedule and budget gates (only Anthropic's real limit can stop it).

Unpinned sessions still wait for the night window, so a busy day doesn't quietly
drain your weekly budget.

## Morning summary & weekly stats

When the window ends, Night Conductor posts a one-line morning notification
("Resumed 3 sessions while you slept"). The share button renders a card of your
week you can drop straight into a post:

<p align="center">
  <img src="docs/stat-card.png" width="420" alt="Weekly stat card">
</p>

## Raycast extension & CLI

A companion [Raycast](https://raycast.com) extension lives in
[`raycast/`](raycast/) — a menu-bar command for live usage + stalled count, and
a list view to resume stalled sessions. The same logic also ships as a
zero-dependency Python package for servers and tinkerers:

```bash
python3 -m autoconduct status     # usage, stalled sessions, decision
python3 -m autoconduct install    # launchd agent, ticks every 10 min
```

## Good to know

- **Read-only by design.** Night Conductor never writes to Conductor's
  database. Every file change and commit a resumed turn makes lands in the
  workspace, visible in Conductor's diff view.
- Overnight runs use Claude Code's `acceptEdits` permission mode: edit files
  yes, arbitrary unapproved commands no.
- Your OAuth token is read from the Keychain per request and never stored or
  logged.
- Not affiliated with [Conductor](https://conductor.build) or Anthropic — just
  built with love by a heavy user.

## FAQ

**Does the Conductor chat update when it resumes?**
Yes — by default it presses the session's own Retry via the Accessibility API,
so the conversation continues in place. If that ever fails it falls back to a
headless `claude --resume`: the work still lands in the workspace, but the chat
shows a stale error banner.

**I granted Accessibility but it still shows the orange warning.**
If you build the app yourself, each rebuild gets a new ad-hoc signature and
macOS silently ignores the old grant. Run
`tccutil reset Accessibility app.night-conductor` and grant again, or remove +
re-add it in System Settings → Privacy & Security → Accessibility.

**The popover keeps closing by itself.**
A menu bar manager (Ice, Bartender) with auto-rehide will close any open menu
bar popover. Pin Night Conductor to the always-visible section.

## About

Made with ❤️ in Brazil by **[Jonathan Korn](https://www.linkedin.com/in/jkkorn)**.
Built because I love [Conductor](https://conductor.build) and kept hitting my
limits at midnight. If it saved your night,
[buy me a coffee](https://buymeacoffee.com/jkkorn) ☕.

## License

MIT — see [LICENSE](LICENSE).
