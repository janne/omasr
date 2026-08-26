import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Channels.js" as Channels

// Sveriges Radio in the Omarchy bar: an SR monogram that opens a panel of the
// four channel logos. Pressing a channel tunes in, pressing the playing
// channel stops, pressing another switches -- one stream at a time, always.
Panel {
  id: root
  moduleName: "omasr.radio"
  ipcTarget: "omasr"
  // We publish a richer surface than the base's open/close, so we own the
  // IpcHandler below instead of letting Panel install the default one.
  manageIpc: false

  readonly property string p4Region: setting("p4Region", Channels.defaultP4Region)
  readonly property var tiles: Channels.resolved(p4Region)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Keyboard cursor over the four tiles. Dormant until a key is pressed, so
  // opening the panel with the mouse doesn't show a ring nobody asked for.
  property int cursorIndex: 0
  property bool cursorActive: false
  // Set for the instant between Enter's two signals; see the key catcher.
  property bool enterPressed: false

  readonly property bool tintBarIcon: setting("barIcon", "Channel color") === "Channel color"
  readonly property color playingColor: {
    if (!player.active) return barForeground
    var t = tileFor(player.channelKey)
    return t ? t.color : barForeground
  }
  readonly property color barIconColor: player.active
    ? (tintBarIcon ? playingColor : barForeground)
    : Qt.darker(barForeground, 1.5)

  // Station name of whichever tile the pointer is over, so P4's region is
  // visible before you commit to pressing it.
  property string hoveredStation: ""

  readonly property string statusLine: {
    if (hoveredStation !== "") return hoveredStation
    if (!player.available) return "mpv is not installed"
    if (player.status === "error") return player.lastError || "Playback failed"
    if (player.status === "connecting") return "Tuning in to " + player.station + "…"
    if (player.status === "playing") return player.station
    return "Pick a channel"
  }

  function tileFor(key) {
    for (var i = 0; i < tiles.length; i++) if (tiles[i].key === key) return tiles[i]
    return null
  }

  // The tile currently tuned in, whatever the player is actually decoding --
  // stepping back to a published programme keeps the channel identity.
  readonly property var playingTile: tileFor(player.channelKey)

  // Play a published programme file on the tuned-in channel, keeping the
  // channel identity so the tile stays lit and Direkt still returns to live.
  // Play the live stream from a moment inside its DVR window.
  function playLiveFrom(wallMs) {
    if (!playingTile) return
    var tile = playingTile
    liveWindow.locate(wallMs, function(spot) {
      if (!spot) { player.seekToWall(wallMs); return }   // window moved; clamp
      player.playSource({
        key: tile.key,
        name: tile.name,
        station: tile.station,
        // The variant the index was counted in, not the master: a segment
        // index only means anything within its own playlist.
        url: spot.url || tile.url,
        mode: "live",
        startIndex: spot.index,
        // Position 0 of this player is the start of that segment.
        originWallMs: spot.startMs,
        timeShifted: true
      })
    })
  }

  function playProgramme(audio, atSec) {
    if (!audio || !playingTile) return
    player.playSource({
      key: playingTile.key,
      name: playingTile.name,
      station: playingTile.station,
      programme: audio.title,
      url: audio.url,
      mode: "ondemand",
      originWallMs: audio.startMs,
      duration: audio.duration,
      // Clamp into the file. A slot is often filled with a repeat whose file
      // is shorter than the slot it occupies, so a wall-clock offset can point
      // past the end of it -- and opening a file past its end just ends it.
      // Clamping also gives stepping back across a boundary the behaviour that
      // reads correctly: land at the end of the previous programme.
      startAtSec: Math.max(0, Math.min(Number(atSec) || 0,
                                       Math.max(0, (audio.duration || 0) - 5)))
    })
  }

  // Moving about inside the programme.
  //
  // A live stream can only be scrubbed within what has actually been received,
  // which is usually just the last few minutes. Asking for anything older used
  // to clamp silently, so the timeline looked dead and a second press of
  // back-15 appeared to do nothing. Where SR has published the programme, we
  // switch to that file at the requested moment instead -- the same move the
  // back button makes for an earlier programme, and what makes the whole
  // broadcast window reachable rather than only the buffer.
  readonly property bool programmeFullySeekable: player.mode === "ondemand"
    || !!schedule.currentAudio
    || (liveWindow.known && liveWindow.windowStartMs <= transport.windowStartMs)

  // Playing the file of the programme that is on air right now.
  //
  // Whether it is still running comes from the schedule, not from the file's
  // length: SR often fills a slot with a repeat whose file is a different
  // length from the slot it occupies, so the file's end says nothing about
  // when the broadcast ends. Reaching the present in such a programme means
  // the live feed has caught up, and rejoining it is what the listener wants.
  // Is there anything scheduled before what is playing? Cheap enough to bind,
  // and it keeps the back controls honest about whether they can do anything.
  readonly property bool earlierProgrammeExists: transport.windowStartMs > 0
    && schedule.episodeBefore(transport.windowStartMs) !== null

  readonly property bool programmeStillOnAir: player.active
    && schedule.currentStartMs > 0
    && Math.abs(transport.windowStartMs - schedule.currentStartMs) < 60000
    && schedule.currentEndMs > player.nowMs

  // Go to a moment in the broadcast, whichever programme it falls in.
  //
  // The schedule is treated as one continuous timeline, so a target outside
  // the programme being heard is looked up and played from the right offset --
  // that is what lets a step back from the start of a programme land near the
  // end of the one before it.
  function seekToWall(wallMs) {
    if (!player.active) return

    // Asking for the present, in a programme that is still on air, is asking
    // to rejoin the broadcast.
    // Compared against the clock rather than the player's own end, which for
    // a recorded programme is just its last frame.
    if (programmeStillOnAir && wallMs >= player.nowMs - 2000) {
      returnToLive()
      return
    }

    var inThisProgramme = transport.windowEndMs > 0
      && wallMs >= transport.windowStartMs
      && wallMs < transport.windowEndMs

    // Already reachable in what this player holds.
    if (player.mode === "ondemand" && inThisProgramme) { player.seekToWall(wallMs); return }
    // Reachable in what this live player has buffered -- both ends matter: a
    // target past the head needs the stream restarted further on, not a seek
    // that silently clamps.
    if (player.mode === "live"
        && wallMs >= player.seekableStartWallMs - 500
        && wallMs <= player.originWallMs + player.reachableEndSec * 1000) {
      player.seekToWall(wallMs)
      return
    }

    // Inside the live DVR window: restart the live stream there. This works
    // whatever the programme is, so it is preferred over a published file.
    if (liveWindow.covers(wallMs)) { playLiveFrom(wallMs); return }

    // Older than the window. A published file is the only way back that far.
    var episode = schedule.episodeAt(wallMs)
    if (!episode) { player.seekToWall(wallMs); return }
    schedule.resolveAudio(episode.id, episode.startMs, episode.title, function(audio) {
      if (audio) playProgramme(audio, (wallMs - audio.startMs) / 1000)
      else player.seekToWall(wallMs)   // nothing published; clamp where we are
    })
  }

  function seekBy(seconds) {
    if (!player.active) return
    if (seconds > 0) {
      var roomAhead = player.behindLiveSec - 1.0
      // Stepping forward off the end of what has been broadcast means the
      // live feed has caught up: join it rather than stopping short of it.
      if (programmeStillOnAir && roomAhead <= seconds) {
        returnToLive()
        return
      }
      // Off the end of a recorded programme: carry on into the next one,
      // rather than sitting at the end with the button dimmed.
      if (player.mode === "ondemand" && roomAhead <= seconds) {
        stepForward()
        return
      }
      // On a live stream, forward past what this player has buffered needs it
      // restarted further on -- or, if that is the live edge, rejoined.
      if (player.mode === "live" && player.inProcessRoomSec - 1.0 <= seconds) {
        var ahead = player.playheadWallMs + seconds * 1000
        if (ahead >= player.liveWallMs - 5000) returnToLive()
        else seekToWall(ahead)
        return
      }
      player.seekRelative(seconds)
      return
    }
    // Going back. Seek in place while the target is both inside this
    // programme and actually reachable; otherwise let seekToWall find whatever
    // covers that moment, crossing into the previous programme if need be.
    var target = player.playheadWallMs + seconds * 1000
    if (target >= player.seekableStartWallMs && target >= transport.windowStartMs) {
      player.seekRelative(seconds)
      return
    }
    seekToWall(target)
  }

  // The back button: go to the beginning of the programme being heard, unless
  // you are already within a few seconds of it, in which case go to the one
  // before -- the convention every music player uses.
  //
  // On a live stream "the beginning" reaches only as far as the buffer, unless
  // SR has published the programme as a file, in which case we switch to that
  // and start it properly from the top.
  function stepBack() {
    if (!player.active) return
    if (transport.atProgrammeStart) {
      stepToProgrammeBefore(transport.windowStartMs, 6)
    } else if (liveWindow.covers(transport.windowStartMs)) {
      playLiveFrom(transport.windowStartMs)
    } else if (player.mode !== "ondemand" && schedule.currentAudio) {
      playCurrentProgrammeFromStart()
    } else {
      player.seekToStart()
    }
  }

  // Advance to the programme after the one being heard. Running out of
  // schedule, or catching up with what is on air, means rejoining the live
  // feed -- there is nothing later to play.
  function stepForward() {
    if (!player.active) return
    // Already following the broadcast: nothing ahead of it.
    if (player.mode === "live" && !player.timeShifted) { returnToLive(); return }
    // Inside the programme that is on air: the only thing after it is the
    // live broadcast itself.
    if (programmeStillOnAir) { returnToLive(); return }
    stepToProgrammeAfter(transport.windowStartMs, 6)
  }

  function stepToProgrammeAfter(startMs, hopsLeft) {
    if (hopsLeft <= 0) { returnToLive(); return }
    var next = schedule.episodeAfter(startMs)
    if (!next) { returnToLive(); return }
    // The programme on air is played from its beginning like any other, rather
    // than being skipped over into the live feed. Stepping forward once more
    // from inside it is what joins the broadcast.
    playProgrammeAt(next, function() { root.stepToProgrammeAfter(next.startMs, hopsLeft - 1) })
  }

  // Start a scheduled programme at its beginning, by whichever route reaches
  // it. The DVR window is tried first: it covers every programme inside it,
  // published or not, which a file lookup does not.
  function playProgrammeAt(episode, onUnavailable) {
    if (liveWindow.covers(episode.startMs)) {
      player.announceTitle(programmeLabel(episode.title))
      playLiveFrom(episode.startMs)
      return
    }
    schedule.resolveAudio(episode.id, episode.startMs, episode.title, function(audio) {
      if (audio) {
        player.announceTitle(root.programmeLabel(audio.title))
        playProgramme(audio, 0)
      } else {
        onUnavailable()
      }
    })
  }

  // How a programme is named on MPRIS, and so in the notification the media
  // keys raise.
  function programmeLabel(title) {
    return title && title !== "" ? player.station + " — " + title : player.station
  }

  // Walk back through the schedule from `startMs`, playing the first
  // programme SR has actually published. Unpublished ones are skipped rather
  // than dead-ending the button on them -- a run of short news bulletins
  // between produced programmes is common, and none of those have files.
  function stepToProgrammeBefore(startMs, hopsLeft) {
    if (hopsLeft <= 0) return
    var prev = schedule.episodeBefore(startMs)
    if (!prev) return
    playProgrammeAt(prev, function() { root.stepToProgrammeBefore(prev.startMs, hopsLeft - 1) })
  }

  // The current programme from its real start, where SR has published it --
  // which reaches further back than the live buffer does.
  function playCurrentProgrammeFromStart() { playProgramme(schedule.currentAudio, 0) }

  // Back to the live broadcast, from wherever you are. Seeking to the live
  // edge only works while a live stream is what is playing; a published
  // programme has no live edge, so that case re-tunes the channel instead.
  function returnToLive() {
    // Seeking to the live edge only works for a player that is following it.
    // A published file has no live edge, and a live player started inside the
    // DVR window has a cache that begins where it started -- both have to be
    // re-tuned.
    // Seeking to the live edge only works for a player still following it.
    // A published file has no live edge; one started inside the DVR window has
    // a cache beginning where it started; and after the machine sleeps, or a
    // long pause, even a plain live player's cache sits far behind the clock.
    // All three have to be re-tuned rather than seeked.
    if (player.canReachLive) player.goLive()
    else if (playingTile) {
      player.announceTitle(programmeLabel(schedule.currentTitle))
      player.play(playingTile)
    }
  }

  function indexOfKey(key) {
    for (var i = 0; i < tiles.length; i++) if (tiles[i].key === key) return i
    return -1
  }

  function activate(index) {
    if (index < 0 || index >= tiles.length) return
    player.toggle(tiles[index])
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    // The tiles are one row, so vertical keys walk it too -- j/k should not
    // be dead keys just because the layout happens to be horizontal.
    var step = dx !== 0 ? dx : dy
    if (step === 0) return
    cursorIndex = Math.max(0, Math.min(tiles.length - 1, cursorIndex + step))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    hoveredStation = ""
    cursorActive = false
    // Park the cursor on whatever is playing, so Enter stops it.
    var playingIndex = indexOfKey(player.channelKey)
    cursorIndex = playingIndex >= 0 ? playingIndex : 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Player {
    id: player
    clientName: "Sveriges-Radio"
    // What the media keys and the bar's now-playing widget see.
    mediaTitle: transport.heldTitle !== ""
      ? player.station + " — " + transport.heldTitle
      : player.station
  }

  Connections {
    target: player
    // A programme running out continues with the next one, just as the
    // broadcast did -- and rejoins the live feed once it catches up.
    function onProgrammeEnded() { root.stepForward() }

    // Back from sleep: the schedule has moved on and the DVR window has slid
    // right past what we knew of it. Refresh both, or the timeline keeps
    // describing whatever was on when the machine went to sleep.
    // The media keys' skip buttons step between programmes, which is the only
    // thing "next track" can sensibly mean on live radio.
    function onNextRequested() { root.stepForward() }
    function onPreviousRequested() { root.stepBack() }

    function onWokeFromSuspend() {
      schedule.refresh()
      schedule.loadDays()
      liveWindow.refresh()
    }
  }

  LiveWindow {
    id: liveWindow
    masterUrl: root.playingTile ? root.playingTile.url : ""
  }

  Schedule {
    id: schedule
    channelId: root.playingTile ? root.playingTile.id : 0
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // `omarchy-shell omasr play p3`, and so on -- so the channels can be
    // bound to Hyprland keys without opening the panel at all.
    function play(channel: string): string {
      var t = root.tileFor(String(channel).toLowerCase())
      if (!t) return "unknown channel: " + channel
      player.play(t)
      return "playing " + t.station
    }
    function stop(): string { player.stop(); return "stopped" }
    function playPause(channel: string): string {
      var t = root.tileFor(String(channel).toLowerCase())
      if (!t) return "unknown channel: " + channel
      player.toggle(t)
      return player.active ? "playing " + player.station : "stopped"
    }
    function status(): string {
      if (!player.active) return "idle"
      // `seek` reports whether the mpv control socket is live: when it is
      // not, every transport control is correctly disabled, which looks like
      // the panel has gone dead.
      var seek = player.canSeek ? "seek" : "NOSEEK"
      var where = player.mode === "ondemand"
        ? "recorded"
        : (player.atLive ? "live" : "-" + Math.round(player.behindLiveSec) + "s")
      // The playhead as a clock time, which is what the timeline shows and is
      // comparable across live and published playback.
      var at = player.playheadWallMs > 0
        ? Qt.formatDateTime(new Date(player.playheadWallMs), "HH:mm:ss") : "--:--:--"
      return player.status + " " + player.station
        + " [" + where + " " + seek + " at " + at + "]"
    }

    // Transport, so the controls can be bound to Hyprland keys too.
    function pause(): string {
      player.togglePause()
      return player.paused ? "paused" : "playing"
    }
    function back(seconds: string): string {
      root.seekBy(-Math.abs(Number(seconds) || 15))
      return "ok"
    }
    function forward(seconds: string): string {
      root.seekBy(Math.abs(Number(seconds) || 15))
      return "ok"
    }
    function live(): string { root.returnToLive(); return "live" }
    function restart(): string { player.seekToStart(); return "ok" }
    function previous(): string {
      root.stepToProgrammeBefore(transport.windowStartMs, 6)
      return "stepping back"
    }
    // Same rule the back button follows.
    function next(): string {
      root.stepForward()
      return "stepping forward"
    }
    // What clicking the timeline does: go to a clock time today (HH:MM or
    // HH:MM:SS). Exposed mainly so the timeline's path is testable.
    function seekTo(clock: string): string {
      var m = String(clock).match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/)
      if (!m) return "expected HH:MM or HH:MM:SS"
      var d = new Date()
      d.setHours(Number(m[1]), Number(m[2]), Number(m[3] || 0), 0)
      root.seekToWall(d.getTime())
      return "ok"
    }
    function stepBack(): string {
      root.stepBack()
      return player.mode === "ondemand"
        ? "playing " + player.programme
        : "rewound"
    }
    function fromStart(): string {
      if (!schedule.currentAudio) {
        player.seekToStart()
        return "no published file; rewound to the start of the buffer"
      }
      root.playCurrentProgrammeFromStart()
      return "playing " + schedule.currentAudio.title + " from the start"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: player.active ? player.station : "Sveriges Radio"
    iconComponent: Component {
      Item {
        SrMark {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor

          // A slow breath while connecting; nothing once audio is flowing.
          SequentialAnimation on opacity {
            running: player.status === "connecting"
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 560; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.0;  duration: 560; easing.type: Easing.InOutSine }
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      // Middle-click stops without needing the panel at all.
      if (buttonCode === Qt.MiddleButton) player.stop()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // contentWidth is the whole card, padding included -- unlike
    // fittedContentHeight, KeyboardPanel adds no horizontal inset of its own.
    // Size to the tile row, which is always the widest thing in the panel, and
    // leave room for the ring an active tile draws outside its own bounds.
    contentWidth: panel.fittedContentWidth(Math.max(tileRow.implicitWidth,
        player.active ? Style.space(268) : 0)
      + panel.padding * 2
      + Border.left(panel.borderSpec) + Border.right(panel.borderSpec)
      + Style.space(8))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      // PanelKeyCatcher emits returnRequested() just before activateRequested()
      // for Enter, and only activateRequested() for Space -- so the flag set
      // here is what tells them apart.
      onReturnRequested: root.enterPressed = true
      onActivateRequested: {
        var wasEnter = root.enterPressed
        root.enterPressed = false
        // Space is play/pause, as it is in every other player. Enter keeps
        // meaning "the channel under the cursor", and Space falls back to that
        // when there is nothing playing to pause.
        if (!wasEnter && player.active) player.togglePause()
        else root.activate(root.cursorIndex)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        // 1-4 tune directly; s stops.
        var n = parseInt(t, 10)
        if (n >= 1 && n <= root.tiles.length) {
          root.cursorActive = true
          root.cursorIndex = n - 1
          root.activate(n - 1)
        } else if (t === "s" || t === "S") {
          player.stop()
        } else if (t === ",") {
          root.seekBy(-15)
        } else if (t === ".") {
          root.seekBy(15)
        } else if (t === "d" || t === "D") {
          root.returnToLive()
        } else if (t === "p" || t === "P") {
          player.togglePause()
        }
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          width: parent.width
          title: "Sveriges Radio"
          meta: root.statusLine
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            SrMark {
              iconSize: Style.font.heading
              color: root.foreground
            }
          }
        }

        Row {
          id: tileRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(12)

          Repeater {
            model: root.tiles

            delegate: ChannelTile {
              required property var modelData
              required property int index

              channelKey: modelData.key
              label: modelData.station
              channelColor: modelData.color
              foreground: root.foreground
              fontFamily: root.fontFamily
              playing: player.channelKey === modelData.key && player.status === "playing"
              connecting: player.channelKey === modelData.key && player.status === "connecting"
              paused: player.paused
              backgrounded: player.active && player.channelKey !== modelData.key
              hasCursor: root.cursorActive && root.cursorIndex === index
              onHoveringChanged: root.hoveredStation = hovering ? modelData.station : ""
              onActivated: {
                root.cursorActive = false
                root.cursorIndex = index
                root.activate(index)
              }
            }
          }
        }

        Transport {
          id: transport
          width: parent.width
          visible: player.active && player.status !== "error"
          player: player
          schedule: schedule
          foreground: root.foreground
          fontFamily: root.fontFamily
          fullySeekable: root.programmeFullySeekable
          canCatchUp: root.programmeStillOnAir
          hasEarlierProgramme: root.earlierProgrammeExists
          onSeekRequested: function(wallMs) { root.seekToWall(wallMs) }
          onSeekByRequested: function(seconds) { root.seekBy(seconds) }
          onStepBackRequested: root.stepBack()
          onStepForwardRequested: root.stepForward()
          onPlayCurrentFromStart: root.playCurrentProgrammeFromStart()
          onReturnToCurrent: root.returnToLive()
        }

        // The programme being heard: its name, whatever SR is announcing over
        // the stream, and its cover art. Reserves no space when there is
        // nothing to say.
        Column {
          id: caption
          width: parent.width
          spacing: Style.space(7)
          // Stays put through a restart: hiding it while the stream comes back
          // is what made the caption blink on every seek.
          visible: player.active && player.status !== "error"

          Text {
            id: captionTitle
            width: parent.width
            text: transport.heldTitle
            visible: text !== ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }

          Text {
            id: captionNow
            width: parent.width
            // Only when it says something the programme name does not.
            text: {
              var icy = player.nowPlaying
              var show = transport.heldTitle
              if (icy === "" || icy === show) return ""
              if (show !== "" && icy.indexOf(show) === 0)
                return icy.substring(show.length).replace(/^[\s,\u00b7-]+/, "")
              return icy
            }
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WordWrap
          }

          // Cover art across the panel, shown whole. Its height follows the
          // artwork's own proportions rather than being fixed, so nothing is
          // cropped away -- SR composes these wide, and the interesting part
          // is often at an edge.
          Rectangle {
            id: cover
            width: parent.width
            height: coverImage.status === Image.Ready && coverImage.implicitWidth > 0
              ? Math.round(width * coverImage.implicitHeight / coverImage.implicitWidth)
              : 0
            visible: transport.heldImage !== "" && coverImage.status === Image.Ready
            radius: Math.max(Style.space(3), Style.cornerRadius)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
            clip: true

            Image {
              id: coverImage
              anchors.fill: parent
              // Gated rather than bound straight to the URL, so a failed load
              // can be asked for again: an Image that has errored stays
              // errored, and clearing the source and putting it back is what
              // makes it go to the network a second time.
              property bool wanted: true
              property int attempts: 0
              source: wanted ? transport.heldImage : ""
              // Loaded off the render thread, and kept so a rollover between
              // programmes does not blink. The source is 2048 wide; decoding
              // it at panel size keeps that out of memory.
              asynchronous: true
              cache: true
              fillMode: Image.PreserveAspectFit
              sourceSize.width: Math.max(64, cover.width * 2)

              // A name lookup that fails -- which happens on a connection
              // coming back up, and just after the shell restarts -- would
              // otherwise leave the panel without a picture until the
              // programme changed, since nothing re-requests it.
              onStatusChanged: if (status === Image.Error && attempts < 4) coverRetry.restart()

              Timer {
                id: coverRetry
                interval: 3000 * (coverImage.attempts + 1)
                repeat: false
                onTriggered: {
                  coverImage.attempts++
                  coverImage.wanted = false
                  coverImage.wanted = true
                }
              }

              Connections {
                target: transport
                // A different programme is a fresh start: its picture has not
                // failed yet, whatever the last one did.
                function onHeldImageChanged() {
                  coverRetry.stop()
                  coverImage.attempts = 0
                  coverImage.wanted = true
                }
              }
            }
          }
        }
      }
    }
  }
}
