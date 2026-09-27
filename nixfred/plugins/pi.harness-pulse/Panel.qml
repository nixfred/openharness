import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "pi.harness-pulse"
  ipcTarget: "nixfred.harness-pulse"
  manageIpc: false

  readonly property int refreshIntervalSec: {
    var v = Number(setting("refreshIntervalSec", 1))
    return isFinite(v) ? Math.max(1, Math.min(30, Math.round(v))) : 1
  }
  readonly property int maxAgents: {
    var v = Number(setting("maxAgents", 8))
    return isFinite(v) ? Math.max(1, Math.min(24, Math.round(v))) : 8
  }
  readonly property bool reducedMotion: setting("reducedMotion", false) === true
  readonly property bool showMachine: setting("showMachine", true) !== false
  readonly property string focusWindowClass: String(setting("focusWindowClass", "harness"))
  readonly property int ringSize: {
    var v = Number(setting("ringSize", 18))
    return isFinite(v) ? Math.max(12, Math.min(28, Math.round(v))) : 18
  }

  property var agents: []
  property string hostname: ""
  property string lastError: ""
  property bool daemonUp: false
  property var theme: ({})
  property int nowMs: Date.now()

  readonly property string helperPath: {
    var p = Qt.resolvedUrl("pulse-feed").toString()
    return p.indexOf("file://") === 0 ? p.substring(7) : p
  }

  // The bar row never grows: a fixed slot per ring up to maxAgents, plus a status glyph.
  readonly property int slotWidth: ringSize + 6
  implicitWidth: statusGlyph.width + 4 + Math.max(1, Math.min(maxAgents, agents.length)) * slotWidth
  implicitHeight: ringSize + 4

  // Theme palette (yellow/red/green) for the state colours; shell Color.* for the rest.
  FileView {
    id: themeFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    preload: false
    onLoaded: root.theme = Model.parseThemeColors(text())
    onFileChanged: reload()
  }
  Component.onCompleted: themeFile.reload()

  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }

  // pulse-feed polls the daemon and prints one JSON line per poll; exit 3 means daemon down.
  Process {
    id: feed
    command: ["python3", root.helperPath, "--interval", String(root.refreshIntervalSec)]
    running: true
    stdout: SplitParser {
      onRead: function (line) {
        var r = Model.parseFeedLine(line)
        if (!r.ok) { root.lastError = r.error; root.daemonUp = false; return }
        root.lastError = ""
        root.daemonUp = true
        root.hostname = r.hostname
        root.agents = Model.sortAgents(r.agents)
      }
    }
    onExited: function (code) {
      root.daemonUp = false
      if (code === 3) root.lastError = "Harness daemon not running"
      else if (code !== 0) root.lastError = "pulse-feed exited " + code
      restart.start()
    }
  }
  Timer { id: restart; interval: 5000; repeat: false; onTriggered: feed.running = true }

  Process {
    id: focus
    command: ["hyprctl", "dispatch", "focuswindow", "class:^(" + root.focusWindowClass + ")$"]
    running: false
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    spacing: 0

    // Status glyph: the daemon itself. Non-colour, one character.
    Text {
      id: statusGlyph
      anchors.verticalCenter: parent.verticalCenter
      text: root.daemonUp ? "⬡" : "⬢"   // hexagon outline vs filled
      color: root.daemonUp ? Color.foreground : Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.35)
      font.pixelSize: root.ringSize * 0.7
      Behavior on color { ColorAnimation { duration: root.reducedMotion ? 0 : 220 } }
    }
    Item { width: 4; height: 1 }

    Repeater {
      model: Math.min(root.maxAgents, root.agents.length)
      delegate: Item {
        required property int index
        readonly property var agent: root.agents[index] || ({})
        width: root.slotWidth
        height: root.ringSize + 4

        // A soft dot travels along the row toward a ring that waits on Fred (leads the eye on wide bars).
        Rectangle {
          id: pulseDot
          width: 4; height: 4; radius: 2
          y: parent.height / 2 - 2
          color: agentRing.stateColor
          opacity: 0
          visible: !root.reducedMotion && (agent.state === "waiting" || agent.state === "permission")
          SequentialAnimation on x {
            running: pulseDot.visible
            loops: Animation.Infinite
            PropertyAction { target: pulseDot; property: "opacity"; value: 0.0 }
            NumberAnimation { from: -root.slotWidth * 2; to: root.slotWidth / 2 - 2; duration: 900; easing.type: Easing.InOutQuad }
            PropertyAction { target: pulseDot; property: "opacity"; value: 0.0 }
            PauseAnimation { duration: 1500 }
          }
          SequentialAnimation on opacity {
            running: pulseDot.visible
            loops: Animation.Infinite
            NumberAnimation { from: 0; to: 0.85; duration: 300 }
            NumberAnimation { from: 0.85; to: 0; duration: 600 }
            PauseAnimation { duration: 1500 }
          }
        }

        AgentRing {
          id: agentRing
          anchors.centerIn: parent
          size: root.ringSize
          agent: parent.agent
          reducedMotion: root.reducedMotion
          theme: root.theme
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onClicked: focus.running = true
          ToolTip.visible: containsMouse
          ToolTip.delay: 300
          ToolTip.text: (agent.name || "agent") + "  " + (agent.engine || "") +
            (root.showMachine && agent.machine ? "  @" + agent.machine : "") +
            "\n" + (agent.label || agent.state) + (agent.since ? "  " + Model.ago(agent.since, root.nowMs) : "") +
            (agent.detail ? "\n" + agent.detail : "")
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.agents.length === 0
    hoverEnabled: true
    ToolTip.visible: containsMouse
    ToolTip.delay: 300
    ToolTip.text: root.daemonUp ? "Harness: no agents" : (root.lastError || "Harness daemon not running")
  }
}
