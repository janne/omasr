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

  readonly property string statusLine: {
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

  // Step back to the previous programme, and back out of it again.
  function playPreviousProgramme() {
    var audio = schedule.prevAudio
    if (!audio || !playingTile) return
    player.playSource({
      key: playingTile.key,
      name: playingTile.name,
      station: playingTile.station,
      url: audio.url,
      mode: "ondemand",
      originWallMs: audio.startMs,
      duration: audio.duration
    })
  }

  function returnToLive() {
    if (playingTile) player.play(playingTile)
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
      var where = player.mode === "ondemand"
        ? "recorded"
        : (player.atLive ? "live" : "-" + Math.round(player.behindLiveSec) + "s")
      return player.status + " " + player.station + " [" + where + "]"
    }

    // Transport, so the controls can be bound to Hyprland keys too.
    function pause(): string {
      player.togglePause()
      return player.paused ? "paused" : "playing"
    }
    function back(seconds: string): string {
      var n = Number(seconds) || 15
      player.seekRelative(-Math.abs(n))
      return "ok"
    }
    function forward(seconds: string): string {
      var n = Number(seconds) || 15
      player.seekRelative(Math.abs(n))
      return "ok"
    }
    function live(): string { player.goLive(); return "live" }
    function restart(): string { player.seekToStart(); return "ok" }
    function previous(): string {
      if (!schedule.prevAudio) return "no published previous programme"
      root.playPreviousProgramme()
      return "playing " + schedule.prevAudio.title
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
          player.seekRelative(-15)
        } else if (t === ".") {
          player.seekRelative(15)
        } else if (t === "d" || t === "D") {
          player.goLive()
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
          onPlayPrevious: root.playPreviousProgramme()
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
