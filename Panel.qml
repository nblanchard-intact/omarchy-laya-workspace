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
// This is a plain PanelWindow rather than a bar-anchored KeyboardPanel: the
// dialog is hotkey-driven and must center on the screen regardless of any
// bar widget. The root Item is what the shell's panel loader hosts; the
// window inside activates on open().
Item {
  id: root

  // ------------------------------------------------------------ lifecycle

  function open() {
    root.statusText = ""
    windowLoader.active = true
    loadPurposes()
    Qt.callLater(function () {
      if (windowLoader.item) windowLoader.item.forceActiveFocus()
    })
  }

  function close() {
    windowLoader.active = false
  }

  function toggle() {
    windowLoader.active ? close() : open()
  }

  // ------------------------------------------------------------ state

  property bool busy: false
  property string statusText: ""

  // ------------------------------------------------------------ window

  Loader {
    id: windowLoader
    active: false

    sourceComponent: PanelWindow {
      id: window
      color: "transparent"

      // Returns true once the field has keyboard focus; the loader's timer
      // retries until then (the layer surface maps asynchronously).
      function focusInput() {
        inputField.forceActiveFocus()
        return inputField.activeFocus
      }

      function submitInput() {
        root.doSubmit(inputField.text)
      }
      WlrLayershell.namespace: "laya-workspace"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; bottom: true; left: true; right: true }

      onVisibleChanged: {
        if (!visible) inputField.text = ""
      }

      // Click-outside dismissal: full-screen surface, click-through except
      // the card, like the Omarchy notification popups.
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

          Item { width: 1; height: Style.space(2) }

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

        Keys.onEscapePressed: root.close()
      }
    }
  }

  // ------------------------------------------------------------ logic

  // The layer surface maps asynchronously: focus the field once the window
  // content is live, retrying a few times.
  Timer {
    id: focusTimer
    interval: 120
    repeat: true
    running: windowLoader.active
    onTriggered: {
      // The item exposes focusInput() (declared in the window component);
      // it no-ops until the surface has mapped and the field exists.
      if (windowLoader.item && typeof windowLoader.item.focusInput === "function") {
        if (windowLoader.item.focusInput()) focusTimer.stop()
      }
    }
  }

  // A wedged classification must not leave the field disabled forever.
  Timer {
    id: busyGuard
    interval: 45000
    onTriggered: {
      if (root.busy && !classifyProcRunning()) {
        root.busy = false
        root.statusText = "classification timed out - is the laya server up?"
      }
    }
  }

  function classifyProcRunning() {
    return submitProc.running
  }

  function submit() {
    if (submitProc.running) return
    if (windowLoader.item && typeof windowLoader.item.submitInput === "function")
      return windowLoader.item.submitInput()
  }

  // Called from the window component: has access to the field.
  function doSubmit(text) {
    if (submitProc.running) return
    var t = String(text || "").trim()
    if (t === "") return
    root.busy = true
    root.statusText = ""
    busyGuard.restart()
    submitProc.running = true
  }

  Process {
    id: relaunchProc
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

  // Classification + launch run through the plugin CLI; the result JSON
  // drives the status line and the window closes itself on success.
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
        Qt.callLater(function () { root.close() })
      } catch (e) {
        root.statusText = "classification failed"
      }
    }
  }
}
