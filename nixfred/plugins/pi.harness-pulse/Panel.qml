import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "pi.harness-pulse"
  ipcTarget: "nixfred.harness-pulse"
  // The shared Panel IPC gives `open`, `close` and `toggle` on nixfred.harness-pulse for the fleet popup.
  manageIpc: true

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
  // The face shown inside a ring that waits on you. "Auto": avatarPath when set, else ~/.face, else
  // initials. "Initials": always initials. "None": plain ring. Nothing personal ships in the plugin.
  readonly property string avatarMode: String(setting("avatar", "Auto") || "Auto")
  readonly property string avatarSetting: String(setting("avatarPath", "") || "")
  readonly property string homeDir: Quickshell.env("HOME") || ""
  function expandHome(p) { return p.indexOf("~/") === 0 ? root.homeDir + p.substring(1) : p }
  // The candidate picture is probed once here, so a missing ~/.face costs one warning, not one per ring.
  readonly property string avatarPath: avatarProbe.status === Image.Ready ? avatarCandidate : ""
  Image { id: avatarProbe; visible: false; asynchronous: true; sourceSize.width: 64; sourceSize.height: 64; source: root.avatarCandidate !== "" ? "file://" + root.avatarCandidate : "" }
  readonly property string avatarCandidate: avatarMode !== "Auto" ? ""
    : (avatarSetting !== "" ? expandHome(avatarSetting) : (homeDir !== "" ? homeDir + "/.face" : ""))
  readonly property string avatarInitials: {
    if (avatarMode === "None") return ""
    var s = String(setting("avatarInitials", "") || "").trim()
    if (s === "") s = String(Quickshell.env("USER") || "").substring(0, 1)
    return s.substring(0, 2).toUpperCase()
  }
  // Logo for the popup's idle and connecting states: Omarchy (read from the system at runtime,
  // never bundled), Harness (a drawn hexagon mark), Custom (logoPath) or None.
  readonly property string logoMode: String(setting("logo", "Harness") || "Harness")
  readonly property string logoPath: expandHome(String(setting("logoPath", "") || ""))
  readonly property int ringSize: {
    var v = Number(setting("ringSize", 18))
    return isFinite(v) ? Math.max(12, Math.min(28, Math.round(v))) : 18
  }

  property var agents: []
  property var alerts: []
  property string lastStop: ""
  property string hostname: ""
  property string lastError: ""
  property bool daemonUp: false
  property var theme: ({})
  property int nowMs: Date.now()
  // agentId -> last state, for the fleet view activity ticker.
  property var lastStates: null

  readonly property string helperPath: {
    var p = Qt.resolvedUrl("pulse-feed").toString()
    return p.indexOf("file://") === 0 ? p.substring(7) : p
  }

  // The bar row never grows: a fixed slot per ring up to maxAgents, plus a status glyph.
  readonly property int slotWidth: ringSize + 6
  implicitWidth: statusGlyph.width + 4 + (collisionBadge.visible ? collisionBadge.width + 4 : 0) + Math.max(1, Math.min(maxAgents, agents.length)) * slotWidth
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

  // The clock only ticks while a tooltip or the popup could show it.
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
        root.alerts = r.alerts || []
        var d = Model.diffStates(root.lastStates, root.agents, Date.now())
        root.lastStates = d.map
        if (d.events.length > 0) fleetView.pushEvents(d.events)
      }
    }
    onExited: function (code) {
      root.daemonUp = false
      // A minute without the daemon: the last roster is stale, so drop it rather than show ghosts.
      if (code === 3) { root.agents = []; root.alerts = []; root.lastStates = null }
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

      // Hold-to-stop: press and hold the hexagon for two seconds to cancel every agent turn on this
      // machine. A red ring drains around the hexagon while held; release early and nothing happens.
      property real hold: 0
      NumberAnimation on hold {
        id: holdAnim
        running: false
        from: 0; to: 1; duration: 2000
        onFinished: { if (statusGlyph.hold >= 1) { stopAll.running = true; statusGlyph.hold = 0 } }
      }
      // Shape, not Canvas: a Canvas repainted per frame flickers on the bar.
      Shape {
        id: holdArc
        anchors.centerIn: parent
        width: root.ringSize + 4; height: root.ringSize + 4
        visible: statusGlyph.hold > 0
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeWidth: 2
          capStyle: ShapePath.RoundCap
          fillColor: "transparent"
          strokeColor: (root.theme && root.theme.red) ? root.theme.red : Color.urgent
          PathAngleArc { centerX: holdArc.width / 2; centerY: holdArc.height / 2; radiusX: holdArc.width / 2 - 1.5; radiusY: radiusX; startAngle: -90; sweepAngle: (1 - statusGlyph.hold) * 360 }
        }
      }
      MouseArea {
        anchors.fill: parent
        enabled: root.daemonUp
        hoverEnabled: true
        onPressed: { statusGlyph.hold = 0; holdAnim.restart() }
        onReleased: { holdAnim.stop(); statusGlyph.hold = 0 }
        onCanceled: { holdAnim.stop(); statusGlyph.hold = 0 }
        ToolTip.visible: containsMouse && !pressed
        ToolTip.delay: 500
        ToolTip.text: root.lastStop !== "" ? root.lastStop : "Hold 2 s to stop every agent on " + (root.hostname || "this machine")
      }
    }
    Process {
      id: stopAll
      command: ["python3", root.helperPath, "--stop-all"]
      running: false
      stdout: SplitParser {
        onRead: function (line) {
          try { var d = JSON.parse(line); root.lastStop = d.cancelled ? "Stopped " + d.cancelled.length + " agent(s)" : "Stop failed: " + (d.error || "unknown") }
          catch (e) { root.lastStop = "Stop failed" }
        }
      }
    }
    Item { width: 4; height: 1 }

    // Collision badge: two agents on one file, folder or branch in the last hour. Only present when
    // there is something to say, so the bar stays quiet otherwise (Law 17: it takes a fixed slot only
    // while visible, and the ring row shifts by one glyph, never by a layout reflow).
    Text {
      id: collisionBadge
      anchors.verticalCenter: parent.verticalCenter
      visible: root.alerts.length > 0
      text: "△" + (root.alerts.length > 1 ? String(root.alerts.length) : "")
      color: (root.theme && root.theme.red) ? root.theme.red : Color.urgent
      font.pixelSize: root.ringSize * 0.7
      font.bold: true
      opacity: 1.0
      SequentialAnimation on opacity {
        running: collisionBadge.visible && !root.reducedMotion
        loops: Animation.Infinite
        NumberAnimation { from: 1.0; to: 0.45; duration: 900; easing.type: Easing.InOutSine }
        NumberAnimation { from: 0.45; to: 1.0; duration: 900; easing.type: Easing.InOutSine }
      }
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        ToolTip.visible: containsMouse
        ToolTip.delay: 300
        ToolTip.text: {
          var lines = []
          for (var i = 0; i < root.alerts.length && i < 6; i++) lines.push(root.alerts[i].kind + ": " + root.alerts[i].detail)
          return lines.join("\n")
        }
      }
    }
    Item { width: collisionBadge.visible ? 4 : 0; height: 1 }

    Repeater {
      model: Math.min(root.maxAgents, root.agents.length)
      delegate: Item {
        required property int index
        readonly property var agent: root.agents[index] || ({})
        width: root.slotWidth
        height: root.ringSize + 4

        // A soft dot travels along the row toward a ring that waits on you (leads the eye on wide bars).
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
          avatarPath: root.avatarPath
          avatarInitials: root.avatarInitials
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          // Left: focus the Harness window. Right: the fleet popup.
          onClicked: function (mouse) { if (mouse.button === Qt.RightButton) root.toggle(); else focus.running = true }
          ToolTip.visible: containsMouse
          ToolTip.delay: 300
          ToolTip.text: (agent.name || "agent") + "  " + (agent.engine || "") +
            (root.showMachine && agent.machine ? "  @" + agent.machine : "") +
            (agent.lane ? "  [" + agent.lane + "]" : "") +
            "\n" + (agent.label || agent.state) + (agent.since ? "  " + Model.ago(agent.since, root.nowMs) : "") +
            (agent.spend && agent.spend.usd ? "\nspend $" + agent.spend.usd.toFixed(2) + (agent.spend.fraction !== null ? "  " + Math.round(agent.spend.fraction * 100) + "% of cap" : "") : "") +
            (agent.detail ? "\n" + agent.detail : "")
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.agents.length === 0
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: root.toggle()
    ToolTip.visible: containsMouse
    ToolTip.delay: 300
    ToolTip.text: root.daemonUp ? "Harness: no agents" : (root.lastError || "Harness daemon not running")
  }

  // ---- Fleet popup: right-click the widget (or `toggle` over IPC). ----
  KeyboardPanel {
    id: popup
    anchorItem: row
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(480)
    contentHeight: popup.fittedContentHeight(fleetView.implicitHeight, 620)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      FleetView {
        id: fleetView
        anchors.fill: parent
        agents: root.agents
        alerts: root.alerts
        hostname: root.hostname
        daemonUp: root.daemonUp
        active: root.opened
        reducedMotion: root.reducedMotion
        theme: root.theme
        logoMode: root.logoMode
        logoPath: root.logoPath
        lastStop: root.lastStop
        nowMs: root.nowMs
        onStopAllRequested: stopAll.running = true
      }
    }
  }
}
