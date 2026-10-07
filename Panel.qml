import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The Laya Workspace input dialog: a screen-centered window. Opened by the
// SUPER+CTRL+L hotkey (Service.qml IPC), dismissed with Esc or an outside
// click. Type a purpose, press Enter: the service classifies it and launches
// the matching apps into a new special workspace.
//
// One PanelWindow per screen (Variants on Quickshell.screens), like the
// Omarchy notification service - nested Loaders do not attach layer
// surfaces reliably. The root Item is what the shell's panel loader hosts;
// `opened` is what its isPluginOpen() reads.
Item {
  id: root

  // Injected by the shell's panel loader (used for shell.run/summon/hide).
  property var shell: null

  // ------------------------------------------------------------ lifecycle

  function open() {
    root.visible = true
    root.statusText = ""
    loadPurposes()
    Qt.callLater(function () { inputField.forceActiveFocus() })
  }

  function close() { root.visible = false }

  function toggle() { root.visible ? close() : open() }

  // The shell's isPluginOpen() reads this.
  readonly property bool opened: root.visible

  onVisibleChanged: {
    if (!visible) inputField.text = ""
  }

  // ------------------------------------------------------------ state

  property bool busy: false
  property string statusText: ""

  // ------------------------------------------------------------ window

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: window
      required property var modelData
      screen: modelData
      visible: root.visible
      color: "transparent"
      WlrLayershell.namespace: "laya-workspace"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; bottom: true; left: true; right: true }

      onVisibleChanged: {
        if (!visible) inputField.text = ""
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.close()
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: 520
        height: cardColumn.implicitHeight + Style.space(24) * 2
        radius: Style.cornerRadius
        color: Color.popups.background
        border.width: 1
        border.color: Color.popups.border

        Column {
          id: cardColumn
          anchors.centerIn: parent
          width: parent.width - Style.space(24) * 2
          spacing: Style.spacing.sm

          PanelHero {
            width: parent.width
            title: "Laya Workspace"
            meta: root.busy ? "classifying..." : "type a purpose, press Enter"
          }

          TextField {
            id: inputField
            width: parent.width
            placeholderText: "What is this workspace for? (e.g. Image Editing)"
            enabled: !root.busy
            onAccepted: root.submit()
          }

          Text {
            width: parent.width
            visible: root.statusText !== ""
            text: root.statusText
            color: Color.muted
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Item { width: 1; height: Style.space(2) }

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
                text: (modelData.purpose || modelData) + "  -  " + (modelData.apps || []).length + " apps"
                color: Color.popups.text
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                anchors.fill: parent
                onClicked: {
                  var d = modelData
                  var home = Quickshell.env("HOME")
                  relaunchProc.command = [
                    home + "/.local/share/laya/.venv/bin/python",
                    home + "/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/classify.py",
                    "--purpose", d.purpose, "--launch", "--move-existing"
                  ]
                  relaunchProc.running = true
                  root.close()
                }
              }
            }
          }

          Item { width: 1; height: Style.space(2) }

          Row {
            spacing: Style.spacing.sm

            Button {
              text: "Scan and classify apps"
              onClicked: {
                scanProc.command = [
                  Quickshell.env("HOME") + "/.local/share/laya/.venv/bin/python",
                  Quickshell.env("HOME") + "/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/scan-apps.py"
                ]
                scanProc.running = true
                root.busy = true
              }
            }

            Button {
              text: "Edit classifications"
              onClicked: {
                editProc.command = [
                  Quickshell.env("HOME") + "/.local/share/laya/.venv/bin/python",
                  Quickshell.env("HOME") + "/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/open-editor.py"
                ]
                editProc.running = true
              }
            }

            Button {
              text: "Clear remembered purposes"
              onClicked: {
                clearProc.command = [
                  Quickshell.env("HOME") + "/.local/share/laya/.venv/bin/python",
                  Quickshell.env("HOME") + "/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/clear-cache.py"
                ]
                clearProc.running = true
                root.statusText = "remembered purposes cleared"
                loadPurposes()
              }
            }
          }
        }

        Keys.onEscapePressed: root.close()
        Keys.onReturnPressed: root.submit()
        Keys.onEnterPressed: root.submit()
      }
    }
  }

  // ------------------------------------------------------------ state procs

  Process {
    id: scanProc
    stdout: StdioCollector { id: scanOut; waitForEnd: true }
    onExited: function (code) {
      root.busy = false
      if (code === 0) {
        try {
          var d = JSON.parse(scanOut.text.trim() || "{}")
          root.statusText = "scanned: " + (d.classified || 0) + " apps classified, "
            + (d.skipped || 0) + " already known"
        } catch (e) {}
        loadPurposes()
      } else {
        root.statusText = "scan failed - is the laya server up?"
      }
    }
  }

  Process {
    id: editProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: clearProc
    stdout: StdioCollector { waitForEnd: true }
  }

  property var purposes: []

  function loadPurposes() {
    var home = Quickshell.env("HOME")
    if (!home) return
    purposesProc.command = [
      home + "/.local/share/laya/.venv/bin/python",
      home + "/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/list-purposes.py"
    ]
    purposesProc.running = true
  }

  Process {
    id: purposesProc
    stdout: StdioCollector { id: purposesOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) return
      try {
        root.purposes = JSON.parse(purposesOut.text.trim() || "[]")
      } catch (e) {}
    }
  }

  Process {
    id: relaunchProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // ------------------------------------------------------------ logic

  function submit() {
    if (submitProc.running) return
    var text = inputField.text.trim()
    if (text === "") return
    var home = Quickshell.env("HOME")
    submitProc.command = [
      home + "/.local/share/laya/.venv/bin/python",
      home + "/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/classify.py",
      "--purpose", text,
      "--max-apps", "3",
      "--launch",
      "--move-existing"
    ]
    root.busy = true
    root.statusText = ""
    busyGuard.restart()
    submitProc.running = true
  }

  Timer {
    id: busyGuard
    interval: 45000
    onTriggered: {
      if (root.busy) {
        root.busy = false
        root.statusText = "classification timed out - is the laya server up?"
      }
    }
  }

  Process {
    id: submitProc
    stdout: StdioCollector { id: submitOut; waitForEnd: true }
    onExited: function (code) {
      root.busy = false
      if (code !== 0) {
        root.statusText = "classification failed - is the laya server up?"
        return
      }
      try {
        var d = JSON.parse(submitOut.text.trim())
        root.statusText = "launched " + (d.apps || []).length + " apps into " + d.workspace
        loadPurposes()
        Qt.callLater(function () { root.close() })
      } catch (e) {
        root.statusText = "classification failed"
      }
    }
  }
}
