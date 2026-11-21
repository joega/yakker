import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "." as Radio

Ui.BarWidget {
  id: root
  moduleName: "io.github.joega.yakker"
  property bool attached: false
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: Style.bar.iconSlot
  readonly property real openPanelIndicatorHeight: Style.bar.iconSlot

  readonly property var radio: Radio.RadioService
  readonly property bool recordingActive: Number(radio.recordings.activeCount) > 0
  readonly property string playbackLabel: radio.playbackState === "error" ? "Offline"
    : radio.playbackState === "retrying" ? "Reconnecting"
    : radio.playbackState === "connecting" ? "Connecting"
    : radio.playbackPaused ? (radio.playbackKind === "live" ? "Paused · buffering" : "Paused")
    : radio.wanted && radio.playbackState === "playing" ? (radio.playbackKind === "recording" ? "Playing"
      : radio.dvr && radio.behindLive > 3 ? "Behind live" : "Live") : "Stopped"
  readonly property string playbackIcon: radio.playbackState === "error" ? "warning"
    : radio.playbackState === "connecting" || radio.playbackState === "retrying" ? "radio"
    : radio.playbackPaused ? "pause"
    : radio.wanted && radio.playbackState === "playing" ? (radio.playbackKind === "live" && radio.dvr && radio.behindLive > 3 ? "back" : "play") : "stop"
  readonly property color playbackColor: radio.playbackState === "error" ? Commons.Color.urgent
    : radio.wanted && (radio.playbackState === "playing" || radio.playbackPaused && radio.playbackKind === "live") ? Commons.Color.accent
    : root.bar ? root.bar.barForeground : Commons.Color.foreground

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function chooseStation() {
    if (panelLoader.item) panelLoader.item.chooseStation()
  }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }
  function savePreferences(volume, muted, stationId, bufferMinutes) {
    if (!root.bar || !root.bar.shell) return
    const entry = {id: root.moduleName}
    for (let key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    const favorites = Radio.RadioService.favoriteIds
    const notifications = Radio.RadioService.recordingNotifications
    const startNotifications = Radio.RadioService.recordingStartNotifications
    if (entry.volume === volume && entry.muted === muted && entry.stationId === stationId && entry.bufferMinutes === bufferMinutes && JSON.stringify(entry.favorites || []) === JSON.stringify(favorites) && entry.recordingNotifications === notifications && entry.recordingStartNotifications === startNotifications) return
    entry.volume = volume
    entry.muted = muted
    entry.stationId = stationId
    entry.bufferMinutes = bufferMinutes
    entry.favorites = favorites.slice()
    entry.recordingNotifications = notifications
    entry.recordingStartNotifications = startNotifications
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: { if (attached) Radio.RadioService.configureSettings(root.settings) }
  Component.onCompleted: Qt.callLater(function() {
    root.attached = true
    Radio.RadioService.acquire(root.settings)
  })
  Component.onDestruction: { if (attached) Radio.RadioService.release() }

  Connections {
    target: Radio.RadioService
    function onPreferencesChanged(volume, muted, stationId, bufferMinutes) { root.savePreferences(volume, muted, stationId, bufferMinutes) }
    function onFavoritesUpdated() { root.savePreferences(Radio.RadioService.volume, Radio.RadioService.muted, Radio.RadioService.stationId, Radio.RadioService.bufferMinutes) }
  }
  Loader {
    id: panelLoader
    active: true
    visible: false
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }
  IpcHandler {
    target: root.moduleName
    function play(): void { Radio.RadioService.play() }
    function stop(): void { Radio.RadioService.stop() }
    function pause(): void { if (!Radio.RadioService.paused) Radio.RadioService.togglePause() }
    function resume(): void { Radio.RadioService.play() }
    function skip(seconds: int): void { Radio.RadioService.skip(seconds) }
    function goLive(): void { Radio.RadioService.goLive() }
    function setBufferMinutes(minutes: int): void { Radio.RadioService.setBufferMinutes(minutes) }
    function setVolume(value: int): void { Radio.RadioService.commitVolume(value) }
    function toggleMute(): void { Radio.RadioService.toggleMute() }
    function setStation(stationId: string): void { Radio.RadioService.selectStation(stationId) }
    function chooseStation(): void { root.chooseStation() }
    function status(): string {
      return JSON.stringify({state: Radio.RadioService.playbackState, wanted: Radio.RadioService.wanted,
        volume: Radio.RadioService.volume, muted: Radio.RadioService.muted,
        error: Radio.RadioService.error, playerPid: Radio.RadioService.playerPid,
        title: Radio.RadioService.title, stationId: Radio.RadioService.stationId,
        station: Radio.RadioService.station, stations: Radio.RadioService.stations,
        paused: Radio.RadioService.paused, bufferMinutes: Radio.RadioService.bufferMinutes,
        temporaryBuffer: Radio.RadioService.temporaryBuffer, dvr: Radio.RadioService.dvr,
        position: Radio.RadioService.position, bufferStart: Radio.RadioService.bufferStart, bufferEnd: Radio.RadioService.bufferEnd,
        playbackKind: Radio.RadioService.playbackKind, recordingId: Radio.RadioService.recordingId,
        recordingTitle: Radio.RadioService.recordingTitle, duration: Radio.RadioService.duration,
        activeRecordings: Number(Radio.RadioService.recordings.activeCount) || 0,
        recordingError: Radio.RadioService.recordings.error || "",
        ready: Radio.RadioService.ready, opened: root.opened})
    }
  }
  Ui.WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : branding.implicitWidth + button.scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    fontSize: Style.font.icon
    foreground: root.playbackColor
    Accessible.role: Accessible.Button
    Accessible.name: "Yakker · " + (root.radio.playbackKind === "recording" ? root.radio.recordingTitle : root.radio.station.name) + " · " + root.radio.statusText
    Accessible.description: root.radio.playbackDetail + (root.recordingActive ? " · Recording " + root.radio.recordings.activeCount + " stream(s)" : "")
    tooltipText: (root.radio.playbackKind === "recording" ? root.radio.recordingTitle : root.radio.station.name) + " · " + root.radio.statusText
      + (root.radio.playbackDetail ? "\n" + root.radio.playbackDetail : "")
      + (root.recordingActive ? "\nRecording " + root.radio.recordings.activeCount + " stream(s)" : "")
      + "\nClick for controls · Right-click for stations"
    onPressed: buttonCode => {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) root.chooseStation()
    }

    Row {
      id: branding
      anchors.centerIn: parent
      spacing: Style.space(6)
      Item {
        width: Style.space(24)
        height: Math.max(Style.space(12), Math.min(Style.space(22), button.height - Style.space(4)))
        anchors.verticalCenter: parent.verticalCenter
        Radio.StationLogo {
          id: stationLogo
          anchors.fill: parent
          // A paused stream still owns its station and keeps receiving audio.
          station: root.radio.wanted && (root.radio.playbackState === "playing" || root.radio.playbackPaused)
            ? root.radio.playbackStation : ({})
          fallbackColor: button.foreground
        }
        Rectangle {
          visible: root.vertical
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          width: Style.space(13); height: width
          radius: Style.space(3)
          color: root.bar ? root.bar.background : Commons.Color.background
          Radio.FocusIcon { anchors.fill: parent; anchors.margins: Style.space(1); name: root.playbackIcon; foreground: root.playbackColor }
        }
        Rectangle {
          visible: root.vertical && root.recordingActive
          anchors.top: parent.top; anchors.right: parent.right
          width: Style.space(5); height: width; radius: width / 2
          color: Commons.Color.urgent
        }
      }
      Text {
        visible: !root.vertical && root.setting("showName", false)
        text: "Yakker"
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
      Row {
        visible: !root.vertical
        spacing: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        Radio.FocusIcon {
          id: stateIcon
          width: Style.space(12); height: width
          anchors.verticalCenter: parent.verticalCenter
          name: root.playbackIcon
          foreground: root.playbackColor
        }
        Text {
          id: playbackStateLabel
          text: root.playbackLabel
          textFormat: Text.PlainText
          color: root.playbackColor
          font.family: button.fontFamily
          font.pixelSize: Style.fontPx(1)
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      Row {
        id: recordingIndicator
        visible: !root.vertical && root.recordingActive
        spacing: Style.space(3)
        anchors.verticalCenter: parent.verticalCenter
        Rectangle {
          width: Style.space(5); height: width; radius: width / 2
          anchors.verticalCenter: parent.verticalCenter
          color: Commons.Color.urgent
        }
        Text {
          text: "REC " + (Number(root.radio.recordings.activeCount) || 0)
          textFormat: Text.PlainText
          color: Commons.Color.urgent
          font.family: button.fontFamily
          font.pixelSize: Style.fontPx(0.917)
        }
      }
    }
  }
}
