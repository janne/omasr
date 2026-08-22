import QtQuick
import qs.Commons

// A transport control: a glyph with a generous hit area, dimmed when the
// action isn't available. `primary` gives the middle play/pause button its
// filled disc.
Item {
  id: root

  property string kind: "skip"
  property bool mirrored: false
  property string label: "15"
  property bool actionEnabled: true
  property bool primary: false
  property real glyphSize: Style.space(22)
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal activated()

  readonly property bool hot: mouse.containsMouse && actionEnabled

  implicitWidth: primary ? Style.space(38) : Style.space(30)
  implicitHeight: implicitWidth

  Rectangle {
    visible: root.primary
    anchors.centerIn: parent
    width: Style.space(36)
    height: width
    radius: width / 2
    color: root.foreground
    opacity: root.hot ? 1.0 : 0.9
    scale: mouse.pressed ? 0.94 : 1.0
    Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 120 } }
  }

  TransportGlyph {
    anchors.centerIn: parent
    width: root.glyphSize
    height: root.glyphSize
    kind: root.kind
    mirrored: root.mirrored
    label: root.label
    fontFamily: root.fontFamily
    // On the primary button the glyph is knocked out of the filled disc.
    color: root.primary ? Color.background : root.foreground
    opacity: root.actionEnabled ? (root.hot || root.primary ? 1.0 : 0.88) : 0.3
    scale: mouse.pressed && !root.primary ? 0.92 : 1.0
    Behavior on opacity { NumberAnimation { duration: 120 } }
    Behavior on scale { NumberAnimation { duration: 90 } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.actionEnabled
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
