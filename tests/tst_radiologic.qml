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
      listeners: "42", audio_id: "7", skip_votes: "bogus"
    }, freshState(), 0, null)
    compare(v.title, "T x")
    compare(v.bigArtUrl, "https://uploads.ngfiles.com/a.png")
    compare(v.listeners, 42)
    compare(v.audioId, 7)
    compare(v.skipVotes, 0)
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

  // ---- classifyFrame
  function test_frame_open_ping_connected_reconnect() {
    compare(RadioLogic.classifyFrame('0{"sid":"x"}').kind, "open")
    compare(RadioLogic.classifyFrame("2").kind, "ping")
    compare(RadioLogic.classifyFrame("40").kind, "connected")
    compare(RadioLogic.classifyFrame("41").kind, "reconnect")
    compare(RadioLogic.classifyFrame("44").kind, "reconnect")
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
}
