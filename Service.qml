import QtQuick
import QtWebSockets
import Quickshell
import Quickshell.Io
import "RadioLogic.js" as RadioLogic

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

  // Mutable bookkeeping for the rate-limited rejection breadcrumb, owned here
  // and threaded through RadioLogic so that logic stays pure and testable.
  property var urlWarnState: ({ lastRejectedUrl: "", lastWarnAt: 0 })

  function warnRejectedUrl(t) { console.warn("newgrounds radio: rejected feed url:", t) }

  function applyStatusData(d) {
    var now = Date.now()
    var v = RadioLogic.normalizeStatus(d, root.urlWarnState, now, root.warnRejectedUrl)
    var changed = v.audioId !== 0 && v.audioId !== root.audioId
    root.title = v.title
    root.artist = v.artist
    root.genre = v.genre
    root.bigArtUrl = v.bigArtUrl
    root.listeners = v.listeners
    root.onAirAt = v.onAirAt
    root.skipVotes = v.skipVotes
    root.skipThreshold = v.skipThreshold
    root.audioId = v.audioId
    if (RadioLogic.shouldNotify(changed, root.notifyOnTrackChange, root.playing,
                                now, root.lastNotifyAt)) {
      root.lastNotifyAt = now
      Quickshell.execDetached(["notify-send", "-a", "Newgrounds Radio", "-e", "--",
        RadioLogic.stripMarkup(root.title),
        RadioLogic.escapeMarkup(root.artist + (root.genre ? "  \u00b7  " + root.genre : ""))])
    }
  }

  // ---- Realtime feed. RadioLogic.classifyFrame owns the Engine.IO v4
  // framing; this only acts on the classification. An oversize frame
  // classifies as "oversize" and is deliberately dropped without a reply.
  function handleSocketMessage(message) {
    lastSocketMessageAt = Date.now()
    var f = RadioLogic.classifyFrame(message)
    if (f.kind === "open") { socket.sendTextMessage("40"); return }
    if (f.kind === "ping") { socket.sendTextMessage("3"); return }
    if (f.kind === "connected") {
      if (!socketConnected) console.log("newgrounds radio: realtime socket connected")
      socketConnected = true
      return
    }
    if (f.kind === "reconnect") { reconnectSocket(); return }
    if (f.kind === "status") {
      var now = Date.now()
      if (Array.isArray(f.packet.play_log))
        root.playLog = RadioLogic.sanitizePlayLog(f.packet.play_log, root.urlWarnState,
                                                  now, root.warnRejectedUrl)
      if (f.packet.currently_playing) applyStatusData(f.packet.currently_playing)
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
