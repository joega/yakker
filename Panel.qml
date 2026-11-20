import QtQuick
import QtQuick.Controls as QQC
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
  property bool settingsOpen: false
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
  function advanceCursor(direction) {
    let order = [4]
    if (settingsOpen) order.push(5)
    order = order.concat([0,1])
    if (radio.dvr) order = order.concat([6,7,8,9])
    order = order.concat([2,3])
    const index = Math.max(0, order.indexOf(cursor))
    cursor = order[(index + direction + order.length) % order.length]
    Qt.callLater(ensureCursorVisible)
  }
  function ensureCursorVisible() {
    const targets = [stationPicker, playButton, volumeSlider, muteButton, settingsButton,
                     bufferPicker, pauseButton, backButton, forwardButton, liveButton]
    const item = targets[cursor]
    if (!item) return
    const top = item.mapToItem(panelContent, 0, 0).y
    if (top < scroller.contentY) scroller.contentY = top
    else if (top + item.height > scroller.contentY + scroller.height)
      scroller.contentY = Math.min(Math.max(0, scroller.contentHeight - scroller.height), top + item.height - scroller.height)
  }
  function activate() {
    if (cursor === 0) stationPicker.toggle()
    else if (cursor === 1) radio.togglePlayback()
    else if (cursor === 3) radio.toggleMute()
    else if (cursor === 4) settingsOpen = !settingsOpen
    else if (cursor === 5 && settingsOpen) bufferPicker.toggle()
    else if (cursor === 6 && radio.dvr) radio.togglePause()
    else if (cursor === 7) radio.skip(-30)
    else if (cursor === 8) radio.skip(30)
    else if (cursor === 9 && radio.dvr) radio.goLive()
  }
  onOpenedChanged: if (!opened) { stationPicker.close(); bufferPicker.close() }
  Connections {
    target: root.radio
    function onStationIdChanged() { stationPicker.value = root.radio.stationId }
    function onBufferMinutesChanged() { bufferPicker.value = String(root.radio.bufferMinutes) }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: (stationPicker.popupOpen || bufferPicker.popupOpen) ? null : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelContent.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: stationPicker.popupOpen || bufferPicker.popupOpen
      onCloseRequested: root.close()
      onTabRequested: direction => root.advanceCursor(direction)
      onMoveRequested: (dx, dy) => {
        if (dy) root.advanceCursor(dy)
        if (dx) {
          root.cursor = 2
          root.radio.commitVolume(root.radio.volume + dx * 5)
        }
      }
      onActivateRequested: root.activate()
      onTextKey: text => {
        if (text.toLowerCase() === "p") root.radio.togglePause()
        if (text === "[") root.radio.skip(-30)
        if (text === "]") root.radio.skip(30)
        if (text.toLowerCase() === "g") root.radio.goLive()
        if (text.toLowerCase() === "m") root.radio.toggleMute()
        if (text.toLowerCase() === "r" && !root.radio.wanted) root.radio.play()
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelContent.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
      Column {
        id: panelContent
        width: parent.width
        spacing: Style.space(14)

        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: parent.width - settingsButton.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "YAKKER · " + root.radio.stations.length + " STATIONS"
            textFormat: Text.PlainText
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Ui.Button {
            id: settingsButton
            iconText: "󰒓"
            tooltipText: root.settingsOpen ? "Close settings" : "Open settings"
            Accessible.role: Accessible.Button
            Accessible.name: settingsButton.tooltipText
            foreground: root.barForeground
            bordered: true
            selected: root.settingsOpen
            hasCursor: root.cursor === 4
            onHovered: hovered => { if (hovered) root.cursor = 4 }
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.settingsOpen
          Ui.Dropdown {
            id: bufferPicker
            width: parent.width
            label: "Listening buffer"
            options: [{value:"0",label:"Live only"}, {value:"5",label:"5 minutes"}, {value:"15",label:"15 minutes"}, {value:"30",label:"30 minutes"}]
            value: String(root.radio.bufferMinutes)
            foreground: root.barForeground
            hasCursor: root.cursor === 5
            onHovered: hovered => { if (hovered) root.cursor = 5 }
            onChanged: value => { root.radio.setBufferMinutes(Number(value)); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
          }
          Text {
            width: parent.width
            text: "Enable a buffer to pause and rewind. Audio stays in memory; no files are recorded. Changing this setting clears history and returns to live."
            textFormat: Text.PlainText
            color: root.barForeground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Ui.PanelSeparator { width: parent.width }
        }
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
          visible: text.length > 0 && root.radio.playbackState === "playing" && (!root.radio.dvr || root.radio.behindLive <= 3)
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
          id: playButton
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
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.radio.bufferMinutes > 0
          Ui.Button {
            id: pauseButton
            width: parent.width
            text: root.radio.paused ? "Resume" : "Pause"
            iconText: root.radio.paused ? "󰐊" : "󰏤"
            foreground: root.barForeground
            bordered: true
            enabled: root.radio.wanted && root.radio.dvr
            hasCursor: root.cursor === 6
            onHovered: hovered => { if (hovered) root.cursor = 6 }
            onClicked: root.radio.togglePause()
          }
          Text {
            width: parent.width
            text: root.radio.bufferText
            textFormat: Text.PlainText
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Ui.PanelSlider {
            id: timelineSlider
            width: parent.width
            step: 30
            bar: root.bar
            minimum: root.radio.bufferStart
            maximum: Math.max(minimum + 1, root.radio.bufferEnd)
            value: root.radio.position
            enabled: root.radio.dvr
            fillColor: Color.accent
            knobColor: root.barForeground
            trackColor: Style.selectedFillFor(root.barForeground, Color.accent)
            onReleased: value => root.radio.seek(value)
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            Ui.Button {
              id: backButton
              width: (parent.width - parent.spacing * 2) / 3
              text: "−30s"
              foreground: root.barForeground
              bordered: true
              enabled: root.radio.dvr
              hasCursor: root.cursor === 7
              onHovered: hovered => { if (hovered) root.cursor = 7 }
              onClicked: root.radio.skip(-30)
            }
            Ui.Button {
              id: forwardButton
              width: (parent.width - parent.spacing * 2) / 3
              text: "+30s"
              foreground: root.barForeground
              bordered: true
              enabled: root.radio.dvr
              hasCursor: root.cursor === 8
              onHovered: hovered => { if (hovered) root.cursor = 8 }
              onClicked: root.radio.skip(30)
            }
            Ui.Button {
              id: liveButton
              width: (parent.width - parent.spacing * 2) / 3
              text: "Go live"
              foreground: root.barForeground
              bordered: true
              enabled: root.radio.dvr
              hasCursor: root.cursor === 9
              onHovered: hovered => { if (hovered) root.cursor = 9 }
              onClicked: root.radio.goLive()
            }
          }
          Text {
            width: parent.width
            visible: root.radio.bufferExpired
            text: "Older audio expired. Playback moved to the available buffer."
            textFormat: Text.PlainText
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
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
          id: muteButton
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
          text: "Tab  Controls    ← →  Volume    P  Pause    [ ]  Seek    G  Live"
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
}
