import QtQuick
import QtTest
import "../RadioLogic.js" as RadioLogic

// Exercises the pure feed-handling logic. Nothing here imports Quickshell,
// so qmltestrunner can load it without the shell.
TestCase {
  name: "RadioLogic"

  function freshState() { return ({ lastRejectedUrl: "", lastWarnAt: 0 }) }

  // ---- sanitizeText
  function test_sanitize_strips_bidi_override() {
    compare(RadioLogic.sanitizeText("evil\u202Egnp.txt", 200), "evil gnp.txt")
  }
  function test_sanitize_strips_zero_width_and_control() {
    compare(RadioLogic.sanitizeText("a\u200Bb\tc", 200), "a b c")
  }
  function test_sanitize_keeps_zwj_and_zwnj() {
    compare(RadioLogic.sanitizeText("a\u200Db\u200Cc", 200), "a\u200Db\u200Cc")
  }
  function test_sanitize_caps_length() {
    var long = ""
    for (var i = 0; i < 500; i++) long += "x"
    compare(RadioLogic.sanitizeText(long, 200).length, 200)
  }
  function test_sanitize_null_and_undefined_become_empty() {
    compare(RadioLogic.sanitizeText(null, 200), "")
    compare(RadioLogic.sanitizeText(undefined, 200), "")
  }

  // ---- markup
  function test_strip_markup_drops_angle_brackets() {
    compare(RadioLogic.stripMarkup("<img src=x>hi"), "img src=xhi")
  }
  function test_escape_markup_escapes_amp_first() {
    compare(RadioLogic.escapeMarkup("&<>"), "&amp;&lt;&gt;")
  }

  // ---- cleanArtUrl
  function test_clean_art_url_drops_cache_buster() {
    compare(RadioLogic.cleanArtUrl("https://uploads.ngfiles.com/a.png?t=123"),
            "https://uploads.ngfiles.com/a.png")
  }

  // ---- safeUrl
  function test_url_allows_bare_and_subdomain_hosts() {
    compare(RadioLogic.safeUrl("https://newgrounds.com/a"), "https://newgrounds.com/a")
    compare(RadioLogic.safeUrl("https://uploads.ngfiles.com/a.png"),
            "https://uploads.ngfiles.com/a.png")
  }
  function test_url_rejects_foreign_host() {
    compare(RadioLogic.safeUrl("https://evil.com/a.png"), "")
  }
  function test_url_rejects_suffix_smuggle() {
    compare(RadioLogic.safeUrl("https://notnewgrounds.com/a.png"), "")
    compare(RadioLogic.safeUrl("https://newgrounds.com.evil.com/a"), "")
  }
  function test_url_rejects_non_https_schemes() {
    compare(RadioLogic.safeUrl("http://newgrounds.com/a"), "")
    compare(RadioLogic.safeUrl("file:///etc/passwd"), "")
    compare(RadioLogic.safeUrl("javascript:alert(1)"), "")
  }
  function test_url_rejects_userinfo_and_whitespace() {
    compare(RadioLogic.safeUrl("https://evil.com@newgrounds.com/a"), "")
    compare(RadioLogic.safeUrl("https://newgrounds.com/a b"), "")
  }

  // ---- safeUrlLogged rate floor
  function test_warn_fires_once_then_memoes_and_floors() {
    var st = freshState(), warned = []
    var w = function(t) { warned.push(t) }
    compare(RadioLogic.safeUrlLogged("https://evil.com/a", st, 100000, w), "")
    compare(warned.length, 1)
    RadioLogic.safeUrlLogged("https://evil.com/a", st, 100100, w)   // same url
    compare(warned.length, 1)
    RadioLogic.safeUrlLogged("https://other.com/b", st, 100200, w)  // inside floor
    compare(warned.length, 1)
    RadioLogic.safeUrlLogged("https://other.com/b", st, 200000, w)  // floor elapsed
    compare(warned.length, 2)
  }
  function test_warn_gate_unsticks_after_backwards_clock() {
    var st = ({ lastRejectedUrl: "", lastWarnAt: 900000 }), warned = []
    RadioLogic.safeUrlLogged("https://evil.com/z", st, 1000, function(t) { warned.push(t) })
    compare(warned.length, 1)
  }
  function test_accepted_url_never_warns() {
    var st = freshState(), warned = []
    compare(RadioLogic.safeUrlLogged("https://newgrounds.com/a", st, 500000,
            function(t) { warned.push(t) }), "https://newgrounds.com/a")
    compare(warned.length, 0)
  }

  // ---- sanitizePlayLog
  function test_playlog_caps_entries() {
    var many = []
    for (var i = 0; i < 60; i++) many.push({ title: "t", artist: "a" })
    compare(RadioLogic.sanitizePlayLog(many, freshState(), 0, null).length, 12)
  }
  function test_playlog_scan_bound_survives_nulls() {
    var nulls = []
    for (var i = 0; i < 5000; i++) nulls.push(null)
    compare(RadioLogic.sanitizePlayLog(nulls, freshState(), 0, null).length, 0)
  }
  // Valid entries parked past the scan bound: the walk must stop before
  // reaching them. Asserting only on a all-null array can't catch a dropped
  // bound, since the entry cap alone still yields an empty result.
  function test_playlog_scan_bound_stops_the_walk() {
    var padded = []
    for (var i = 0; i < 200; i++) padded.push(null)
    for (var j = 0; j < 12; j++) padded.push({ title: "late", artist: "a" })
    compare(RadioLogic.sanitizePlayLog(padded, freshState(), 0, null).length, 0)
  }
  function test_playlog_rebuilds_fixed_fields_only() {
    var r = RadioLogic.sanitizePlayLog(
      [{ title: "t", artist: "a", evil: "x", listen_url: "https://evil.com/a" }],
      freshState(), 0, null)[0]
    compare(r.evil, undefined)
    compare(r.listen_url, "")
    compare(r.title, "t")
  }

  // ---- normalizeStatus
  function test_normalize_sanitizes_and_coerces() {
    var v = RadioLogic.normalizeStatus({
      title: "T\u202Ex", artist: "A", genre: "G",
      media_icon_url: "https://uploads.ngfiles.com/a.png?t=9",
      listeners: "42", audio_id: "7", skip_votes: "bogus", length: "233"
    }, freshState(), 0, null)
    compare(v.title, "T x")
    compare(v.bigArtUrl, "https://uploads.ngfiles.com/a.png")
    compare(v.listeners, 42)
    compare(v.audioId, 7)
    compare(v.skipVotes, 0)
    compare(v.lengthSeconds, 233)
  }
  function test_normalize_length_rejects_out_of_range_and_junk() {
    compare(RadioLogic.normalizeStatus({ length: -5 }, freshState(), 0, null).lengthSeconds, 0)
    compare(RadioLogic.normalizeStatus({ length: "x" }, freshState(), 0, null).lengthSeconds, 0)
    compare(RadioLogic.normalizeStatus({ length: 2147483648 }, freshState(), 0, null).lengthSeconds, 0)
    compare(RadioLogic.normalizeStatus({ length: 86401 }, freshState(), 0, null).lengthSeconds, 0)
    compare(RadioLogic.normalizeStatus({ length: 86400 }, freshState(), 0, null).lengthSeconds, 86400)
  }
  function test_normalize_prefers_cover_url() {
    var v = RadioLogic.normalizeStatus({
      cover_url: "https://aicon.ngfiles.com/1/1_cover.webp?f123",
      media_icon_url: "https://aicon.ngfiles.com/1/1_raw.png"
    }, freshState(), 0, null)
    compare(v.bigArtUrl, "https://aicon.ngfiles.com/1/1_cover.webp")
  }
  function test_normalize_falls_back_past_rejected_cover_url() {
    var v = RadioLogic.normalizeStatus({
      cover_url: "https://evil.com/c.webp",
      media_icon_url: "https://aicon.ngfiles.com/1/1_raw.png"
    }, freshState(), 0, null)
    compare(v.bigArtUrl, "https://aicon.ngfiles.com/1/1_raw.png")
  }
  function test_normalize_falls_back_to_icon_url() {
    var v = RadioLogic.normalizeStatus({
      media_icon_url: "https://evil.com/a.png",
      icon_url: "https://uploads.ngfiles.com/b.png"
    }, freshState(), 0, null)
    compare(v.bigArtUrl, "https://uploads.ngfiles.com/b.png")
  }
  function test_normalize_rejects_both_art_urls() {
    var v = RadioLogic.normalizeStatus({
      cover_url: "file:///etc/passwd",
      media_icon_url: "https://evil.com/a.png", icon_url: "http://newgrounds.com/b.png"
    }, freshState(), 0, null)
    compare(v.bigArtUrl, "")
  }

  // ---- shouldNotify
  function test_notify_requires_change_enabled_and_playing() {
    compare(RadioLogic.shouldNotify(true, true, true, 100000, 0), true)
    compare(RadioLogic.shouldNotify(false, true, true, 100000, 0), false)
    compare(RadioLogic.shouldNotify(true, false, true, 100000, 0), false)
    compare(RadioLogic.shouldNotify(true, true, false, 100000, 0), false)
  }
  function test_notify_rate_floor_and_backwards_clock() {
    compare(RadioLogic.shouldNotify(true, true, true, 101000, 100000), false)
    compare(RadioLogic.shouldNotify(true, true, true, 110000, 100000), true)
    compare(RadioLogic.shouldNotify(true, true, true, 1000, 900000), true)
  }

  // ---- shouldSendFetchedToast
  function test_fetched_toast_needs_same_track_enabled_and_playing() {
    compare(RadioLogic.shouldSendFetchedToast(7, 7, true, true), true)
    compare(RadioLogic.shouldSendFetchedToast(7, 8, true, true), false)
    compare(RadioLogic.shouldSendFetchedToast(7, 7, false, true), false)
    compare(RadioLogic.shouldSendFetchedToast(7, 7, true, false), false)
  }

  // ---- clockText
  function test_clock_minutes_and_hours() {
    compare(RadioLogic.clockText(0), "0:00")
    compare(RadioLogic.clockText(222), "3:42")
    compare(RadioLogic.clockText(3723), "1:02:03")
  }

  // ---- notification
  function track() {
    return { title: "<b>Song</b>", artist: "A&B", genre: "Rock <3", lengthSeconds: 222,
             audioId: 7, listenUrl: "https://www.newgrounds.com/audio/listen/7" }
  }
  function hintsOf(argv) {
    var at = argv.indexOf("susssasa{sv}i") + 7
    var n = parseInt(argv[at], 10)
    var h = {}
    for (var i = 0; i < n; i++) h[argv[at + 1 + i * 3]] = argv[at + 3 + i * 3]
    compare(argv.length, at + 1 + n * 3 + 1)
    return h
  }
  function test_notify_body_escapes_and_splits_lines() {
    compare(RadioLogic.notifyBody("A&B", "Rock <3", 222), "A&amp;B\nRock &lt;3  ·  3:42")
    compare(RadioLogic.notifyBody("", "", 0), "")
    compare(RadioLogic.notifyBody("A", "", 0), "A")
  }
  function test_notify_argv_shape() {
    var argv = RadioLogic.trackNotifyArgv(track(), "")
    compare(argv[0], "busctl")
    var at = argv.indexOf("susssasa{sv}i")
    compare(argv[at + 4], "bSong/b")
    compare(argv[argv.length - 1], "-1")
    var h = hintsOf(argv)
    compare(h["transient"], "true")
    compare(JSON.parse(h["omarchy-exec-argv"]), ["xdg-open", "https://www.newgrounds.com/audio/listen/7"])
    compare(h["image-path"], undefined)
  }
  function test_notify_argv_carries_art() {
    var h = hintsOf(RadioLogic.trackNotifyArgv(track(), "file:///c/art-7"))
    compare(h["image-path"], "file:///c/art-7")
  }
  function test_art_fetch_keeps_values_out_of_the_script() {
    var argv = RadioLogic.artFetchArgv("/c", "7x", "https://a.ngfiles.com/$(x)")
    compare(argv.slice(3), ["--", "/c", "7", "https://a.ngfiles.com/$(x)", "5242880"])
    verify(argv[2].indexOf("ngfiles") === -1)
    verify(argv[2].indexOf(" -L") === -1)
    verify(argv[2].indexOf("--proto =https") !== -1)
    verify(argv[2].indexOf("--max-filesize \"$4\"") !== -1)
  }
  // curl writes only inside a fresh mktemp -d directory, never to a fixed
  // name in the cache dir where a symlink could be waiting.
  function test_sid_validation() {
    verify(RadioLogic.validSid("3DevBcH9vq1QjgBaAAKC"))
    verify(RadioLogic.validSid("eefabnIG-YCL9ArMAAJp"))
    verify(!RadioLogic.validSid(""))
    verify(!RadioLogic.validSid("a&b"))
    verify(!RadioLogic.validSid("a b"))
    verify(!RadioLogic.validSid("a/../b"))
    verify(!RadioLogic.validSid(42))
    var long = ""
    for (var i = 0; i < 65; i++) long += "a"
    verify(!RadioLogic.validSid(long))
    verify(RadioLogic.validSid(long.substring(1)))
  }
  function test_handshake_parse() {
    compare(RadioLogic.parseHandshake('0{"sid":"3DevBcH9vq1QjgBaAAKC","pingInterval":25000}'),
            "3DevBcH9vq1QjgBaAAKC")
    compare(RadioLogic.parseHandshake('0{"sid":"x&y=z"}'), "")
    compare(RadioLogic.parseHandshake('0{"sid":7}'), "")
    compare(RadioLogic.parseHandshake('0{bad json'), "")
    compare(RadioLogic.parseHandshake('40{"sid":"abc"}'), "")
    compare(RadioLogic.parseHandshake(""), "")
  }
  function test_handshake_rejects_oversize_packet() {
    // Valid apart from its length, so only the size cap can reject it.
    var pad = new Array(RadioLogic.maxMessageLength + 1).join("x")
    compare(RadioLogic.parseHandshake('0{"sid":"abc","pad":"' + pad + '"}'), "")
  }
  function test_payload_splits_on_record_separator() {
    compare(RadioLogic.splitPayload('40{"sid":"a"}\x1e42["status",{}]\x1e2'),
            ['40{"sid":"a"}', '42["status",{}]', "2"])
    compare(RadioLogic.splitPayload("2"), ["2"])
  }
  function test_feed_get_argv_shape_and_caps() {
    var argv = RadioLogic.feedGetArgv("abc_DEF-1")
    compare(argv[0], "curl")
    compare(argv[1], "-q")
    compare(argv[argv.indexOf("--proto") + 1], "=https")
    compare(argv[argv.indexOf("--max-filesize") + 1], String(RadioLogic.maxResponseBytes))
    compare(argv[argv.indexOf("--max-time") + 1], "45")
    verify(argv.indexOf("--connect-timeout") !== -1)
    verify(argv.indexOf("-L") === -1 && argv.indexOf("--location") === -1)
    compare(argv.slice(-2), ["--", RadioLogic.feedEndpoint + "&sid=abc_DEF-1"])
    var hs = RadioLogic.feedGetArgv("")
    compare(hs[hs.indexOf("--max-time") + 1], "10")
    compare(hs[hs.indexOf("--max-filesize") + 1], String(RadioLogic.maxResponseBytes))
    compare(hs[hs.length - 1], RadioLogic.feedEndpoint)
    compare(RadioLogic.feedGetArgv("a&b"), null)
  }
  // Long enough for a batch of full-size packets, not a lot more.
  function test_response_cap_relative_to_packet_cap() {
    verify(RadioLogic.maxResponseBytes >= RadioLogic.maxMessageLength)
    verify(RadioLogic.maxResponseBytes <= 4 * RadioLogic.maxMessageLength)
    verify(RadioLogic.feedPollMaxTime > 25)
  }
  function test_poll_delay_floors_back_to_back_polls() {
    compare(RadioLogic.pollDelay(100000, 100000), 1000)
    compare(RadioLogic.pollDelay(100400, 100000), 600)
    compare(RadioLogic.pollDelay(101000, 100000), 0)
    compare(RadioLogic.pollDelay(125000, 100000), 0)
    compare(RadioLogic.pollDelay(1000, 900000), 0)
  }
  function test_feed_post_argv_fixed_bodies_only() {
    var argv = RadioLogic.feedPostArgv("abc", "3")
    compare(argv[argv.indexOf("--data-binary") + 1], "3")
    compare(argv[argv.indexOf("-o") + 1], "/dev/null")
    compare(argv[argv.indexOf("--proto") + 1], "=https")
    compare(argv.slice(-2), ["--", RadioLogic.feedEndpoint + "&sid=abc"])
    compare(RadioLogic.feedPostArgv("abc", "40")[argv.indexOf("--data-binary") + 1], "40")
    compare(RadioLogic.feedPostArgv("abc", "@/etc/passwd"), null)
    compare(RadioLogic.feedPostArgv("", "3"), null)
    compare(RadioLogic.feedPostArgv("a b", "3"), null)
  }
  function test_poll_result_failures_are_never_parsed() {
    var over = RadioLogic.pollResult(63, '42["status",{}]')
    compare(over.ok, false)
    compare(over.oversize, true)
    compare(over.packets.length, 0)
    compare(RadioLogic.pollResult(22, "").ok, false)
    compare(RadioLogic.pollResult(28, "2").packets.length, 0)
    var ok = RadioLogic.pollResult(0, "2\x1e40")
    compare(ok.ok, true)
    compare(ok.packets, ["2", "40"])
  }
  // A clean exit with too much output (curl letting one through) is still
  // an oversize failure. Fails if pollResult's length check is removed.
  function test_poll_result_rejects_over_cap_body() {
    var big = ""
    while (big.length <= RadioLogic.maxResponseBytes) big += "xxxxxxxxxxxxxxxx"
    var r = RadioLogic.pollResult(0, big)
    compare(r.ok, false)
    compare(r.oversize, true)
    compare(r.packets.length, 0)
  }

  // ---- classifyFrame
  function test_frame_open_ping_connected_reconnect() {
    compare(RadioLogic.classifyFrame('0{"sid":"x"}').kind, "open")
    compare(RadioLogic.classifyFrame("2").kind, "ping")
    compare(RadioLogic.classifyFrame("40").kind, "connected")
    compare(RadioLogic.classifyFrame("41").kind, "reconnect")
    compare(RadioLogic.classifyFrame("44").kind, "reconnect")
    compare(RadioLogic.classifyFrame("1").kind, "reconnect")
  }
  function test_frame_status_payload_extracted() {
    var f = RadioLogic.classifyFrame('42["status",{"currently_playing":{"title":"T"}}]')
    compare(f.kind, "status")
    compare(f.packet.currently_playing.title, "T")
  }
  function test_frame_other_event_ignored() {
    compare(RadioLogic.classifyFrame('42["chat",{}]').kind, "ignore")
  }
  function test_frame_malformed_json_ignored() {
    compare(RadioLogic.classifyFrame('42[not json').kind, "ignore")
  }
  function test_frame_oversize_dropped() {
    var big = "42["
    for (var i = 0; i < 140000; i++) big += "x"
    compare(RadioLogic.classifyFrame(big).kind, "oversize")
  }

  // ---- codecs
  function test_codec_accepts_known_values_case_insensitively() {
    compare(RadioLogic.normalizeCodec("MP3"), "mp3")
    compare(RadioLogic.normalizeCodec("opus"), "opus")
  }
  function test_codec_defaults_to_opus() {
    compare(RadioLogic.normalizeCodec(undefined), "opus")
    compare(RadioLogic.normalizeCodec(null), "opus")
    compare(RadioLogic.normalizeCodec(""), "opus")
  }
  function test_codec_rejects_unknown_and_path_smuggle() {
    compare(RadioLogic.normalizeCodec("flac"), "opus")
    compare(RadioLogic.normalizeCodec("mp3/../x"), "opus")
  }
  function test_stream_url_per_codec() {
    compare(RadioLogic.streamUrl("mp3"), "https://stream.newgroundsradio.com/radio.mp3")
    compare(RadioLogic.streamUrl("opus"), "https://stream.newgroundsradio.com/radio.opus")
    compare(RadioLogic.streamUrl("aac"), "https://stream.newgroundsradio.com/radio.opus")
  }
}
