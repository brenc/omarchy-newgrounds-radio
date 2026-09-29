import QtQuick
import QtQuick.Effects
import Quickshell.Widgets
import qs.Ui
import qs.Commons
import "RadioLogic.js" as RadioLogic

BarWidget {
  id: root
  moduleName: "brenc.newgrounds-radio"

  readonly property var radio: bar && bar.shell ? bar.shell.serviceFor("brenc.newgrounds-radio") : null
  // wantPlaying, not playing: during the stream-drop restart backoff the
  // stream is conceptually on, and a left-click should still mean "stop".
  readonly property bool playing: radio ? radio.wantPlaying : false
  readonly property string title: radio ? radio.title : ""
  readonly property string artist: radio ? radio.artist : ""

  readonly property color ngOrange: "#FFA300"
  property bool popupOpen: false

  function close() { popupOpen = false }

  // Play log entry 0 mirrors the current track; the rest are history.
  readonly property var recentTracks: radio && Array.isArray(radio.playLog)
    ? radio.playLog.slice(1, 6) : []

  // URLs and artist names are network data: exec as argv, never a shell
  // string, and only ever hand xdg-open an https URL the service vetted.
  function openUrl(u) {
    if (/^https:\/\//i.test(String(u))) Util.execArgv(["xdg-open", String(u)])
  }

  // The shared tooltip renders with QML's default AutoText detection, which
  // would treat a crafted track title as markup; drop the "<" that is the
  // only way to open one. Deleting rather than escaping: with no tag left
  // the text can't be detected as rich, so an entity would show up
  // literally as "&amp;". ">" is kept - it can't start a tag, and titles
  // like "Level 1 -> 2" should read correctly.
  function plain(s) { return String(s).replace(/</g, "") }

  // Only artist strings that look like a single Newgrounds username get a
  // link; jingles ("Newgrounds Radio! ...") and multi-credit strings would
  // build a bogus hostname.
  readonly property bool artistLinkable: /^[A-Za-z0-9_-]+$/.test(artist)
  readonly property string artistUrl: artistLinkable
    ? "https://" + artist.toLowerCase() + ".newgrounds.com" : ""

  // Per-widget shell.json settings flow to the shared service.
  onRadioChanged: syncSettings()
  onSettingsChanged: syncSettings()
  function syncSettings() {
    if (!radio) return
    radio.notifyOnTrackChange = setting("trackNotifications", true) !== false
    radio.applyCodecSetting(setting("codec", ""))
  }

  function logTime(iso) {
    var d = new Date(String(iso || ""))
    return isNaN(d.getTime()) ? "" : Qt.formatTime(d, "HH:mm")
  }

  // Ticks while the popup is open so the on-air elapsed readout advances.
  property double nowSeconds: 0

  readonly property int trackLength: radio ? radio.lengthSeconds : 0

  // Seconds since the track went on air, held at the track length so a late
  // status update can't run the readout past the end. -1 when unknown.
  readonly property int elapsedSeconds: {
    if (!radio || !radio.onAirAt || !nowSeconds) return -1
    var s = Math.max(0, Math.floor(nowSeconds - radio.onAirAt))
    return trackLength > 0 ? Math.min(s, trackLength) : s
  }

  function elapsedText() {
    if (elapsedSeconds < 0) return "—"
    return RadioLogic.clockText(elapsedSeconds)
      + (trackLength > 0 ? " / " + RadioLogic.clockText(trackLength) : "")
  }

  Timer {
    interval: 1000
    running: root.popupOpen
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowSeconds = Date.now() / 1000
  }

  visible: radio !== null
  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(5)

    Text {
      id: ngMark
      visible: !root.vertical
      anchors.verticalCenter: parent.verticalCenter
      text: "NG"
      color: root.ngOrange
      opacity: root.playing ? 1.0 : 0.6
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      font.letterSpacing: 0.5
      Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      text: root.playing ? "󰏤" : "󰐊"
      color: root.playing ? root.ngOrange : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    onClicked: function(mouse) {
      if (!root.radio) return
      if (mouse.button === Qt.LeftButton) root.radio.toggle()
      else root.popupOpen = !root.popupOpen
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.title
      ? root.plain("Newgrounds Radio — " + root.title + (root.artist ? " · " + root.artist : ""))
      : "Newgrounds Radio")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    // Ambient backdrop, after newgroundsradio.com's .ngr-deck-ambient-art.
    // PopupCard exposes no background property, so this reaches out over
    // the card's padding and rounds to the inner edge of its border.
    ClippingRectangle {
      anchors.fill: parent
      anchors.margins: -popup.padding
      radius: Math.max(0, Style.cornerRadius - Border.left(popup.borderSpec))
      color: "transparent"

      Image {
        id: ambientArt
        // Overscanned so the blur's soft edge falls outside the clip.
        anchors.centerIn: parent
        width: parent.width * 1.4
        height: parent.height * 1.4
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Same URL and sourceSize as artImage, so the pixmap cache shares
        // one fetch and decode, and the popup-only fetch gate still holds.
        source: artImage.source
        sourceSize.width: artImage.sourceSize.width
        sourceSize.height: artImage.sourceSize.height
        opacity: status === Image.Ready ? 0.38 : 0
        visible: opacity > 0

        Behavior on opacity {
          NumberAnimation { duration: 900; easing.type: Easing.OutCubic }
        }

        layer.enabled: visible
        layer.effect: MultiEffect {
          autoPaddingEnabled: false
          blurEnabled: true
          blur: 1.0
          blurMax: 64
          saturation: 0.6
          // Pulls bright covers down so secondary text keeps its contrast;
          // dark covers barely change.
          brightness: -0.25
        }
      }
    }

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      Row {
        spacing: Style.space(12)
        width: parent.width

        ClippingRectangle {
          width: Style.space(88)
          height: Style.space(88)
          anchors.verticalCenter: parent.verticalCenter
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)

          Image {
            id: artImage
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            // sourceSize keeps the decode proportional to the 88px slot (Qt
            // only ever downscales, and preserves the aspect ratio). It is not
            // a hard memory bound — PNG decodes at full size before scaling —
            // so the real limit is that the source is only ever an https URL
            // on a Newgrounds host, vetted by the service.
            sourceSize.width: Style.space(176)
            sourceSize.height: Style.space(176)
            // Bound to the popup: otherwise every status update fetches art on
            // every monitor's bar with the UI closed, which lets the feed pick
            // both when the shell makes a request and what path it asks for.
            source: root.popupOpen && root.radio && root.radio.bigArtUrl
              ? root.radio.bigArtUrl : ""
            opacity: status === Image.Ready ? 1 : 0
            visible: opacity > 0

            Behavior on opacity {
              NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
          }

          Text {
            anchors.centerIn: parent
            // Covers no-service, no-art, error, and - now that the fetch
            // starts when the popup opens - the load window too.
            visible: artImage.status !== Image.Ready
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.45)
            opacity: artArea.containsMouse ? 1 : 0
            visible: opacity > 0

            Behavior on opacity { NumberAnimation { duration: 120 } }

            Text {
              anchors.centerIn: parent
              text: "󰏌"
              color: "white"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          MouseArea {
            id: artArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openUrl(root.radio ? root.radio.listenUrl : "")
          }
        }

        Column {
          spacing: Style.space(4)
          width: parent.width - Style.space(100)
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: stationLink
            text: "NEWGROUNDS RADIO"
            color: root.ngOrange
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 2
            font.bold: true
            font.underline: stationHover.hovered

            HoverHandler {
              id: stationHover
              cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
              onTapped: root.openUrl("https://www.newgroundsradio.com")
            }
          }

          Text {
            text: root.title || "Tuning in…"
            textFormat: Text.PlainText
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            width: parent.width
            font.underline: root.title !== "" && titleHover.hovered

            HoverHandler {
              id: titleHover
              enabled: root.title !== ""
              cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
              enabled: root.title !== ""
              onTapped: root.openUrl(root.radio ? root.radio.listenUrl : "")
            }
          }

          Text {
            text: root.artist
            textFormat: Text.PlainText
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
            font.underline: root.artistLinkable && artistHover.hovered

            HoverHandler {
              id: artistHover
              enabled: root.artistLinkable
              cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
              enabled: root.artistLinkable
              onTapped: root.openUrl(root.artistUrl)
            }
          }

          Text {
            text: root.radio ? root.radio.genre : ""
            textFormat: Text.PlainText
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      Rectangle {
        visible: root.trackLength > 0 && root.elapsedSeconds >= 0
        width: parent.width
        height: Math.max(2, Style.space(3))
        radius: height / 2
        color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.15)

        Rectangle {
          width: parent.width * (root.trackLength > 0
            ? Math.max(0, root.elapsedSeconds) / root.trackLength : 0)
          height: parent.height
          radius: parent.radius
          color: root.ngOrange
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(32)

        Column {
          spacing: Style.space(4)
          Text {
            text: "LISTENERS"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            anchors.horizontalCenter: parent.horizontalCenter
          }
          Text {
            text: root.radio ? String(root.radio.listeners) : "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            anchors.horizontalCenter: parent.horizontalCenter
          }
        }

        Column {
          spacing: Style.space(4)
          Text {
            text: "ON AIR"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            anchors.horizontalCenter: parent.horizontalCenter
          }
          Text {
            text: root.elapsedText()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            anchors.horizontalCenter: parent.horizontalCenter
          }
        }

        Column {
          spacing: Style.space(4)
          Text {
            text: "SKIP VOTES"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            anchors.horizontalCenter: parent.horizontalCenter
          }
          Text {
            text: root.radio && root.radio.skipThreshold > 0
              ? root.radio.skipVotes + " / " + root.radio.skipThreshold
              : (root.radio ? String(root.radio.skipVotes) : "—")
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            anchors.horizontalCenter: parent.horizontalCenter
          }
        }

      }

      PanelSeparator {
        visible: root.recentTracks.length > 0
        foreground: root.bar.foreground
      }

      Column {
        visible: root.recentTracks.length > 0
        width: parent.width
        spacing: Style.space(4)

        Text {
          text: "RECENTLY PLAYED"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }

        Repeater {
          model: root.recentTracks

          Rectangle {
            required property var modelData
            readonly property string entryUrl: String(modelData.listen_url || "")

            width: parent.width
            height: logRow.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: entryUrl !== "" && logRowArea.containsMouse
              ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Row {
              id: logRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: root.logTime(modelData.on_air_at)
                textFormat: Text.PlainText
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                width: parent.width - Style.space(48)
                text: String(modelData.title || "")
                  + (modelData.artist ? "  ·  " + modelData.artist : "")
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: logRowArea
              anchors.fill: parent
              hoverEnabled: true
              enabled: entryUrl !== ""
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.openUrl(entryUrl)
            }
          }
        }
      }

      // Two named choices, not on/off: the knob points at the active codec,
      // and either label switches to it.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)

        Text {
          readonly property bool active: root.radio && root.radio.codec === "mp3"
          text: "MP3"
          color: active || mp3Hover.hovered ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: active
          font.letterSpacing: 1
          anchors.verticalCenter: parent.verticalCenter

          HoverHandler { id: mp3Hover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: if (root.radio) root.radio.setCodec("mp3") }
        }

        ToggleSwitch {
          checked: root.radio ? root.radio.codec === "opus" : false
          foreground: root.bar.foreground
          accent: root.ngOrange
          anchors.verticalCenter: parent.verticalCenter
          onToggled: if (root.radio) root.radio.setCodec(checked ? "mp3" : "opus")
        }

        Text {
          readonly property bool active: root.radio && root.radio.codec === "opus"
          text: "OPUS"
          color: active || opusHover.hovered ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: active
          font.letterSpacing: 1
          anchors.verticalCenter: parent.verticalCenter

          HoverHandler { id: opusHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: if (root.radio) root.radio.setCodec("opus") }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)

        Button {
          iconText: root.playing ? "󰓛" : "󰐊"
          text: root.playing ? "Stop" : "Play"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: if (root.radio) root.radio.toggle()
        }

        Button {
          iconText: "󰏌"
          text: "Open on NG"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.openUrl(root.radio ? root.radio.listenUrl : "")
        }
      }
    }
  }
}
