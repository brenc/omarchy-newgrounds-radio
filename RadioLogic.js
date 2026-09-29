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

// Stream codecs the station serves, first entry is the default. Each maps to
// radio.<codec> on the stream host; Opus arrives in an Ogg container.
var codecs = ["opus", "mp3"]
var streamBase = "https://stream.newgroundsradio.com/radio."

// A codec from settings or the popup, folded to a known value. Anything
// unrecognized falls back to the default rather than building a URL.
function normalizeCodec(codec) {
  var c = String(codec === undefined || codec === null ? "" : codec).toLowerCase()
  return codecs.indexOf(c) === -1 ? codecs[0] : c
}

function streamUrl(codec) { return streamBase + normalizeCodec(codec) }

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

// Track length in seconds, or 0 when unknown. Anything past a day is not a
// real track, and capping it keeps the value inside the QML int it lands in.
var maxTrackSeconds = 86400
function lengthSeconds(v) {
  var n = parseInt(v, 10)
  return n > 0 && n <= maxTrackSeconds ? n : 0
}

// The sanitized shape of a currently_playing payload. The caller owns the
// change detection and the notification - this only normalizes.
function normalizeStatus(d, st, now, warn) {
  return {
    title: sanitizeText(d.title, maxFieldLength),
    artist: sanitizeText(d.artist, maxFieldLength),
    genre: sanitizeText(d.genre, maxFieldLength),
    // cover_url is square 600px art; the icon fields are older fallbacks
    // (media_icon_url is 16:9 and gets cropped in the square slot).
    bigArtUrl: safeUrlLogged(cleanArtUrl(d.cover_url), st, now, warn)
      || safeUrlLogged(cleanArtUrl(d.media_icon_url), st, now, warn)
      || safeUrlLogged(cleanArtUrl(d.icon_url), st, now, warn),
    listeners: parseInt(d.listeners, 10) || 0,
    onAirAt: Number(d.on_air_at) || 0,
    lengthSeconds: lengthSeconds(d.length),
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

// Whether a toast whose art fetch just finished is still worth sending. The
// fetch takes seconds, and in that window the listener may have stopped the
// stream, turned notifications off, or the feed moved to another track - a
// toast for any of those would announce something that isn't playing.
function shouldSendFetchedToast(trackAudioId, currentAudioId, enabled, playing) {
  return !!(trackAudioId === currentAudioId && enabled && playing)
}

// A duration in seconds as m:ss, or h:mm:ss from an hour up.
function clockText(s) {
  var m = Math.floor(s / 60)
  var h = Math.floor(m / 60)
  var pad = function(n) { return (n < 10 ? "0" : "") + n }
  return h > 0 ? h + ":" + pad(m % 60) + ":" + pad(s % 60) : m + ":" + pad(s % 60)
}

// ---- Track-change notification.
var maxArtBytes = 5242880
var notifyGlyph = "\u{f075a}"

// Downloads cover art for the toast into dir as art-<audioId>, clearing the
// previous track's file first. The host notification service copies an
// image the moment the toast arrives, so nothing else reads the old file.
// Values travel as positional parameters, never through the script text. No
// -L: following a redirect would leave the safeUrl allowlist behind, and
// --proto pins https even so. Exits non-zero on any failure, in which case
// the caller sends the toast without art.
function artFetchArgv(dir, audioId, url) {
  return ["bash", "-c",
    "mkdir -p -- \"$1\" && rm -f -- \"$1\"/art-* && " +
    "exec curl -fsS --proto =https --connect-timeout 3 --max-time 5 " +
    "--max-filesize \"$4\" -o \"$1/art-$2\" -- \"$3\"",
    "--", String(dir), String(parseInt(audioId, 10) || 0), String(url),
    String(maxArtBytes)]
}

// The toast body: artist on the first line, then genre and length. Bodies
// are markup-parsed by the notification server, so every field is escaped.
function notifyBody(artist, genre, lengthSeconds) {
  var details = []
  if (genre) details.push(escapeMarkup(genre))
  if (lengthSeconds > 0) details.push(clockText(lengthSeconds))
  var lines = []
  if (artist) lines.push(escapeMarkup(artist))
  if (details.length) lines.push(details.join("  ·  "))
  return lines.join("\n")
}

// A Notify call on the session bus, as busctl argv. busctl rather than
// notify-send so the toast can carry Omarchy's hints: omarchy-exec-argv
// opens the track on click (and survives a shell restart, unlike a
// libnotify action), and omarchy-glyph stands in when there is no art.
// `transient` keeps a toast silenced by Do Not Disturb out of history - a
// session's worth of tracks there is noise. artUrl is a file:// URL or "".
function trackNotifyArgv(t, artUrl) {
  var hints = [
    "urgency", "y", "1",
    "transient", "b", "true",
    "omarchy-glyph", "s", notifyGlyph,
    "omarchy-exec-argv", "s", JSON.stringify(["xdg-open", t.listenUrl])
  ]
  if (artUrl) hints.push("image-path", "s", artUrl)
  return ["busctl", "--user", "--", "call",
    "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
    "org.freedesktop.Notifications", "Notify", "susssasa{sv}i",
    "Newgrounds Radio", "0", "", stripMarkup(t.title),
    notifyBody(t.artist, t.genre, t.lengthSeconds),
    "0", String(hints.length / 3)].concat(hints, ["-1"])
}

// ---- Realtime feed: minimal Engine.IO v4 client over the polling
// transport, one curl per request. A long-poll GET is held open by the server
// until it has something to send, so status still arrives in realtime.
//   GET  (no sid)  -> "0{sid,...}" handshake
//   POST "40"      -> join the default namespace
//   GET  &sid=...  -> one or more packets separated by \x1e (see below)
//   POST "3"       -> answer a server ping
//
// curl, not QML, enforces the response cap: --max-filesize aborts a transfer
// mid-stream once it passes maxResponseBytes (even with no Content-Length)
// and exits non-zero, so an oversize body is discarded after the shell has
// buffered at most the cap. A real response holds a namespace ack, a status
// (a few KiB) and perhaps a ping; room for two packets at the per-packet cap
// is ample, and classifyFrame still drops any single packet over it.
var feedEndpoint = "https://api.newgroundsradio.com/socket.io/?EIO=4&transport=polling"
var maxResponseBytes = 2 * maxMessageLength
var maxSidLength = 64
// Seconds. The server holds a GET for up to its ping interval (25s) before
// answering with a ping; the long-poll cap sits above that, and still ends a
// stalled request. Handshake and POSTs answer at once.
var feedPollMaxTime = 45
var feedRequestMaxTime = 10
var feedPostPackets = ["40", "3"]
// A real long-poll is held until there is news, but a server answering
// every GET at once would otherwise turn the loop into back-to-back curl
// spawns. Packets sent in the gap wait on the server for the next GET.
var minPollInterval = 1000

// Milliseconds to wait before the next GET, given when the last one started.
// A backwards clock correction means no wait rather than a stuck loop.
function pollDelay(now, lastPollAt) {
  var elapsed = now - lastPollAt
  return elapsed < 0 || elapsed >= minPollInterval ? 0 : minPollInterval - elapsed
}

// A session id from the network ends up in a URL, so it must look like one
// socket.io issues (base64url, 20 chars today) and nothing more.
function validSid(sid) {
  return typeof sid === "string" && sid.length <= maxSidLength
    && /^[A-Za-z0-9_-]+$/.test(sid)
}

function feedUrl(sid) {
  return sid ? feedEndpoint + "&sid=" + sid : feedEndpoint
}

// Shared curl options: no ~/.curlrc (-q), https only, no redirects, bounded
// connect and total time. Every argument is a fixed string or a validated
// sid, and there is no shell in between.
function feedCurlBase(maxTime) {
  return ["curl", "-q", "-fsS", "--proto", "=https", "--connect-timeout", "5",
          "--max-time", String(maxTime)]
}

// A handshake (sid "") or long-poll GET, body to stdout. Returns null for an
// invalid sid rather than a request carrying it.
function feedGetArgv(sid) {
  if (sid && !validSid(sid)) return null
  return feedCurlBase(sid ? feedPollMaxTime : feedRequestMaxTime).concat(
    ["--max-filesize", String(maxResponseBytes), "--", feedUrl(sid)])
}

// A POST of one of the fixed client packets. The server answers "ok", which
// nothing needs, so the body goes to /dev/null rather than into the shell.
// Only the packets in feedPostPackets are sent; anything else is null.
function feedPostArgv(sid, packet) {
  if (!validSid(sid) || feedPostPackets.indexOf(packet) === -1) return null
  return feedCurlBase(feedRequestMaxTime).concat(
    ["-o", "/dev/null", "-H", "Content-Type: text/plain;charset=UTF-8",
     "--data-binary", packet, "--", feedUrl(sid)])
}

// Polling bodies batch packets separated by the record separator.
function splitPayload(body) {
  return String(body === undefined || body === null ? "" : body).split("\x1e")
}

// A finished GET, as {ok, packets}. Anything but a clean exit - curl's
// size-cap abort (63), an HTTP error such as an unknown sid (22), a timeout -
// is a failure whose partial body is never parsed. The length test repeats
// the cap in case curl ever lets one through.
function pollResult(exitCode, body) {
  var s = String(body === undefined || body === null ? "" : body)
  if (exitCode !== 0) return { ok: false, oversize: exitCode === 63, packets: [] }
  if (s.length > maxResponseBytes) return { ok: false, oversize: true, packets: [] }
  return { ok: true, oversize: false, packets: splitPayload(s) }
}

// The session id from a handshake response, or "" to reject it. The server's
// pingInterval/pingTimeout are ignored: the timeouts above are constants.
function parseHandshake(body) {
  var first = splitPayload(body)[0]
  if (first.length > maxMessageLength || first.charAt(0) !== "0") return ""
  try {
    var open = JSON.parse(first.substring(1))
    if (open && validSid(open.sid)) return open.sid
  } catch (e) {}
  return ""
}

// One Engine.IO packet from a poll response:
//   "0{...}"  open handshake  -> only expected from the handshake GET
//   "40..."   namespace ack   -> connected
//   "2"       server ping     -> reply "3"
//   "42[...]" event           -> ["status", {currently_playing, play_log}]
//   "1"       transport close -> reconnect
//   "41"/"44" namespace kick  -> reconnect
//
// Returns {kind, packet}. A packet larger than the cap is never a real status
// update, so it is dropped rather than parsed into the shell.
function classifyFrame(message) {
  var m = String(message)
  if (m.length > maxMessageLength) return { kind: "oversize" }
  if (m.charAt(0) === "0") return { kind: "open" }
  if (m === "2") return { kind: "ping" }
  if (m === "1") return { kind: "reconnect" }
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
