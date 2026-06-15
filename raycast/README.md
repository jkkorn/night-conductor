# Night Conductor for Raycast

A companion to the [Night Conductor](https://github.com/jkkorn/Night-Conductor)
menu bar app — glance at your Claude usage and resume stalled Conductor
sessions without leaving Raycast.

## Commands

- **Usage & Stalled Sessions** (menu bar) — live 5-hour and weekly Claude
  usage, plus a count of Conductor sessions stalled at the limit.
- **Stalled Sessions** (view) — list every session waiting at the limit
  (labelled `usage limit` vs `rate-limited`) and **Resume Now** any of them.

It reads the same sources as the app: Conductor's local SQLite DB
(read-only, via `sqlite3`) and the official usage endpoint (using the OAuth
token Claude Code keeps in your Keychain).

## Run it

```bash
cd raycast
npm install
npm run dev      # opens in Raycast via `ray develop`
```

## Note

Raycast commands run on demand, so this is a **companion**, not a
replacement: the unattended overnight watching + budget-gated auto-resume
lives in the menu bar app. Raycast gives you the quick glance and manual
resume. Resumes here run headlessly (`claude --resume`); the app does the
in-Conductor resume that keeps the chat in sync.
