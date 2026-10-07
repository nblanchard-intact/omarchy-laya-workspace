#!/usr/bin/env python3
"""Classify a workspace purpose and return the apps to launch.

Pipeline:

  1. purpose -> category via the local Laya server (one choice question,
     fixed taxonomy). Laya's choice head is sharp with few options, so
     nothing else is asked of the model.
  2. category -> apps, deterministically, from lib/app-categories.json.
     The map carries hand-written per-app descriptions; unknown installed
     apps land in "utilities" and are appended after the curated picks.
  3. A ranked pass adds at most one "discovery" app: an installed app whose
     own desktop name scores high on a noul question, used only when the
     curated list is shorter than max-apps.

Outputs JSON on stdout:
  {"purpose", "category", "category_prob", "apps": ["X.desktop"],
   "workspace": "Image Editing"}

Exit codes: 0 ok, 3 laya unreachable/malformed.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import urllib.request

HOME = os.path.expanduser("~")
LAYA_URL = os.environ.get("LAYA_URL", "http://127.0.0.1:8000/v1/systemone")
HERE = os.path.dirname(os.path.abspath(__file__))
BUCKETS_PATH = os.path.join(HERE, "app-categories.json")

DESKTOP_DIRS = [
    "/usr/share/applications",
    os.path.join(HOME, ".local/share/applications"),
]

# Secondary entries that just open another app's new window.
SAME_APP_AS = {
    "google-chrome": "chromium",
    "libreoffice-startcenter": "libreoffice-writer",
    "foot-server": "foot",
    "footclient": "foot",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def laya(state: str, questions: dict, timeout: int = 20) -> dict:
    payload = json.dumps({"state": state[:8000], "questions": questions}).encode()
    req = urllib.request.Request(LAYA_URL, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except Exception as e:
        print(f"laya request failed: {e}", file=sys.stderr)
        sys.exit(3)


def normalize(stem: str) -> str:
    return stem.lower().removesuffix(".desktop")


def installed_apps() -> dict[str, str]:
    """desktop-id (normalized, no .desktop) -> display name, skipping NoDisplay."""
    out: dict[str, str] = {}
    for d in DESKTOP_DIRS:
        for f in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            stem = normalize(os.path.basename(f))
            if stem in out:
                continue
            display = stem
            nodisplay = False
            try:
                with open(f, errors="replace") as fh:
                    for line in fh:
                        if line.startswith("NoDisplay=true") or line.startswith("Hidden=true"):
                            nodisplay = True
                            break
                        if line.startswith("Name="):
                            display = line.split("=", 1)[1].strip()
            except Exception:
                pass
            if not nodisplay:
                out[stem] = display
    return out


def load_buckets() -> dict:
    with open(BUCKETS_PATH) as f:
        return json.load(f)


def bucket_for(stem: str, buckets: dict) -> str:
    b = buckets["categories"]
    for cat, info in b.items():
        if stem in info.get("apps", []):
            return cat
    for cat, alias_list in buckets.get("aliases", {}).items():
        if stem in alias_list:
            return cat
    return "utilities"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--purpose", required=True)
    ap.add_argument("--max-apps", type=int, default=3)
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--discovery-threshold", type=float, default=0.65)
    args = ap.parse_args()

    purpose = args.purpose.strip()
    if not purpose:
        print("empty purpose", file=sys.stderr)
        return 3

    buckets = load_buckets()
    installed = installed_apps()
    cats = {k: v["description"] for k, v in buckets["categories"].items()}

    # ---- 1. purpose -> category
    r1 = laya(purpose, {"category": {
        "type": "choice",
        "instructions": "What is this computer workspace for?",
        "criteria": cats,
    }})
    cat_answer = r1["answers"]["category"]
    category = cat_answer["choice"]
    cat_prob = float(cat_answer["probabilities"][category])

    # ---- 2. curated apps for that category (deterministic)
    curated: list[str] = []
    for stem, _display in sorted(installed.items()):
        if bucket_for(stem, buckets) == category and stem not in SAME_APP_AS:
            curated.append(stem)

    chosen = curated[: args.max_apps]
    apps_meta = {stem: "curated" for stem in chosen}

    # ---- 3. discovery: fill remaining slots with one ranked noul pass over
    # non-curated installed apps (their own display name as the question).
    if len(chosen) < args.max_apps:
        rest = {stem: display for stem, display in sorted(installed.items())
                if stem not in chosen and stem not in SAME_APP_AS
                and bucket_for(stem, buckets) != category}
        if rest:
            state = (f"{purpose}. Multiple applications are typically open "
                     "side by side in such a workspace.")
            questions = {
                f"app::{stem}": {
                    "type": "noul",
                    "instructions": f"Would {display} typically be open in this workspace?",
                }
                for stem, display in rest.items()
            }
            r2 = laya(state, questions)
            scored: list[tuple[float, str]] = []
            for key, ans in r2["answers"].items():
                stem = key.split("::", 1)[1]
                score = float(ans["noul"])
                if score >= args.discovery_threshold:
                    scored.append((score, stem))
            scored.sort(key=lambda t: -t[0])
            for _, stem in scored[: args.max_apps - len(chosen)]:
                chosen.append(stem)
                apps_meta[stem] = "discovered"

    # ---- map normalized stems back to real desktop ids
    real_ids: list[str] = []
    for stem in chosen:
        match = next((s for s in installed if normalize(s) == stem), stem)
        real_ids.append(match + ".desktop")

    print(json.dumps({
        "purpose": purpose,
        "category": category,
        "category_prob": round(cat_prob, 4),
        "apps": real_ids,
        "app_meta": apps_meta,
        "workspace": purpose if len(purpose) <= 32 else purpose[:29].rstrip() + "…",
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
