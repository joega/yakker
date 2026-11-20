import QtQuick
import Quickshell.Io
import qs.Commons
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
    if (entry.volume === volume && entry.muted === muted && entry.stationId === stationId && entry.bufferMinutes === bufferMinutes) return
    entry.volume = volume
    entry.muted = muted
    entry.stationId = stationId
    entry.bufferMinutes = bufferMinutes
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
        paused: Radio.RadioService.paused, bufferMinutes: Radio.RadioService.bufferMinutes, dvr: Radio.RadioService.dvr,
        position: Radio.RadioService.position, bufferStart: Radio.RadioService.bufferStart, bufferEnd: Radio.RadioService.bufferEnd,
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
    fontSize: Style.font.icon
    foreground: Radio.RadioService.playbackState === "error" ? Color.urgent
      : Radio.RadioService.playbackState === "playing" ? Color.accent
      : root.bar ? root.bar.barForeground : Color.foreground
    tooltipText: Radio.RadioService.station.name + " · " + Radio.RadioService.statusText + "\nClick for controls · Right-click for stations"
    onPressed: buttonCode => {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) root.chooseStation()
    }

    Row {
      id: branding
      anchors.centerIn: parent
      spacing: Style.space(6)
      Radio.StationLogo {
        width: Style.space(24)
        height: Math.min(Style.space(22), button.height - Style.space(4))
        anchors.verticalCenter: parent.verticalCenter
        // An idle selection is not a live station; use the neutral radio fallback.
        station: Radio.RadioService.wanted && Radio.RadioService.playbackState === "playing"
          ? Radio.RadioService.station : ({})
        fallbackColor: button.foreground
      }
      Text {
        visible: !root.vertical && root.setting("showName", false)
        text: "Yakker"
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Rectangle {
      width: Style.space(4)
      height: width
      radius: width / 2
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(3)
      visible: Radio.RadioService.playbackState !== "stopped"
      color: Radio.RadioService.playbackState === "error" ? Color.urgent
        : Radio.RadioService.playbackState === "playing" ? Color.accent : button.foreground
    }
  }
}
