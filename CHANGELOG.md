# Changelog

All notable changes to Night Conductor. Dates are when the release was cut.

## 1.0.8

### Added
- Proof of why the watch did not resume anything. The app already computes a
  live reason every tick (an expired sign-in, stale usage, and so on) but it
  only ever lived on screen in the moment. It is now recorded durably, and the
  Activity panel shows the biggest blocker from the last 24 hours, for example
  "Held 6h 40m: Claude sign-in expired." Silent on a normal night.

## 1.0.7

### Added
- Launch at login is on by default now, so a restart never leaves the watch
  silently not running (turn it off in Settings if you prefer). This was the
  most common reason it looked like nothing happened: the app simply was not up.
- Proof that it is working. The Activity panel now shows, for the last 24 hours,
  whether it is keeping your Mac awake right now and how long it kept it awake,
  alongside how many sessions it resumed.

### Changed
- Honest wording on the nightly wake: it can wake your Mac from sleep, but it
  cannot turn on a Mac that is fully shut down (no app can, especially on Apple
  silicon).

## 1.0.6

### Added
- The Activity panel now shows your durable resume history (what was resumed
  and when), read from the same store as the weekly stat. It previously showed
  only the current session's log, so it looked empty after a relaunch even when
  the watch had been resuming all night. Resumes that landed inside the app
  (chat in sync) are tagged "in app"; the rest ran in the background.
- The version number now shows in the app, in the popover footer.

### Fixed
- Per-session resume cool-down. After a session is resumed it is not retried
  for about ten minutes, so the auto loop can't pile inference onto a session
  that is still rate-limited (for example when a background resume doesn't clear
  the host's stalled flag right away).
- The usage check is now throttled before the first reading too. When you were
  signed out or already rate-limited (so no reading had loaded yet), rapidly
  opening the menu could fire one usage call per open; it is now floored and
  backed off like every other call, so the app cannot add to a rate limit.
- Steadier stall detection. A stalled session is no longer missed because a
  file read landed mid-character or the transcript was very large, and a
  session whose timestamp can't be read is left alone instead of being treated
  as brand new (which could resume something you abandoned days ago).
  Timezone-less timestamps now parse correctly.
- Finding the claude command line tool now times out, so an unusually slow
  shell startup can't stall a resume.

## 1.0.5

### Added
- "Resume around the clock" toggle. When on, the watch resumes whenever there's
  budget (not just the night window) and keeps the Mac awake while armed, so it
  is ready to resume the moment your limit resets, any time of day. Off by
  default; best when you're plugged in.

### Fixed
- "Resume now" stopped after the first session that resumed inside Conductor or
  the Claude app (once Accessibility was granted), so the rest were left stalled.
  A manual resume now goes through the whole list. An auto pass still resumes one
  per tick to spread the night's work.

## 1.0.4

### Added
- A configurable resume pace. A slider in Settings sets how often the night
  watch attempts a resume (5 to 20 minutes, jittered), so you can spread the
  night's work out as much as you like.

## 1.0.3

### Added
- Cool-down before retrying a transient server rate-limit. The app already
  recognized the "Server is temporarily limiting requests (not your usage
  limit)" error; now the auto loop waits 5 minutes before retrying such a
  session, so it never bounces straight back into the same limit.

### Fixed
- The terminal-session scanner could miss an older stalled session when a
  newer, active session existed in the same directory. It now keeps the newest
  STALLED transcript per directory, not merely the newest.
- Floored the rate of usage-endpoint calls so rapid opening of the popover
  while rate-limited cannot fire one request per open.

## 1.0.2

### Added
- Check for updates. The app reads the latest GitHub release on launch and
  shows "Update available" with a download link in Settings, plus a manual
  "Check for updates" button. Unauthenticated and throttled, so it cannot
  rate-limit GitHub.

### Changed
- An expired Claude sign-in is now surfaced ("Open Claude Code or Conductor to
  refresh") instead of silently holding on a stale reading. It never refreshes
  or writes the token, so it cannot disturb Claude Code's own sign-in.
- Removed em dashes from all in-app copy.

## 1.0.1

### Fixed
- The app could hold overnight on a stale usage reading. After a rate-limit
  backoff it kept showing an old "you're maxed" value and refused to resume
  even when the limit had reset. A stale reading now always refreshes.

## 1.0.0

Initial public release. A macOS menu bar app that resumes stalled
Conductor / Claude desktop / terminal sessions while you sleep, gated by your
live 5-hour and weekly usage, with morning protection and per-night caps.
