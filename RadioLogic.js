// Pure feed-handling logic for the Newgrounds Radio service.
//
// This lives outside Service.qml so it can be exercised by qmltestrunner:
// Quickshell's QML modules are compiled into the quickshell binary as
// resources, so anything importing them can only be loaded by the shell
// itself. Nothing here imports Quickshell, so tests/ can run it directly.
//
// Everything is a pure function: the clock is passed in and mutable
// bookkeeping travels in a caller-owned state object, so the rate floors are
// testable rather than wall-clock dependent.

// ---- Bounds on everything the feed supplies. The service is long-lived and
// shared by every monitor's bar, so nothing from the network is stored
// unbounded: oversized frames are dropped, strings are truncated, and the
// play log keeps a fixed number of records with a fixed set of fields.
var maxMessageLength = 131072
var maxFieldLength = 200
var maxUrlLength = 512
var maxPlayLogEntries = 12
// Bounds the walk itself: an array of nulls never grows `out`, so the entry
// cap alone wouldn't stop the loop early.
var maxPlayLogScan = 100
var minNotifyInterval = 5000
var minWarnInterval = 5000

// Hosts the feed is allowed to point us at. Artwork and listen links are
// Newgrounds-owned; anything else is dropped rather than fetched or opened.
var allowedHosts = ["newgrounds.com", "ngfiles.com", "newgroundsradio.com"]

// Feed strings are display-only: drop control characters and cap the length
// before anything stores or renders them. That includes the bidi and
// zero-width formatting controls - a title ending in U+202E can visually
// reverse the text after it, and the title in the popup is a clickable link,
// so a spoofed one is worth more than a cosmetic glitch. ZWNJ and ZWJ are
// deliberately left alone - they can't reorder or hide anything, and dropping
// them would shred emoji sequences and Persian word shaping.
function sanitizeText(value, limit) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(/[\x00-\x1F\x7F\u0080-\u009F\u061C\u200B\u200E\u200F\u2028\u2029\u202A-\u202E\u2060-\u206F\uFEFF]/g, " ")
  return s.length > limit ? s.substring(0, limit) : s
}

// Notification summaries are not markup-parsed but bodies are, so drop the
// angle brackets from one and escape the whole of the other. Either way a
// crafted title can't inject an <img> that phones home.
function stripMarkup(s) { return String(s).replace(/[<>]/g, "") }
function escapeMarkup(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// ngfiles art URLs carry a ?t= cache-buster that can differ between
// responses; strip it so the Image source stays stable across updates.
function cleanArtUrl(url) {
  var s = String(url || "")
  var q = s.indexOf("?")
  return q === -1 ? s : s.substring(0, q)
}

// Only plain https URLs on Newgrounds-owned hosts reach an Image source or
// xdg-open. Anything else - other schemes, other hosts, local paths - becomes
// "" rather than a request we never declared.
function safeUrl(url) {
  var s = sanitizeText(url, maxUrlLength)
  var m = /^https:\/\/([A-Za-z0-9.-]+)(\/[!-~]*)?$/.exec(s)
  if (m) {
    var host = m[1].toLowerCase()
    for (var i = 0; i < allowedHosts.length; i++) {
      var h = allowedHosts[i]
      if (host === h || host.substring(host.length - h.length - 1) === "." + h) return s
    }
  }
  return ""
}

// safeUrl plus a breadcrumb. Silent rejection would show up only as missing
// art or a dead link, so leave a trace: today's URLs are ASCII and portless,
// and a future feed change should be debuggable rather than invisible. Only
// the first of a repeated rejection is logged, behind a rate floor - this
// runs up to 13 times per status frame, the feed sets the rate, and
// alternating URLs would defeat the memo alone. The second clock test
// un-sticks the gate after a backwards correction.
function safeUrlLogged(url, st, now, warn) {
  var s = safeUrl(url)
  if (s !== "") return s
  var t = sanitizeText(url, maxUrlLength).replace(/^\s+|\s+$/g, "")
  if (t !== "" && t !== st.lastRejectedUrl
      && (now - st.lastWarnAt > minWarnInterval || now < st.lastWarnAt)) {
    st.lastRejectedUrl = t
    st.lastWarnAt = now
    if (warn) warn(t)
  }
  return ""
}

// Rebuild each play-log record from scratch: a fixed set of fields, each
// bounded, so the shell never holds arbitrary server-shaped objects.
function sanitizePlayLog(entries, st, now, warn) {
  var out = []
  var scan = Math.min(entries.length, maxPlayLogScan)
  for (var i = 0; i < scan && out.length < maxPlayLogEntries; i++) {
    var e = entries[i]
    if (!e || typeof e !== "object") continue
    out.push({
      title: sanitizeText(e.title, maxFieldLength),
      artist: sanitizeText(e.artist, maxFieldLength),
      on_air_at: sanitizeText(e.on_air_at, 64),
      listen_url: safeUrlLogged(e.listen_url, st, now, warn)
    })
  }
  return out
}

// The sanitized shape of a currently_playing payload. The caller owns the
// change detection and the notification - this only normalizes.
function normalizeStatus(d, st, now, warn) {
  return {
    title: sanitizeText(d.title, maxFieldLength),
    artist: sanitizeText(d.artist, maxFieldLength),
    genre: sanitizeText(d.genre, maxFieldLength),
    bigArtUrl: safeUrlLogged(cleanArtUrl(d.media_icon_url), st, now, warn)
      || safeUrlLogged(cleanArtUrl(d.icon_url), st, now, warn),
    listeners: parseInt(d.listeners, 10) || 0,
    onAirAt: Number(d.on_air_at) || 0,
    skipVotes: parseInt(d.skip_votes, 10) || 0,
    skipThreshold: parseInt(d.skip_threshold, 10) || 0,
    audioId: parseInt(d.audio_id, 10) || 0
  }
}

// Real tracks are minutes apart, so a floor of a few seconds costs nothing -
// and it stops a feed that flips audio_id on every frame from spawning one
// notify-send per message out of a long-lived shell. The second clock test
// un-sticks the gate after a backwards correction.
function shouldNotify(changed, enabled, playing, now, lastNotifyAt) {
  return !!(changed && enabled && playing
    && (now - lastNotifyAt > minNotifyInterval || now < lastNotifyAt))
}

// ---- Realtime feed: minimal Engine.IO v4 framing over WebSocket.
//   "0{...}"  open handshake  -> reply "40" to join the default namespace
//   "40..."   namespace ack   -> connected
//   "2"       server ping     -> reply "3"
//   "42[...]" event           -> ["status", {currently_playing, play_log}]
//   "41"      namespace kick  -> reconnect
//
// Returns {kind, packet}. A frame larger than the cap is never a real status
// update, so it is dropped rather than parsed into the shell.
function classifyFrame(message) {
  var m = String(message)
  if (m.length > maxMessageLength) return { kind: "oversize" }
  if (m.charAt(0) === "0") return { kind: "open" }
  if (m === "2") return { kind: "ping" }
  var head = m.substring(0, 2)
  if (head === "40") return { kind: "connected" }
  if (head === "41" || head === "44") return { kind: "reconnect" }
  if (head === "42") {
    try {
      var packet = JSON.parse(m.substring(2))
      if (packet[0] === "status" && packet[1]) return { kind: "status", packet: packet[1] }
    } catch (e) {}
    return { kind: "ignore" }
  }
  return { kind: "ignore" }
}
