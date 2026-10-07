#!/usr/bin/env python3
"""Clear the plugin's cached state: remembered purposes, triage and agent
decision logs, and the triage seen-map. The laya venv is untouched."""

from __future__ import annotations

import os
import sys

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "laya-workspace")
FILES = [
    "purposes.json",
    "triage.jsonl",
    "triage_seen.json",
    "decisions.jsonl",
    "agents.json",
]


def main() -> int:
    removed = []
    for name in FILES:
        path = os.path.join(STATE_DIR, name)
        if os.path.exists(path):
            os.remove(path)
            removed.append(name)
    print("removed: " + (", ".join(removed) if removed else "nothing"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
