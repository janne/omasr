import QtQuick
import QtQuick.Shapes
import qs.Commons

// Sveriges Radio's interlocking SR monogram, drawn as vector geometry so it
// takes the bar's theme color and stays crisp at any size -- the same approach
// the first-party Dropbox widget uses for its logo.
//
// The outline is the monogram from Sveriges Radio's 2024 channel logos. Its
// natural coordinates sit at x 164.784..218.04, y 9.576..41.088 in the source
// artwork; `srX`/`srY`/`srW`/`srH` below record that box so the transform can
// move it to the origin and scale it into whatever `height` the caller asks
// for. Width follows from the mark's own aspect ratio.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  readonly property real srX: 164.784
  readonly property real srY: 9.576
  readonly property real srW: 53.256
  readonly property real srH: 31.512

  implicitHeight: iconSize
  implicitWidth: Math.round(iconSize * (srW / srH))
  width: implicitWidth
  height: implicitHeight

  // The mark is drawn in the artwork's own coordinates and mapped onto this
  // item by the Shape's transform. Transforms live on Shape (an Item) rather
  // than on ShapePath, and apply in list order: shift the bounding box to the
  // origin first, then scale it up to fill us.
  Shape {
    width: root.srW
    height: root.srH
    antialiasing: true
    // Resolution-independent geometry, so scaling the Shape up stays crisp.
    preferredRendererType: Shape.CurveRenderer

    transform: [
      Translate { x: -root.srX; y: -root.srY },
      Scale {
        xScale: root.width / root.srW
        yScale: root.height / root.srH
      }
    ]

    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: root.color
      // SVG's nonzero winding, which is what the source artwork is drawn for.
      fillRule: ShapePath.WindingFill

      PathSvg {
        path: "m 207.89,17.5 c 0,-7.92 -7.79,-7.45 -10.21,-7.92 h 11.24 c 3.23,0 8.4,2.13 8.4,7.92 0,5.79 -4.06,7.92 -7.28,7.92 h -5.28 c 0,0 3.13,0 3.13,-7.92 z m -42.6,23.56 h 13.47 L 165.29,27.02 Z M 179.5,9.6 192.31,24.91 V 9.6 Z m 24.69,15.83 h -11.45 l 13.08,15.63 h 12.22 z M 174.45,17.5 c 0,6 1.93,7.45 4.32,7.92 H 172 c -3.19,0 -7.2,-2.13 -7.2,-7.92 0,-5.79 4,-7.92 7.2,-7.92 h 6.76 c -2.4,0.46 -4.32,1.95 -4.32,7.92 z m 9.35,15.74 c 0,-5.88 -1.94,-7.35 -4.35,-7.81 h 6.82 c 3.22,0 7.27,2.11 7.27,7.82 0,5.71 -4,7.81 -7.27,7.82 h -6.82 c 2.41,-0.46 4.35,-1.93 4.35,-7.83 z"
      }
    }
  }
}
