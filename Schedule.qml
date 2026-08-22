import QtQuick

// What is on the air right now, from SR's open API.
//
// `scheduledepisodes/rightnow` returns the previous, current and next
// scheduled episode for a channel, each with UTC start and end times. That is
// what gives the transport its timeline: the bar spans the current
// programme's broadcast window, and the labels at either end are its start
// and end clock times.
//
// Episode audio is a separate lookup. A programme that has already aired
// usually has a published file (`listenpodfile`), which is what makes
// "previous programme" playable; one that is still airing usually does not,
// so the transport dims that button rather than offering a dead control.
Item {
  id: root

  property int channelId: 0

  property string currentTitle: ""
  // Programme artwork, as the wide image SR composes for it.
  //
  // The URLs the API hands back carry `?preset=api-default-square`, which
  // crops the artwork to a square; the underlying asset is 16:9. Asking for
  // the template without a preset gives that, which is what SR's own apps
  // show. `imageTemplate` fields throughout are therefore preset-free.
  property string currentImage: ""

  // programId -> wide artwork, for programmes whose schedule entry carries no
  // image of its own. Every programme has one.
  property var programImages: ({})

  function bareTemplate(url) {
    return String(url || "").split("?")[0]
  }
  property string currentProgram: ""
  property double currentStartMs: 0
  property double currentEndMs: 0
  property int currentEpisodeId: 0

  property string prevTitle: ""
  property int prevEpisodeId: 0
  property double prevStartMs: 0
  property double prevEndMs: 0

  property string nextTitle: ""
  property int nextEpisodeId: 0
  property double nextStartMs: 0

  // Resolved on-demand audio, when SR has published it: { url, duration,
  // startMs, title }.
  //
  // `currentAudio` is the useful one: SR publishes many programmes as a file
  // while they are still on air, so where it exists the programme can be
  // played from its real start rather than only back to wherever the live
  // buffer happens to begin. Live desks -- news, morning shows -- generally
  // have nothing until after they finish, so this is often null.
  property var currentAudio: null

  readonly property bool valid: currentEndMs > 0

  // The channel's full schedule for today and yesterday, oldest first, so the
  // back button can walk back through programmes one at a time instead of
  // only ever reaching the one before the live programme. Two days is enough
  // to step back across midnight without another round trip.
  property var daySchedule: []

  signal loaded()

  // SR serializes times as "/Date(1787385780000)/".
  function parseDate(value) {
    var m = String(value || "").match(/\/Date\((-?\d+)/)
    return m ? Number(m[1]) : 0
  }

  function clear() {
    currentTitle = ""; currentProgram = ""; currentStartMs = 0; currentEndMs = 0; currentEpisodeId = 0
    currentImage = ""
    currentAudio = null
    prevTitle = ""; prevEpisodeId = 0; prevStartMs = 0; prevEndMs = 0
    nextTitle = ""; nextEpisodeId = 0; nextStartMs = 0
  }

  // Latest scheduled programme starting before `startMs`, or null.
  function episodeBefore(startMs) {
    var best = null
    for (var i = 0; i < daySchedule.length; i++) {
      var e = daySchedule[i]
      if (e.startMs < startMs - 1000 && (!best || e.startMs > best.startMs)) best = e
    }
    return best
  }

  // The scheduled programme covering a given instant, or null.
  function episodeAt(wallMs) {
    for (var i = 0; i < daySchedule.length; i++) {
      var e = daySchedule[i]
      if (wallMs >= e.startMs && wallMs < e.endMs) return e
    }
    return null
  }

  // Earliest scheduled programme starting after `startMs`, or null.
  function episodeAfter(startMs) {
    var best = null
    for (var i = 0; i < daySchedule.length; i++) {
      var e = daySchedule[i]
      if (e.startMs > startMs + 1000 && (!best || e.startMs < best.startMs)) best = e
    }
    return best
  }

  function dateStamp(offsetDays) {
    var d = new Date(Date.now() + offsetDays * 86400000)
    return Qt.formatDate(d, "yyyy-MM-dd")
  }

  function loadDays() {
    if (channelId <= 0) { daySchedule = []; return }
    var merged = []
    var pending = 2
    var id = channelId
    function absorb(data) {
      // A channel switch mid-flight would otherwise merge two channels'
      // schedules into one list.
      if (id !== root.channelId) return
      var list = (data && data.schedule) || []
      for (var i = 0; i < list.length; i++) {
        merged.push({
          id: list[i].episodeid || 0,
          title: list[i].title || "",
          imageUrl: bareTemplate(list[i].imageurltemplate || list[i].imageurl),
          programId: (list[i].program && list[i].program.id) || 0,
          startMs: parseDate(list[i].starttimeutc),
          endMs: parseDate(list[i].endtimeutc)
        })
      }
      if (--pending === 0) {
        merged.sort(function(a, b) { return a.startMs - b.startMs })
        daySchedule = merged
        fillMissingArtwork(merged)
      }
    }
    var base = "https://api.sr.se/api/v2/scheduledepisodes?channelid=" + channelId
      + "&format=json&pagination=false&date="
    getJson(base + dateStamp(-1), absorb)
    getJson(base + dateStamp(0), absorb)
  }

  // Some entries carry no image; their programme always does. Looked up once
  // per programme after the day lands, rather than on demand from a binding.
  function fillMissingArtwork(entries) {
    var wanted = {}
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (e.imageUrl === "" && e.programId > 0 && programImages[e.programId] === undefined)
        wanted[e.programId] = true
    }
    for (var id in wanted) rememberProgrammeImage(Number(id))
  }

  function rememberProgrammeImage(programId) {
    // Claim it first, so a second pass does not fetch it again.
    var pending = {}
    for (var k in programImages) pending[k] = programImages[k]
    pending[programId] = ""
    programImages = pending

    getJson("https://api.sr.se/api/v2/programs/" + programId + "?format=json", function(data) {
      var p = data && data.program
      if (!p) return
      var url = bareTemplate(p.programimagetemplatewide || p.programimagetemplate)
      var next = {}
      for (var k2 in programImages) next[k2] = programImages[k2]
      next[programId] = url
      programImages = next
    })
  }

  // Artwork for a schedule entry: its own where it has one, otherwise its
  // programme's. Empty until the lookup lands, and reactive when it does.
  function artworkFor(episode) {
    if (!episode) return ""
    if (episode.imageUrl) return episode.imageUrl
    var byProgram = programImages[episode.programId]
    return byProgram || ""
  }

  function refresh() {
    if (channelId <= 0) { clear(); return }
    var url = "https://api.sr.se/api/v2/scheduledepisodes/rightnow?channelid="
      + channelId + "&format=json"
    getJson(url, function(data) {
      var ch = data && data.channel
      if (!ch) return
      var cur = ch.currentscheduledepisode
      var prev = ch.previousscheduledepisode
      var nxt = ch.nextscheduledepisode

      if (cur) {
        currentImage = bareTemplate(cur.socialimage)
        currentTitle = cur.title || ""
        currentProgram = (cur.program && cur.program.name) || ""
        currentStartMs = parseDate(cur.starttimeutc)
        currentEndMs = parseDate(cur.endtimeutc)
        currentEpisodeId = cur.episodeid || 0
      }
      if (prev) {
        prevTitle = prev.title || ""
        prevEpisodeId = prev.episodeid || 0
        prevStartMs = parseDate(prev.starttimeutc)
        prevEndMs = parseDate(prev.endtimeutc)
      } else {
        prevTitle = ""; prevEpisodeId = 0
      }
      if (nxt) {
        nextTitle = nxt.title || ""
        nextEpisodeId = nxt.episodeid || 0
        nextStartMs = parseDate(nxt.starttimeutc)
      } else {
        nextTitle = ""; nextEpisodeId = 0
      }

      currentAudio = null
      if (currentEpisodeId > 0) resolveAudio(currentEpisodeId, currentStartMs, currentTitle,
        function(a) { currentAudio = a })

      loaded()
      rescheduleRefresh()
    })
  }

  // Look up a published file for an episode. Calls back with null when SR has
  // nothing for it, which is the normal case for a programme still on air.
  function resolveAudio(episodeId, startMs, title, callback) {
    // Not every scheduled entry has an episode behind it, and asking for id 0
    // is a 404 rather than an empty answer.
    if (!episodeId || episodeId <= 0) { callback(null); return }
    getJson("https://api.sr.se/api/v2/episodes/get?id=" + episodeId + "&format=json",
      function(data) {
        var ep = data && data.episode
        var file = ep && (ep.listenpodfile || ep.broadcast)
        var url = file && (file.url || (file.broadcastfiles && file.broadcastfiles.length
          ? file.broadcastfiles[0].url : ""))
        if (!url) { callback(null); return }
        callback({
          url: url,
          duration: Number(file.duration || (file.broadcastfiles && file.broadcastfiles[0]
            ? file.broadcastfiles[0].duration : 0)) || 0,
          startMs: startMs,
          title: title
        })
      })
  }

  // Always calls back, with null when there is nothing to hand over. Callers
  // chain on this -- stepping back through programmes recurses from inside the
  // callback -- so a request that failed silently would end the chain rather
  // than move it along.
  function getJson(url, callback) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status < 200 || xhr.status >= 300) { callback(null); return }
      var parsed = null
      try { parsed = JSON.parse(xhr.responseText) } catch (e) { parsed = null }
      callback(parsed)
    }
    xhr.open("GET", url)
    xhr.send()
  }

  // Re-fetch shortly after the current programme is due to end, so the
  // timeline rolls over on its own, with a slow poll as the safety net for a
  // schedule that shifts under us.
  function rescheduleRefresh() {
    var untilEnd = currentEndMs - Date.now()
    rolloverTimer.interval = untilEnd > 0
      ? Math.min(untilEnd + 2000, 15 * 60 * 1000)
      : 30 * 1000
    rolloverTimer.restart()
  }

  onChannelIdChanged: {
    clear()
    daySchedule = []
    refresh()
    loadDays()
  }

  Timer {
    id: rolloverTimer
    repeat: false
    onTriggered: root.refresh()
  }
}
