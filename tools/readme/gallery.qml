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
    width: 380
    height: 600
    color: "transparent"
    Plugin.Panel { id: panel; width: window.width; height: window.height }
    Timer { interval: 800; running: true; onTriggered: gallery.render() }
    TestCase {
      id: gallery
      when: false
      readonly property var radio: panel.radio
      readonly property var schedule: ({id: "afternoon", label: "Afternoon sports", stationId: "wbz-fm", stationName: "98.5 The Sports Hub", weekdays: [1,2,3,4,5], startTime: "14:00", endTime: "14:20", timezone: "America/New_York", enabled: true, nextStart: "2026-11-23T14:00:00-05:00", nextEnd: "2026-11-23T14:20:00-05:00"})
      function snapshot(schedules, recordings, active) {
        return {available: true, revision: 1, error: "", localTimezone: "America/New_York",
          settings: {folder: "/home/demo/Music/Yakker", storageCapBytes: 5368709120, freeSpaceReserveBytes: 1073741824, concurrency: 3},
          usedBytes: recordings.reduce(function(total, item) { return total + item.bytes }, 0), schedules: schedules, recordings: recordings, activeCount: active || 0}
      }
      function capture(name) {
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
          const request = new XMLHttpRequest()
          request.open("GET", Qt.resolvedUrl("plugin/stations.json"), false)
          request.send()
          radio.stations = JSON.parse(request.responseText)
          radio.station = radio.stations[0]
          radio.stationId = radio.station.id
          radio.favoriteIds = ["wbz-fm", "wfan", "tsn-690"]
          radio.initialized = true; radio.ready = true
          radio.wanted = true; radio.playbackState = "playing"
          radio.volume = 62
          radio.recordings = snapshot([], [], 0)
          panel.cursor = -1
          panel.open()
          capture("popup")

          radio.bufferMinutes = 15; radio.dvr = true
          radio.bufferStart = 0; radio.bufferEnd = 900; radio.position = 690
          radio.paused = true; radio.playbackState = "paused"
          capture("dvr")

          radio.bufferMinutes = 0; radio.dvr = false; radio.paused = false
          radio.playbackState = "playing"
          panel.screenshotPicker.open()
          capture("stations")
          panel.screenshotPicker.close()

          const complete = {id: "saved", label: "Afternoon sports", stationName: "98.5 The Sports Hub", status: "complete", bytes: 3600000, durationSeconds: 1200,
            plannedStart: "2026-11-19T14:00:00-05:00", plannedEnd: "2026-11-19T14:20:00-05:00", startedAt: "2026-11-19T14:00:01-05:00", endedAt: "2026-11-19T14:20:00-05:00", playable: true}
          const active = {id: "capturing", label: "Afternoon sports", stationName: "98.5 The Sports Hub", status: "recording", bytes: 1800000,
            plannedStart: "2026-11-20T14:00:00-05:00", plannedEnd: "2026-11-20T14:20:00-05:00", startedAt: "2026-11-20T14:00:01-05:00", playable: false}
          radio.recordings = snapshot([schedule], [active, complete], 1)
          panel.openRecordings(false)
          capture("recordings")

          radio.recordings = snapshot([], [], 0)
          panel.screenshotView.beginEdit(Object.assign({}, schedule, {id: ""}))
          capture("schedule")
          panel.screenshotView.editing = false

          panel.recordingsOpen = false
          radio.playbackKind = "recording"; radio.recordingTitle = "Afternoon sports"
          radio.duration = 1200; radio.position = 486
          capture("recording-player")

          radio.playbackKind = "live"; radio.position = 0
          panel.settingsOpen = true
          capture("settings")
          panel.settingsOpen = false
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
