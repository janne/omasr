import QtQuick
import Quickshell
import Quickshell.Io

// Playback engine for the channel buttons and the transport controls.
//
// The stream is decoded by an mpv child process rather than by QtMultimedia
// inside the shell. omarchy-shell is one long-running process that owns the
// bar, the panels, and the lock screen, so a decoder that wedges or crashes on
// a bad stream would take the whole desktop shell with it. A child process
// costs one fork and can simply be killed.
//
// Rewinding live radio
// --------------------
// None of SR's public endpoints offer a seekable DVR window -- `srapi/<id>.mp3`
// and the misleadingly named `hls/<id>.m3u8` both resolve to a plain ICY
// stream. What makes the transport work is mpv's own demuxer back-cache: with
// `--demuxer-max-back-bytes` set, mpv can seek backwards through everything it
// has already pulled down, even though it reports `seekable: false`. So the
// rewindable window is "everything since you tuned in", bounded by the cache
// size, and `Transport.qml` draws exactly that region as available.
//
// Two source modes:
//   live       an SR channel stream. Position is wall-clock derived; the live
//              edge is the head of the demuxer cache.
//   ondemand   a published episode file, which is ordinarily seekable and
//              carries a real duration.
//
// The state machine has one running process at most. `play` on a different
// channel while one is up has to wait for the old child to actually exit --
// Process.running stays true from the SIGTERM until the child is reaped -- so
// the request parks in `pendingChannel` and onExited picks it up.
Item {
  id: root

  // Empty while stopped; otherwise the Channels.js key ("p1".."p4") that is
  // playing or being connected to.
  property string channelKey: ""
  property string channelName: ""
  property string station: ""
  // Programme title, when playing a published file rather than the live feed.
  property string programme: ""

  // "idle" | "connecting" | "playing" | "error"
  property string status: "idle"
  property string lastError: ""

  // Programme title from the stream's ICY metadata, when SR sends one.
  property string nowPlaying: ""

  // False when mpv isn't installed; the panel surfaces this instead of
  // letting every button press quietly do nothing.
  property bool available: true

  // mpv-mpris, which Omarchy installs alongside mpv. Loading it puts the radio
  // on the MPRIS bus, which is what the media keys already talk to -- so they
  // control it without touching anyone's Hyprland config. `--no-config` means
  // it has to be asked for explicitly rather than picked up from /etc/mpv.
  property string mprisScript: ""

  // What MPRIS -- and so the media keys and the bar's now-playing widget --
  // calls this. Follows the programme once one is known.
  property string mediaTitle: ""
  // Name what is about to play, on the process that is still running.
  //
  // A step between programmes replaces the whole player, and whatever asked
  // for it -- the media keys, say -- is showing a notification within about a
  // second. A replacement takes longer than that to appear on the bus, so the
  // outgoing one carries the announcement.
  function announceTitle(title) {
    if (!canSeek || !title) return
    ipc.command(["set_property", "force-media-title", title])
  }

  function pushMediaTitle() {
    if (canSeek && mediaTitle !== "")
      ipc.command(["set_property", "force-media-title", mediaTitle])
  }
  onMediaTitleChanged: pushMediaTitle()
  // The title is usually known before the control socket is, so it has to be
  // sent again once there is somewhere to send it.
  onCanSeekChanged: pushMediaTitle()

  readonly property bool active: channelKey !== ""

  // A published programme played through to its end. Not a failure -- the
  // panel decides what to do next, which is to rejoin the live broadcast.
  signal programmeEnded()

  // The media keys' skip buttons, arriving over MPRIS.
  signal nextRequested()
  signal previousRequested()

  // Where mpv is in the playlist described below. Playback sits at 1.
  property int playlistPos: 1

  // Name shown to the system mixer, so the stream is identifiable in
  // Omarchy's audio panel and in pavucontrol.
  //
  // No spaces: mpv-mpris builds its D-Bus name from this, and a space makes an
  // invalid bus name. That does not merely skip MPRIS -- the failed assertion
  // takes the script down and leaves mpv sitting idle, playing nothing.
  property string clientName: "Sveriges-Radio"

  // How far back the transport can rewind. 64 MiB is roughly an hour of SR's
  // ~128 kbps streams, which covers a typical programme. It is a ceiling, not
  // an allocation: mpv holds only what it has actually read, so the cost grows
  // with how long you have been listening rather than being paid up front.
  property string backCache: "64MiB"
  // The read-ahead ceiling is never reached on a live stream -- you cannot
  // fetch audio that has not been broadcast yet -- so it stays small.
  property string forwardCache: "16MiB"

  // Live streams drop. Reconnect a bounded number of times before giving up,
  // so a passing network blip doesn't silently end the broadcast.
  property int maxReconnects: 3
  property int reconnectDelayMs: 1500

  // --- transport state (pushed by mpv via observe_property) ----------------

  // "live" | "ondemand"
  property string mode: "live"

  // The live stream was started at a chosen point in the DVR window rather
  // than at the live edge. Such a player cannot seek forward to live -- its
  // cache begins where it started -- so rejoining live means re-tuning.
  property bool dvrStarted: false
  property real timePos: 0
  // Head of the demuxer cache: in live mode this is the live edge.
  property real cacheEnd: 0
  // Oldest timestamp still cached, when mpv reports one.
  property real cacheBegin: 0
  property bool paused: false
  // Real duration, on-demand only; 0 for a live stream.
  property real duration: 0

  // Wall-clock time (ms since epoch) that playback position 0 corresponds to.
  // For a live stream that is the moment we connected; for an episode it is
  // the moment that episode started broadcasting.
  property double originWallMs: 0

  // Wall clock, ticked while something is playing so that bindings depending
  // on "now" -- chiefly how far forward it is possible to go -- stay live.
  property double nowMs: Date.now()

  readonly property double playheadWallMs: originWallMs + timePos * 1000

  // How far behind the broadcast the playhead may sit and still count as
  // following it.
  //
  // Ordinary live playback runs a segment or two back: measured on SR's HLS,
  // 2 to 12 seconds after seeking to the cache head and 14 to 20 straight
  // after tuning in, which starts a segment further back. This clears both
  // bands, and a stall of half a minute with them, while still being far
  // under any sleep worth noticing -- and a sleep is caught by the clock tick
  // regardless of this figure.
  property real liveToleranceSec: 90

  // Whether the live edge can be reached by seeking inside what this player
  // already holds. After the machine sleeps, or the stream stalls, it holds
  // nothing newer than the moment it fell behind, and seeking to the head of
  // that cache lands where the playhead already is. Reaching live then means
  // re-tuning.
  //
  // Read from the playhead rather than from the cache head, which is not an
  // independent measurement: `originWallMs` is re-anchored below so that the
  // cache head *is* now, which made the older test true by construction and
  // left this permanently, quietly true.
  readonly property bool canReachLive: mode === "live"
    && !dvrStarted
    && behindLiveSec < liveToleranceSec

  // The furthest point that can be reached.
  //
  // On a live stream that is the head of the cache. In a published file it is
  // the end of the file -- except for a programme that is still on air, where
  // the file's duration is its *scheduled* length and runs into the future.
  // Audio that has not been broadcast yet cannot be played, so the present
  // moment is the real limit.
  // Stay a couple of seconds clear of the end of a file: seeking onto EOF
  // ends playback, and mpv exiting there looks exactly like a dropped stream.
  readonly property real reachableEndSec: mode === "live"
    ? Math.max(0, cacheEnd - 0.5)
    : Math.max(0, Math.min(duration - 5, (nowMs - originWallMs) / 1000))

  // How far this player can seek without being restarted: everything it has
  // buffered, which for a DVR-started stream begins where it started.
  readonly property real inProcessRoomSec: Math.max(0, reachableEndSec - timePos)

  // The live edge. On a live stream that is simply now -- the cache head is
  // only where *this* player has read to, which after starting inside the DVR
  // window says nothing about how far behind the broadcast we are.
  readonly property double liveWallMs: mode === "live"
    ? nowMs
    : originWallMs + reachableEndSec * 1000
  // Oldest point we could seek back to.
  readonly property double seekableStartWallMs: originWallMs + cacheBegin * 1000

  readonly property real behindLiveSec: Math.max(0, (liveWallMs - playheadWallMs) / 1000)

  // Whether the listener has deliberately stepped off the live edge.
  // Rewinding and pausing are what set this; Direkt is what clears it.
  property bool timeShifted: false

  // Following the broadcast. Being asked to stay there is not the same as
  // being there: a machine that slept leaves the player holding audio as old
  // as the sleep, without anything having been rewound. So the lamp answers
  // to the measured lag as well as to the listener's own intent -- otherwise
  // it reports live while playing an hour-old programme, and the one control
  // that would fix it looks like it is already doing its job.
  readonly property bool atLive: mode === "live" && !timeShifted
    && behindLiveSec < liveToleranceSec

  readonly property bool canSeek: status === "playing" && ipc.ready

  // How much is actually behind the playhead. At the start of a published
  // programme, or at the oldest thing still buffered, this is zero and there
  // is nowhere left to rewind to.
  readonly property real seekableBackSec: Math.max(0, timePos - cacheBegin)

  // --- internal ------------------------------------------------------------

  // Set before we kill the child ourselves, so onExited can tell a deliberate
  // stop from the stream dying on us.
  property bool _expectedStop: false
  property var _pendingSource: null
  property int _reconnects: 0
  property var _source: null
  property int _spawnSerial: 0

  readonly property string _runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"

  // A source is { key, name, station, url, mode, originWallMs, duration }.
  function playSource(source) {
    if (!source) return
    _reconnects = 0
    _start(source)
  }

  // Tune in to a live channel (a Channels.js entry). `paused` is for a session
  // resumed from a note that was kept paused: coming back from a reload must
  // not start audio the listener had stopped.
  function play(channel, paused) {
    if (!channel) return
    playSource({
      key: channel.key,
      name: channel.name,
      station: channel.station,
      url: channel.url,
      mode: "live",
      originWallMs: 0,   // stamped at spawn: "now"
      duration: 0,
      paused: !!paused
    })
  }

  function stop() {
    // A reconnect may be armed with no child running (we are inside the delay
    // window). Disarm it before clearing state, or it would fire into a
    // stopped player.
    reconnectTimer.stop()
    _pendingSource = null
    _reconnects = 0
    _source = null
    channelKey = ""
    channelName = ""
    station = ""
    programme = ""
    nowPlaying = ""
    status = "idle"
    lastError = ""
    _resetTransport()
    _kill()
    stopSweep.restart()
  }

  // The behavior the four channel buttons implement: the playing channel
  // stops, any other channel switches.
  function toggle(channel) {
    if (!channel) return
    if (channelKey === channel.key) stop()
    else play(channel)
  }

  // --- transport commands --------------------------------------------------

  function togglePause() {
    if (!canSeek) return
    // Pausing a live stream is itself a time shift: the broadcast carries on
    // without you, and resuming picks up where you stopped.
    if (!paused && mode === "live") timeShifted = true
    ipc.command(["set_property", "pause", !paused])
  }

  function seekRelative(seconds) {
    if (!canSeek) return
    // Never let a forward seek run past what has actually been broadcast --
    // in either mode. On a live stream mpv would sit at the cache head with
    // the playhead pinned, which reads as a hang; in a programme still on air
    // it would step into a part of the file that does not exist yet.
    if (seconds > 0) {
      // Clamped by what is buffered, not by the distance to live: reaching
      // further forward than that needs a restart, which the panel arranges.
      var room = inProcessRoomSec - 1.0
      if (room <= 0) return
      seconds = Math.min(seconds, room)
    }
    if (seconds < 0 && mode === "live") timeShifted = true
    ipc.command(["seek", seconds, "relative"])
  }

  // Jump to a wall-clock instant, clamped to what we can actually reach.
  function seekToWall(wallMs) {
    if (!canSeek) return
    var target = (wallMs - originWallMs) / 1000
    var lo = Math.max(0, cacheBegin)
    var hi = Math.max(lo, reachableEndSec)
    var clamped = Math.max(lo, Math.min(hi, target))
    // Scrubbing to within a couple of seconds of the head counts as going back
    // to live, so the lamp lights up rather than leaving a Direkt button that
    // would do nothing. Not so for a player started inside the DVR window:
    // its head is wherever it has read to, nowhere near the broadcast, so it
    // is time-shifted until it is re-tuned.
    if (mode === "live") timeShifted = dvrStarted || (hi - clamped) > 2
    ipc.command(["seek", clamped, "absolute"])
  }

  // The Direkt button: jump to the head of the cache, which is live.
  function goLive() {
    if (!canSeek || mode !== "live") return
    ipc.command(["seek", Math.max(0, cacheEnd - 0.5), "absolute"])
    if (paused) ipc.command(["set_property", "pause", false])
    timeShifted = false
  }

  // The earliest point reachable: position 0 of a published file, or the
  // oldest thing still buffered on a live stream.
  function seekToStart() {
    if (!canSeek) return
    if (mode === "live") timeShifted = true
    ipc.command(["seek", mode === "ondemand" ? 0 : Math.max(0, cacheBegin), "absolute"])
  }

  // --- process lifecycle ---------------------------------------------------

  // mpv unlinks its IPC socket when it exits normally, but not when it is
  // signalled. Each spawn uses a fresh path, so a leftover is harmless -- it
  // is just litter in the runtime dir, and worth clearing anyway.
  function _removeSocket() {
    var path = ipc.socketPath
    if (path === "") return
    ipc.socketPath = ""
    // Only ever the path we tracked. A blanket sweep would race: the removal
    // is detached, and by the time it ran a replacement child could already
    // have created its own socket.
    Quickshell.execDetached(["rm", "-f", path])
  }

  // mpv outlives the widget that started it. A plugin reload -- which
  // removing or editing any plugin causes -- destroys the panel and builds it
  // again, but the child it spawned carries on, orphaned: still playing, no
  // longer reachable over an IPC socket nothing knows the path of any more.
  // It dies eventually, when it next writes to a pipe with no reader left,
  // which can be seconds later and sounds like the radio refusing to stop.
  //
  // So a life that is starting sweeps up whatever the one before it left
  // running, before starting anything of its own. Matched on the socket path,
  // which no other program has a reason to name.
  function sweepStrays() {
    // Without the leading dashes, which pkill would read as options of its own.
    Quickshell.execDetached(["pkill", "-f", "input-ipc-server=[^ ]*/omasr-mpv-"])
  }

  function _resetTransport(startAtSec) {
    playlistPos = 1
    timePos = Number(startAtSec) || 0
    cacheEnd = 0
    cacheBegin = 0
    duration = 0
    paused = false
  }

  function _kill() {
    ipc.teardown()
    if (proc.running) {
      _expectedStop = true
      proc.running = false
    }
  }

  function _start(source) {
    // Same reason as in stop(): a pending reconnect for the previous source
    // must not fire on top of the one we are switching to.
    reconnectTimer.stop()
    channelKey = source.key
    channelName = source.name
    station = source.station
    programme = source.programme || ""
    nowPlaying = ""
    lastError = ""
    status = "connecting"
    mode = source.mode || "live"
    // A source that opens paused is off the live edge whatever else it says:
    // that is what pausing did to the session being resumed.
    timeShifted = !!source.timeShifted || !!source.paused
    dvrStarted = isFinite(Number(source.startIndex)) && Number(source.startIndex) >= 0
    _source = source
    _resetTransport(source.startAtSec)
    // Shown straight away rather than when mpv reports the property back, so
    // the transport does not flash as playing on the way in.
    paused = !!source.paused

    // A previous child is still shutting down; hand off to onExited.
    if (proc.running) {
      _pendingSource = source
      _expectedStop = true
      ipc.teardown()
      proc.running = false
      return
    }
    _pendingSource = null
    _spawn()
  }

  function _spawn() {
    if (!_source) return
    // A fresh socket path per spawn, so a not-yet-reaped child's stale socket
    // can never be mistaken for the new one's.
    _spawnSerial++
    var socketPath = _runtimeDir + "/omasr-mpv-" + _spawnSerial + ".sock"

    // Position 0 of a live stream is the moment we connect.
    // A first guess only, for live: mpv joins an HLS stream a few segments
    // behind its end, so position 0 is not actually now. It is corrected from
    // the cache as soon as mpv says where it really is. A DVR start names its
    // own origin and needs no correcting.
    originWallMs = _source.originWallMs || Date.now()
    if (mode === "ondemand") duration = _source.duration || 0
    var startAt = Number(_source.startAtSec) || 0
    var startIndex = Number(_source.startIndex)

    // The same stream three times, playing the middle one.
    //
    // mpv-mpris offers Next and Previous only when mpv's playlist has
    // somewhere to go, and it is the media keys' skip buttons that ask for
    // them. A single entry leaves them greyed out and the key press
    // unhandled. Moving off the middle entry is intercepted below and turned
    // into a step between programmes; the entry mpv starts loading is thrown
    // away with the process.
    proc.command = [
      "mpv", _source.url, _source.url, _source.url, "--playlist-start=1",
      "--no-video",
      // Ignore ~/.config/mpv: a user's own profile (forced video output,
      // a different ao, --shuffle) should not reach into the bar widget.
      "--no-config",
      "--no-input-terminal",
      "--idle=no",
      "--quiet",
      "--audio-client-name=" + clientName,
      "--force-media-title=" + (mediaTitle !== "" ? mediaTitle : (_source.station || clientName)),
      "--term-playing-msg=@omasr-playing",
      // The back-cache is what makes rewinding a live stream possible at all.
      "--cache=yes",
      "--demuxer-max-bytes=" + forwardCache,
      "--demuxer-max-back-bytes=" + backCache,
      "--input-ipc-server=" + socketPath
    ]
    // Seeking after playback starts would be audible as a stutter, so let mpv
    // open the file at the right place instead.
    if (startAt > 0) proc.command = proc.command.concat(["--start=" + startAt.toFixed(2)])
    // A session resumed from a note that was kept paused opens paused, so not
    // a moment of it is heard. mpv still announces that playback started, so
    // the transport comes up controllable rather than stuck in "connecting".
    if (_source.paused) proc.command = proc.command.concat(["--pause=yes"])
    // Begin at a chosen point in the live DVR window. ffmpeg will not seek
    // inside a live playlist, but it will start at a given segment.
    if (mprisScript !== "") proc.command = proc.command.concat(["--script=" + mprisScript])
    if (isFinite(startIndex) && startIndex >= 0)
      proc.command = proc.command.concat(
        ["--demuxer-lavf-o=live_start_index=" + Math.round(startIndex)])
    else if (mode === "live")
      // Join at the newest segment rather than at ffmpeg's default of three
      // back. Those three are how far behind the broadcast the playhead then
      // sits for as long as the stream runs -- measured at 15 to 16 seconds
      // on SR's playlist, against 3 to 9 seconds joining at the end -- and it
      // showed: the marker sat visibly short of the live edge on a bar
      // spanning a short programme. The cost is a thinner cushion against a
      // stalled connection, which is the same cushion any player sitting at
      // the live edge has.
      proc.command = proc.command.concat(["--demuxer-lavf-o=live_start_index=-1"])
    ipc.socketPath = socketPath
    proc.running = true
    ipc.beginConnect()
  }

  function _handleLine(raw) {
    var line = String(raw || "")
    if (line.indexOf("@omasr-playing") !== -1) {
      // Audio is actually flowing; a reconnect that got this far succeeded.
      _reconnects = 0
      if (status === "connecting") status = "playing"
      return
    }
    var icy = line.match(/icy-title:\s*(.+?)\s*$/)
    if (icy) nowPlaying = icy[1]
  }

  Process {
    id: proc

    stdout: SplitParser {
      onRead: function(line) { root._handleLine(line) }
    }
    // mpv sends diagnostics to stdout; stderr only carries hard startup
    // failures, which is what we want to quote back in the error state.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t !== "") root.lastError = t.split("\n")[t.split("\n").length - 1]
      }
    }

    onExited: function(exitCode) {
      ipc.teardown()
      root._removeSocket()

      // Queued source switch: the old child is finally gone, start the new one.
      if (root._pendingSource) {
        root._source = root._pendingSource
        root._pendingSource = null
        root._expectedStop = false
        Qt.callLater(root._spawn)
        return
      }

      if (root._expectedStop) {
        root._expectedStop = false
        return
      }

      // A file that ran out is finished, not dropped. Reconnecting would
      // restart it at the same offset and immediately end again.
      //
      // Announced on the next turn of the event loop, not from inside this
      // handler: whatever the panel does next will almost certainly start
      // playing something, and `proc.running` is still true until this
      // handler returns -- so the request would park in `_pendingSource`
      // waiting for an exit that has already happened.
      if (root.mode === "ondemand" && exitCode === 0) {
        Qt.callLater(function() { root.programmeEnded() })
        return
      }

      // Died on its own. Reconnect while we have attempts left, otherwise
      // surface the failure and go quiet.
      if (root.channelKey !== "" && root._reconnects < root.maxReconnects) {
        root._reconnects++
        root.status = "connecting"
        reconnectTimer.restart()
        return
      }

      if (root.channelKey !== "") {
        root.status = "error"
        if (root.lastError === "") root.lastError = "Stream ended unexpectedly"
        root.channelKey = ""
        root.channelName = ""
        root.station = ""
        root.nowPlaying = ""
        root._resetTransport()
      }
    }
  }

  // Anything that was true about the clock before the machine slept is stale
  // afterwards. There is no need for a suspend signal to notice: this tick
  // stops with everything else, so an interval far longer than its own is the
  // wall clock having jumped.
  signal wokeFromSuspend()

  Timer {
    running: root.active
    interval: 500
    repeat: true
    onTriggered: {
      var previous = root.nowMs
      root.nowMs = Date.now()
      if (previous > 0 && root.nowMs - previous > 30000) root.wokeFromSuspend()
    }
  }

  // Once stopped, clear any socket a child left behind -- one killed mid-switch
  // can exit without us ever recording its path. Guarded on nothing playing,
  // so tuning straight back in cannot have its socket swept from under it.
  Timer {
    id: stopSweep
    interval: 2000
    repeat: false
    onTriggered: {
      if (root.active || proc.running) return
      Quickshell.execDetached(["sh", "-c",
        "rm -f \"${XDG_RUNTIME_DIR:-/tmp}\"/omasr-mpv-*.sock"])
    }
  }

  Timer {
    id: reconnectTimer
    interval: root.reconnectDelayMs
    repeat: false
    onTriggered: if (root.channelKey !== "" && !proc.running) root._spawn()
  }

  // --- mpv JSON IPC --------------------------------------------------------
  //
  // mpv creates its socket a moment after launch, so connecting is a retry
  // loop rather than a single attempt. Once up, we ask mpv to *push* the
  // properties the transport needs instead of polling for them.
  QtObject {
    id: ipc

    property string socketPath: ""
    property bool ready: false

    readonly property var observed: [
      { id: 1, name: "time-pos" },
      { id: 2, name: "demuxer-cache-time" },
      { id: 3, name: "pause" },
      { id: 4, name: "duration" },
      { id: 5, name: "demuxer-cache-state" },
      { id: 6, name: "playlist-pos" }
    ]

    // Throw away the current socket and stand up a clean one.
    function rebuild() {
      sockLoader.active = false
      sockLoader.active = true
    }

    function beginConnect() {
      ready = false
      // Start from a clean socket rather than the previous child's.
      rebuild()
    }

    function teardown() {
      ready = false
      sockLoader.active = false
    }

    function command(args) {
      var sock = sockLoader.item
      if (!sock || !sock.connected) return
      sock.write(JSON.stringify({ command: args }) + "\n")
      sock.flush()
    }

    function onConnected() {
      ready = true
      for (var i = 0; i < observed.length; i++) {
        command(["observe_property", observed[i].id, observed[i].name])
      }
    }

    function handle(payload) {
      var msg
      try { msg = JSON.parse(payload) } catch (e) { return }
      if (!msg) return

      // Why a file stopped tells a key press from a mishap: asking for
      // another playlist entry reports "stop", a stream failing reports
      // "error", and a file running out reports "eof".
      if (msg.event === "end-file") {
        if (msg.reason === "stop" && root.playlistPos !== 1) {
          if (root.playlistPos > 1) root.nextRequested()
          else root.previousRequested()
        } else if (msg.reason === "eof" && root.mode === "ondemand") {
          Qt.callLater(function() { root.programmeEnded() })
        }
        return
      }

      if (msg.event !== "property-change") return
      var d = msg.data
      switch (msg.name) {
        case "time-pos":
          if (typeof d === "number") root.timePos = d
          break
        case "demuxer-cache-time":
          if (typeof d === "number") {
            root.cacheEnd = d
            // The newest audio mpv holds is, near enough, what is being
            // broadcast now, so it says where position 0 falls on the clock.
            //
            // Kept up to date rather than measured once: a stream fills
            // faster than it plays while it catches up to the live edge, so
            // the cache head gains on the clock and any single reading goes
            // stale. Left stale, the playhead drifts *ahead* of the clock and
            // claims audio that has not been broadcast. A DVR start knows its
            // own origin exactly and must keep it.
            //
            // Not while paused: the playhead is standing still by definition,
            // and re-anchoring it against a cache that keeps filling would
            // walk it slowly backwards.
            if (!root.dvrStarted && root.mode === "live" && !root.paused && d > 0)
              root.originWallMs = Date.now() - d * 1000
          }
          break
        case "pause":
          // Pausing is a time shift whoever asks for it -- the media keys go
          // straight to mpv over MPRIS, never through togglePause().
          if (!!d && !root.paused && root.mode === "live") root.timeShifted = true
          root.paused = !!d
          break
        case "duration":
          if (typeof d === "number" && root.mode === "ondemand") root.duration = d
          break
        case "playlist-pos":
          if (typeof d === "number") root.playlistPos = d
          break
        case "demuxer-cache-state":
          // `cache-begin` is null until mpv has evicted anything, in which
          // case the whole stream since tune-in is still reachable.
          if (d && typeof d["cache-begin"] === "number") root.cacheBegin = d["cache-begin"]
          else root.cacheBegin = 0
          break
      }
    }
  }

  // A Socket per connection attempt.
  //
  // Quickshell's Socket latches its connect request: once `connected = true`
  // has been asked for and the attempt failed -- which the first attempt
  // usually does, before mpv has created the socket -- asking again changes
  // nothing and no further attempt is ever made. Toggling the property or
  // reassigning the path does not clear it either. So each retry gets a fresh
  // object, which is the only reliable way to actually try again.
  Component {
    id: socketComponent

    Socket {
      onConnectedChanged: {
        if (connected && path === ipc.socketPath && ipc.socketPath !== "") ipc.onConnected()
        else if (!connected) ipc.ready = false
      }
      parser: SplitParser {
        onRead: function(line) { ipc.handle(line) }
      }
    }
  }

  Loader {
    id: sockLoader
    active: false
    sourceComponent: socketComponent
  }

  // Keeps trying until there is a usable control channel, and starts itself
  // again if one is ever lost.
  Timer {
    id: connectTimer
    interval: connectTimer.attempts < 25 ? 250 : 1000
    repeat: true
    running: proc.running && ipc.socketPath !== "" && !ipc.ready
    property int attempts: 0
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      attempts++
      var sock = sockLoader.item
      if (sock && sock.connected) {
        // Connected, but not ready: either this is the right socket and the
        // change signal was missed, or it belongs to the previous child.
        if (sock.path === ipc.socketPath) ipc.onConnected()
        else ipc.rebuild()
        return
      }
      ipc.rebuild()
      sock = sockLoader.item
      if (!sock) return
      sock.path = ipc.socketPath
      sock.connected = true
    }
  }

  // One-shot probe so the panel can say "mpv isn't installed" rather than
  // appearing broken.
  Process {
    id: mpvCheck
    running: true
    command: ["sh", "-c", "command -v mpv"]
    onExited: function(exitCode) { root.available = exitCode === 0 }
  }

  Process {
    id: mprisCheck
    running: true
    command: ["sh", "-c",
      "for p in /etc/mpv/scripts/mpris.so /usr/lib/mpv-mpris/mpris.so; do "
      + "[ -e \"$p\" ] && { printf %s \"$p\"; exit 0; }; done; exit 1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.mprisScript = String(text || "").trim()
    }
  }

  // The shell outlives any one panel; never leave a stream playing behind a
  // closed or unloaded widget. Asking is not the same as it happening, though:
  // a plugin reload destroys the whole tree at once and the child can outlive
  // the request by a good few seconds, which is what sweepStrays() is for.
  Component.onDestruction: if (proc.running) proc.running = false
}
