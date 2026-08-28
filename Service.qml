import QtQuick
import QtWebSockets
import Quickshell
import Quickshell.Io

// Newgrounds Radio service: owns the mpv playback process and the status
// feed, so bar widgets on every monitor share one stream and one connection.
//
// Status arrives in realtime over the station's socket.io endpoint (a
// minimal Engine.IO v4 client over WebSocket), which pushes a full status
// on connect and on every change — no polling needed.
Item {
  id: root

  property var shell: null

  property string streamUrl: "https://stream.newgroundsradio.com/radio.mp3"
  property string socketUrl: "wss://api.newgroundsradio.com/socket.io/?EIO=4&transport=websocket"
  property bool notifyOnTrackChange: true

  property bool wantPlaying: false
  readonly property bool playing: wantPlaying && player.running
  property int restartAttempts: 0

  // Now-playing state from the last successful status update. Kept on
  // failure so stale data stays visible.
  property string title: ""
  property string artist: ""
  property string genre: ""
  property string bigArtUrl: ""
  property int audioId: 0
  property int listeners: 0
  property double onAirAt: 0
  property int skipVotes: 0
  property int skipThreshold: 0
  property var playLog: []
  property bool socketConnected: false
  property double lastSocketMessageAt: Date.now()
  property double lastNotifyAt: 0
  property string lastRejectedUrl: ""
  property double lastWarnAt: 0

  readonly property string listenUrl: audioId > 0
    ? "https://www.newgrounds.com/audio/listen/" + audioId
    : "https://newgroundsradio.com"

  function play() {
    wantPlaying = true
    restartAttempts = 0
    if (!player.running) player.running = true
  }

  function stop() {
    wantPlaying = false
    player.running = false
  }

  function toggle() {
    if (wantPlaying) stop()
    else play()
  }

  // ---- Bounds on everything the feed supplies. This service is long-lived
  // and shared by every monitor's bar, so nothing from the network is stored
  // unbounded: oversized frames are dropped, strings are truncated, and the
  // play log keeps a fixed number of records with a fixed set of fields.
  readonly property int maxMessageLength: 131072
  readonly property int maxFieldLength: 200
  readonly property int maxUrlLength: 512
  readonly property int maxPlayLogEntries: 12
  // Bounds the walk itself: an array of nulls never grows `out`, so the
  // entry cap alone wouldn't stop the loop early.
  readonly property int maxPlayLogScan: 100
  readonly property int minNotifyInterval: 5000
  readonly property int minWarnInterval: 5000

  // Hosts the feed is allowed to point us at. Artwork and listen links are
  // Newgrounds-owned; anything else is dropped rather than fetched or opened.
  readonly property var allowedHosts: ["newgrounds.com", "ngfiles.com", "newgroundsradio.com"]

  // Feed strings are display-only: drop control characters and cap the length
  // before anything stores or renders them. That includes the bidi and
  // zero-width formatting controls — a title ending in U+202E can visually
  // reverse the text after it, and the title in the popup is a clickable
  // link, so a spoofed one is worth more than a cosmetic glitch. ZWNJ and
  // ZWJ are deliberately left alone - they can't reorder or hide anything,
  // and dropping them would shred emoji sequences and Persian word shaping.
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
  // xdg-open. Anything else — other schemes, other hosts, local paths —
  // becomes "" rather than a request we never declared.
  function safeUrl(url) {
    var s = root.sanitizeText(url, root.maxUrlLength)
    var m = /^https:\/\/([A-Za-z0-9.-]+)(\/[!-~]*)?$/.exec(s)
    if (m) {
      var host = m[1].toLowerCase()
      for (var i = 0; i < root.allowedHosts.length; i++) {
        var h = root.allowedHosts[i]
        if (host === h || host.substring(host.length - h.length - 1) === "." + h) return s
      }
    }
    // Silent rejection would show up only as missing art or a dead link, so
    // leave a breadcrumb: today's URLs are ASCII and portless, and a future
    // feed change should be debuggable rather than invisible. Only the first
    // of a repeated rejection is logged, behind the same rate floor as the
    // notifications - safeUrl runs up to 13 times per status frame, the feed
    // sets the rate, and alternating URLs would defeat the memo alone.
    var t = s.replace(/^\s+|\s+$/g, "")
    var at = Date.now()
    if (t !== "" && t !== root.lastRejectedUrl
        && (at - root.lastWarnAt > root.minWarnInterval || at < root.lastWarnAt)) {
      root.lastRejectedUrl = t
      root.lastWarnAt = at
      console.warn("newgrounds radio: rejected feed url:", t)
    }
    return ""
  }

  // Rebuild each play-log record from scratch: a fixed set of fields, each
  // bounded, so the shell never holds arbitrary server-shaped objects.
  function sanitizePlayLog(entries) {
    var out = []
    var scan = Math.min(entries.length, root.maxPlayLogScan)
    for (var i = 0; i < scan && out.length < root.maxPlayLogEntries; i++) {
      var e = entries[i]
      if (!e || typeof e !== "object") continue
      out.push({
        title: root.sanitizeText(e.title, root.maxFieldLength),
        artist: root.sanitizeText(e.artist, root.maxFieldLength),
        on_air_at: root.sanitizeText(e.on_air_at, 64),
        listen_url: root.safeUrl(e.listen_url)
      })
    }
    return out
  }

  function applyStatusData(d) {
    var newId = parseInt(d.audio_id, 10) || 0
    var changed = newId !== 0 && newId !== root.audioId
    root.title = root.sanitizeText(d.title, root.maxFieldLength)
    root.artist = root.sanitizeText(d.artist, root.maxFieldLength)
    root.genre = root.sanitizeText(d.genre, root.maxFieldLength)
    root.bigArtUrl = root.safeUrl(root.cleanArtUrl(d.media_icon_url))
      || root.safeUrl(root.cleanArtUrl(d.icon_url))
    root.listeners = parseInt(d.listeners, 10) || 0
    root.onAirAt = Number(d.on_air_at) || 0
    root.skipVotes = parseInt(d.skip_votes, 10) || 0
    root.skipThreshold = parseInt(d.skip_threshold, 10) || 0
    root.audioId = newId
    // Real tracks are minutes apart, so a floor of a few seconds costs
    // nothing — and it stops a feed that flips audio_id on every frame from
    // spawning one notify-send per message out of a long-lived shell. The
    // second test un-sticks the gate after a backwards clock correction.
    var now = Date.now()
    if (changed && root.notifyOnTrackChange && root.playing
        && (now - root.lastNotifyAt > root.minNotifyInterval
            || now < root.lastNotifyAt)) {
      root.lastNotifyAt = now
      Quickshell.execDetached(["notify-send", "-a", "Newgrounds Radio", "-e", "--",
        root.stripMarkup(root.title),
        root.escapeMarkup(root.artist + (root.genre ? "  \u00b7  " + root.genre : ""))])
    }
  }

  // ---- Realtime feed: minimal Engine.IO v4 framing over WebSocket.
  //   "0{...}"  open handshake  -> reply "40" to join the default namespace
  //   "40..."   namespace ack   -> connected
  //   "2"       server ping     -> reply "3"
  //   "42[...]" event           -> ["status", {currently_playing, play_log}]
  //   "41"      namespace kick  -> reconnect
  function handleSocketMessage(message) {
    lastSocketMessageAt = Date.now()
    var m = String(message)
    // A frame this large is never a real status update; drop it rather than
    // parse it into the shell.
    if (m.length > root.maxMessageLength) return
    if (m.charAt(0) === "0") { socket.sendTextMessage("40"); return }
    if (m === "2") { socket.sendTextMessage("3"); return }
    if (m.substring(0, 2) === "40") {
      if (!socketConnected) console.log("newgrounds radio: realtime socket connected")
      socketConnected = true
      return
    }
    if (m.substring(0, 2) === "41" || m.substring(0, 2) === "44") { reconnectSocket(); return }
    if (m.substring(0, 2) === "42") {
      try {
        var packet = JSON.parse(m.substring(2))
        if (packet[0] === "status" && packet[1]) {
          if (Array.isArray(packet[1].play_log))
            root.playLog = root.sanitizePlayLog(packet[1].play_log)
          if (packet[1].currently_playing) applyStatusData(packet[1].currently_playing)
        }
      } catch (e) {}
    }
  }

  function reconnectSocket() {
    socketConnected = false
    socket.active = false
    reconnectTimer.restart()
  }

  WebSocket {
    id: socket
    url: root.socketUrl
    active: true
    onTextMessageReceived: function(message) { root.handleSocketMessage(message) }
    onStatusChanged: {
      if (socket.status === WebSocket.Open) {
        // Start the silence clock from the transport opening, so a server
        // that never completes the Engine.IO handshake still gets reaped.
        root.lastSocketMessageAt = Date.now()
      } else if (socket.status === WebSocket.Closed || socket.status === WebSocket.Error) {
        root.socketConnected = false
        reconnectTimer.restart()
      }
    }
  }

  Timer {
    id: reconnectTimer
    interval: 5000
    onTriggered: {
      if (root.socketConnected) return
      socket.active = false
      socket.active = true
    }
  }

  // The server pings every 25s; a 60s silence means the connection died
  // without a proper close (sleep/resume, network drop) or never completed
  // its handshake. Gated on the transport, not socketConnected, so a
  // half-open initial connection is also reaped.
  Timer {
    interval: 60000
    running: socket.status === WebSocket.Open || socket.status === WebSocket.Connecting
    repeat: true
    onTriggered: {
      if (Date.now() - root.lastSocketMessageAt > 60000) root.reconnectSocket()
    }
  }

  // ---- Playback.
  Process {
    id: player
    // --load-scripts=no keeps this managed instance off MPRIS (mpv-mpris
    // ships with Omarchy): an external pause via the media widget would
    // desync the pill, which can't observe it. This widget is the control
    // surface.
    command: ["mpv", "--no-video", "--no-terminal", "--load-scripts=no",
              "--force-media-title=Newgrounds Radio",
              root.streamUrl]
    onExited: function() {
      if (!root.wantPlaying) return
      if (root.restartAttempts >= 5) {
        root.wantPlaying = false
        Quickshell.execDetached(["notify-send", "-a", "Newgrounds Radio",
          "Stream dropped", "Gave up reconnecting — click the bar widget to retry."])
        return
      }
      root.restartAttempts++
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 2500
    onTriggered: if (root.wantPlaying && !player.running) player.running = true
  }

  // A stretch of stable playback earns a fresh reconnect budget.
  Timer {
    interval: 30000
    running: player.running
    onTriggered: root.restartAttempts = 0
  }

}
