import QtQuick
import QtQuick.Shapes
import qs.Commons

// The P1/P2/P3/P4 wordmarks from Sveriges Radio's 2024 channel logos, drawn as
// vector geometry in the artwork's own 200x200 tile space and scaled to fit.
//
// The caller paints the colored tile behind this and passes the glyph color
// (white in SR's own logos). Keeping the glyph separate from its background
// lets a tile dim, tint, or animate without the mark going with it.
Item {
  id: root

  // "p1" | "p2" | "p3" | "p4" -- matches Channels.js `key`.
  property string channel: "p1"
  property color color: "#ffffff"

  // Side of the artwork's square tile. The glyphs are positioned inside it,
  // so the whole box has to scale as one rather than each mark being fitted
  // to its own ink -- that is what keeps the four tiles optically consistent.
  readonly property real tile: 200

  readonly property var paths: ({
    "p1": "M 156.1,138.5 H 131.9 V 75.81 c 7.84,-0.38 18.79,-4.72 24.2,-16.51 z M 67.51,61.5 H 43.9 v 77 h 23.61 z m 50.43,22.92 h 0.02 c 0,-12.96 -7.29,-18.47 -14.08,-21.31 -2.91,-1.22 -6.71,-1.62 -11.54,-1.62 H 69.9 c 2.51,0.29 4.36,0.65 6.8,1.06 10.9,1.81 17.24,6.45 17.24,21.89 0,15.44 -1.74,19.35 -11.35,21.74 -1.94,0.47 -4.15,0.84 -6.71,1.17 h 15.76 c 3.43,0 6.36,0 9.12,-0.68 6.75,-1.67 17.18,-7 17.18,-22.24 z",
    "p2": "M163.08 138.5h-61.33v-20.51h61.33v20.51Zm-102.55-77H36.92v77h23.61v-77Zm50.45 22.93c0-12.96-7.29-18.47-14.08-21.31-2.91-1.22-6.71-1.62-11.54-1.62H62.92c2.51.29 4.36.65 6.8 1.06 10.9 1.81 17.23 6.45 17.23 21.88s-1.74 19.35-11.35 21.74c-1.94.47-4.15.84-6.71 1.17h15.76c3.43 0 6.35 0 9.12-.68 6.75-1.67 17.18-7 17.18-22.24h.02Zm11.38 27.79c-2.44.47-4.29.86-6.8 1.2H138c4.85 0 8.65-.45 11.54-1.83 6.79-3.2 14.08-9.46 14.08-24.13s-7.29-20.92-14.08-24.13c-2.91-1.35-6.71-1.81-11.54-1.81h-22.44c2.51.32 4.38.74 6.8 1.2 10.9 2.05 17.23 7.29 17.23 24.76s-6.34 22.69-17.23 24.76v-.02Z",
    "p3": "M117.12 119.25c0 14.51 4.27 18.11 10.12 19.25h-14.29c-3.86 0-6.8-.36-9.12-1.36-5.69-2.44-10.93-7.85-10.93-17.9h24.22v.02Zm35.91-17.89c-2.33-.99-5.26-1.35-9.12-1.35h-5.42c3.43 0 6.36 0 9.12-.57 6.75-1.4 13.23-7.25 13.23-18.67 0-9.86-6.43-15.51-13.21-17.9-2.93-1.02-6.73-1.36-11.58-1.36h-23.27c2.51.25 4.38.52 6.8.93 10.52 1.76 17.74 5.28 17.74 18.31 0 14.51-2.84 18.53-7.22 19.25 5.85 1.13 9.62 4.74 9.62 19.25s-4.27 18.11-10.13 19.25h14.29c3.86 0 6.8-.36 9.12-1.36 5.69-2.44 10.93-7.85 10.93-17.9s-5.24-15.51-10.93-17.9l.02.04ZM60.53 61.5H36.92v77h23.61v-77Zm50.45 22.93c0-12.96-7.29-18.47-14.08-21.31-2.91-1.22-6.71-1.62-11.54-1.62H62.92c2.51.29 4.36.65 6.8 1.06 10.9 1.81 17.23 6.45 17.23 21.88s-1.74 19.35-11.35 21.74c-1.94.47-4.15.84-6.71 1.17h15.76c3.43 0 6.35 0 9.12-.68 6.75-1.67 17.18-7 17.18-22.24h.02Z",
    "p4": "m165.37 61.5-38.42 55.89H99.8l39.37-55.89h26.2Zm-4.11 45.89h-24.14v31.09h24.14v-31.09ZM94.97 63.12c-2.73-1.22-6.3-1.62-10.86-1.62h-21.1c2.37.29 4.11.65 6.41 1.06 10.25 1.81 16.66 6.45 16.66 21.88s-2.12 19.35-11.15 21.74c-1.8.47-3.9.84-6.3 1.17h14.83c3.23 0 5.98 0 8.58-.68 6.35-1.67 16.16-7 16.16-22.24 0-12.96-6.84-18.47-13.23-21.31ZM60.62 61.5H37.01v77h23.61v-77Z"
  })

  // Drawn in the artwork's 200x200 space and scaled onto this item. The
  // transform belongs on Shape (an Item); ShapePath has none.
  Shape {
    width: root.tile
    height: root.tile
    antialiasing: true
    // Resolution-independent geometry, so scaling stays crisp at any tile size.
    preferredRendererType: Shape.CurveRenderer

    transform: Scale {
      xScale: root.width / root.tile
      yScale: root.height / root.tile
    }

    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: root.color
      fillRule: ShapePath.WindingFill

      PathSvg {
        path: root.paths[root.channel] || root.paths["p1"]
      }
    }
  }
}
