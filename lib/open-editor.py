#!/usr/bin/env python3
"""Open the learned app-bucket map in the user's default editor.

Creates the file first if it does not exist, so the editor has something to
edit. The editor opens on the CURRENT Hyprland workspace (a window rule is
registered for it, and already-running editor windows are moved there), so
the file appears next to the dialog instead of on another workspace.

Editor resolution mirrors omarchy-launch-editor: the Omarchy default
(~/.local/state/omarchy/defaults/editor, "code" on standard installs), then
$EDITOR, then a GUI fallback list.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hyprland as hlp

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local/state")), "laya-workspace")
LEARNED = os.path.join(STATE_DIR, "app-buckets.json")
DEFAULTS_EDITOR = os.path.join(HOME, ".local/state/omarchy/defaults/editor")

TERMINAL_EDITORS = {"nvim", "vim", "nano", "micro", "hx", "helix", "fresh"}
GUI_FALLBACKS = ["code", "gedit", "kate", "mousepad"]

SEED = {
    "apps": {},
    "descriptions": {},
    "_note": "Learned app buckets. Format: {category: [desktop-id, ...]}. Entries here override the shipped map in app-categories.json. Delete an entry and rescan to reclassify.",
}


def current_workspace() -> str:
    """The active workspace name, via the shell socket (j/activeworkspace)."""
    raw = hlp.command("j/activeworkspace")
    if raw:
        try:
            return str(json.loads(raw).get("name", "1"))
        except Exception:
            pass
    return "1"


def resolve_editor() -> tuple[str, bool]:
    """Return (editor command, is_terminal). Mirrors omarchy-launch-editor."""
    omarchy_default = ""
    try:
        with open(DEFAULTS_EDITOR) as f:
            omarchy_default = f.read().strip()
    except OSError:
        pass

    candidates = []
    if omarchy_default:
        candidates.append(omarchy_default)
    env_editor = os.environ.get("EDITOR", "")
    if env_editor:
        candidates.append(env_editor)
    candidates += GUI_FALLBACKS

    for cand in candidates:
        name = os.path.basename(cand.split()[0])
        if name in TERMINAL_EDITORS:
            return cand, True
        if cand == "code" and not shutil.which("code"):
            continue
        return cand, False
    return "code", False


def ensure_file() -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    if not os.path.exists(LEARNED):
        with open(LEARNED, "w") as f:
            json.dump(SEED, f, indent=2)


def launch(editor: str, is_terminal: bool, workspace: str) -> None:
    """Launch the editor targeting the current workspace."""
    if is_terminal:
        # Terminal editors: run inside a terminal on this workspace.
        subprocess.run(
            ["hyprctl", "dispatch", "exec",
             "[workspace " + workspace + "] " + editor + " " + LEARNED],
            capture_output=True, timeout=10)
    else:
        # GUI editors: register a one-shot rule so the window maps here,
        # then launch. The editor binary name is the window class hint.
        class_hint = os.path.basename(editor.split()[0])
        ws_name = "[workspace " + workspace + "]"
        hlp.register_workspace_rule("editor-" + class_hint, class_hint, ws_name)
        subprocess.Popen(["uwsm-app", "--", editor, LEARNED],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Already-running editors won't map a new window; move the newest
        # matching one instead.
        hlp.move_windows(class_hint, ws_name)


def main() -> int:
    ensure_file()

    editor, is_terminal = resolve_editor()
    ws = current_workspace()

    if shutil.which("omarchy-launch-editor") and not is_terminal and editor == "code":
        # Standard GUI path: let omarchy-launch-editor place it, then move
        # the resulting window to the current workspace.
        subprocess.Popen(["omarchy-launch-editor", "--inline", LEARNED],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        moved = 0
        import time
        for _ in range(20):
            time.sleep(0.5)
            moved = hlp.move_windows("com.microsoft.vscode", ws)
            if moved:
                break
        if moved:
            print("opened " + LEARNED + " on workspace " + ws)
            return 0

    launch(editor, is_terminal, ws)
    print("opened " + LEARNED + " on workspace " + ws)
    return 0


if __name__ == "__main__":
    sys.exit(main())
