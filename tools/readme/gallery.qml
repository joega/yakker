import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import qs.Commons as Commons
import "plugin" as Plugin

ShellRoot {
  Window {
    id: window
    visible: true
    width: 420
    height: 600
    color: "transparent"
    Plugin.Panel { id: panel; width: window.width; height: window.height }
    Timer { interval: 800; running: true; onTriggered: gallery.render() }
    TestCase {
      id: gallery
      when: false
      property var themes: ({})
      readonly property var radio: panel.radio
      readonly property var schedule: ({id: "football", label: "Football review", stationId: "talksport", stationName: "talkSPORT", weekdays: [1,2,3,4,5], startTime: "14:00", endTime: "14:20", timezone: "America/New_York", enabled: true, preRollSeconds:30, postRollSeconds:60, nextStart: "2026-11-23T14:00:00-05:00", nextEnd: "2026-11-23T14:20:00-05:00", nextCaptureStart:"2026-11-23T13:59:30-05:00", nextCaptureEnd:"2026-11-23T14:21:00-05:00"})
      function snapshot(schedules, recordings, active) {
        return {available: true, revision: 1, error: "", localTimezone: "America/New_York",
          settings: {folder: "/home/demo/Music/Yakker", storageCapBytes: 5368709120, freeSpaceReserveBytes: 1073741824, concurrency: 3},
          usedBytes: recordings.reduce(function(total, item) { return total + item.bytes }, 0), schedules: schedules, recordings: recordings, activeCount: active || 0}
      }
      function selectExample(id) {
        const station = radio.stations.find(function(item) { return item.id === id })
        verify(!!station, "Unknown screenshot station: " + id)
        radio.station = station
        radio.stationId = id
        radio.title = ""
      }
      function readFile(path) {
        const request = new XMLHttpRequest()
        request.open("GET", Qt.resolvedUrl(path), false)
        request.send()
        verify(request.status === 0 || request.status === 200, "Could not read " + path)
        verify(request.responseText.length > 0, "Empty file: " + path)
        return request.responseText
      }
      function capture(name) {
        const theme = themes[name]
        verify(!!theme, "No theme assigned to " + name)
        // Use stock theme surfaces rather than machine-specific shell overrides.
        // These functions update only this isolated process's native singletons.
        Commons.Color.loadUserShell("")
        Commons.Color.loadColors(readFile("themes/" + theme + "/colors.toml"))
        Commons.Color.loadShell(readFile("themes/" + theme + "/shell.toml"))
        Commons.Style.fontFamily = "JetBrainsMono Nerd Font"
        panel.screenshotScroller.contentY = 0
        wait(150)
        window.height = panel.screenshotPanel.contentHeight
        wait(150)
        var done = false, saved = false
        window.contentItem.grabToImage(function(result) {
          saved = result.saveToFile(Quickshell.env("YAKKER_SCREENSHOT_DIR") + "/yakker-" + name + ".png")
          done = true
        })
        tryVerify(function() { return done }, 5000)
        verify(saved, "Could not save " + name)
      }
      function render() {
        try {
          // The production components render sample state without starting the
          // shared controller. Dates and show labels are illustrative.
          Commons.Style.cornerRadius = 8
          Commons.Style.fontFamily = "JetBrainsMono Nerd Font"
          themes = JSON.parse(readFile("themes.json"))
          compare(Object.keys(themes).length, 18)
          radio.stations = JSON.parse(readFile("plugin/stations.json"))
          radio.station = radio.stations[0]
          radio.stationId = radio.station.id
          radio.favoriteIds = ["wfan", "weei-fm", "tsn-690"]
          radio.initialized = true; radio.ready = true
          radio.wanted = true; radio.playbackState = "playing"
          radio.volume = 62
          radio.recordings = snapshot([], [], 0)
          panel.cursor = -1
          panel.open()
          selectExample("wfan")
          capture("popup")

          radio.bufferMinutes = 15; radio.dvr = true
          radio.bufferStart = 0; radio.bufferEnd = 900; radio.position = 690
          radio.paused = true; radio.playbackState = "paused"
          selectExample("wip-fm")
          capture("dvr")

          radio.bufferMinutes = 0; radio.dvr = false; radio.paused = false
          radio.playbackState = "playing"
          selectExample("tsn-690")
          panel.screenshotPicker.open()
          capture("stations")
          panel.screenshotPicker.close()

          const complete = {id: "saved", stationId: "weei-fm", label: "Morning drive", stationName: "WEEI 93.7", status: "complete", bytes: 3870000, durationSeconds: 1290,
            plannedStart: "2026-11-19T09:00:00-05:00", plannedEnd: "2026-11-19T09:20:00-05:00", captureStart:"2026-11-19T08:59:30-05:00", captureEnd:"2026-11-19T09:21:00-05:00", startedAt: "2026-11-19T08:59:31-05:00", endedAt: "2026-11-19T09:21:00-05:00", playable: true, resumePosition: 486}
          const recovered = {id:"recovered",stationId:"kdka-fm",label:"Afternoon sports",stationName:"93.7 The Fan",status:"partial",bytes:1080000,durationSeconds:360,
            plannedStart:"2026-11-19T14:00:00-05:00",plannedEnd:"2026-11-19T14:20:00-05:00",captureStart:"2026-11-19T13:59:30-05:00",captureEnd:"2026-11-19T14:21:00-05:00",startedAt:"2026-11-19T13:59:31-05:00",endedAt:"",reason:"plugin interrupted; recovered retained audio",playable:true,resumePosition:96}
          const active = {id: "capturing", stationId: "kiro-am", label: "Seattle sports", stationName: "Seattle Sports 710", status: "recording", bytes: 1800000,
            plannedStart: "2026-11-20T14:00:00-05:00", plannedEnd: "2026-11-20T14:20:00-05:00", startedAt: "2026-11-20T14:00:01-05:00", playable: false}
          radio.recordings = snapshot([schedule], [active, recovered, complete], 1)
          selectExample("kiro-am")
          panel.openRecordings(false)
          capture("recordings")
          selectExample("kdka-fm")
          const detailed = Object.assign({}, recovered, {id:"detailed"})
          radio.recordings = snapshot([], [detailed], 0)
          panel.screenshotView.toggleDetails("detailed")
          capture("recording-details")
          panel.screenshotView.toggleDetails("detailed")

          selectExample("talksport")
          const later = Object.assign({}, schedule, {id: "later", label: "Afternoon drive", stationId: "wscr", stationName: "104.3 The Score", startTime: "16:00", endTime: "17:00", preRollSeconds:60,postRollSeconds:120, nextStart: "2026-11-23T16:00:00-05:00", nextEnd: "2026-11-23T17:00:00-05:00",nextCaptureStart:"2026-11-23T15:59:00-05:00",nextCaptureEnd:"2026-11-23T17:02:00-05:00"})
          const paused = Object.assign({}, schedule, {id: "paused", label: "Weekend catch-up", stationId: "bbc-radio-5-live", stationName: "BBC Radio 5 Live", weekdays: [0,6], enabled: false, nextStart: "", nextEnd: "",nextCaptureStart:"",nextCaptureEnd:""})
          radio.recordings = snapshot([paused, later, schedule], [], 0)
          panel.openSchedules()
          capture("schedules")

          selectExample("wzgc-fm")
          radio.recordings = snapshot([], [], 0)
          panel.screenshotView.beginEdit(Object.assign({}, schedule, {id: "", kind: "once", date: "2026-11-23"}))
          panel.screenshotView.screenshotPreviewDelay.stop()
          panel.screenshotView.previewText = "Mon Nov 23 · 02:00PM–02:20PM · America/New_York"
          panel.screenshotView.previewCaptureText = "Captures Mon Nov 23 · 01:59:30PM–02:21:00PM"
          capture("schedule")
          panel.screenshotView.editing = false

          selectExample("klac")
          panel.screenshotView.beginNow()
          capture("record-now")
          panel.screenshotView.nowEditing = false

          panel.recordingsOpen = false
          radio.recordings = snapshot([], [complete], 0)
          radio.recordingId = "saved"
          radio.playbackKind = "recording"; radio.recordingTitle = "Morning drive"
          radio.duration = complete.durationSeconds; radio.position = 486
          radio.playbackSpeed = 1.25; radio.sleepRemaining = 900
          capture("recording-player")
          panel.showPlayer()
          radio.playbackKind = "live"; radio.position = 0
          selectExample("bbc-radio-5-live")
          panel.screenshotSleep.open()
          capture("sleep-timer")
          panel.screenshotSleep.close()

          radio.playbackKind = "live"; radio.position = 0
          selectExample("tsn-1050")
          radio.sleepRemaining = 0
          radio.wanted = true; radio.paused = true; radio.playbackState = "paused"
          radio.temporaryBuffer = true; radio.dvr = true
          radio.bufferEnd = 90; radio.position = 60
          panel.settingsOpen = true
          capture("settings")
          panel.settingsOpen = false
          selectExample("kkfn-fm")
          radio.sleepRemaining = 0
          panel.openSettings()
          panel.openSettingsStorage()
          radio.wanted = false; radio.paused = false; radio.playbackState = "stopped"
          radio.temporaryBuffer = false; radio.dvr = false
          radio.bufferEnd = 0; radio.position = 0
          capture("storage")
          radio.wanted = true; radio.playbackState = "playing"
          selectExample("wkrk-fm")
          panel.selectSettingsTab("alerts")
          capture("notifications")
          selectExample("wbns-fm")
          panel.selectSettingsTab("stations")
          panel.openStationEditor({name:"Community Radio", streamUrl:"https://radio.example/stream", city:"Boston", country:"US", website:"https://radio.example"})
          capture("custom-station")
          panel.showPlayer()
          radio.playbackKind = "live"; radio.playbackState = "playing"; radio.wanted = true
          selectExample("krld-fm")
          radio.recordings = snapshot([], [], 0)
          panel.openRecordings(false)
          panel.screenshotView.clearLibraryFilters()
          capture("empty-library")
          selectExample("wscr")
          radio.recordings = snapshot([], [complete], 0)
          panel.screenshotView.screenshotSearch.text = "Late game"
          capture("empty-search")
          panel.showPlayer()
          selectExample("espn-new-york")
          radio.wanted = false; radio.playbackState = "error"
          radio.error = "The stream could not be opened."
          capture("connection-error")
          radio.error = ""; radio.wanted = true; radio.playbackState = "playing"
          selectExample("off-the-ball")
          panel.screenshotPicker.open()
          panel.screenshotPicker.screenshotSearch.text = "Snowboarding"
          capture("empty-stations")
          panel.screenshotPicker.close()
          console.log("YAKKER_README_SCREENSHOTS_PASS")
        } catch (error) {
          console.error("YAKKER_README_SCREENSHOTS_FAIL", error, error.stack)
        }
        Qt.quit()
      }
    }
  }
}
