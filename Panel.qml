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
      startAtSec: Math.max(0, Number(atSec) || 0)
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

  // Playing the file of the programme that is on air right now.
  //
  // Whether it is still running comes from the schedule, not from the file's
  // length: SR often fills a slot with a repeat whose file is a different
  // length from the slot it occupies, so the file's end says nothing about
  // when the broadcast ends. Reaching the present in such a programme means
  // the live feed has caught up, and rejoining it is what the listener wants.
  readonly property bool programmeStillOnAir: player.mode === "ondemand"
    && schedule.currentStartMs > 0
    && Math.abs(player.originWallMs - schedule.currentStartMs) < 60000
    && schedule.currentEndMs > player.nowMs

  function seekToWall(wallMs) {
    if (!player.active) return
    // Asking for the present, in a programme that is still on air, is asking
    // to rejoin the broadcast.
    if (programmeStillOnAir && wallMs >= player.liveWallMs - 2000) {
      returnToLive()
      return
    }
    if (player.mode === "ondemand" || wallMs >= player.seekableStartWallMs - 500) {
      player.seekToWall(wallMs)
      return
    }
    var audio = schedule.currentAudio
    if (audio) playProgramme(audio, (wallMs - audio.startMs) / 1000)
    else player.seekToWall(wallMs)   // clamps to the oldest buffered moment
  }

  function seekBy(seconds) {
    if (!player.active) return
    if (seconds > 0) {
      // Stepping forward off the end of what has been broadcast means the
      // live feed has caught up: join it rather than stopping short of it.
      if (programmeStillOnAir && player.behindLiveSec - 1.0 <= seconds) {
        returnToLive()
        return
      }
      player.seekRelative(seconds)
      return
    }
    if (player.mode === "ondemand") {
      player.seekRelative(seconds)
      return
    }
    // Going back past what the buffer holds: hand off to the published file.
    var target = player.playheadWallMs + seconds * 1000
    if (target >= player.seekableStartWallMs) player.seekRelative(seconds)
    else seekToWall(target)
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
    if (transport.atProgrammeStart) stepToProgrammeBefore(transport.windowStartMs, 6)
    else if (player.mode !== "ondemand" && schedule.currentAudio) playCurrentProgrammeFromStart()
    else player.seekToStart()
  }

  // Walk back through the schedule from `startMs`, playing the first
  // programme SR has actually published. Unpublished ones are skipped rather
  // than dead-ending the button on them -- a run of short news bulletins
  // between produced programmes is common, and none of those have files.
  function stepToProgrammeBefore(startMs, hopsLeft) {
    if (hopsLeft <= 0) return
    var prev = schedule.episodeBefore(startMs)
    if (!prev) return
    schedule.resolveAudio(prev.id, prev.startMs, prev.title, function(audio) {
      if (audio) playProgramme(audio)
      else root.stepToProgrammeBefore(prev.startMs, hopsLeft - 1)
    })
  }

  // The current programme from its real start, where SR has published it --
  // which reaches further back than the live buffer does.
  function playCurrentProgrammeFromStart() { playProgramme(schedule.currentAudio, 0) }

  // Back to the live broadcast, from wherever you are. Seeking to the live
  // edge only works while a live stream is what is playing; a published
  // programme has no live edge, so that case re-tunes the channel instead.
  function returnToLive() {
    if (player.mode === "ondemand") {
      if (playingTile) player.play(playingTile)
    } else {
      player.goLive()
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
    clientName: "Sveriges Radio"
  }

  Connections {
    target: player
    // Reaching the end of a published programme means the broadcast has moved
    // on without us; rejoin it rather than falling silent.
    function onProgrammeEnded() { root.returnToLive() }
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
      onActivateRequested: root.activate(root.cursorIndex)
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
          onSeekRequested: function(wallMs) { root.seekToWall(wallMs) }
          onSeekByRequested: function(seconds) { root.seekBy(seconds) }
          onStepBackRequested: root.stepBack()
          onPlayCurrentFromStart: root.playCurrentProgrammeFromStart()
          onReturnToCurrent: root.returnToLive()
        }

        // Whatever SR is announcing over the stream right now, when it sends
        // it. Reserves no space when the stream is silent about it.
        Text {
          width: parent.width
          visible: player.status === "playing"
            && (player.nowPlaying !== "" || transport.programmeTitle !== "")
          text: {
            var show = transport.programmeTitle
            var icy = player.nowPlaying
            if (show === "") return icy
            if (icy === "" || icy === show) return show
            // SR often repeats the programme name in the ICY title; only add
            // it when it is actually saying something else.
            if (icy.indexOf(show) === 0) return icy
            return show + " · " + icy
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
