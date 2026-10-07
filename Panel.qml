import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The Laya Workspace input dialog: a screen-centered window. Opened by the
// SUPER+CTRL+L hotkey via Service.qml IPC, dismissed with Esc or an outside
// click. Type a purpose, press Enter: the service classifies it and launches
// the matching apps into a new special workspace.
//
// A plain PanelWindow - not a bar-anchored KeyboardPanel: the dialog is
// hotkey-driven and centers on the screen regardless of any bar widget.
Item {
  id: root

  // Injected by the shell panel loader.
  property var shell: null

  function open() {
    windowLoader.active = true
    loadPurposes()
    focusTimer.restart()
  }

  function close() {
    windowLoader.active = false
  }

  function toggle() {
    windowLoader.active ? close() : open()
  }

  // The shell isPluginOpen reads this.
  readonly property bool opened: windowLoader.active

  property bool busy: false
  property string statusText: ''
  property var purposes: []

  Loader {
    id: windowLoader
    active: false

    sourceComponent: PanelWindow {
      id: window
      color: "transparent"
      WlrLayershell.namespace: "laya-workspace"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; bottom: true; left: true; right: true }

      function focusInput() {
        inputField.forceActiveFocus()
        return inputField.activeFocus
      }

      function submitInput() {
        root.doSubmit(inputField.text)
      }

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

          Item {
            width: parent.width
            height: Math.max(titleText.implicitHeight, statusText2.implicitHeight)

            Text {
              id: titleText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Laya Workspace"
              color: Color.popups.text
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              id: statusText2
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.busy ? "classifying..." : "ready"
              color: root.busy ? Color.urgent : Color.muted
              font.pixelSize: Style.font.bodySmall
            }
          }

          TextField {
            id: inputField
            width: parent.width
            placeholderText: "What is this workspace for? e.g. Image Editing"
            enabled: !root.busy
            onAccepted: window.submitInput()
          }

          Text {
            width: parent.width
            visible: root.statusText !== ""
            text: root.statusText
            color: Color.muted
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          PanelSeparator {}

          Text {
            width: parent.width
            text: "Remembered workspaces"
            color: Color.muted
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

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
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                onClicked: {
                  var d = modelData
                  var home = Quickshell.env('HOME')
                  relaunchProc.command = [
                    home + '/.local/share/laya/.venv/bin/python',
                    home + '/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/classify.py',
                    '--purpose', d.purpose, '--launch', '--move-existing'
                  ]
                  relaunchProc.running = true
                  root.close()
                }
              }
            }
          }

          Item { width: 1; height: Style.space(2) }

          PanelSeparator {}

          Text {
            width: parent.width
            text: "App classifications"
            color: Color.muted
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Button {
              text: "Scan apps"
              onClicked: {
                scanProc.command = [
                  Quickshell.env('HOME') + '/.local/share/laya/.venv/bin/python',
                  Quickshell.env('HOME') + '/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/scan-apps.py'
                ]
                scanProc.running = true
                root.busy = true
              }
            }

            Button {
              text: "Edit classifications"
              onClicked: {
                editProc.command = [
                  Quickshell.env('HOME') + '/.local/share/laya/.venv/bin/python',
                  Quickshell.env('HOME') + '/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/open-editor.py'
                ]
                editProc.running = true
              }
            }

            Button {
              text: "Clear cache"
              onClicked: {
                clearProc.command = [
                  Quickshell.env('HOME') + '/.local/share/laya/.venv/bin/python',
                  Quickshell.env('HOME') + '/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/clear-cache.py'
                ]
                clearProc.running = true
                root.statusText = 'remembered purposes cleared'
                loadPurposes()
              }
            }
          }
        }

        Keys.onEscapePressed: root.close()
      }
    }
  }

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

  Process {
    id: relaunchProc
    stdout: StdioCollector { waitForEnd: true }
  }

  function loadPurposes() {
    var home = Quickshell.env('HOME')
    if (!home) return
    purposesProc.command = [
      home + '/.local/share/laya/.venv/bin/python',
      home + '/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/list-purposes.py'
    ]
    purposesProc.running = true
  }

  Process {
    id: purposesProc
    stdout: StdioCollector { id: purposesOut; waitForEnd: true }
    onExited: function (code) {
      if (code !== 0) return
      try {
        root.purposes = JSON.parse(purposesOut.text.trim() || '[]')
      } catch (e) {}
    }
  }

  function doSubmit(text) {
    if (submitProc.running) return
    var t = String(text || '').trim()
    if (t === '') return
    var home = Quickshell.env('HOME')
    submitProc.command = [
      home + '/.local/share/laya/.venv/bin/python',
      home + '/.config/omarchy/plugins/cheapseatsecon.laya-workspace/lib/classify.py',
      '--purpose', t,
      '--max-apps', '3',
      '--launch',
      '--move-existing'
    ]
    root.busy = true
    root.statusText = ''
    busyGuard.restart()
    submitProc.running = true
  }

  Timer {
    id: focusTimer
    interval: 120
    repeat: true
    running: windowLoader.active
    onTriggered: {
      if (windowLoader.item && typeof windowLoader.item.focusInput === "function") {
        if (windowLoader.item.focusInput()) focusTimer.stop()
      }
    }
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
