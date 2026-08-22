import QtQuick
import qs.Commons

// The controls that appear once something is playing.
//
// Live and time-shifted are the two states everything keys off. On live, the
// lamp is lit and the forward controls have nothing to move towards, so they
// are dimmed; step back and the lamp becomes a "Direkt" button that returns
// you to the live edge.
Item {
  id: root

  property var player: null
  property var schedule: null
  property color foreground: Color.foreground
  property color liveColor: "#e0243c"
  property string fontFamily: Style.font.family

  readonly property bool isLive: player ? player.atLive : false
  readonly property bool ready: player ? player.canSeek : false
  readonly property bool hasWindow: schedule ? schedule.valid : false

  // Only offer the previous programme when SR has actually published it.
  readonly property var prevAudio: schedule ? schedule.prevAudio : null
  readonly property bool onDemand: player ? player.mode === "ondemand" : false

  // Which programme the *playhead* is inside, which is not always the one on
  // air: rewind far enough, or sit time-shifted across a programme boundary,
  // and the bar has to keep describing the programme being heard rather than
  // jumping to the new one and stranding the playhead off-scale.
  readonly property bool inPreviousProgramme: !!schedule
    && !onDemand
    && schedule.prevEndMs > 0
    && !!player
    && player.playheadWallMs > 0
    && player.playheadWallMs < schedule.currentStartMs

  readonly property double windowStartMs: {
    if (onDemand && prevAudio) return prevAudio.startMs
    if (!schedule) return 0
    return inPreviousProgramme ? schedule.prevStartMs : schedule.currentStartMs
  }
  readonly property double windowEndMs: {
    if (onDemand && prevAudio) return prevAudio.startMs + prevAudio.duration * 1000
    if (!schedule) return 0
    return inPreviousProgramme ? schedule.prevEndMs : schedule.currentEndMs
  }
  // The programme actually being heard.
  readonly property string programmeTitle: {
    if (onDemand && prevAudio) return prevAudio.title
    if (!schedule) return ""
    return inPreviousProgramme ? schedule.prevTitle : schedule.currentTitle
  }

  // Back steps to the start of what we can reach; once there, to the previous
  // programme. Forward only exists while we are behind live.
  readonly property bool canStepBack: ready
  readonly property bool canStepForward: ready && (onDemand || !isLive)
  readonly property bool canForward15: ready && !isLive && player.behindLiveSec > 1.5

  signal playPrevious()
  signal returnToCurrent()

  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.space(10)

    // --- Direkt lamp / button ---------------------------------------------
    //
    // Live: a lit lamp beside the word, purely an indicator. Behind live: the
    // same corner becomes a button that takes you back to the live edge.
    Item {
      width: parent.width
      height: Math.max(Style.space(22), directContent.implicitHeight)

      Rectangle {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.isLive
        width: directContent.implicitWidth + Style.space(20)
        height: Style.space(22)
        radius: height / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                       directMouse.containsMouse ? 0.22 : 0.12)
        Behavior on color { ColorAnimation { duration: 120 } }
      }

      Row {
        id: directContent
        anchors.right: parent.right
        anchors.rightMargin: root.isLive ? 0 : Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Rectangle {
          id: lamp
          anchors.verticalCenter: parent.verticalCenter
          visible: root.isLive
          width: Style.space(10)
          height: width
          radius: width / 2
          color: root.liveColor

          // A slow pulse, so a lit lamp reads as "on air" rather than as a
          // static dot.
          SequentialAnimation on opacity {
            running: root.isLive
            loops: Animation.Infinite
            NumberAnimation { to: 0.5; duration: 1100; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Direkt"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: root.isLive
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.isLive
          text: "\u203a"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }
      }

      MouseArea {
        id: directMouse
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: directContent.implicitWidth + Style.space(20)
        height: Style.space(22)
        hoverEnabled: true
        enabled: !root.isLive && root.ready
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
          if (root.onDemand) root.returnToCurrent()
          else if (root.player) root.player.goLive()
        }
      }
    }

    // --- timeline ----------------------------------------------------------
    Timeline {
      id: timeline
      width: parent.width
      visible: root.hasWindow
      foreground: root.foreground
      fontFamily: root.fontFamily
      interactive: root.ready

      startMs: root.windowStartMs
      endMs: root.windowEndMs
      playheadMs: root.player ? root.player.playheadWallMs : 0
      liveMs: root.player ? root.player.liveWallMs : 0
      seekableFromMs: root.player ? root.player.seekableStartWallMs : 0
      // The live marker only means something while a live stream is running;
      // a recorded programme has an end, not a live edge.
      timeShifted: !root.isLive && !root.onDemand

      onSeekRequested: function(wallMs) { if (root.player) root.player.seekToWall(wallMs) }
    }

    // --- buttons -----------------------------------------------------------
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(4)

      TransportButton {
        kind: "edge"
        anchors.verticalCenter: parent.verticalCenter
        actionEnabled: root.canStepBack
        foreground: root.foreground
        fontFamily: root.fontFamily
        glyphSize: Style.space(15)
        onActivated: {
          // At the start of what we can reach already? Then step back a
          // programme, if SR has published one.
          var atStart = root.player
            && (root.player.playheadWallMs - root.player.seekableStartWallMs) < 2000
          if (atStart && root.prevAudio && !root.onDemand) root.playPrevious()
          else if (root.player) root.player.seekToStart()
        }
      }

      TransportButton {
        kind: "skip"
        anchors.verticalCenter: parent.verticalCenter
        actionEnabled: root.ready
        foreground: root.foreground
        fontFamily: root.fontFamily
        onActivated: if (root.player) root.player.seekRelative(-15)
      }

      TransportButton {
        primary: true
        anchors.verticalCenter: parent.verticalCenter
        kind: root.player && root.player.paused ? "play" : "pause"
        glyphSize: Style.space(17)
        actionEnabled: root.ready
        foreground: root.foreground
        fontFamily: root.fontFamily
        onActivated: if (root.player) root.player.togglePause()
      }

      TransportButton {
        kind: "skip"
        mirrored: true
        anchors.verticalCenter: parent.verticalCenter
        actionEnabled: root.canForward15
        foreground: root.foreground
        fontFamily: root.fontFamily
        onActivated: if (root.player) root.player.seekRelative(15)
      }

      TransportButton {
        kind: "edge"
        mirrored: true
        anchors.verticalCenter: parent.verticalCenter
        actionEnabled: root.canStepForward
        foreground: root.foreground
        fontFamily: root.fontFamily
        glyphSize: Style.space(15)
        onActivated: {
          if (root.onDemand) root.returnToCurrent()
          else if (root.player) root.player.goLive()
        }
      }
    }
  }

  // No repaint timer here on purpose: mpv pushes both `time-pos` and
  // `demuxer-cache-time` continuously, so the playhead and the live edge each
  // advance on their own -- including while paused, when the cache head keeps
  // moving and the playhead deliberately does not.
}
