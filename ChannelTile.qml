import QtQuick
import qs.Commons
import qs.Ui

// One channel button: Sveriges Radio's channel logo as a tile you press to
// tune in. The logo artwork is a hard-edged colored square with a white
// wordmark, so the tile keeps that and expresses state around it instead of
// repainting it -- the mark always stays recognizable.
//
// States, in the order they take precedence:
//   playing     full color, ring, running equalizer
//   connecting  full color, ring, pulsing equalizer
//   backgrounded  another channel is playing: dimmed well back
//   idle        slightly held back, coming forward on hover
Item {
  id: root

  property string channelKey: "p1"
  // Full station name, shown on hover -- it is the only place you can see
  // which regional station the P4 tile is pointed at before pressing it.
  property string label: "P1"
  property color channelColor: "#0167c6"
  property string fontFamily: Style.font.family

  property bool playing: false
  property bool connecting: false
  // Some other channel is the active one.
  property bool backgrounded: false
  property bool hasCursor: false
  property color foreground: Color.foreground

  readonly property bool active: playing || connecting
  readonly property bool hot: mouse.containsMouse || hasCursor

  signal activated()

  implicitWidth: Style.space(64)
  implicitHeight: Style.space(64)

  Rectangle {
    id: tile
    anchors.fill: parent
    radius: Math.max(Style.space(3), Style.cornerRadius)
    color: root.channelColor
    antialiasing: true

    opacity: root.active ? 1.0
      : root.hot ? 1.0
      : root.backgrounded ? 0.4
      : 0.86

    Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

    scale: mouse.pressed ? 0.96 : 1.0
    Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

    ChannelMark {
      anchors.fill: parent
      channel: root.channelKey
      color: "#ffffff"
    }

    // Running equalizer in the corner, so the playing tile reads as playing
    // even in a screenshot-still panel. Held static while connecting.
    Row {
      id: meter
      visible: root.active
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: Style.space(7)
      anchors.bottomMargin: Style.space(7)
      spacing: Math.max(1, Style.space(2))
      layoutDirection: Qt.RightToLeft

      Repeater {
        model: 3
        delegate: Rectangle {
          required property int index
          width: Math.max(2, Style.space(3))
          radius: width / 2
          color: "#ffffff"
          anchors.bottom: parent.bottom
          height: Math.max(3, Style.space(4))

          SequentialAnimation on height {
            running: root.playing
            loops: Animation.Infinite
            // Stagger the bars so they read as a level meter rather than
            // three things blinking in unison.
            PauseAnimation { duration: index * 130 }
            NumberAnimation { to: Style.space(15); duration: 380; easing.type: Easing.InOutSine }
            NumberAnimation { to: Style.space(4);  duration: 320; easing.type: Easing.InOutSine }
            NumberAnimation { to: Style.space(11); duration: 300; easing.type: Easing.InOutSine }
            NumberAnimation { to: Style.space(5);  duration: 420; easing.type: Easing.InOutSine }
          }
        }
      }

      SequentialAnimation on opacity {
        running: root.connecting
        loops: Animation.Infinite
        NumberAnimation { to: 0.25; duration: 520; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0;  duration: 520; easing.type: Easing.InOutSine }
      }
    }
  }

  // Ring drawn outside the tile so it never crops the logo.
  Rectangle {
    anchors.fill: parent
    anchors.margins: -Style.space(3)
    radius: tile.radius + Style.space(3)
    color: "transparent"
    antialiasing: true
    border.width: root.active ? Math.max(1, Style.space(2)) : (root.hot ? Math.max(1, Style.space(1)) : 0)
    border.color: root.active ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
    opacity: root.active || root.hot ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 130 } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  PanelToolTip {
    visible: mouse.containsMouse
    text: root.label
    fontFamily: root.fontFamily
  }
}
