# Omarchy Laya Workspace — Plan

**Concept:** press `SUPER + CTRL + L`, type what a workspace is for ("Image
Editing", "Q3 release crunch", "Social Media"), and the plugin classifies the
purpose with the local Laya server, picks the best-fitting installed apps,
creates a new Hyprland workspace, and launches them into it.

Same family as `omarchy-laya-attention`: a System-1 model deciding cheap,
reversible desktop questions locally.

## Verified feasibility (probes already run against laya-serve 0.3.28)

| Question | Answer |
|---|---|
| Can laya pick an app from a large option set? | Yes, but dilutes: 15 options → winner 0.65 with close runners-up |
| Two-stage (purpose → category → apps) sharper? | Yes: category 0.81, then winner 0.66 with clear separation |
| Can one call multi-select apps? | No — options are softmaxed, one winner per question |
| Multi-select alternative? | **Per-app `noul` questions in one call** ("Would X typically be open side by side in this workspace?") — vscode 0.59 / firefox 0.52 / spotify 0.14 / steam 0.23. Correct 3-way separation, still one forward pass |
| Latency | ~2 laya calls total (category + per-app batch); 33 ms GPU, ~0.5 s CPU. Fine for an interactive popup |
| `SUPER + CTRL + L` free? | Yes — no `SUPER + CTRL` binds and no `L` binds in `bindings.lua` |

## Architecture

New plugin `omarchy-laya-workspace` (id `cheapseatsecon.laya-workspace`),
kinds `service` + `bar-widget` (optional dot) + `panel` (the input box).
Same skeleton as omarchy-laya-attention: manifest.json, Service.qml,
Panel.qml, bin/, lib/.

### 1. Hotkey — the hot-apps pattern

Register `SUPER + CTRL + L` at runtime via the Hyprland Lua shim
(`hl.bind(...)` re-asserted on every `configreloaded`), exactly like
omarchy-hot-apps does — no `bindings.lua` edits, no sudo. The bind dispatches
`omarchy-shell shell toggle cheapseatsecon.laya-workspace`.

### 2. Input popup — Ui.TextField in a KeyboardPanel

Anchored panel beside the bar (clock-panel pattern, `focusTarget` →
`PanelKeyCatcher`), containing `qs.Ui.TextField` focused on open. User types
the purpose, presses **Enter** → classify → launch; **Esc** → close.

### 3. App universe — DesktopEntries, two-stage narrowing

- Enumerate installed apps from `Quickshell.DesktopEntries.applications`
  (same source hot-apps uses; ids + names + icons).
- **Stage 1 (one laya call):** purpose → category from a fixed taxonomy
  (~9 categories: coding, image editing, video, audio, communication,
  writing, gaming, browsing, media). Probe: 0.81 confidence.
- **Stage 2 (one laya call):** the ~40–80 installed apps are pre-bucketed
  into those categories (see below); only the winning category's apps —
  typically 3–8 — go in as per-app `noul` questions in ONE call with the
  "typically open side by side" framing. Take apps scoring ≥ 0.5, cap at 3.

Pre-bucketing matters: laya never sees 80 options. The bucket map ships in
the plugin (`lib/app-categories.json`) keyed by well-known desktop-id
patterns (gimp/krita/inkscape → image editing; code/nvim/sublime → coding;
thunderbird/signal/discord → communication; fallback bucket "other" for
unknown ids — unknowns are appended to stage 2's option set regardless of
category so nothing installed is unreachable).

### 4. Launch — hot-apps' launch machinery

Resolve desktop id → `Toggler.launchCommand`-style `DesktopEntries` exec
line → `hyprctl dispatch hl.dsp.exec_cmd(...)` with a workspace switch.
Learn the real window class after launch (hot-apps' poll-learn approach) so
reopening the purpose later reuses the same workspace. Launches go to a NEW
numbered workspace named after the purpose (e.g. `3: Image Editing`) —
Hyprland workspace names are free-form.

### 5. Memory — purposes are remembered

`~/.config/omarchy/plugins/cheapseatsecon.laya-workspace/purposes.json`:
purpose text → {category, apps[], workspace}. Same purpose typed again
skips laya entirely and relaunches the same set (fast path, deterministic).
The panel lists remembered purposes as one-key candidates.

## UI flow

1. `SUPER + CTRL + L` → panel opens, text field focused
2. Type "Image editing" → Enter
3. ~0.5 s later: workspace `N: Image editing` exists, 2–3 apps launching
   into it, view switches there
4. Re-typing the same purpose (or picking it from the remembered list)
   reuses the workspace

Settings (shell.json plugin entry): `defaultWorkspacePrefix` ("laya"),
`maxApps` (3), `appThreshold` (0.5), plus a `blockedApps` list.

## Risks / open questions

- **Terminal is generic** — "terminal emulator" scores low because laya
  doesn't know app identity from the description. Fix: app criteria always
  say "the <app name> application" + the desktop-id, and the bucket map
  carries hand-written descriptions for common apps.
- **Wrong picks** — always visible before launch: after Enter, the panel
  flips to a confirm row (app chips, clickable to drop one) — no modal, one
  extra Enter.
- **Non-GPU machines** — 2 laya calls ≈ 1 s CPU. Acceptable; show "thinking"
  state in the panel.
- **laya down** — panel shows the hollow state and falls back to a plain
  fuzzy app search (no classification), so the hotkey still works.

## File layout

```
manifest.json                     kinds: service, panel; optional bar-widget
Service.qml                       hotkey, panel, classify+launch pipeline
Panel.qml                         input box, confirm row, remembered list
lib/app-categories.json           category buckets for known desktop ids
lib/classify.py                   laya calls (category + per-app noul)
purposes.json                     remembered purposes (written by service)
```

## Milestones

1. Skeleton + hotkey + text panel that echoes input (no laya)
2. classify.py: two-stage classification against the live server + probe set
3. App bucket map + launch into named workspace + poll-learn
4. Purposes memory + remembered list UI
5. Bar widget dot (optional) + README + validate + publish

Estimated: milestones 1–3 are one session; 4–5 a second.
