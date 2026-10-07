import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons

// Laya Workspace service.
//
// Owns the SUPER+CTRL+L hotkey (registered at runtime through Hyprland's
// Lua API and re-asserted on every configreloaded — no bindings.lua edits)
// and the classification/launch pipeline behind the panel's text box.
//
// IPC (omarchy-shell laya-workspace <method> ...):
//   open          open the input panel
//   submit <text> classify + launch for the given purpose
//
// Settings live inline on this plugin's entry in shell.json:
//   { "id": "cheapseatsecon.laya-workspace",
//     "maxApps": 3,
//     "appThreshold": 0.5,
//     "workspacePrefix": "laya" }
Item {
  id: service

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "cheapseatsecon.laya-workspace"
  readonly property string configPath: home + "/.config/omarchy/shell.json"
  readonly property string python: home + "/.local/share/laya/.venv/bin/python"
  readonly property string pluginDir: {
    var d = (manifest && manifest.__dir) ? String(manifest.__dir) : ""
    return d || (home + "/.config/omarchy/plugins/" + pluginId)
  }
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/laya-workspace"

  // ------------------------------------------------------------- settings

  property var settings: ({})
  readonly property int maxApps: (settings.maxApps | 0) || 3
  readonly property real appThreshold: settings.appThreshold !== undefined ? Number(settings.appThreshold) : 0.5
  readonly property string workspacePrefix: String(settings.workspacePrefix || "laya")

  function parseSettings(raw) {
    var cfg = null
    try { cfg = JSON.parse(raw || "{}") } catch (e) { return {} }
    var entries = Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (e && String(e.id || "") === service.pluginId) {
        var next = {}
        for (var k in e) next[k] = e[k]
        service.settings = next
        return next
      }
    }
    service.settings = {}
    return {}
  }

  function applySettings(s) {
    if (!s) return
    service.settings = s
  }

  // ------------------------------------------------------------- state

  property bool classifyRunning: false
  property var lastResult: null  // {purpose, workspace, apps: [ids]}
  property bool panelRequested: false

  // -------------------------------------------------- hotkey (hot-apps pattern)

  function luaQuote(value) {
    return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  property var evalQueue: []
  property var cmdQueue: []   // unified ordered queue: {kind: "eval"|"dispatch", arg}

  function runEval(lua) {
    service.cmdQueue = service.cmdQueue.concat([{ kind: "eval", arg: lua }])
    service.runNextCmd()
  }

  Process {
    id: evalProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: service.runNextCmd()
  }

  function runNextCmd() {
    if (evalProc.running || service.cmdQueue.length === 0) return
    var next = service.cmdQueue.shift()
    evalProc.command = next.kind === "eval"
      ? ["hyprctl", "eval", next.arg]
      : ["hyprctl", "dispatch", next.arg]
    evalProc.running = true
  }

  function registerBinds() {
    var combo = "SUPER + CTRL + L"
    var desc = "Laya Workspace: open the workspace purpose box"
    var lua = "hl.unbind(" + luaQuote(combo) + ");"
    lua += "hl.bind(" + luaQuote(combo) + ", hl.dsp.exec_cmd("
      + luaQuote("omarchy-shell shell toggle " + pluginId) + "), { description = "
      + luaQuote(desc) + " });"
    service.runEval(lua)
  }

  // Safety net: Hyprland config reloads re-create static binds; re-register
  // slightly after configreloaded, and poll at low frequency as a net.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name)
      if (name === "configreloaded") rebindTimer.restart()
    }
  }

  Timer {
    id: rebindTimer
    interval: 1500
    onTriggered: service.registerBinds()
  }

  Timer {
    id: bindSafetyTimer
    interval: 60000
    repeat: true
    running: true
    onTriggered: service.registerBinds()
  }

  // ------------------------------------------------------------- IPC

  IpcHandler {
    target: "laya-workspace"

    function open(): string {
      service.panelRequested = true
      if (service.shell && typeof service.shell.summon === "function")
        service.shell.summon(service.pluginId, "{}")
      return "ok"
    }

    function toggle(): string {
      service.panelRequested = true
      if (service.shell && typeof service.shell.toggle === "function") {
        service.shell.toggle(service.pluginId, "{}")
        return "ok"
      }
      return "no-shell"
    }

    function submit(text: string): string {
      service.requestClassify(String(text || ""))
      return "ok"
    }
  }

  // ------------------------------------------------------------- classify

  property string classifyPurpose: ""

  function requestClassify(purpose) {
    // Self-heal: a crashed classify leaves the flag stuck; reset when the
    // process is not actually running.
    if (service.classifyRunning && !classifyProc.running) service.classifyRunning = false
    if (service.classifyRunning || String(purpose).trim() === "") return
    service.classifyRunning = true
    service.classifyPurpose = String(purpose).trim()
    classifyProc.command = [
      service.python,
      service.pluginDir + "/lib/classify.py",
      "--purpose", service.classifyPurpose,
      "--max-apps", String(service.maxApps),
      "--threshold", String(service.appThreshold)
    ]
    classifyProc.running = true
  }

  Process {
    id: classifyProc
    stdout: StdioCollector { id: classifyOut; waitForEnd: true }
    onExited: function (code) {
      service.classifyRunning = false
      if (code !== 0) {
        service.classifyFailed(classifyOut.text)
        return
      }
      try {
        var d = JSON.parse(classifyOut.text.trim())
        service.classifyFinished(d)
      } catch (e) {
        service.classifyFailed(String(e))
      }
    }
  }

  function classifyFailed(err) {
    service.lastError = err
    if (service.shell && typeof service.shell.run === "function")
      service.shell.run("omarchy notification send --app-name 'Laya Workspace' 'Workspace classification failed' '" + String(err).slice(0, 80) + "'")
  }

  property string lastError: ""

  function classifyFinished(d) {
    // d: {purpose, category, category_prob, apps: [desktopId...], workspace}
    service.lastResult = d
    service.launchIntoWorkspace(d.purpose, service.workspaceName(d.purpose), d.apps || [])
    service.savePurpose(d)
    if (service.shell && typeof service.shell.hide === "function")
      service.shell.hide(service.pluginId)
  }

  // ------------------------------------------------------------- launch

  // Hyprland creates a special workspace when a window whose rule points at
  // it maps — the hot-apps mechanism (verified on Hyprland 0.56.2). Plain
  // named workspaces are NOT auto-created by rules, so purposes always use
  // "special:laya-<slug>": apps stay alive and the workspace toggles.
  function slugify(text) {
    var slug = String(text).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    return slug.slice(0, 32) || "workspace"
  }

  function workspaceName(purpose) {
    return "special:laya-" + slugify(purpose)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function registerRule(slug, desktopId) {
    var ruleName = "laya-workspace-" + slug
    var classPattern = String(desktopId).replace(/\.desktop$/i, "")
    var lua = "_G.__layaWorkspaceRules = _G.__layaWorkspaceRules or {}; "
      + "local old = _G.__layaWorkspaceRules[" + luaQuote(ruleName) + "]; "
      + "if old then old:set_enabled(false) end; "
      + "_G.__layaWorkspaceRules[" + luaQuote(ruleName) + "] = hl.window_rule({ name = "
      + luaQuote(ruleName) + ", match = { class = " + luaQuote(classPattern) + " }, "
      + "workspace = " + luaQuote("special:laya-" + slug + " silent") + " })"
    service.runEval(lua)
  }

  function launchIntoWorkspace(purpose, specialWs, desktopIds) {
    var slug = slugify(purpose)
    for (var i = 0; i < desktopIds.length; i++) {
      var id = String(desktopIds[i])
      service.registerRule(slug, id)
      var cmd = "gtk-launch " + shellQuote(id.replace(/\.desktop$/i, ""))
      service.runDispatch("hl.dsp.exec_cmd(" + shellQuote(cmd) + ")")
    }
    service.pendingLaunch = { slug: slug, at: Date.now() }
    learnTimer.restart()
  }

  function runDispatch(cmd) {
    service.cmdQueue = service.cmdQueue.concat([{ kind: "dispatch", arg: cmd }])
    service.runNextCmd()
  }

  Timer {
    id: learnTimer
    interval: 500
    repeat: true
    onTriggered: {
      if (!service.pendingLaunch.slug) { learnTimer.stop(); return }
      if (Date.now() - service.pendingLaunch.at > 12000) {
        service.pendingLaunch = ({})
        learnTimer.stop()
      }
    }
  }
  property var pendingLaunch: ({})
  // ------------------------------------------------------------- purposes

  function savePurpose(d) {
    purposeProc.command = [
      service.python,
      service.pluginDir + "/lib/save-purpose.py",
      JSON.stringify(d)
    ]
    purposeProc.running = true
  }

  Process {
    id: purposeProc
    stdout: StdioCollector { waitForEnd: true }
  }

  FileView {
    id: shellFile
    path: service.configPath
    watchChanges: true
    printErrors: false
    onLoaded: service.applySettings(service.parseSettings(text()))
    onFileChanged: reload()
  }

  Component.onCompleted: {
    shellFile.reload()
    service.registerBinds()
  }
}
