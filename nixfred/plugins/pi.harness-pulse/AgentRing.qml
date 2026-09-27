import QtQuick
import qs.Commons

// One agent, one ring. Fixed footprint (Law 17: rings resize in place, never the row).
Item {
  id: ring

  property var agent: ({})
  property int size: 18
  property bool reducedMotion: false
  property var theme: ({})
  property bool showGlyph: reducedMotion

  readonly property string state: agent && agent.state ? agent.state : "idle"
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
        var r = c - lw
        ctx.reset()
        ctx.clearRect(0, 0, w, h)
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

    Text {
      anchors.centerIn: parent
      visible: ring.showGlyph
      text: agent && agent.glyph ? agent.glyph : ""
      color: ring.state === "done" ? Color.background : ring.stateColor
      font.pixelSize: Math.max(8, ring.size * 0.55)
      font.bold: true
    }
  }
}
