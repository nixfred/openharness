import QtQuick
import QtQuick.Effects
import qs.Commons

// One agent, one ring. Fixed footprint (Law 17: rings resize in place, never the row).
Item {
  id: ring

  property var agent: ({})
  property int size: 18
  property bool reducedMotion: false
  property var theme: ({})
  property bool showGlyph: reducedMotion
  // A picture of the person the agent is waiting on (Fred's face), shown inside the ring only while
  // the agent waits or needs permission. Empty means never.
  property string avatarPath: ""

  readonly property string state: agent && agent.state ? agent.state : "idle"
  // Spend as a fraction of the per-agent cap, or -1 when no cap is set: drawn as the outer arc.
  readonly property real spendFraction: agent && agent.spend && agent.spend.fraction !== null && agent.spend.fraction !== undefined ? Number(agent.spend.fraction) : -1
  readonly property bool waitingOnPerson: state === "waiting" || state === "permission"
  readonly property bool showAvatar: avatarPath !== "" && waitingOnPerson
  readonly property color accent: Color.accent
  readonly property color urgent: theme.yellow ? theme.yellow : Color.urgent
  readonly property color danger: theme.red ? theme.red : Color.urgent
  readonly property color okay: theme.green ? theme.green : Color.accent
  readonly property color dim: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.28)

  readonly property color stateColor: {
    switch (state) {
      case "working": return accent
      case "waiting": return urgent
      case "permission": return danger
      case "failed": return danger
      case "done": return okay
      case "offline": return dim
      default: return Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.55)
    }
  }

  // Motion state: the visible ring animates, the Item itself never changes size.
  property real breath: 1.0
  property real sweep: 0.0
  property real fill: state === "done" ? 1.0 : 0.0
  property real flash: 1.0

  width: size
  height: size

  Behavior on fill { NumberAnimation { duration: reducedMotion ? 0 : 420; easing.type: Easing.OutCubic } }

  // Waiting and permission breathe. Scale only; layout width stays fixed.
  SequentialAnimation on breath {
    running: !reducedMotion && (state === "waiting" || state === "permission")
    loops: Animation.Infinite
    NumberAnimation { from: 1.0; to: 1.08; duration: 600; easing.type: Easing.InOutSine }
    NumberAnimation { from: 1.08; to: 1.0; duration: 600; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) breath = 1.0
  }

  // Working sweeps clockwise, 3 s per turn.
  NumberAnimation on sweep {
    running: !reducedMotion && state === "working"
    loops: Animation.Infinite
    from: 0; to: 1; duration: 3000
    onRunningChanged: if (!running) sweep = 0
  }

  // Failed: two quick flashes, then a steady thin ring. No strobing.
  SequentialAnimation {
    id: failFlash
    running: false
    NumberAnimation { target: ring; property: "flash"; from: 1.0; to: 0.2; duration: 90 }
    NumberAnimation { target: ring; property: "flash"; from: 0.2; to: 1.0; duration: 90 }
    PauseAnimation { duration: 120 }
    NumberAnimation { target: ring; property: "flash"; from: 1.0; to: 0.2; duration: 90 }
    NumberAnimation { target: ring; property: "flash"; from: 0.2; to: 1.0; duration: 90 }
  }
  onStateChanged: {
    if (state === "failed" && !reducedMotion) failFlash.restart()
    arc.requestPaint()
  }
  onSweepChanged: arc.requestPaint()
  onFillChanged: arc.requestPaint()
  onStateColorChanged: arc.requestPaint()
  onFlashChanged: arc.requestPaint()
  onSpendFractionChanged: arc.requestPaint()

  Item {
    anchors.centerIn: parent
    width: ring.size
    height: ring.size
    scale: ring.breath
    opacity: ring.flash

    Canvas {
      id: arc
      anchors.fill: parent
      renderStrategy: Canvas.Cooperative
      renderTarget: Canvas.Image
      antialiasing: true
      onPaint: {
        var ctx = getContext("2d")
        var w = width, h = height, c = w / 2
        var lw = ring.state === "failed" ? 1.5 : 2.2
        // The outer edge belongs to the spend arc when a cap is set; the state ring sits one line in.
        var hasSpend = ring.spendFraction >= 0
        var r = c - lw - (hasSpend ? 1.6 : 0)
        ctx.reset()
        ctx.clearRect(0, 0, w, h)
        if (hasSpend) {
          var f = Math.min(1, ring.spendFraction)
          var spendColor = ring.spendFraction >= 1 ? ring.danger : ring.spendFraction >= 0.8 ? ring.urgent : Qt.rgba(ring.accent.r, ring.accent.g, ring.accent.b, 0.85)
          ctx.beginPath()
          ctx.lineWidth = 1.2
          ctx.strokeStyle = Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
          ctx.arc(c, c, c - 0.7, 0, Math.PI * 2)
          ctx.stroke()
          if (f > 0) {
            ctx.beginPath()
            ctx.lineWidth = 1.2
            ctx.lineCap = "round"
            ctx.strokeStyle = spendColor
            ctx.arc(c, c, c - 0.7, -Math.PI / 2, -Math.PI / 2 + f * Math.PI * 2)
            ctx.stroke()
          }
        }
        // Base ring, always present so the footprint reads even when idle.
        ctx.beginPath()
        ctx.lineWidth = lw
        ctx.strokeStyle = ring.state === "working"
          ? Qt.rgba(ring.stateColor.r, ring.stateColor.g, ring.stateColor.b, 0.25)
          : ring.stateColor
        ctx.arc(c, c, r, 0, Math.PI * 2)
        ctx.stroke()
        // Working: a bright 90 degree arc that sweeps clockwise.
        if (ring.state === "working") {
          var start = -Math.PI / 2 + ring.sweep * Math.PI * 2
          ctx.beginPath()
          ctx.lineWidth = lw
          ctx.lineCap = "round"
          ctx.strokeStyle = ring.stateColor
          ctx.arc(c, c, r, start, start + Math.PI / 2)
          ctx.stroke()
        }
        // Done: fill grows to a solid dot and settles.
        if (ring.fill > 0) {
          ctx.beginPath()
          ctx.fillStyle = ring.stateColor
          ctx.arc(c, c, r * ring.fill, 0, Math.PI * 2)
          ctx.fill()
        }
      }
    }

    // The face of the person being waited on, round-masked inside the ring. Fades in and out; the
    // ring itself is unchanged so the footprint never moves.
    Item {
      id: avatarHolder
      anchors.centerIn: parent
      width: ring.size - 6
      height: ring.size - 6
      visible: opacity > 0
      opacity: ring.showAvatar ? 1.0 : 0.0
      Behavior on opacity { NumberAnimation { duration: ring.reducedMotion ? 0 : 220 } }
      Image {
        id: avatar
        anchors.fill: parent
        source: ring.avatarPath !== "" ? "file://" + ring.avatarPath : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        visible: false
      }
      Rectangle {
        id: avatarMask
        anchors.fill: parent
        radius: width / 2
        color: "white"
        visible: false
        layer.enabled: true
      }
      MultiEffect {
        anchors.fill: parent
        source: avatar
        maskEnabled: true
        maskSource: avatarMask
      }
    }

    Text {
      anchors.centerIn: parent
      visible: ring.showGlyph && !ring.showAvatar
      text: agent && agent.glyph ? agent.glyph : ""
      color: ring.state === "done" ? Color.background : ring.stateColor
      font.pixelSize: Math.max(8, ring.size * 0.55)
      font.bold: true
    }
  }
}
