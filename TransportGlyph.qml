import QtQuick
import QtQuick.Shapes
import qs.Commons

// The transport's icon set, drawn as vector geometry in a 100x100 box and
// scaled to whatever the button asks for. Keeping them as geometry rather
// than glyphs from a font means they take the theme's color and stay sharp at
// every scaling factor, like the channel marks do.
//
//   skip   a circling arrow with its jump length in the middle. `mirrored`
//          turns the back arrow into the forward one.
//   play   / pause -- the middle button's two faces.
//   edge   the |< and >| marks that step between programmes.
//
// The skip arrow is authored as the *back* arrow, so `mirrored` reads as
// "forward". Only the geometry is mirrored, never the whole item: the jump
// length has to stay readable on the forward button, so it is a sibling of
// the mirrored container rather than a child of it.
Item {
  id: root

  // "skip" | "play" | "pause" | "edge"
  property string kind: "skip"
  property bool mirrored: false
  property color color: Color.foreground
  property string label: "15"
  property string fontFamily: Style.font.family

  implicitWidth: Style.space(22)
  implicitHeight: Style.space(22)

  Item {
    id: geometry
    anchors.fill: parent

    transform: Scale {
      origin.x: root.width / 2
      xScale: root.mirrored ? -1 : 1
    }

    // Each kind gets its own Shape: ShapePath is not an Item, so visibility
    // has to be switched one level up.
    Shape {
      anchors.fill: parent
      visible: root.kind === "skip"
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer
      // Authored in a 100x100 box.
      transform: Scale { xScale: root.width / 100; yScale: root.height / 100 }

      // The ring, broken at the top where the arrow head sits. 0 degrees is 3
      // o'clock and angles increase clockwise, so the gap straddles 270.
      //
      // The sweep runs anticlockwise, which is the direction a rewind turns:
      // down the left of the ring, round the bottom, and back up the right to
      // meet the head. Head and sweep have to agree, or the icon reads as
      // pointing one way while circling the other.
      ShapePath {
        strokeColor: root.color
        strokeWidth: 11
        fillColor: "transparent"
        capStyle: ShapePath.FlatCap

        PathAngleArc {
          centerX: 50; centerY: 56
          radiusX: 39; radiusY: 39
          startAngle: 245
          sweepAngle: -300
        }
      }

      // Head at the right end of the break, where that anticlockwise sweep
      // arrives, pointing on round the way it is travelling.
      ShapePath {
        strokeWidth: 0
        fillColor: root.color
        fillRule: ShapePath.WindingFill

        startX: 98; startY: 20
        PathLine { x: 62; y: 0 }
        PathLine { x: 62; y: 40 }
      }
    }

    Shape {
      anchors.fill: parent
      visible: root.kind === "play"
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer
      transform: Scale { xScale: root.width / 100; yScale: root.height / 100 }

      ShapePath {
        strokeWidth: 0
        fillColor: root.color
        startX: 26; startY: 16
        PathLine { x: 82; y: 50 }
        PathLine { x: 26; y: 84 }
        PathLine { x: 26; y: 16 }
      }
    }

    Shape {
      anchors.fill: parent
      visible: root.kind === "edge"
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer
      transform: Scale { xScale: root.width / 100; yScale: root.height / 100 }

      // The bar the triangle runs into.
      ShapePath {
        strokeWidth: 0
        fillColor: root.color
        fillRule: ShapePath.WindingFill
        startX: 12; startY: 20
        PathLine { x: 24; y: 20 }
        PathLine { x: 24; y: 80 }
        PathLine { x: 12; y: 80 }
        PathLine { x: 12; y: 20 }
      }

      ShapePath {
        strokeWidth: 0
        fillColor: root.color
        startX: 88; startY: 18
        PathLine { x: 88; y: 82 }
        PathLine { x: 32; y: 50 }
        PathLine { x: 88; y: 18 }
      }
    }
  }

  // Never mirrored: the number has to read the same on both arrows.
  Text {
    visible: root.kind === "skip"
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: root.height * 0.07
    text: root.label
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: Math.max(7, root.height * 0.42)
    font.bold: true
  }

  // Pause: two bars, symmetrical, so mirroring is irrelevant.
  Row {
    visible: root.kind === "pause"
    anchors.centerIn: parent
    spacing: root.width * 0.16
    Repeater {
      model: 2
      delegate: Rectangle {
        width: root.width * 0.19
        height: root.height * 0.62
        radius: width * 0.25
        color: root.color
      }
    }
  }
}
