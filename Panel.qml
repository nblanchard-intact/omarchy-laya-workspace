import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Laya Workspace input panel: a text box anchored to the bar. Type what
// the workspace is for and press Enter — the service classifies the purpose,
// creates a named Hyprland workspace, and launches the best-fitting apps.
//
// BarWidget contract: the shell routes open/close/toggle here through the
// service (Service.qml's IpcHandler), and the panel exposes open/close/
// toggle/opened itself.
Panel {
  id: root
  moduleName: "laya-workspace"
  ipcTarget: "laya-workspace"
  manageIpc: false

  property var service: null
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var lookedUp: null
  property int lookups: 0
  readonly property var svc: service || lookedUp

  function findService() {
    if (!service && !lookedUp && shell && typeof shell.serviceFor === "function")
      lookedUp = shell.serviceFor("laya-workspace")
  }

  function open() {
    refresh()
    root.controller.show()
    Qt.callLater(function () { inputField.forceActiveFocus() })
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? close() : open() }

  // ---------------------------------------------------------------- state

  property bool busy: false
  property string purpose: ""
  property string statusText: ""
  property var purposes: []   // remembered: [{purpose, apps, workspace, last_used}]

  function refresh() {
    findService()
    loadPurposes()
  }

  Process {
    id: purposesLoadProc
    stdout: StdioCollector { id: purposesOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) return
      try { root.purposes = JSON.parse(purposesOut.text.trim() || "[]") } catch (e) {}
    }
  }

  function loadPurposes() {
    var home = Quickshell.env("HOME")
    if (!home) return
    purposesLoadProc.command = [
      home + "/.local/share/laya/.venv/bin/python",
      home + "/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/list-purposes.py"
    ]
    purposesLoadProc.running = true
  }

  Timer {
    interval: 500
    repeat: true
    running: panel.open && !root.svc && root.lookups < 20
    onTriggered: { root.lookups++; root.findService() }
  }

  // ---------------------------------------------------------------- view

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      Keys.onEscapePressed: root.close()
      Keys.onReturnPressed: root.submit()
      Keys.onEnterPressed: root.submit()
    }

    Column {
      id: contentColumn
      width: parent.width
      spacing: Style.spacing.sm

      PanelHero {
        width: parent.width
        title: "Laya Workspace"
        meta: {
          if (!root.svc) return "service not loaded"
          return root.busy ? "classifying…" : "type a purpose, press Enter"
        }
      }

      TextField {
        id: inputField
        width: parent.width
        placeholderText: "What is this workspace for? (e.g. Image Editing)"
        enabled: !root.busy
        onAccepted: root.submit()

        Component.onCompleted: {
          // Reflect the service state each open.
        }
      }

      Text {
        width: parent.width
        visible: root.statusText !== ""
        text: root.statusText
        color: Color.muted
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      // Remembered purposes: one row each, click to relaunch.
      Repeater {
        model: root.purposes

        delegate: Item {
          id: purposeRow
          required property var modelData
          width: parent.width
          height: purposeText.implicitHeight + Style.space(4)

          Text {
            id: purposeText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: (modelData.purpose || modelData) + "  ·  " + (modelData.apps || []).length + " apps"
            color: Color.popups.text
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            anchors.fill: parent
            onClicked: {
              var d = modelData
              if (root.svc && typeof root.svc.launchIntoWorkspace === "function")
                root.svc.launchIntoWorkspace(d.purpose, d.workspace || root.svc.workspaceName(d.purpose), d.apps || [])
              root.close()
            }
          }
        }
      }
    }
  }

  function submit() {
    var text = inputField.text.trim()
    if (text === "" || root.busy) return
    root.busy = true
    root.statusText = ""
    if (root.svc && typeof root.svc.requestClassify === "function") {
      root.svc.requestClassify(text)
      // The service closes the panel when the launch fires. Poll for busy
      // falling back to false to re-enable the field on failure.
      waitTimer.restart()
    } else {
      root.busy = false
      root.statusText = "service not loaded"
    }
  }

  Timer {
    id: waitTimer
    interval: 15000
    onTriggered: {
      // Give up waiting: re-enable the box; the service failed silently.
      if (root.busy) {
        root.busy = false
        root.statusText = "classification timed out — is the laya server up?"
      }
    }
  }

  // Keep busy state in sync with the service each time the panel is open.
  Timer {
    interval: 1000
    repeat: true
    running: panel.open
    onTriggered: {
      if (!root.svc) return
      if ("classifyRunning" in root.svc) root.busy = !!root.svc.classifyRunning
      if ("lastError" in root.svc && root.svc.lastError !== "") {
        root.statusText = String(root.svc.lastError)
        root.svc.lastError = ""
      }
    }
  }
}
