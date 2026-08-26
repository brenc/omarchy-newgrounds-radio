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

  // ngfiles art URLs carry a ?t= cache-buster that can differ between
  // responses; strip it so the Image source stays stable across polls.
  function cleanArtUrl(url) {
    var s = String(url || "")
    var q = s.indexOf("?")
    return q === -1 ? s : s.substring(0, q)
  }

  function applyStatusData(d) {
    var newId = parseInt(d.audio_id, 10) || 0
    var changed = newId !== 0 && newId !== root.audioId
    root.title = String(d.title || "")
    root.artist = String(d.artist || "")
    root.genre = String(d.genre || "")
    root.bigArtUrl = root.cleanArtUrl(d.media_icon_url) || root.cleanArtUrl(d.icon_url)
    root.listeners = parseInt(d.listeners, 10) || 0
    root.onAirAt = Number(d.on_air_at) || 0
    root.skipVotes = parseInt(d.skip_votes, 10) || 0
    root.skipThreshold = parseInt(d.skip_threshold, 10) || 0
    root.audioId = newId
    if (changed && root.notifyOnTrackChange && root.playing)
      Quickshell.execDetached(["notify-send", "-a", "Newgrounds Radio", "-e", "--",
        root.title, root.artist + (root.genre ? "  ·  " + root.genre : "")])
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
            root.playLog = packet[1].play_log.filter(function(e) { return e && typeof e === "object" })
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
