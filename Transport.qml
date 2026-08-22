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

  // Only offer the current programme when SR has actually published it.
  readonly property var currentAudio: schedule ? schedule.currentAudio : null
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

  // A published file carries its own window, so take it from the player
  // rather than guessing which scheduled episode it corresponds to.
  readonly property double windowStartMs: {
    if (onDemand) return player ? player.originWallMs : 0
    if (!schedule) return 0
    return inPreviousProgramme ? schedule.prevStartMs : schedule.currentStartMs
  }
  readonly property double windowEndMs: {
    if (onDemand) return player ? player.originWallMs + player.duration * 1000 : 0
    if (!schedule) return 0
    return inPreviousProgramme ? schedule.prevEndMs : schedule.currentEndMs
  }
  // The programme actually being heard.
  readonly property string programmeTitle: {
    if (onDemand) return player ? player.programme : ""
    if (!schedule) return ""
    return inPreviousProgramme ? schedule.prevTitle : schedule.currentTitle
  }

  // Back steps to the start of what we can reach; once there, to the previous
  // programme. Forward only exists while we are behind live.
  readonly property bool canStepBack: ready
  // Only meaningful while a recorded programme is playing: there is nothing
  // after the live broadcast to step to.
  readonly property bool canStepForward: ready && onDemand
  readonly property bool canForward15: ready && !isLive
    && (player.behindLiveSec > 1.5 || canCatchUp)
  // Nothing behind the playhead means the button would silently do nothing,
  // so dim it rather than let it look broken. How far back "behind" reaches
  // depends on whether the programme can be switched to as a file.
  readonly property bool canBack15: ready && (hasEarlierProgramme || (fullySeekable
    ? player.playheadWallMs > windowStartMs + 1500
    : player.seekableBackSec > 1.5))

  signal stepBackRequested()
  signal stepForwardRequested()
  signal playCurrentFromStart()
  signal returnToCurrent()
  // Seeking goes through the panel, which decides between moving inside the
  // live buffer and switching to the published programme.
  signal seekRequested(double wallMs)
  signal seekByRequested(int seconds)

  // True when the whole broadcast window can be reached, because a published
  // file is playing or one exists to switch to. Otherwise only what the live
  // buffer holds is reachable.
  property bool fullySeekable: false
  // Forwarding off the end of this programme rejoins the live broadcast, so
  // the button stays available right up to the present.
  property bool canCatchUp: false
  // Something scheduled before this programme, so stepping back off the start
  // of it has somewhere to land.
  property bool hasEarlierProgramme: false

  // Where "the beginning of this programme" actually lands. A published file
  // starts at the programme's real start; a live stream can only go back as
  // far as the buffer, unless SR has published the programme being heard.
  readonly property double programmeStartMs: {
    if (!player) return windowStartMs
    if (onDemand || currentAudio) return windowStartMs
    return Math.max(windowStartMs, player.seekableStartWallMs)
  }

  // Already at the beginning, by the usual few-seconds grace that makes a
  // second press mean "the one before this".
  readonly property bool atProgrammeStart: !!player
    && (player.playheadWallMs - programmeStartMs) < 3000

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
        onClicked: root.returnToCurrent()
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
      // With a published file to fall back on, the whole programme is
      // reachable, not just the part we happen to have buffered.
      seekableFromMs: root.fullySeekable
        ? root.windowStartMs
        : (root.player ? root.player.seekableStartWallMs : 0)
      // The live marker only means something while a live stream is running;
      // a recorded programme has an end, not a live edge.
      timeShifted: !root.isLive && !root.onDemand

      onSeekRequested: function(wallMs) { root.seekRequested(wallMs) }
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
        // The rule itself lives on the panel, so the keyboard and IPC paths
        // step back the same way this button does.
        onActivated: root.stepBackRequested()
      }

      TransportButton {
        kind: "skip"
        anchors.verticalCenter: parent.verticalCenter
        actionEnabled: root.canBack15
        foreground: root.foreground
        fontFamily: root.fontFamily
        onActivated: root.seekByRequested(-15)
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
        onActivated: root.seekByRequested(15)
      }

      TransportButton {
        kind: "edge"
        mirrored: true
        anchors.verticalCenter: parent.verticalCenter
        actionEnabled: root.canStepForward
        foreground: root.foreground
        fontFamily: root.fontFamily
        glyphSize: Style.space(15)
        onActivated: root.stepForwardRequested()
      }
    }
  }

  // No repaint timer here on purpose: mpv pushes both `time-pos` and
  // `demuxer-cache-time` continuously, so the playhead and the live edge each
  // advance on their own -- including while paused, when the cache head keeps
  // moving and the playhead deliberately does not.
}
