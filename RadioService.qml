pragma Singleton
import QtQuick
import Quickshell.Io
import "RecordingNotices.js" as RecordingNotices

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
  property int helperRestarts: 0
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
  property var recordings: ({available: false, error: "", revision: 0, settings: {}, schedules: [], recordings: [], usedBytes: 0, activeCount: 0})
  property int recordingMutationSerial: 0
  property bool recordingMutationOK: false
  property string recordingError: ""
  property var schedulePreview: ({})
  property int schedulePreviewSerial: 0
  property string schedulePreviewError: ""
  property string playbackKind: "live"
  property string recordingId: ""
  property string recordingTitle: ""
  property real duration: 0
  property real playbackSpeed: 1
  property string playbackProgressError: ""
  property int sleepRemaining: 0
  property bool recordingNotifications: true
  property bool recordingStartNotifications: false
  property var noticeState: ({initialized: false, rows: {}, error: ""})
  property var noticeQueue: []
  property string customStationError: ""
  property string customCatalogError: ""
  property int customMutationSerial: 0
  property bool customMutationOK: false
  property string title: ""
  readonly property var noStation: ({id: "", name: "Choose a station", subtitle: "", icon: "󰐹"})
  property var station: noStation
  readonly property bool hasStation: stationId.length > 0 && station.id === stationId
  property var stations: []
  // Saved audio can come from a different station than the selected live one.
  readonly property var playbackStation: {
    if (playbackKind !== "recording") return station
    const item = (recordings.recordings || []).find(function(recording) { return recording.id === root.recordingId })
    return stations.find(function(source) { return item && source.id === item.stationId })
      || {name: item ? item.stationName : "Saved recording", icon: "󰲸"}
  }
  property var favoriteIds: []
  readonly property var countryNames: ({US: "United States (US)", CA: "Canada (CA)", GB: "United Kingdom (UK)", IE: "Ireland (IE)"})
  readonly property var stationOptions: {
    const favorites = [], others = []
    for (const item of stations) {
      const favorite = root.favoriteIds.indexOf(item.id) !== -1
      const option = {value: item.id, name: item.name, city: item.city || "", favorite: favorite, station: item,
        countryName: ({US:"United States", CA:"Canada", GB:"United Kingdom", IE:"Ireland"})[item.country] || item.country || "",
        label: (favorite ? "♥ " : "") + (item.city ? item.city + " · " : "") + item.name,
        description: (root.countryNames[item.country] || item.country || "") + (item.subtitle ? " · " + item.subtitle : "")}
      if (favorite) favorites.push(option); else others.push(option)
    }
    return favorites.concat(others)
  }
  property int volume: 65
  property bool muted: false
  property int retry: 0
  property int retryDelay: 0
  property int playerPid: 0
  property string stationId: ""
  property string mprisPlugin: ""
  property int pendingVolume: -1
  readonly property bool playbackPaused: wanted && paused && playbackState === "paused"
  readonly property bool playbackStopped: !wanted && playbackState === "stopped"
  readonly property string statusText: playbackState === "playing" ? (playbackKind === "recording" ? "Playing recording" : (dvr && behindLive > 3 ? "Delayed · " + clock(behindLive) : "Live"))
    : playbackPaused ? (playbackKind === "recording" ? "Recording paused" : "Paused · buffering")
    : playbackState === "connecting" ? "Connecting…"
    : playbackState === "retrying" ? "Reconnecting in " + retryDelay + "s · attempt " + retry + "/5"
    : playbackState === "error" ? "Unable to play" : playbackKind === "recording" ? "Recording stopped" : !hasStation ? "Choose a station to start listening" : "Listening stopped"
  readonly property string playbackDetail: playbackStopped ? (playbackKind === "recording" ? "Position saved · Resume from Library"
      : hasStation ? "Stream disconnected · Replay cleared" : "Choose a station, then press Play")
    : playbackPaused ? (playbackKind === "recording" ? "Position saved · Resume when ready"
      : bufferExpired ? "Stream stays connected · Earlier audio expired" : "Stream stays connected · Resume keeps your place") : ""
  signal preferencesChanged(int volume, bool muted, string stationId, int bufferMinutes)
  signal favoritesUpdated()
  signal statusReceived(int serial)

  function normalizeFavorites(value) {
    if (!Array.isArray(value)) return []
    const result = []
    for (const id of value) {
      if (typeof id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(id) && result.indexOf(id) === -1) result.push(id)
      if (result.length >= 1000) break
    }
    return result
  }
  function toggleFavorite(id) {
    if (!stations.some(function(station) { return station.id === id })) return
    const next = favoriteIds.slice()
    const index = next.indexOf(id)
    if (index < 0) {
      if (next.length >= 1000) return
      next.push(id)
    } else next.splice(index, 1)
    favoriteIds = next
    favoritesUpdated()
  }

  function clock(seconds) {
    const value = Math.max(0, Math.floor(seconds))
    return Math.floor(value / 60) + ":" + (value % 60 < 10 ? "0" : "") + (value % 60)
  }

  function acquire(settings) {
    clients++
    helperRetry.stop()
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
    if (["play", "stop", "pause", "seek", "skip", "live", "playRecording", "seekRecording", "speed", "sleepTimer"].indexOf(command.action) >= 0) latestIntent = serial
    if (command.action === "configure") latestStationIntent = serial
    if (command.action === "volume") latestVolumeIntent = serial
    if (command.action === "mute") latestMuteIntent = serial
    helper.write(JSON.stringify(command) + "\n")
    return command.serial
  }
  function configureSettings(settings) {
    favoriteIds = normalizeFavorites(settings.favorites)
    recordingNotifications = settings.recordingNotifications !== false
    recordingStartNotifications = settings.recordingStartNotifications === true
    if (!recordingNotifications) noticeQueue = []
    else if (!recordingStartNotifications) noticeQueue = noticeQueue.filter(function(notice) { return notice.kind !== "start" })
    const selected = String(settings.stationId || "")
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
    if (id === stationId) { if (playbackKind === "recording") goLive(); return }
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
    if (!hasStation && !(playbackKind === "recording" && wanted)) return
    helperRetry.stop()
    helperRestarts = 0
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
  function skip(seconds) { if (dvr || (playbackKind === "recording" && wanted)) send({action: "skip", value: seconds}) }
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
  function recordingSettings(revision, settings) { return send({action: "recordingSettings", revision: revision, settings: settings}) }
  function upsertSchedule(revision, schedule, refreshStation) { return send({action: "upsertSchedule", revision: revision, schedule: schedule, refreshStation: refreshStation === true}) }
  function previewSchedule(schedule) { return send({action: "previewSchedule", schedule: schedule}) }
  function deleteSchedule(revision, id) { return send({action: "deleteSchedule", revision: revision, id: id}) }
  function stopRecording(revision, id) { return send({action: "stopRecording", revision: revision, id: id}) }
  function deleteRecording(revision, id) { return send({action: "deleteRecording", revision: revision, id: id}) }
  function startRecording(revision, stationId, durationMinutes) { return send({action: "startRecording", revision: revision, stationId: stationId, durationMinutes: durationMinutes}) }
  function playRecording(id, fromStart) { return send({action: "playRecording", id: id, fromStart: fromStart === true}) }
  function seekRecording(value) { return send({action: "seekRecording", value: value}) }
  function setPlaybackSpeed(value) { return send({action: "speed", value: value}) }
  function setSleepTimer(minutes) { return send({action: "sleepTimer", minutes: minutes}) }
  function setRecordingNotifications(value) {
    recordingNotifications = value === true
    if (!recordingNotifications) noticeQueue = []
    preferencesChanged(volume, muted, stationId, bufferMinutes)
  }
  function setRecordingStartNotifications(value) {
    recordingStartNotifications = value === true
    if (!recordingStartNotifications) noticeQueue = noticeQueue.filter(function(notice) { return notice.kind !== "start" })
    preferencesChanged(volume, muted, stationId, bufferMinutes)
  }
  function observeRecordings(snapshot) {
    const result = RecordingNotices.update(noticeState, snapshot, recordingNotifications, recordingStartNotifications)
    noticeState = result.state
    noticeQueue = noticeQueue.concat(result.notices).slice(-20)
    pumpNotice()
  }
  function pumpNotice() {
    if (!recordingNotifications) { noticeQueue = []; return }
    if (notifier.running || !noticeQueue.length) return
    const queue = noticeQueue.slice(), notice = queue.shift()
    noticeQueue = queue
    notifier.command = ["notify-send", "--app-name=Yakker", "--icon=audio-radio", "--",
                        notice.title, RecordingNotices.escapeMarkup(notice.body)]
    notifier.running = true
    noticeTimeout.restart()
  }
  Process {
    id: notifier
    onExited: { noticeTimeout.stop(); Qt.callLater(root.pumpNotice) }
  }
  Timer {
    id: noticeTimeout
    interval: 5000
    onTriggered: { notifier.running = false; Qt.callLater(root.pumpNotice) }
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
      helperRetry.stop()
      root.volumeFlushStop()
      root.retiring = true
      root.send({action: "quit"})
      shutdownGuard.restart()
    }
  }
  function volumeFlushStop() { volumeFlush.stop(); pendingVolume = -1 }
  Timer {
    id: helperRetry
    interval: Math.min(8000, 1000 * Math.pow(2, Math.max(0, root.helperRestarts - 1)))
    onTriggered: if (root.clients > 0 && !helper.running) helper.running = true
  }
  Timer {
    id: helperStable
    interval: 60000
    onTriggered: if (root.ready && helper.running) root.helperRestarts = 0
  }
  Timer {
    id: shutdownGuard
    interval: 25000
    onTriggered: if (root.clients === 0) helper.running = false
  }
  Process {
    id: helper
    command: [decodeURIComponent(Qt.resolvedUrl("yakker-controller").toString().replace(/^file:\/\//, ""))]
    stdinEnabled: true
    onStarted: {
      helperStable.restart()
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
          if (next.recordings && typeof next.recordings === "object") {
            root.recordings = next.recordings
            root.observeRecordings(next.recordings)
          }
          if (typeof next.schedulePreviewSerial === "number" && next.schedulePreviewSerial > root.schedulePreviewSerial) {
            root.schedulePreview = next.schedulePreview || ({})
            root.schedulePreviewError = next.schedulePreviewError || ""
            root.schedulePreviewSerial = next.schedulePreviewSerial
          }
          if (typeof next.recordingMutationSerial === "number" && next.recordingMutationSerial > root.recordingMutationSerial) {
            root.recordingMutationOK = next.recordingMutationOK === true
            root.recordingError = next.recordingError || ""
            root.recordingMutationSerial = next.recordingMutationSerial
          }
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
            root.playbackKind = next.playbackKind || "live"
            root.recordingId = next.recordingId || ""
            root.recordingTitle = next.recordingTitle || ""
            root.duration = Number(next.duration) || 0
            root.playbackSpeed = Number(next.playbackSpeed) || 1
            root.playbackProgressError = String(next.playbackProgressError || "")
            root.sleepRemaining = Math.max(0, Number(next.sleepRemaining) || 0)
            root.position = Number(next.position) || 0
            root.bufferStart = Number(next.bufferStart) || 0
            root.bufferEnd = Number(next.bufferEnd) || 0
            root.bufferExpired = next.bufferExpired === true
            if ([0,5,15,30].indexOf(next.bufferMinutes) >= 0) root.bufferMinutes = next.bufferMinutes
            root.error = next.error || ""
            root.title = next.title || ""
            const selectedStation = next.station && next.station.id ? next.station : root.noStation
            const changedStation = root.stationId !== selectedStation.id
            root.station = selectedStation
            root.stationId = selectedStation.id
            if (changedStation) root.preferencesChanged(root.volume, root.muted, root.stationId, root.bufferMinutes)
            root.retry = next.retry || 0
            root.retryDelay = next.retryDelay || 0
            root.playerPid = next.playerPid || 0
            root.statusReceived(Number(next.serial) || 0)
          }
          if ((next.serial || 0) >= root.latestVolumeIntent && typeof next.volume === "number") root.volume = next.volume
          if ((next.serial || 0) >= root.latestMuteIntent && typeof next.muted === "boolean") root.muted = next.muted
        } catch (e) { console.warn("Yakker: invalid helper response: " + e) }
      }
    }
    stderr: SplitParser { onRead: data => console.warn("Yakker: " + data) }
    onExited: exitCode => {
      helperStable.stop()
      root.ready = false
      root.wanted = false
      root.paused = false
      root.temporaryBuffer = false
      root.dvr = false
      root.recordings = Object.assign({}, root.recordings, {available: false, activeCount: 0, error: "Recording manager disconnected."})
      if (!root.retiring && root.clients > 0) root.observeRecordings(root.recordings)
      root.playerPid = 0
      root.sleepRemaining = 0
      root.playbackSpeed = 1
      root.playbackState = root.clients ? "error" : "stopped"
      if (root.clients && !root.error) root.error = "Yakker controller exited (" + exitCode + "). Press Retry."
      shutdownGuard.stop()
      if (root.retiring && root.clients) Qt.callLater(function() { helper.running = true })
      else if (root.clients > 0 && root.helperRestarts < 5) { root.helperRestarts++; helperRetry.restart() }
      root.retiring = false
    }
  }
}
