import QtQuick
import Quickshell.Widgets
import qs.Ui
import qs.Commons

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

  // URLs and artist names are network data: exec as argv, never a shell string.
  function openUrl(u) {
    if (u) Util.execArgv(["xdg-open", String(u)])
  }

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
    if (radio) radio.notifyOnTrackChange = setting("trackNotifications", true) !== false
  }

  function logTime(iso) {
    var d = new Date(String(iso || ""))
    return isNaN(d.getTime()) ? "" : Qt.formatTime(d, "HH:mm")
  }

  // Ticks while the popup is open so the on-air elapsed readout advances.
  property double nowSeconds: 0

  function elapsedText() {
    if (!radio || !radio.onAirAt || !nowSeconds) return "—"
    var s = Math.max(0, Math.floor(nowSeconds - radio.onAirAt))
    var m = Math.floor(s / 60)
    var h = Math.floor(m / 60)
    var pad = function(n) { return (n < 10 ? "0" : "") + n }
    return h > 0 ? h + ":" + pad(m % 60) + ":" + pad(s % 60) : m + ":" + pad(s % 60)
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
    onEntered: if (root.bar) root.bar.showTooltip(root,
      root.title ? "Newgrounds Radio — " + root.title + (root.artist ? " · " + root.artist : "") : "Newgrounds Radio")
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
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)

          Image {
            id: artImage
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.radio && root.radio.bigArtUrl ? root.radio.bigArtUrl : ""
            visible: status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: !root.radio || !root.radio.bigArtUrl || artImage.status === Image.Error
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          MouseArea {
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
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
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
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
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
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                width: parent.width - Style.space(48)
                text: String(modelData.title || "")
                  + (modelData.artist ? "  ·  " + modelData.artist : "")
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
