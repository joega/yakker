pragma Singleton
import QtQuick
import Quickshell.Io

// One controller per shell engine, shared by every monitor and popup.
Item {
  id: root
  property int clients: 0
  property bool initialized: false
  property int serial: 0
  property int latestIntent: 0
  property int latestStationIntent: 0
  property int latestVolumeIntent: 0
  property int latestMuteIntent: 0
  property bool retiring: false
  property bool pendingPlay: false
  property bool ready: false
  property string playbackState: "stopped"
  property bool wanted: false
  property bool paused: false
  property int bufferMinutes: 0
  property bool temporaryBuffer: false
  readonly property bool bufferActive: bufferMinutes > 0 || temporaryBuffer
  property bool dvr: false
  property real position: 0
  property real bufferStart: 0
  property real bufferEnd: 0
  property bool bufferExpired: false
  readonly property real behindLive: Math.max(0, bufferEnd - position)
  readonly property string bufferText: !wanted ? "Buffer starts when you play" : !dvr ? "Building buffer…"
    : (paused ? "Paused · " : behindLive > 3 ? "" : "Live · ")
      + ((paused || behindLive > 3) ? clock(behindLive) + " behind live · " : "")
      + clock(bufferEnd - bufferStart) + " available"
  property string error: ""
  property string customStationError: ""
  property string customCatalogError: ""
  property int customMutationSerial: 0
  property bool customMutationOK: false
  property string title: ""
  property var station: ({id: "wbz-fm", name: "98.5 The Sports Hub", subtitle: "WBZ-FM · Boston", icon: "󰐹", artwork: "assets/sports-hub.png"})
  property var stations: []
  readonly property var countryNames: ({US: "United States (US)", CA: "Canada (CA)", GB: "United Kingdom (UK)", IE: "Ireland (IE)"})
  readonly property var stationOptions: stations.map(function(item) {
    return {value: item.id, label: (item.city ? item.city + " · " : "") + item.name,
      description: (root.countryNames[item.country] || item.country || "") + (item.subtitle ? " · " + item.subtitle : "")}
  })
  property int volume: 65
  property bool muted: false
  property int retry: 0
  property int retryDelay: 0
  property int playerPid: 0
  property string stationId: "wbz-fm"
  property string mprisPlugin: ""
  property int pendingVolume: -1
  readonly property string statusText: playbackState === "playing" ? (dvr && behindLive > 3 ? "Delayed · " + clock(behindLive) : "Live")
    : playbackState === "paused" ? "Paused"
    : playbackState === "connecting" ? "Connecting…"
    : playbackState === "retrying" ? "Reconnecting in " + retryDelay + "s · attempt " + retry + "/5"
    : playbackState === "error" ? "Unable to play" : "Stopped"
  signal preferencesChanged(int volume, bool muted, string stationId, int bufferMinutes)

  function clock(seconds) {
    const value = Math.max(0, Math.floor(seconds))
    return Math.floor(value / 60) + ":" + (value % 60 < 10 ? "0" : "") + (value % 60)
  }

  function acquire(settings) {
    clients++
    retire.stop()
    shutdownGuard.stop()
    if (!initialized) {
      initialized = true
      const v = Number(settings.volume === undefined ? 65 : settings.volume)
      volume = isFinite(v) ? Math.max(0, Math.min(100, Math.round(v))) : 65
      muted = settings.muted === true
    }
    configureSettings(settings)
    if (!helper.running) helper.running = true
    else configure()
  }
  function release() {
    clients = Math.max(0, clients - 1)
    if (!clients) retire.restart()
  }
  function send(command) {
    if (!ready || !helper.running) return 0
    command.serial = ++serial
    if (["play", "stop", "pause", "seek", "skip", "live"].indexOf(command.action) >= 0) latestIntent = serial
    if (command.action === "configure") latestStationIntent = serial
    if (command.action === "volume") latestVolumeIntent = serial
    if (command.action === "mute") latestMuteIntent = serial
    helper.write(JSON.stringify(command) + "\n")
    return command.serial
  }
  function configureSettings(settings) {
    const selected = String(settings.stationId || "wbz-fm")
    const mpris = String(settings.mprisPlugin || "")
    const minutes = [0,5,15,30].indexOf(Number(settings.bufferMinutes)) >= 0 ? Number(settings.bufferMinutes) : 0
    if (stationId === selected && mprisPlugin === mpris && bufferMinutes === minutes) return
    stationId = selected
    mprisPlugin = mpris
    bufferMinutes = minutes
    configure()
  }
  function configure() {
    send({action: "configure", stationId: stationId, mprisPlugin: mprisPlugin, bufferMinutes: bufferMinutes})
  }
  function selectStation(id) {
    if (id === stationId) return
    for (let i = 0; i < stations.length; i++) {
      if (stations[i].id !== id) continue
      stationId = id
      station = stations[i]
      title = ""
      error = ""
      playbackState = wanted ? "connecting" : "stopped"
      configure()
      preferencesChanged(volume, muted, stationId, bufferMinutes)
      return
    }
  }
  function play() {
    wanted = true
    if (!ready || !helper.running) {
      pendingPlay = true
      if (!helper.running) helper.running = true
      return
    }
    send({action: "play"})
  }
  function stop() { pendingPlay = false; wanted = false; send({action: "stop"}) }
  function togglePlayback() { wanted ? stop() : play() }
  function togglePause() { if (wanted) send({action: paused ? "play" : "pause"}) }
  function skip(seconds) { if (dvr) send({action: "skip", value: seconds}) }
  function seek(seconds) { if (dvr) send({action: "seek", value: seconds}) }
  function goLive() { send({action: "live"}) }
  function setBufferMinutes(minutes) {
    if ([0,5,15,30].indexOf(minutes) < 0 || minutes === bufferMinutes) return
    bufferMinutes = minutes
    dvr = false
    paused = false
    position = 0; bufferStart = 0; bufferEnd = 0; bufferExpired = false
    playbackState = wanted ? "connecting" : "stopped"
    configure()
    preferencesChanged(volume, muted, stationId, bufferMinutes)
  }
  function setVolume(value) {
    pendingVolume = Math.max(0, Math.min(100, Math.round(value)))
    volumeFlush.restart()
  }
  function commitVolume(value) {
    volumeFlush.stop()
    pendingVolume = -1
    volume = Math.max(0, Math.min(100, Math.round(value)))
    send({action: "volume", value: volume})
    preferencesChanged(volume, muted, stationId, bufferMinutes)
  }
  function toggleMute() {
    muted = !muted
    send({action: "mute", value: muted})
    preferencesChanged(volume, muted, stationId, bufferMinutes)
  }
  function saveCustomStation(station) {
    if (!ready || !helper.running) { customStationError = "Station manager is unavailable. Try again when Yakker reconnects."; return 0 }
    customStationError = ""
    return send({action: "upsertStation", station: station})
  }
  function deleteCustomStation(id) {
    if (!ready || !helper.running) { customStationError = "Station manager is unavailable. Try again when Yakker reconnects."; return 0 }
    customStationError = ""
    return send({action: "deleteStation", stationId: id})
  }

  Timer {
    id: volumeFlush
    interval: 60
    onTriggered: {
      root.send({action: "volume", value: root.pendingVolume})
      root.pendingVolume = -1
    }
  }
  Timer {
    id: retire
    interval: 1000
    onTriggered: {
      root.volumeFlushStop()
      root.retiring = true
      root.send({action: "quit"})
      shutdownGuard.restart()
    }
  }
  function volumeFlushStop() { volumeFlush.stop(); pendingVolume = -1 }
  Timer {
    id: shutdownGuard
    interval: 3000
    onTriggered: if (root.clients === 0) helper.running = false
  }
  Process {
    id: helper
    command: [decodeURIComponent(Qt.resolvedUrl("yakker-controller").toString().replace(/^file:\/\//, ""))]
    stdinEnabled: true
    onStarted: {
      root.retiring = false
      root.ready = true
      root.customCatalogError = ""
      root.configure()
      root.send({action: "volume", value: root.volume})
      root.send({action: "mute", value: root.muted})
      if (root.pendingPlay) { root.pendingPlay = false; root.send({action: "play"}) }
    }
    stdout: SplitParser {
      onRead: data => {
        try {
          const next = JSON.parse(data)
          if (Array.isArray(next.stations)) root.stations = next.stations
          if (typeof next.customStationError === "string") root.customStationError = next.customStationError
          if (!next.customMutationSerial && typeof next.customStationError === "string") root.customCatalogError = next.customStationError
          if (typeof next.customMutationSerial === "number" && next.customMutationSerial > root.customMutationSerial) {
            root.customMutationOK = next.customMutationOK === true
            root.customMutationSerial = next.customMutationSerial
          }
          if ((next.serial || 0) >= Math.max(root.latestIntent, root.latestStationIntent)) {
            root.playbackState = next.state || "error"
            root.wanted = next.wanted === true
            root.paused = next.paused === true
            root.temporaryBuffer = next.temporaryBuffer === true
            root.dvr = next.dvr === true
            root.position = Number(next.position) || 0
            root.bufferStart = Number(next.bufferStart) || 0
            root.bufferEnd = Number(next.bufferEnd) || 0
            root.bufferExpired = next.bufferExpired === true
            if ([0,5,15,30].indexOf(next.bufferMinutes) >= 0) root.bufferMinutes = next.bufferMinutes
            root.error = next.error || ""
            root.title = next.title || ""
            if (next.station) {
              const changedStation = root.stationId !== next.station.id
              root.station = next.station
              root.stationId = next.station.id
              if (changedStation) root.preferencesChanged(root.volume, root.muted, root.stationId, root.bufferMinutes)
            }
            root.retry = next.retry || 0
            root.retryDelay = next.retryDelay || 0
            root.playerPid = next.playerPid || 0
          }
          if ((next.serial || 0) >= root.latestVolumeIntent && typeof next.volume === "number") root.volume = next.volume
          if ((next.serial || 0) >= root.latestMuteIntent && typeof next.muted === "boolean") root.muted = next.muted
        } catch (e) { console.warn("Yakker: invalid helper response: " + e) }
      }
    }
    stderr: SplitParser { onRead: data => console.warn("Yakker: " + data) }
    onExited: exitCode => {
      root.ready = false
      root.wanted = false
      root.paused = false
      root.temporaryBuffer = false
      root.dvr = false
      root.playerPid = 0
      root.playbackState = root.clients ? "error" : "stopped"
      if (root.clients && !root.error) root.error = "Yakker controller exited (" + exitCode + "). Press Retry."
      shutdownGuard.stop()
      if (root.retiring && root.clients) Qt.callLater(function() { helper.running = true })
      root.retiring = false
    }
  }
}
