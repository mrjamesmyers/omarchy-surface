import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Surface tablet controls: a bar icon plus a popup panel.
//
// A tablet has no keyboard to press a shortcut on, so everything here has to be
// reachable by touch. The bar icon alone was not enough - "why is my
// touchscreen dead" and "reconnect the keyboard" both need somewhere to live,
// and neither belongs on a right-click nobody will discover.
//
//   left click   open the panel
//   right click  toggle the on-screen keyboard without opening anything
//
// All state comes from `surface-status` rather than being cached here, because
// wvkbd --auto shows and hides the keyboard on its own when a text field takes
// focus. A locally held flag drifts out of sync and inverts the toggles.
Panel {
  id: root
  moduleName: "surface.tablet"
  ipcTarget: "surface.tablet"

  property var st: ({})

  readonly property bool oskVisible: st.osk === "visible"
  readonly property bool rotationLocked: st.rotate === "locked"
  readonly property string touchState: st.touch || "unknown"
  readonly property bool touchOk: touchState === "ok"
  readonly property int btTotal: parseInt(st.bt_total || "0")
  readonly property int btConnected: parseInt(st.bt_connected || "0")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Rotation lock wins the bar icon when engaged: a screen that refuses to
  // rotate with nothing on screen to explain it is the more confusing state.
  // A broken touchscreen outranks both - that is the one worth interrupting for.
  readonly property string barIcon: {
    if (!touchOk && touchState !== "unknown") return "󰅚"
    if (rotationLocked) return "󰑙"
    return oskVisible ? "󰌌" : "󰥻"
  }

  function parseStatus(text) {
    var out = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!line) continue
      var eq = line.indexOf("=")          // split on the FIRST = only: values
      if (eq <= 0) continue               // like touch_detail contain commas
      out[line.substring(0, eq)] = line.substring(eq + 1)
    }
    root.st = out
  }

  // Refresh immediately after acting instead of waiting for the next tick, so
  // a tap feels instant rather than up to two seconds late.
  function act(cmd) {
    if (root.bar) root.bar.run(cmd)
    refreshTimer.restart()
  }

  Process {
    id: statusProc
    command: ["surface-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseStatus(text)
    }
  }

  function poll() { if (!statusProc.running) statusProc.running = true }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  // Short one-shot after an action: the helper needs a moment for hyprctl or
  // BlueZ to reflect the change.
  Timer {
    id: refreshTimer
    interval: 400
    repeat: false
    onTriggered: root.poll()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    active: root.oskVisible
    tooltipText: {
      var t = root.oskVisible ? "Keyboard shown" : "Keyboard hidden"
      t += root.rotationLocked ? "\nRotation locked" : "\nAuto-rotate on"
      if (!root.touchOk && root.touchState !== "unknown") t += "\nTouchscreen: " + root.touchState
      return t + "\nRight-click for keyboard"
    }
    onPressed: function (b) {
      if (b === Qt.RightButton) root.act("surface-osk toggle")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "k" || t === "K") root.act("surface-osk toggle")
        else if (t === "r" || t === "R") root.act("surface-autorotate toggle")
        else if (t === "b" || t === "B") root.act("surface-bt-connect")
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "Tablet"
          meta: root.st.model || "Surface"
          detail: root.st.touch_detail || ""
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Toggle {
          width: parent.width
          label: "On-screen keyboard"
          description: root.oskVisible ? "Shown" : "Hidden"
          checked: root.oskVisible
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.act("surface-osk toggle")
        }

        Toggle {
          width: parent.width
          label: "Auto-rotate"
          description: root.rotationLocked ? "Locked" : "Follows the accelerometer"
          checked: !root.rotationLocked
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.act("surface-autorotate toggle")
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        PanelSectionHeader {
          width: parent.width
          text: "HARDWARE"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.touchOk ? root.dim : root.urgent
          text: "Touchscreen  ·  " + (root.st.touch_detail || root.touchState)
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.dim
          text: "Stylus  ·  " + (root.st.stylus === "present" ? "detected" : "not detected")
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: (root.btTotal > 0 && root.btConnected === 0) ? root.urgent : root.dim
          text: root.btTotal === 0
                ? "Bluetooth input  ·  none paired"
                : "Bluetooth input  ·  " + root.btConnected + " of " + root.btTotal + " connected"
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }

        Row {
          spacing: Style.space(8)

          // BlueZ waits to be paged rather than paging the keyboard itself, so
          // a disconnected keyboard can sit dead for minutes. This is the
          // manual nudge for when you do not want to wait for the boot service.
          PanelActionButton {
            iconText: "󰂯"
            tooltipText: "Reconnect Bluetooth keyboard"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.act("surface-bt-connect")
          }

          PanelActionButton {
            iconText: "󰩺"
            tooltipText: "Diagnose the touchscreen"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.act("omarchy-launch-floating-terminal-with-presentation surface-touch-doctor")
          }
        }
      }
    }
  }
}
