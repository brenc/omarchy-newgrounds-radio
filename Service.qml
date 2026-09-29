import QtQuick
import Quickshell
import Quickshell.Io
import "RadioLogic.js" as RadioLogic

// Newgrounds Radio service: owns the mpv playback process and the status
// feed, so bar widgets on every monitor share one stream and one connection.
//
// Status arrives in realtime from the station's socket.io endpoint, which
// pushes a full status on connect and on every change. The client speaks
// Engine.IO v4 long-polling through curl subprocesses, so every response is
// size-capped by curl before any of it reaches this long-lived process.
Item {
  id: root

  property var shell: null

  // One of RadioLogic.codecs; always set through setCodec() so a running
  // stream follows the change.
  property string codec: RadioLogic.normalizeCodec("")
  readonly property string streamUrl: RadioLogic.streamUrl(codec)
  // Set while mpv is being stopped only to relaunch on a new stream URL, so
  // onExited restarts at once instead of counting it as a dropped stream.
  property bool switchingStream: false
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
  property int lengthSeconds: 0
  property int skipVotes: 0
  property int skipThreshold: 0
  property var playLog: []
  property bool feedConnected: false
  property double lastFeedAt: Date.now()
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

  // The shell.json codec seeds the stream but doesn't pin it: every
  // monitor's widget re-pushes its settings (on hotplug, too), so only an
  // actual change to the configured value overrides a popup choice.
  property string configuredCodec: ""

  function applyCodecSetting(c) {
    var next = RadioLogic.normalizeCodec(c)
    if (next === configuredCodec) return
    configuredCodec = next
    setCodec(next)
  }

  // Switches the stream codec; a playing stream relaunches on the new URL.
  function setCodec(c) {
    var next = RadioLogic.normalizeCodec(c)
    if (next === codec) return
    codec = next
    if (player.running) {
      switchingStream = true
      player.running = false
    }
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
    root.lengthSeconds = v.lengthSeconds
    root.skipVotes = v.skipVotes
    root.skipThreshold = v.skipThreshold
    root.audioId = v.audioId
    if (RadioLogic.shouldNotify(changed, root.notifyOnTrackChange, root.playing,
                                now, root.lastNotifyAt)) {
      root.lastNotifyAt = now
      notifyTrack()
    }
  }

  // Cover art for the toast lands here; artFetch's argv clears old files.
  readonly property string artDir: Quickshell.cachePath("newgrounds-radio")

  // One fetch per track change, in the shared service - so one request
  // however many monitors there are, and only while the user is listening.
  // A fetch still in flight (tracks flipping faster than curl's timeout)
  // means this toast goes out without art rather than queueing.
  function notifyTrack() {
    var track = {
      title: root.title, artist: root.artist, genre: root.genre,
      lengthSeconds: root.lengthSeconds, audioId: root.audioId,
      listenUrl: root.listenUrl
    }
    if (!root.bigArtUrl || artFetch.running) {
      Quickshell.execDetached(RadioLogic.trackNotifyArgv(track, ""))
      return
    }
    artFetch.track = track
    artFetch.command = RadioLogic.artFetchArgv(root.artDir, track.audioId, root.bigArtUrl)
    artFetch.running = true
  }

  // A Process whose exit code and complete stdout are delivered together by
  // settled(). Quickshell reports the two separately, in an order it
  // doesn't document (0.3.1 happens to finish stdout first), so this waits
  // for both before either is acted on.
  component CollectedProcess: Process {
    id: proc
    property bool exitSeen: false
    property bool streamSeen: false
    property int exitCode: -1
    signal settled(int exitCode, string out)

    function launch(argv) {
      exitSeen = false
      streamSeen = false
      command = argv
      running = true
    }
    function trySettle() {
      if (exitSeen && streamSeen) settled(exitCode, collector.text)
    }

    stdout: StdioCollector {
      id: collector
      waitForEnd: true
      onStreamFinished: { proc.streamSeen = true; proc.trySettle() }
    }
    onExited: function(code) {
      proc.exitCode = code
      proc.exitSeen = true
      proc.trySettle()
    }
  }

  Process {
    id: artFetch
    property var track: null
    onExited: function(exitCode) {
      if (!RadioLogic.shouldSendFetchedToast(track.audioId, root.audioId,
                                             root.notifyOnTrackChange, root.playing)) return
      var art = exitCode === 0 ? "file://" + root.artDir + "/art-" + track.audioId : ""
      Quickshell.execDetached(RadioLogic.trackNotifyArgv(track, art))
    }
  }

  // ---- Realtime feed: Engine.IO v4 long-polling, one curl per request.
  // RadioLogic owns the framing, argv and response cap; this only runs the
  // loop. feedPhase is "backoff" (waiting out reconnectTimer), "handshake",
  // "join" (POST "40" in flight) or "poll". Every failure - HTTP error,
  // unknown sid, timeout, oversize response, close or kick - drops the
  // session and waits out the backoff, so nothing retries hot.
  property string feedPhase: "backoff"
  property string feedSid: ""
  property double lastPollAt: 0

  function startFeed() {
    // A torn-down request may still be exiting; its settle would be ignored,
    // but one Process can't run two requests, so wait another round.
    if (feedGet.running || feedPost.running) { reconnectTimer.restart(); return }
    feedSid = ""
    feedPhase = "handshake"
    lastFeedAt = Date.now()
    feedGet.launch(RadioLogic.feedGetArgv(""))
  }

  function failFeed() {
    if (feedPhase === "backoff") return
    if (feedConnected) console.log("newgrounds radio: realtime feed lost")
    feedConnected = false
    feedSid = ""
    feedPhase = "backoff"
    pollTimer.stop()
    feedGet.running = false
    feedPost.running = false
    reconnectTimer.restart()
  }

  function pollFeed() {
    var argv = RadioLogic.feedGetArgv(feedSid)
    if (!argv) { failFeed(); return }
    lastPollAt = Date.now()
    feedGet.launch(argv)
  }

  function postFeed(packet) {
    var argv = RadioLogic.feedPostArgv(feedSid, packet)
    // A pong still in flight 25s after the last one is a stalled session.
    if (!argv || feedPost.running) { failFeed(); return }
    feedPost.packet = packet
    feedPost.launch(argv)
  }

  function handleHandshake(exitCode, body) {
    var r = RadioLogic.pollResult(exitCode, body)
    var sid = r.ok ? RadioLogic.parseHandshake(r.packets[0]) : ""
    if (!sid) { failFeed(); return }
    lastFeedAt = Date.now()
    feedSid = sid
    feedPhase = "join"
    postFeed("40")
  }

  function handlePoll(exitCode, body) {
    var r = RadioLogic.pollResult(exitCode, body)
    if (!r.ok) {
      if (r.oversize) console.warn("newgrounds radio: dropped oversize feed response")
      failFeed()
      return
    }
    lastFeedAt = Date.now()
    for (var i = 0; i < r.packets.length; i++) {
      if (!handlePacket(r.packets[i])) { failFeed(); return }
    }
    var wait = RadioLogic.pollDelay(Date.now(), lastPollAt)
    if (wait > 0) { pollTimer.interval = wait; pollTimer.restart() }
    else pollFeed()
  }

  // Acts on one packet; false means the session is over.
  function handlePacket(message) {
    var f = RadioLogic.classifyFrame(message)
    if (f.kind === "ping") { postFeed("3"); return feedPhase === "poll" }
    if (f.kind === "reconnect") return false
    if (f.kind === "connected") {
      if (!feedConnected) console.log("newgrounds radio: realtime feed connected")
      feedConnected = true
    } else if (f.kind === "status") {
      var now = Date.now()
      if (Array.isArray(f.packet.play_log))
        root.playLog = RadioLogic.sanitizePlayLog(f.packet.play_log, root.urlWarnState,
                                                  now, root.warnRejectedUrl)
      if (f.packet.currently_playing) applyStatusData(f.packet.currently_playing)
    }
    return true
  }

  CollectedProcess {
    id: feedGet
    onSettled: function(exitCode, out) {
      if (root.feedPhase === "handshake") root.handleHandshake(exitCode, out)
      else if (root.feedPhase === "poll") root.handlePoll(exitCode, out)
    }
  }

  // POSTs write their "ok" to /dev/null, so only the exit code matters.
  CollectedProcess {
    id: feedPost
    property string packet: ""
    onSettled: function(exitCode) {
      if (root.feedPhase === "backoff") return
      if (exitCode !== 0) { root.failFeed(); return }
      if (packet === "40" && root.feedPhase === "join") {
        root.feedPhase = "poll"
        root.pollFeed()
      }
    }
  }

  Timer {
    id: pollTimer
    onTriggered: if (root.feedPhase === "poll") root.pollFeed()
  }

  Timer {
    id: reconnectTimer
    interval: 5000
    onTriggered: root.startFeed()
  }

  Component.onCompleted: startFeed()

  // The server pings every 25s and curl caps each request, so a 60s silence
  // means the loop wedged somewhere curl's timeouts don't reach
  // (sleep/resume, a request that never settled) or never finished its
  // handshake.
  Timer {
    interval: 60000
    running: root.feedPhase !== "backoff"
    repeat: true
    onTriggered: {
      if (Date.now() - root.lastFeedAt > 60000) root.failFeed()
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
      if (root.switchingStream) {
        root.switchingStream = false
        if (root.wantPlaying) player.running = true
        return
      }
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
