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
      readonly property var schedule: ({id: "football", label: "Football review", stationId: "talksport", stationName: "talkSPORT", weekdays: [1,2,3,4,5], startTime: "14:00", endTime: "14:20", timezone: "America/New_York", enabled: true, nextStart: "2026-11-23T14:00:00-05:00", nextEnd: "2026-11-23T14:20:00-05:00"})
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
          compare(Object.keys(themes).length, 8)
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

          const complete = {id: "saved", stationId: "weei-fm", label: "Morning drive", stationName: "WEEI 93.7", status: "complete", bytes: 3600000, durationSeconds: 1200,
            plannedStart: "2026-11-19T14:00:00-05:00", plannedEnd: "2026-11-19T14:20:00-05:00", startedAt: "2026-11-19T14:00:01-05:00", endedAt: "2026-11-19T14:20:00-05:00", playable: true, resumePosition: 486}
          const active = {id: "capturing", stationId: "kiro-am", label: "Seattle sports", stationName: "Seattle Sports 710", status: "recording", bytes: 1800000,
            plannedStart: "2026-11-20T14:00:00-05:00", plannedEnd: "2026-11-20T14:20:00-05:00", startedAt: "2026-11-20T14:00:01-05:00", playable: false}
          radio.recordings = snapshot([schedule], [active, complete], 1)
          selectExample("kiro-am")
          panel.openRecordings(false)
          capture("recordings")

          radio.recordings = snapshot([], [], 0)
          panel.screenshotView.beginEdit(Object.assign({}, schedule, {id: "", kind: "once", date: "2026-11-23"}))
          capture("schedule")
          panel.screenshotView.editing = false

          panel.recordingsOpen = false
          radio.recordings = snapshot([], [complete], 0)
          radio.recordingId = "saved"
          radio.playbackKind = "recording"; radio.recordingTitle = "Morning drive"
          radio.duration = 1200; radio.position = 486
          radio.playbackSpeed = 1.25; radio.sleepRemaining = 900
          capture("recording-player")

          radio.playbackKind = "live"; radio.position = 0
          selectExample("kfan")
          panel.settingsOpen = true
          capture("settings")
          panel.settingsOpen = false
          selectExample("sportsnet-590")
          panel.openRecordings(true)
          capture("storage")
          console.log("YAKKER_README_SCREENSHOTS_PASS")
        } catch (error) {
          console.error("YAKKER_README_SCREENSHOTS_FAIL", error, error.stack)
        }
        Qt.quit()
      }
    }
  }
}
