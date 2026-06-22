# Changelog

All notable changes to Night Conductor. Dates are when the release was cut.

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
