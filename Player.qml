import QtQuick
import Quickshell.Io

// Playback engine for the four channel buttons.
//
// The stream is decoded by an mpv child process rather than by QtMultimedia
// inside the shell. omarchy-shell is one long-running process that owns the
// bar, the panels, and the lock screen, so a decoder that wedges or crashes on
// a bad stream would take the whole desktop shell with it. A child process
// costs one fork and can simply be killed.
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

  // "idle" | "connecting" | "playing" | "error"
  property string status: "idle"
  property string lastError: ""

  // Programme title from the stream's ICY metadata, when SR sends one.
  property string nowPlaying: ""

  // False when mpv isn't installed; the panel surfaces this instead of
  // letting every button press quietly do nothing.
  property bool available: true

  readonly property bool active: channelKey !== ""

  // Name shown to the system mixer, so the stream is identifiable in
  // Omarchy's audio panel and in pavucontrol.
  property string clientName: "Sveriges Radio"

  // Live streams drop. Reconnect a bounded number of times before giving up,
  // so a passing network blip doesn't silently end the broadcast.
  property int maxReconnects: 3
  property int reconnectDelayMs: 1500

  // --- internal ------------------------------------------------------------

  // Set before we kill the child ourselves, so onExited can tell a deliberate
  // stop from the stream dying on us.
  property bool _expectedStop: false
  property var _pendingChannel: null
  property int _reconnects: 0
  property string _url: ""

  function play(channel) {
    if (!channel) return
    _reconnects = 0
    _start(channel)
  }

  function stop() {
    // A reconnect may be armed with no child running (we are inside the delay
    // window). Disarm it before clearing state, or it would fire into a
    // stopped player.
    reconnectTimer.stop()
    _pendingChannel = null
    _reconnects = 0
    channelKey = ""
    channelName = ""
    station = ""
    nowPlaying = ""
    status = "idle"
    lastError = ""
    _kill()
  }

  // The behavior the four buttons implement: the playing channel stops, any
  // other channel switches.
  function toggle(channel) {
    if (!channel) return
    if (channelKey === channel.key) stop()
    else play(channel)
  }

  function _kill() {
    if (proc.running) {
      _expectedStop = true
      proc.running = false
    }
  }

  function _start(channel) {
    // Same reason as in stop(): a pending reconnect for the previous channel
    // must not fire on top of the channel we are switching to.
    reconnectTimer.stop()
    channelKey = channel.key
    channelName = channel.name
    station = channel.station
    nowPlaying = ""
    lastError = ""
    status = "connecting"
    _url = channel.url

    // A previous child is still shutting down; hand off to onExited.
    if (proc.running) {
      _pendingChannel = channel
      _expectedStop = true
      proc.running = false
      return
    }
    _pendingChannel = null
    _spawn()
  }

  function _spawn() {
    proc.command = [
      "mpv", _url,
      "--no-video",
      // Ignore ~/.config/mpv: a user's own profile (forced video output,
      // a different ao, --shuffle) should not reach into the bar widget.
      "--no-config",
      "--no-input-terminal",
      "--idle=no",
      "--quiet",
      "--audio-client-name=" + clientName,
      "--term-playing-msg=@omasr-playing"
    ]
    proc.running = true
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
      // Queued channel switch: the old child is finally gone, start the new one.
      if (root._pendingChannel) {
        var next = root._pendingChannel
        root._pendingChannel = null
        root._expectedStop = false
        root._url = next.url
        Qt.callLater(root._spawn)
        return
      }

      if (root._expectedStop) {
        root._expectedStop = false
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
      }
    }
  }

  Timer {
    id: reconnectTimer
    interval: root.reconnectDelayMs
    repeat: false
    onTriggered: if (root.channelKey !== "" && !proc.running) root._spawn()
  }

  // One-shot probe so the panel can say "mpv isn't installed" rather than
  // appearing broken.
  Process {
    id: mpvCheck
    running: true
    command: ["sh", "-c", "command -v mpv"]
    onExited: function(exitCode) { root.available = exitCode === 0 }
  }

  // The shell outlives any one panel; never leave a stream playing behind a
  // closed or unloaded widget.
  Component.onDestruction: if (proc.running) proc.running = false
}
