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
import subprocess
import sys
import urllib.request

# Deterministic latency: the desktop GPU is shared and fills up; laya's GPU
# path under memory pressure retries then falls back to CPU, making the
# classification time unpredictable. Pin to CPU up front.
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")

HOME = os.path.expanduser("~")
LAYA_URL = os.environ.get("LAYA_URL", "http://127.0.0.1:8000/v1/systemone")
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
BUCKETS_PATH = os.path.join(HERE, "app-categories.json")
import hyprland as hlp

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


import buckets as bk
import keywords as kwmod

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--purpose", required=True)
    ap.add_argument("--max-apps", type=int, default=3)
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--launch", action="store_true")
    ap.add_argument("--move-existing", action="store_true")
    ap.add_argument("--discovery-threshold", type=float, default=0.65)
    args = ap.parse_args()

    purpose = args.purpose.strip()
    if not purpose:
        print("empty purpose", file=sys.stderr)
        return 3

    shipped = bk.load_shipped()
    learned = bk.load_learned()
    installed = bk.installed_apps()
    cats = dict(shipped["taxonomy"])

    # Auto-bucket: any installed app with no bucket at all gets classified
    # here (from its desktop metadata) and persisted to the learned map, so
    # newly installed apps are covered on the next run without re-asking.
    unknowns = [stem for stem in installed
                if bk.resolve(stem, shipped, learned) is None
                and stem not in bk.SAME_APP_AS]
    for stem in unknowns:
        meta = installed[stem]
        text = f"App: {meta['name']}"
        if meta["generic"]:
            text += f"\nType: {meta['generic']}"
        if meta["comment"]:
            text += f"\nDescription: {meta['comment']}"
        if meta["cats"]:
            text += f"\nDesktop categories: {meta['cats'].replace(';', ', ')}"
        r = laya(text, {"category": {
            "type": "choice",
            "instructions": "Which category does this application belong to?",
            "criteria": shipped["taxonomy"],
        }})
        bk.learn(learned, stem, r["answers"]["category"]["choice"])
        learned.setdefault("descriptions", {})
        learned["descriptions"][stem] = f"the {meta['name']} application"
    bk.prune(learned, installed)
    if unknowns:
        learned["apps"] = {k: v for k, v in learned["apps"].items() if v}
        bk.save_learned(learned)

    # ---- 1. purpose -> category
    # Direct match: a purpose that literally names a category ("writing",
    # "image editing") is authoritative and needs no model call.
    category = None
    cat_prob = 1.0
    purpose_lower = purpose.lower()
    words = purpose_lower.split()
    # Only a purpose that IS the category name ("writing") takes the fast
    # path; a descriptive sentence containing the word ("social media and
    # messaging") must go to laya, or "media" would hijack it.
    kw_cat, kw_prob = kwmod.match(purpose_lower)
    if kw_cat is not None:
        category = kw_cat
        cat_prob = kw_prob
    if kw_cat is None and len(words) <= 2:
        for name in sorted(cats, key=len, reverse=True):
            if name in purpose_lower or name in words:
                category = name
                break
    if category is None:
        # Hierarchical classification: laya's choice head is sharp with few
        # options and dilutes at 10 (measured 0.33-0.61 flat). Round 1 picks
        # a broad group (3 options), round 2 the category within it.
        groups = {
            "create": "creating or editing content: code, documents, images, video, audio",
            "consume": "consuming or watching: media, feeds, games",
            "connect": "communicating: chat, email, calls, social apps",
        }
        group_members = {
            "create": ["coding", "image_editing", "writing", "video", "audio"],
            "consume": ["media", "gaming", "browsing"],
            "connect": ["communication", "utilities"],
        }
        r1 = laya(purpose, {"group": {
            "type": "choice",
            "instructions": "What does this workspace involve most?",
            "criteria": groups,
        }})
        group = r1["answers"]["group"]["choice"]
        members = group_members.get(group, ["utilities"])
        member_cats = {name: cats[name] for name in members if name in cats}
        r2 = laya(purpose, {"category": {
            "type": "choice",
            "instructions": "What is this computer workspace for?",
            "criteria": member_cats,
        }})
        cat_answer = r2["answers"]["category"]
        category = cat_answer["choice"]
        cat_prob = float(cat_answer["probabilities"][category])

    # ---- 2. curated apps for that category (deterministic)
    # Below this category confidence the pick is a coin flip; a wrong
    # category's apps (Chrome + calculator for "writing") are worse than a
    # conservative utilities workspace the user can adjust.

    curated: list[str] = []
    for stem, _display in sorted(installed.items()):
        if bk.bucket_for(stem, shipped, learned) == category and stem not in bk.SAME_APP_AS:
            curated.append(stem)

    chosen = curated[: args.max_apps]
    apps_meta = {stem: "curated" for stem in chosen}

    # ---- 3. discovery: fill remaining slots with one ranked noul pass over
    # non-curated installed apps (their own display name as the question).
    if len(chosen) < args.max_apps:
        rest = {stem: display for stem, display in sorted(installed.items())
                if stem not in chosen and stem not in SAME_APP_AS
                and bk.bucket_for(stem, shipped, learned) != category}
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
        match = next((s for s in installed if bk.normalize(s) == stem), stem)
        real_ids.append(match + ".desktop")

    slug = "".join(c if c.isalnum() else "-" for c in purpose.lower()).strip("-")[:32] or "workspace"
    special = "laya-" + slug
    workspace_display = purpose if len(purpose) <= 32 else purpose[:29].rstrip() + "…"

    if args.launch:
        for desk_id in real_ids:
            hlp.register_workspace_rule(slug, desk_id.removesuffix(".desktop"), "special:" + special)
        for desk_id in real_ids:
            # Fire-and-forget: gtk-launch blocks on the startup-notification
            # protocol for already-running single-instance apps, which would
            # hang the whole classification.
            subprocess.Popen(["gtk-launch", desk_id],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if args.move_existing:
            for desk_id in real_ids:
                hlp.move_windows(desk_id.removesuffix(".desktop"), "special:" + special)

    print(json.dumps({
        "purpose": purpose,
        "category": category,
        "category_prob": round(cat_prob, 4),
        "apps": real_ids,
        "app_meta": apps_meta,
        "workspace": "special:" + special if args.launch else workspace_display,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
