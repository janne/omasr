import QtQuick

// SR's live HLS carries a rolling DVR window -- currently about three hours --
// and stamps it with absolute times (`EXT-X-PROGRAM-DATE-TIME`). That window
// is what lets live radio be rewound at all on a programme SR has not
// published, which is most of them while they are still on air. It is also
// how SR's own apps do it.
//
// ffmpeg will not seek inside a live playlist, but it will *start* at a chosen
// segment (`live_start_index`). So going to a moment in the window means
// working out which segment covers it and starting a player there. The
// playlist slides continuously, so it is fetched fresh for each lookup rather
// than cached.
Item {
  id: root

  // Master playlist for the channel, e.g. .../srapi/132.hls
  property string masterUrl: ""

  // Bounds of the window, refreshed on every successful read. Zero until the
  // first one lands.
  property double windowStartMs: 0
  property double windowEndMs: 0

  readonly property bool known: windowEndMs > 0

  function covers(wallMs) {
    // Keep clear of both edges: the oldest segment is about to fall out of the
    // playlist, and the newest is the live edge itself.
    return known && wallMs > windowStartMs + 20000 && wallMs < windowEndMs - 10000
  }

  // Resolve `wallMs` to a starting segment. Calls back with
  // { index, startMs, url } or null.
  //
  // `url` is the variant playlist the index was counted in, and is what should
  // be played: handing mpv the master instead would let it choose its own
  // variant, and a segment index only means something within the playlist it
  // was counted in.
  function locate(wallMs, callback) {
    fetchVariant(function(variantUrl) {
      if (!variantUrl) { callback(null); return }
      get(variantUrl, function(text) {
        if (!text) { callback(null); return }
        var parsed = parsePlaylist(text)
        if (!parsed) { callback(null); return }
        // Anchored on the live edge for the same reason as locateIn.
        var edge = Date.now()
        root.windowEndMs = edge - edgeLatencySec * 1000
        root.windowStartMs = edge - parsed.total * 1000
        var spot = locateIn(parsed, wallMs)
        if (spot) spot.url = variantUrl
        callback(spot)
      })
    })
  }

  // Just refresh the bounds, so the UI knows how far back it can offer.
  function refresh() {
    locate(Date.now(), function(ignored) {})
  }

  // Playback can only begin on a segment boundary -- ffmpeg will not seek into
  // a live playlist -- so an instant inside a segment has to round to one.
  //
  // It rounds *up*, to the segment starting at or after the instant, rather
  // than to the one straddling it. Starting at the straddling segment would
  // begin up to a segment early, which when the instant is a programme's start
  // means opening with the last seconds of the programme before it. Better to
  // miss a moment of the one asked for. A segment that begins within a second
  // of the instant is close enough to use as-is.
  property real boundaryToleranceSec: 1.0

  // How far behind real time the newest segment in the playlist is: SR has to
  // finish and publish a segment before it appears, so the live edge is not
  // quite now, and treating it as now lands everything slightly early.
  //
  // Calibrated by fetching the same instant twice -- once through this window
  // and once as the programme's published file -- and cross-correlating the
  // two. That put the mapping 1.4 to 5.8 seconds early across samples, so
  // this is the middle of that range rather than a precise figure: the file's
  // own start is not exactly the scheduled one, which limits how sharp the
  // reading can be. Erring late is the safer side, and rounding up to a
  // segment boundary already leans that way.
  property real edgeLatencySec: 3.5

  // Position is measured back from the live edge, not forward from the
  // playlist's own `EXT-X-PROGRAM-DATE-TIME`.
  //
  // SR's stamp runs roughly half a minute ahead of real time: summing the
  // segment durations from it puts the end of the window about 28 seconds
  // into the future, which is not possible for audio that has been broadcast.
  // Taking it at face value made every jump land that far early -- asking for
  // a programme's start would open half a minute before it. The newest
  // segment is the one thing whose real time is known: it is now, give or
  // take the moment it takes SR to publish it.
  function locateIn(parsed, wallMs) {
    var count = parsed.durations.length
    var edgeMs = Date.now()
    var backSec = Math.max(0, (edgeMs - wallMs) / 1000 - edgeLatencySec)

    // Walk back from the newest segment until the target is covered.
    var acc = 0
    for (var i = count - 1; i >= 0; i--) {
      acc += parsed.durations[i]
      if (acc >= backSec) {
        var startsBeforeTarget = acc - backSec
        // Round up to the boundary at or after the target, so a jump to a
        // programme's start never opens with the end of the one before it.
        if (startsBeforeTarget > boundaryToleranceSec && i + 1 < count) {
          acc -= parsed.durations[i]
          i += 1
        }
        return { index: i, startMs: edgeMs - (acc + edgeLatencySec) * 1000 }
      }
    }
    // Older than the window holds; the oldest segment is the best on offer.
    return { index: 0, startMs: edgeMs - (acc + edgeLatencySec) * 1000 }
  }

  function parsePlaylist(text) {
    var stamp = text.match(/#EXT-X-PROGRAM-DATE-TIME:(\S+)/)
    if (!stamp) return null
    var startMs = Date.parse(stamp[1])
    if (!isFinite(startMs)) return null
    var durations = []
    var re = /#EXTINF:([0-9.]+)/g
    var m
    while ((m = re.exec(text)) !== null) durations.push(parseFloat(m[1]))
    if (durations.length === 0) return null
    var total = 0
    for (var i = 0; i < durations.length; i++) total += durations[i]
    return { startMs: startMs, durations: durations, total: total }
  }

  // Pick a variant from the master playlist. Only absolute URLs are
  // considered: the master is reached through redirects, so a relative one
  // cannot be resolved without knowing the URL it finally came from.
  function fetchVariant(callback) {
    get(masterUrl, function(text) {
      if (!text) { callback(""); return }
      var best = ""
      var bestRate = -1
      var lines = text.split(/\r?\n/)
      for (var i = 0; i < lines.length; i++) {
        var inf = lines[i].match(/#EXT-X-STREAM-INF:.*?BANDWIDTH=(\d+)/)
        if (!inf) continue
        var url = (lines[i + 1] || "").replace(/^\s+|\s+$/g, "")
        if (url.indexOf("http") !== 0) continue
        var rate = Number(inf[1])
        if (rate > bestRate) { bestRate = rate; best = url }
      }
      callback(best)
    })
  }

  function get(url, callback) {
    if (!url) { callback(""); return }
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      callback(xhr.status >= 200 && xhr.status < 300 ? xhr.responseText : "")
    }
    xhr.open("GET", url)
    xhr.send()
  }

  onMasterUrlChanged: {
    windowStartMs = 0
    windowEndMs = 0
    if (masterUrl !== "") refresh()
  }

  // The window slides; keep the bounds roughly current while playing.
  Timer {
    running: root.masterUrl !== ""
    interval: 60000
    repeat: true
    onTriggered: root.refresh()
  }
}
