import QtQuick
import qs.Commons

// The scrub bar, spanning the current programme's broadcast window.
//
// Three regions, from dimmest to brightest:
//   track      the whole programme, start to end
//   aired      what has gone out so far (up to the live edge)
//   played     start of programme to the playhead
//
// Two handles: the playhead, and -- once you are behind live -- a second
// marker showing where live has got to, so it is obvious how far back you are.
//
// The part of the programme that predates tuning in cannot be rewound into,
// since the buffer only holds what we have actually received. `seekableFromMs`
// marks that boundary and the bar shows it as unavailable.
Item {
  id: root

  property double startMs: 0
  property double endMs: 0
  property double playheadMs: 0
  property double liveMs: 0
  // Oldest moment still in the buffer: the left edge of what can be scrubbed.
  property double seekableFromMs: 0
  // Shown as a distinct marker only once the listener is deliberately behind.
  property bool timeShifted: false

  readonly property double reachableFromMs: Math.max(startMs, seekableFromMs)
  property bool interactive: true

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal seekRequested(double wallMs)

  readonly property double span: Math.max(1, endMs - startMs)
  readonly property real barHeight: Math.max(3, Style.space(4))
  readonly property real handle: Math.max(8, Style.space(11))

  implicitHeight: barHeight + Style.space(6) + labelRow.implicitHeight

  function fraction(ms) {
    return Math.max(0, Math.min(1, (ms - startMs) / span))
  }

  function clockLabel(ms) {
    if (!(ms > 0)) return ""
    return Qt.formatDateTime(new Date(ms), "HH:mm")
  }

  function seekAt(px) {
    if (!interactive) return
    var f = Math.max(0, Math.min(1, px / Math.max(1, bar.width)))
    var target = startMs + f * span
    // Clamp into the buffered window rather than seeking into silence.
    root.seekRequested(Math.max(reachableFromMs, Math.min(liveMs, target)))
  }

  Item {
    id: bar
    width: parent.width
    height: root.handle

    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: root.barHeight
      radius: height / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
    }

    // How much of the programme has aired.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: 0
      width: track.width * root.fraction(root.liveMs)
      height: root.barHeight
      radius: height / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.42)
    }

    // Reachable: from the oldest buffered moment up to the playhead. It does
    // not start at the programme's start, because whatever aired before we
    // tuned in was never received and cannot be scrubbed back into.
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: track.width * root.fraction(root.reachableFromMs)
      width: Math.max(root.barHeight,
                      track.width * (root.fraction(root.playheadMs)
                                     - root.fraction(root.reachableFromMs)))
      height: root.barHeight
      radius: height / 2
      color: root.foreground
      opacity: root.interactive ? 1 : 0.5
    }

    // Where live has got to. Only meaningful once the playhead is behind it.
    Rectangle {
      visible: root.timeShifted
      anchors.verticalCenter: parent.verticalCenter
      x: track.width * root.fraction(root.liveMs) - width / 2
      width: root.handle * 0.62
      height: width
      radius: width / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.55)
    }

    Rectangle {
      id: playhead
      anchors.verticalCenter: parent.verticalCenter
      x: track.width * root.fraction(root.playheadMs) - width / 2
      width: root.handle
      height: width
      radius: width / 2
      color: root.foreground
      opacity: root.interactive ? 1 : 0.5
      scale: drag.pressed ? 1.15 : 1.0
      Behavior on scale { NumberAnimation { duration: 90 } }
    }

    MouseArea {
      id: drag
      anchors.fill: parent
      anchors.topMargin: -Style.space(6)
      anchors.bottomMargin: -Style.space(6)
      enabled: root.interactive
      cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
      onPressed: function(mouse) { root.seekAt(mouse.x) }
      onPositionChanged: function(mouse) { if (pressed) root.seekAt(mouse.x) }
    }
  }

  Item {
    id: labelRow
    anchors.top: bar.bottom
    anchors.topMargin: Style.space(2)
    width: parent.width
    implicitHeight: startLabel.implicitHeight

    Text {
      id: startLabel
      anchors.left: parent.left
      text: root.clockLabel(root.startMs)
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.65)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      anchors.right: parent.right
      text: root.clockLabel(root.endMs)
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.65)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
