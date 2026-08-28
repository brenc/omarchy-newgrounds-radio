# AGENTS.md

An official Newgrounds plugin for the Omarchy shell (Quickshell/QML). Two
entry points declared in `manifest.json`: `Service.qml` (shared, `keepLoaded`)
and `BarWidget.qml` (one instance per monitor). User-facing behavior lives in
README.md — this file covers what the code alone won't tell you.

## Verify before you commit

```bash
./check          # qmllint + the RadioLogic test suite
```

`.githooks/pre-commit` runs it on any staged `.qml`/`.js`. To see a change in
the real shell: `omarchy restart shell` (the plugin loads from this directory
in place, so there is no install step).

Expect three qmllint categories to stay suppressed — they're inherent to the
plugin contract, not bugs to fix:

- `missing-property` — the host injects `bar` as an untyped `QObject`.
- `unqualified` — `Repeater` delegates read `modelData` and outer ids.
- `signal-handler-parameters` — `Process.onExited` declares a
  `QProcess::ExitStatus` parameter that Quickshell registers nowhere as a
  QML-visible type, so no import resolves it. Don't try to "fix" the handler.

## What can and can't be tested

Quickshell's QML modules are compiled into the `quickshell` binary as `qrc:`
resources — the on-disk `/usr/lib/qt6/qml/Quickshell/` tree is `qmldir` plus
`.qmltypes` metadata only, with no plugin `.so`. qmllint reads that metadata
statically and works fine, but **no external Qt tool can instantiate anything
that imports Quickshell**; `qmltestrunner` fails with `plugin
"quickshell-coreplugin" not found`. Only the shell itself can load
`Service.qml` or `BarWidget.qml`.

So the pure feed-handling logic lives in `RadioLogic.js`, which imports
nothing, and `tests/tst_radiologic.qml` exercises it directly. This matches
the host shell's own convention (`plugins/notifications/NotificationLogic.js`
and ~20 other `*Model.js` files).

Keep logic testable by keeping it pure: pass the clock in as an argument and
thread mutable bookkeeping through a caller-owned state object, the way
`safeUrlLogged` takes `(url, st, now, warn)`. That is what makes the rate
floors assertable instead of wall-clock dependent.

Untested by construction: everything touching `bar`/`Style`, the reconnect and
restart timers, `applyStatusData`'s property writes, and all rendering.

When adding a bound, check the test actually detects its removal. A cap whose
only effect is on work done — `maxPlayLogScan` — is invisible to output
assertions unless the fixture puts valid entries past the bound, which is what
`test_playlog_scan_bound_stops_the_walk` does.

## Host contract

- `bar.shell.serviceFor("brenc.newgrounds-radio")` reaches the service; it can
  be null, so every access is guarded and `visible` is bound to `radio !== null`.
- Per-widget config comes from `setting(key, default)`, backed by that
  widget's entry in `~/.config/omarchy/shell.json`, and is pushed to the
  shared service in `syncSettings()`.
- `Style`, `Color`, `Util`, `PopupCard`, `PanelSeparator` come from
  `qs.Ui` / `qs.Commons` (`/usr/share/omarchy/shell`). Size with
  `Style.space()` rather than raw pixels.

## Treat the feed as untrusted

The status feed is network input rendered by a long-lived shell process, and
the hardening in `Service.qml` is deliberate. When touching anything that
reads a feed field, keep these invariants:

- Every string goes through `sanitizeText()` (control + bidi/zero-width
  strips, length cap) before it is stored or rendered.
- Every URL goes through `safeUrl()` — https only, on an allow-listed
  Newgrounds host — before it reaches an `Image.source` or `xdg-open`.
  Never hand a feed URL to either directly.
- Play-log records are rebuilt field by field in `sanitizePlayLog()`. Don't
  store raw server objects; don't drop the scan bound.
- Notification summaries use `stripMarkup()`, bodies use `escapeMarkup()`
  (only the body is markup-parsed). The shared tooltip needs `plain()` in
  `BarWidget.qml` because it renders with `AutoText`.
- Subprocesses are argv arrays (`Quickshell.execDetached`, `Util.execArgv`),
  never a shell string.
- Rate floors on notifications and rejection logging exist because the feed
  sets the message rate. Each also tests `now < last` so a backwards clock
  correction can't wedge the gate shut.

Album art is fetched only while the popup is open — otherwise the feed would
choose when every monitor's bar makes a request.

## Playback

`wantPlaying` is intent, `playing` is intent AND process alive. The bar pill
reads `wantPlaying` so a click during the restart backoff still means "stop".
Restarts are capped at 5, and a 30s stretch of stable playback resets the
budget. mpv runs with `--load-scripts=no` to keep it off MPRIS — otherwise an
external pause desyncs the pill, which can't observe it.
