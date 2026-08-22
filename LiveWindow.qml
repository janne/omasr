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
  // { index, startMs } for the segment covering it, or null.
  function locate(wallMs, callback) {
    fetchVariant(function(variantUrl) {
      if (!variantUrl) { callback(null); return }
      get(variantUrl, function(text) {
        if (!text) { callback(null); return }
        var parsed = parsePlaylist(text)
        if (!parsed) { callback(null); return }
        root.windowStartMs = parsed.startMs
        root.windowEndMs = parsed.startMs + parsed.total * 1000
        callback(locateIn(parsed, wallMs))
      })
    })
  }

  // Just refresh the bounds, so the UI knows how far back it can offer.
  function refresh() {
    locate(Date.now(), function(ignored) {})
  }

  function locateIn(parsed, wallMs) {
    var offset = (wallMs - parsed.startMs) / 1000
    if (offset < 0) offset = 0
    var acc = 0
    for (var i = 0; i < parsed.durations.length; i++) {
      var d = parsed.durations[i]
      if (acc + d > offset) return { index: i, startMs: parsed.startMs + acc * 1000 }
      acc += d
    }
    var last = Math.max(0, parsed.durations.length - 1)
    return { index: last, startMs: parsed.startMs + (acc - parsed.durations[last]) * 1000 }
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
