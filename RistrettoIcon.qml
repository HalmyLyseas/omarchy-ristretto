import QtQuick
import QtQuick.Shapes
import qs.Commons

// The ristretto mark: a tapered demitasse with two steam curls, drawn as a
// Shape so it takes whatever foreground colour its host hands it -- the
// same approach as the first-party DropboxIcon. Scaled from a 24x24 grid.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  // The steam is a state, not decoration: the bar and the panel hero show
  // it only while stay-awake keeps the coffee hot.
  property bool steam: true

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // One design-grid unit at the current render size.
  readonly property real u: Math.min(width, height) / 24

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    // With the steam hidden the ink would hug the bottom of the box, so the
    // steamless cup is lifted to sit centred where a bar glyph is expected.
    transform: Translate { y: root.steam ? 0 : -3.5 * root.u }

    // Steam, left curl.
    ShapePath {
      strokeColor: root.steam ? root.color : "transparent"
      strokeWidth: 1.7 * root.u
      capStyle: ShapePath.RoundCap
      fillColor: "transparent"
      startX: 9.1 * root.u
      startY: 2.2 * root.u
      PathCubic {
        control1X: 7.95 * root.u; control1Y: 3.45 * root.u
        control2X: 7.95 * root.u; control2Y: 4.7 * root.u
        x: 9.1 * root.u; y: 5.95 * root.u
      }
      PathCubic {
        control1X: 10.05 * root.u; control1Y: 7.0 * root.u
        control2X: 10.15 * root.u; control2Y: 7.95 * root.u
        x: 9.4 * root.u; y: 8.85 * root.u
      }
    }

    // Steam, right curl -- shorter, offset, the "intense" half of the mark.
    ShapePath {
      strokeColor: root.steam ? root.color : "transparent"
      strokeWidth: 1.7 * root.u
      capStyle: ShapePath.RoundCap
      fillColor: "transparent"
      startX: 14.3 * root.u
      startY: 3.1 * root.u
      PathCubic {
        control1X: 13.4 * root.u; control1Y: 4.1 * root.u
        control2X: 13.4 * root.u; control2Y: 5.1 * root.u
        x: 14.3 * root.u; y: 6.1 * root.u
      }
      PathCubic {
        control1X: 15.1 * root.u; control1Y: 6.95 * root.u
        control2X: 15.15 * root.u; control2Y: 7.7 * root.u
        x: 14.5 * root.u; y: 8.5 * root.u
      }
    }

    // The cup: tapered, no saucer, rounded at the base by two arcs.
    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: root.color
      startX: 4.4 * root.u
      startY: 10.4 * root.u
      PathLine { x: 17.0 * root.u; y: 10.4 * root.u }
      PathLine { x: 15.45 * root.u; y: 18.75 * root.u }
      PathArc {
        radiusX: 2.3 * root.u; radiusY: 2.3 * root.u
        direction: PathArc.Clockwise
        x: 13.19 * root.u; y: 20.6 * root.u
      }
      PathLine { x: 8.2 * root.u; y: 20.6 * root.u }
      PathArc {
        radiusX: 2.3 * root.u; radiusY: 2.3 * root.u
        direction: PathArc.Clockwise
        x: 5.94 * root.u; y: 18.75 * root.u
      }
      PathLine { x: 4.4 * root.u; y: 10.4 * root.u }
    }

    // The handle.
    ShapePath {
      strokeColor: root.color
      strokeWidth: 1.8 * root.u
      capStyle: ShapePath.RoundCap
      fillColor: "transparent"
      startX: 17.5 * root.u
      startY: 11.6 * root.u
      PathCubic {
        control1X: 19.85 * root.u; control1Y: 11.6 * root.u
        control2X: 21.1 * root.u; control2Y: 12.75 * root.u
        x: 21.1 * root.u; y: 14.6 * root.u
      }
      PathCubic {
        control1X: 21.1 * root.u; control1Y: 16.45 * root.u
        control2X: 19.65 * root.u; control2Y: 17.7 * root.u
        x: 17.25 * root.u; y: 17.7 * root.u
      }
    }
  }
}
