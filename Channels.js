// Channel table for Sveriges Radio's four main channels.
//
// Stream URLs are the official `liveaudio` endpoints published by SR's open
// API (https://api.sr.se/api/v2/channels). Each one 302-redirects to whichever
// edge node and bitrate SR is currently serving, so we hand the stable srapi
// URL to the player and let SR do the routing.
//
// Colors are Sveriges Radio's 2024 channel brand colors, taken from the same
// logo artwork the glyph outlines in ChannelMark.qml are traced from, so a
// tile renders as the real channel logo rather than a lookalike. (SR's API
// still reports the pre-2024 palette in its `color` field; we don't use it.)
//
// P4 is regional. The table carries P4's brand identity, and `p4Regions`
// lists every regional station -- the widget's `p4Region` setting picks which
// one the P4 button tunes to.

.pragma library

// SR's HLS live stream. Preferred over the plain mp3 for two reasons: it
// carries a rolling three-hour DVR window with absolute timestamps, which is
// what makes rewinding live radio possible on any programme rather than only
// on ones SR has published as a file; and it is ~192 kbps rather than ~96.
//
// Both URLs come from SR's own audio templates
// (api.sr.se/api/v2/audiourltemplates/liveaudiotypes).
function streamUrl(id) {
  return "https://sverigesradio.se/topsy/direkt/srapi/" + id + ".hls"
}

// Plain ICY mp3. Kept as the fallback for when the HLS master cannot be read.
function mp3StreamUrl(id) {
  return "https://www.sverigesradio.se/topsy/direkt/srapi/" + id + ".mp3"
}

// `id` is SR's channel id. P4's is resolved from the selected region instead,
// so it is left at 0 here.
var channels = [
  { key: "p1", id: 132, name: "P1", color: "#0167c6" },
  { key: "p2", id: 163, name: "P2", color: "#ff5c00" },
  { key: "p3", id: 164, name: "P3", color: "#08b46a" },
  { key: "p4", id: 0,   name: "P4", color: "#cc24b4" }
]

var defaultP4Region = "P4 Stockholm"

var p4Regions = [
  { id: 213, name: "P4 Blekinge" },
  { id: 223, name: "P4 Dalarna" },
  { id: 205, name: "P4 Gotland" },
  { id: 210, name: "P4 Gävleborg" },
  { id: 212, name: "P4 Göteborg" },
  { id: 220, name: "P4 Halland" },
  { id: 200, name: "P4 Jämtland" },
  { id: 203, name: "P4 Jönköping" },
  { id: 201, name: "P4 Kalmar" },
  { id: 211, name: "P4 Kristianstad" },
  { id: 214, name: "P4 Kronoberg" },
  { id: 207, name: "P4 Malmöhus" },
  { id: 209, name: "P4 Norrbotten" },
  { id: 206, name: "P4 Sjuhärad" },
  { id: 208, name: "P4 Skaraborg" },
  { id: 701, name: "P4 Stockholm" },
  { id: 5283, name: "P4 Södertälje" },
  { id: 202, name: "P4 Sörmland" },
  { id: 218, name: "P4 Uppland" },
  { id: 204, name: "P4 Värmland" },
  { id: 219, name: "P4 Väst" },
  { id: 215, name: "P4 Västerbotten" },
  { id: 216, name: "P4 Västernorrland" },
  { id: 217, name: "P4 Västmanland" },
  { id: 221, name: "P4 Örebro" },
  { id: 222, name: "P4 Östergötland" }
]

function p4RegionNames() {
  var names = []
  for (var i = 0; i < p4Regions.length; i++) names.push(p4Regions[i].name)
  return names
}

// Resolve a region name (as stored in the widget's settings) to its station.
// Falls back to the default region so an unknown or stale name still plays.
function p4RegionFor(name) {
  for (var i = 0; i < p4Regions.length; i++) {
    if (p4Regions[i].name === name) return p4Regions[i]
  }
  for (var j = 0; j < p4Regions.length; j++) {
    if (p4Regions[j].name === defaultP4Region) return p4Regions[j]
  }
  return p4Regions[0]
}

// The four tiles as the panel should render them, with P4 resolved against
// the chosen region: `name` is what the UI shows, `station` is the full
// station name (identical for P1-P3, "P4 Göteborg" for P4).
function resolved(p4RegionName) {
  var region = p4RegionFor(p4RegionName)
  var out = []
  for (var i = 0; i < channels.length; i++) {
    var c = channels[i]
    var isP4 = c.key === "p4"
    out.push({
      key: c.key,
      name: c.name,
      color: c.color,
      id: isP4 ? region.id : c.id,
      station: isP4 ? region.name : c.name,
      url: streamUrl(isP4 ? region.id : c.id),
      mp3Url: mp3StreamUrl(isP4 ? region.id : c.id)
    })
  }
  return out
}
