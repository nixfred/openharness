import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Starter bar widget: one label, one accent dot that fades in. Fixed footprint (Law 17).
Panel {
  id: root
  moduleName: "pi.hello"
  ipcTarget: "nixfred.hello"
  manageIpc: false

  readonly property string label: String(setting("label", "hello"))
  readonly property bool reducedMotion: setting("reducedMotion", false) === true

  implicitWidth: row.implicitWidth + 8
  implicitHeight: 22

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 6
    Rectangle {
      width: 8; height: 8; radius: 4
      anchors.verticalCenter: parent.verticalCenter
      color: Color.accent
      opacity: 0
      Component.onCompleted: opacity = 1
      Behavior on opacity { NumberAnimation { duration: root.reducedMotion ? 0 : 400; easing.type: Easing.OutCubic } }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: Color.foreground
      font.pixelSize: 12
    }
  }
}
