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
  readonly property string playbackIcon: radio.playbackState === "error" ? "warning"
    : radio.playbackState === "connecting" || radio.playbackState === "retrying" ? "radio"
    : radio.playbackPaused ? "pause"
    : radio.wanted && radio.playbackState === "playing" ? (radio.playbackKind === "live" && radio.dvr && radio.behindLive > 3 ? "back" : "play") : "stop"
  readonly property color playbackColor: radio.playbackState === "error" ? Commons.Color.urgent
    : radio.wanted && (radio.playbackState === "playing" || radio.playbackPaused && radio.playbackKind === "live") ? Commons.Color.accent
    : root.bar ? root.bar.barForeground : Commons.Color.foreground

  readonly property string tooltipStatus: buildTooltip()
  FontMetrics {
    id: tooltipMetrics
    font.family: button.fontFamily
    font.pixelSize: Style.font.body
  }
  function tooltipText(value) {
    return String(value || "").replace(/\s+/g, " ").trim()
  }
  function tooltipLine(value) {
    return tooltipMetrics.elidedText(tooltipText(value), Text.ElideRight, Style.space(340))
  }
  function tooltipParagraph(value) {
    const words = tooltipText(value).split(" ")
    const lines = []
    let line = ""
    for (let i = 0; i < words.length; i++) {
      const next = line ? line + " " + words[i] : words[i]
      if (line && tooltipMetrics.advanceWidth(next) > Style.space(340)) {
        lines.push(line)
        if (lines.length === 1) {
          line = words.slice(i).join(" ")
          break
        }
        line = words[i]
      } else line = next
    }
    if (line) lines.push(tooltipLine(line))
    return lines.join("\n")
  }
  function buildTooltip() {
    const saved = radio.playbackKind === "recording"
    const source = saved ? radio.playbackStation : radio.station
    const selected = saved || radio.hasStation
    const heading = [tooltipLine(selected ? (saved ? radio.recordingTitle || "Saved recording" : source.name) : "Yakker")]
    if (saved) heading.push(tooltipLine("Saved recording · " + (source.name || "Unknown station")))
    const country = (radio.countryNames[source.country] || source.country || "").replace(/ \([A-Z]{2}\)$/, "")
    const location = [source.city || "", country].filter(function(part) { return !!part }).join(" · ")
    if (selected && location) heading.push(tooltipLine(location))
    else if (selected && !saved && source.subtitle) heading.push(tooltipLine(source.subtitle))
    const groups = [heading.join("\n")]
    let state = radio.statusText
    if (saved && radio.wanted && radio.duration > 0)
      state += " · " + radio.clock(radio.position) + " / " + radio.clock(radio.duration)
    else if (!saved && radio.wanted && radio.dvr && (radio.playbackPaused || radio.playbackState === "playing") && radio.behindLive > 3)
      state = (radio.playbackPaused ? state : "Playing") + " · " + radio.clock(radio.behindLive) + " behind live"
    const listening = [tooltipParagraph(state)]
    if (radio.playbackDetail && selected) listening.push(tooltipParagraph(radio.playbackDetail))
    if (!saved && radio.wanted && (radio.playbackPaused || radio.playbackState === "playing")) {
      if (radio.dvr) listening.push(tooltipParagraph((radio.temporaryBuffer ? "Temporary replay" : "Replay") + " · "
        + radio.clock(Math.max(0, radio.bufferEnd - radio.bufferStart)) + " available"))
      else listening.push(radio.bufferActive ? "Replay · Building buffer…" : "Live only · Pause to keep your place")
      if (radio.playbackState === "playing" && radio.behindLive <= 3 && tooltipText(radio.title))
        listening.push(tooltipParagraph("Now playing · " + radio.title))
    }
    groups.push(listening.join("\n"))
    const snapshot = radio.recordings || {}
    if (snapshot.available === false) groups.push("Recording status unavailable")
    else if (recordingActive) {
      const active = (snapshot.recordings || []).filter(function(item) { return item.status === "recording" })
      const count = Math.max(Number(snapshot.activeCount) || 0, active.length)
      const captures = ["Recording now · " + count + (count === 1 ? " active show" : " active shows")]
      active.slice(0, 3).forEach(function(item) {
        const name = tooltipText(item.label || item.stationName || "Recording")
        const station = tooltipText(item.stationName)
        captures.push(tooltipParagraph("• " + name + (station && station !== name ? " · " + station : "")))
      })
      if (count > 3) captures.push("+ " + (count - 3) + " more in Library")
      groups.push(captures.join("\n"))
    }
    groups.push("Click: player · Right-click: stations")
    return groups.join("\n\n")
  }

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
    Accessible.description: root.tooltipStatus
    tooltipText: root.tooltipStatus
    onPressed: buttonCode => {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) root.chooseStation()
    }

    Row {
      id: branding
      anchors.centerIn: parent
      spacing: Style.space(6)
      Item {
        width: Style.bar.iconCanvas
        height: Math.min(width, Math.max(Style.space(12), button.height - Style.space(8)))
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
          width: Style.space(10); height: width
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
      Radio.FocusIcon {
        id: stateIcon
        visible: !root.vertical
        width: Style.space(12); height: width
        anchors.verticalCenter: parent.verticalCenter
        name: root.playbackIcon
        foreground: root.playbackColor
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
