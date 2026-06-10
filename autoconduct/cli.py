"""CLI: status / run / install."""

from __future__ import annotations

import argparse
import logging
import sys
from datetime import datetime, timezone

from . import conductor_db, launchd, policy, usage
from .config import load_config, write_default_config
from .daemon import run_tick


def cmd_status(_args) -> int:
    config = load_config()
    now = datetime.now(timezone.utc)
    snapshot = usage.fetch_usage(now)
    decision = policy.should_resume(snapshot, config, now.astimezone())
    stalled = conductor_db.find_stalled_sessions()

    fh, wk = snapshot.five_hour, snapshot.seven_day
    print(f"5-hour window : {fh.utilization:.0f}% (resets {fh.resets_at})")
    print(f"Weekly window : {wk.utilization:.0f}% (resets {wk.resets_at})")
    print(f"Decision      : {'RESUME' if decision.resume else 'HOLD'} — {decision.reason}")
    print(f"Stalled       : {len(stalled)} session(s)")
    for s in stalled:
        print(f"  - {s.title} [{s.session_id[:8]}] @ {s.workspace_path}")
        print(f"    stalled {s.stalled_at:%Y-%m-%d %H:%M} UTC: {s.error_text}")
    return 0


def cmd_run(args) -> int:
    config = load_config()
    if args.once:
        run_tick(config, dry_run=args.dry_run)
        return 0
    print("Continuous mode not needed: install the launchd agent instead.")
    print("  python3 -m autoconduct install")
    return 1


def cmd_install(_args) -> int:
    write_default_config()
    plist_path = launchd.install()
    print(f"Installed LaunchAgent: {plist_path}")
    print("It runs every 10 minutes; outside active hours it exits instantly.")
    return 0


def cmd_uninstall(_args) -> int:
    launchd.uninstall()
    print("LaunchAgent removed.")
    return 0


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parser = argparse.ArgumentParser(prog="autoconduct")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="show usage, stalled sessions, and the decision")
    run_p = sub.add_parser("run", help="execute scheduling tick(s)")
    run_p.add_argument("--once", action="store_true", help="single tick then exit")
    run_p.add_argument("--dry-run", action="store_true", help="don't actually resume")
    sub.add_parser("install", help="install launchd agent + default config")
    sub.add_parser("uninstall", help="remove launchd agent")

    args = parser.parse_args(argv)
    handlers = {
        "status": cmd_status,
        "run": cmd_run,
        "install": cmd_install,
        "uninstall": cmd_uninstall,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
