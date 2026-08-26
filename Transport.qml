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
  // Looked up from the schedule rather than assumed to be the current or the
  // previous one: the DVR window reaches hours back, past both.
  readonly property var playheadEpisode: (schedule && player && player.playheadWallMs > 0)
    ? schedule.episodeAt(player.playheadWallMs) : null

  // A published file carries its own window, so take it from the player
  // rather than guessing which scheduled episode it corresponds to.
  readonly property double windowStartMs: {
    if (onDemand) return player ? player.originWallMs : 0
    if (!schedule) return 0
    return heardProgramme ? heardProgramme.startMs : schedule.currentStartMs
  }
  readonly property double windowEndMs: {
    if (onDemand) return player ? player.originWallMs + player.duration * 1000 : 0
    if (!schedule) return 0
    return heardProgramme ? heardProgramme.endMs : schedule.currentEndMs
  }

  // Whether `rightnow` describes the moment being heard. It is the only
  // source that reflects a schedule SR has revised since the day list was
  // fetched, so wherever it covers the playhead it is the one to believe.
  // Between a programme ending and its poll landing it covers nothing, and
  // there the day list is what knows.
  readonly property bool rightnowCovers: !onDemand && !!schedule && !!player
    && schedule.currentStartMs > 0
    && player.playheadWallMs >= schedule.currentStartMs
    && player.playheadWallMs < schedule.currentEndMs

  // The programme being heard, resolved once. Its name, its picture and the
  // timeline's window all read from this single answer, so they cannot end up
  // describing two different programmes -- looking them up separately is what
  // put one programme's title beside the next one's artwork for the couple of
  // seconds a rollover takes to reach `rightnow`.
  readonly property var heardProgramme: {
    if (!schedule || !player) return null
    // Depend on the lookup table so this re-evaluates when a programme's
    // artwork arrives.
    var ignored = schedule.programImages
    var entry = playheadEpisode
    if (rightnowCovers) {
      // The day list normally holds the same programme, and carries the wide
      // artwork rather than the square one `rightnow` hands out.
      var same = entry && Math.abs(entry.startMs - schedule.currentStartMs) < 60000
      return {
        title: schedule.currentTitle,
        image: (same ? schedule.artworkFor(entry) : "") || schedule.currentImage,
        startMs: schedule.currentStartMs,
        endMs: schedule.currentEndMs
      }
    }
    if (entry) return {
      title: entry.title,
      image: schedule.artworkFor(entry),
      startMs: entry.startMs,
      endMs: entry.endMs
    }
    return null
  }

  readonly property string programmeImage: heardProgramme ? heardProgramme.image : ""

  // What the caption shows: the programme last resolved, held across restarts.
  //
  // Any seek outside what the player holds restarts the stream, and during
  // that the playhead is briefly meaningless -- so the episode lookup comes
  // back empty and the name and picture would drop out and reload, even when
  // the programme has not changed at all. These only move when the programme
  // genuinely does.
  property double heldStartMs: 0
  property string heldTitle: ""
  property string heldImage: ""

  function refreshHeld() {
    if (!player || !player.active) { heldStartMs = 0; heldTitle = ""; heldImage = ""; return }
    var title = programmeTitle
    var image = programmeImage
    var startMs = onDemand ? windowStartMs
      : (heardProgramme ? heardProgramme.startMs : 0)
    // Nothing resolved yet -- mid-restart. Keep what is on screen.
    if (startMs === 0 && title === "") return
    if (startMs !== heldStartMs) {
      heldStartMs = startMs
      heldTitle = title
      heldImage = image
      return
    }
    // Same programme: let a late-arriving title or picture fill in, but never
    // blank one that is already showing.
    if (title !== "") heldTitle = title
    if (image !== "") heldImage = image
  }

  onProgrammeTitleChanged: refreshHeld()
  onProgrammeImageChanged: refreshHeld()
  onWindowStartMsChanged: refreshHeld()

  // The programme actually being heard. A published file is named by whatever
  // asked for it; everything else comes from the one lookup above, the same
  // answer the picture and the timeline use.
  readonly property string programmeTitle: {
    if (onDemand) return player ? player.programme : ""
    return heardProgramme ? heardProgramme.title : ""
  }

  // Back steps to the start of what we can reach; once there, to the previous
  // programme. Forward only exists while we are behind live.
  readonly property bool canStepBack: ready
  // Anywhere but the live edge there is something ahead: the next programme,
  // or the broadcast itself. Being time-shifted inside the DVR window counts,
  // which is not the same as playing a recorded file.
  readonly property bool canStepForward: ready && !isLive
  // In a recorded programme there is always somewhere ahead to go: the rest of
  // it, the next programme, or the live broadcast. Only sitting on the live
  // edge leaves nothing in front.
  readonly property bool canForward15: ready && !isLive
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
    // Where the programme can actually be started from. Once the DVR window
    // or a published file reaches its real start, that is the answer; only
    // when neither does is it limited to the oldest buffered moment.
    if (fullySeekable) return windowStartMs
    return Math.max(windowStartMs, player.seekableStartWallMs)
  }

  // How long after a programme's start a press still counts as "already at
  // the beginning", and so means "the one before this".
  //
  // Wider than the few seconds such a grace would normally be, because
  // arriving here is not instant: restarting the stream takes a moment, and
  // playback can only begin on a segment boundary, so a jump to a programme's
  // start already lands several seconds into it. A tighter window would have
  // expired before the listener could press again, leaving no way to walk
  // back through programmes at all.
  property int startGraceMs: 20000

  readonly property bool atProgrammeStart: !!player
    && (player.playheadWallMs - programmeStartMs) < startGraceMs

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
