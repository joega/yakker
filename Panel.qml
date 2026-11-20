import QtQuick
import qs.Commons
import qs.Ui as Ui
import "." as Radio

Ui.Panel {
  id: root
  moduleName: "io.github.joega.yakker"
  manageIpc: false
  property var anchorItem: null
  property var hostWidget: null
  property int cursor: 1
  readonly property var radio: Radio.RadioService

  function chooseStation() {
    root.open()
    Qt.callLater(function() { root.cursor = 0; stationPicker.open() })
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }
  function activate() {
    if (cursor === 0) stationPicker.toggle()
    else if (cursor === 1) radio.togglePlayback()
    else if (cursor === 3) radio.toggleMute()
  }
  onOpenedChanged: if (!opened) stationPicker.close()
  Connections {
    target: root.radio
    function onStationIdChanged() { stationPicker.value = root.radio.stationId }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: stationPicker.popupOpen ? null : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelContent.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: stationPicker.popupOpen
      onCloseRequested: root.close()
      onTabRequested: direction => { root.cursor = (root.cursor + direction + 4) % 4 }
      onMoveRequested: (dx, dy) => {
        if (dy) root.cursor = (root.cursor + dy + 4) % 4
        if (dx) {
          root.cursor = 2
          root.radio.commitVolume(root.radio.volume + dx * 5)
        }
      }
      onActivateRequested: root.activate()
      onTextKey: text => {
        if (text.toLowerCase() === "m") root.radio.toggleMute()
        if (text.toLowerCase() === "r" && !root.radio.wanted) root.radio.play()
      }

      Column {
        id: panelContent
        width: parent.width
        spacing: Style.space(14)

        Ui.PanelSectionHeader { text: "YAKKER · " + root.radio.stations.length + (root.radio.stations.length === 1 ? " STATION" : " STATIONS"); foreground: root.barForeground }
        Row {
          width: parent.width
          spacing: Style.space(14)
          Radio.StationLogo {
            width: Style.space(56)
            height: Style.space(48)
            station: root.radio.station
            fallbackColor: Color.accent
            anchors.verticalCenter: parent.verticalCenter
          }
          Column {
            width: parent.width - Style.space(70)
            spacing: Style.space(4)
            Ui.SearchableDropdown {
              id: stationPicker
              width: parent.width
              showLabel: false
              placeholderText: "Station, city or country"
              emptyText: "No matching stations"
              value: root.radio.stationId
              options: root.radio.stationOptions
              foreground: root.barForeground
              hasCursor: root.cursor === 0
              onHovered: hovered => { if (hovered) root.cursor = 0 }
              onChanged: value => {
                root.radio.selectStation(value)
                Qt.callLater(function() { keyCatcher.forceActiveFocus() })
              }
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.radio.station.subtitle
              color: root.barForeground
              opacity: 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }
        }
        Ui.PanelSeparator { width: parent.width }
        Row {
          width: parent.width
          spacing: Style.space(8)
          Rectangle {
            width: Style.space(6)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.radio.playbackState === "error" ? Color.urgent
              : root.radio.playbackState === "playing" ? Color.accent : root.barForeground
            opacity: root.radio.playbackState === "stopped" ? 0.4 : 1
          }
          Text {
            width: parent.width - Style.space(14)
            text: root.radio.statusText
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }
        Text {
          width: parent.width
          visible: text.length > 0
          textFormat: Text.PlainText
          text: root.radio.error
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
        Text {
          width: parent.width
          visible: text.length > 0 && root.radio.playbackState === "playing"
          textFormat: Text.PlainText
          text: root.radio.title
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
        Ui.Button {
          width: parent.width
          text: root.radio.wanted ? "Stop" : root.radio.playbackState === "error" ? "Retry" : "Play live"
          iconText: root.radio.wanted ? "󰓛" : "󰐊"
          foreground: root.barForeground
          selected: true
          bordered: true
          hasCursor: root.cursor === 1
          onHovered: hovered => { if (hovered) root.cursor = 1 }
          onClicked: root.radio.togglePlayback()
        }
        Row {
          width: parent.width
          Text {
            width: parent.width / 2
            text: root.radio.muted ? "Volume · muted" : "Volume"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width / 2
            horizontalAlignment: Text.AlignRight
            text: Math.round(volumeSlider.dragging ? volumeSlider.liveValue : root.radio.volume) + "%"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
        Ui.BorderSurface {
          width: parent.width
          implicitHeight: volumeSlider.implicitHeight + Style.space(8)
          color: "transparent"
          radius: Style.cornerRadius
          borderSpec: root.cursor === 2 ? Border.controlSpec("focus", root.barForeground, Color.accent) : Border.none()
          Ui.PanelSlider {
            id: volumeSlider
            anchors.fill: parent
            anchors.margins: Style.space(4)
            bar: root.bar
            value: root.radio.volume
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            fillColor: Color.accent
            knobColor: root.barForeground
            trackColor: Style.selectedFillFor(root.barForeground, Color.accent)
            onMoved: value => { root.cursor = 2; root.radio.setVolume(value) }
            onReleased: value => root.radio.commitVolume(value)
            onRightClicked: root.radio.toggleMute()
          }
        }
        Ui.Button {
          width: parent.width
          text: root.radio.muted ? "Unmute" : "Mute"
          iconText: root.radio.muted ? "󰝟" : "󰕾"
          foreground: root.barForeground
          bordered: true
          hasCursor: root.cursor === 3
          onHovered: hovered => { if (hovered) root.cursor = 3 }
          onClicked: root.radio.toggleMute()
        }
        Text {
          width: parent.width
          text: "Tab  Select control    ← →  Volume    M  Mute"
          color: root.barForeground
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
