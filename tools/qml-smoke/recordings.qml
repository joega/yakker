import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import qs.Commons as Commons
import "plugin" as Plugin
ShellRoot {
  Window { id: window; visible: true; width: 380; height: 650
    color: Commons.Color.popups.background
    Rectangle { anchors.fill: parent; color: Commons.Color.popups.background }
    Plugin.Panel { id: panel; width: window.width; height: window.height }
    Plugin.Panel { id: peer; visible: false; width: window.width; height: window.height }
    Timer { interval: 300; running: true; onTriggered: tests.runChecks() }
    TestCase { id: tests; name: "FullRecordings"; when: false
      function capture(name) {
        var done = false, saved = false
        window.contentItem.grabToImage(function(result) { saved = result.saveToFile("__OUTPUT__/" + name + ".png"); done = true })
        tryVerify(function() { return done }, 5000); verify(saved, "screenshot failed: " + name)
      }
      function runChecks() {
        try {
          panel.open(); panel.radio.acquire({})
          tryVerify(function() { return panel.radio.ready && panel.radio.recordings.available && panel.radio.stations.length > 0 }, 5000)
          wait(300)
          verify(panel.testRecordingsButton.visible, "navigation absent")
          capture("player")
          panel.cursor = 14; panel.advanceCursor(1); compare(panel.cursor, 4)
          panel.advanceCursor(-1); compare(panel.cursor, 14)
          panel.activate(); verify(panel.recordingsOpen); verify(panel.testCatcher.blocked)
          capture("recordings")
          panel.testView.beginEdit(null)
          tryVerify(function() { return panel.testView.testLabel.activeFocus }, 2000)
          keyClick(Qt.Key_P); keyClick(Qt.Key_M); keyClick(Qt.Key_R)
          compare(panel.testView.testLabel.text, "pmr")
          panel.testView.toggleDay(5); panel.testView.testStart.text = "00:00"; panel.testView.testEnd.text = "00:20"
          var revisionBeforePreview = panel.radio.recordings.revision
          panel.testView.previewNext()
          tryVerify(function() { return panel.testView.previewSerial === 0 && panel.testView.previewText.indexOf("Next:") === 0 }, 5000)
          compare(panel.radio.recordings.revision, revisionBeforePreview)
          panel.testView.testStart.text = "00:01"
          compare(panel.testView.previewText, "")
          panel.testView.testStart.text = "00:00"
          peer.testView.beginEdit(null); peer.testView.testLabel.text = "Other monitor's draft"
          var current = panel.radio.recordings.settings
          panel.radio.recordingSettings(panel.radio.recordings.revision, {folder:current.folder, storageCapBytes:current.storageCapBytes + 1, freeSpaceReserveBytes:current.freeSpaceReserveBytes, concurrency:current.concurrency})
          tryVerify(function() { return panel.radio.recordings.revision > revisionBeforePreview }, 5000)
          panel.testView.save()
          tryVerify(function() { return !panel.testView.pending }, 5000)
          verify(!panel.radio.recordingMutationOK && panel.testView.editing)
          compare(panel.testView.testLabel.text, "pmr")
          panel.testView.testRefreshDraft.forceActiveFocus(); keyClick(Qt.Key_Return)
          compare(panel.testView.editRevision, panel.radio.recordings.revision)
          compare(panel.testView.testLabel.text, "pmr")
          capture("editor")
          console.log("QA: save schedule")
          panel.testView.scheduleEnabled = false // No calendar-dependent network job in UI QA.
          panel.testView.save()
          tryVerify(function() { return !panel.testView.pending }, 5000)
          verify(panel.radio.recordingMutationOK, panel.testView.localError)
          compare(panel.radio.recordings.schedules.length, 1)
          compare(panel.radio.recordings.schedules[0].label, "pmr")
          verify(peer.testView.editing); compare(peer.testView.testLabel.text, "Other monitor's draft"); compare(peer.testView.localError, "")
          compare(panel.testView.sizeText(4000000), "3.8 MiB")
          console.log("QA: missing recording")
          panel.testView.playItem("missing-id")
          tryVerify(function() { return panel.testView.localError.length > 0 }, 5000)
          verify(panel.recordingsOpen, "failed playback left library")
          console.log("QA: recording handoff")
          panel.testView.playItem("test-recording")
          tryVerify(function() { return !panel.recordingsOpen && panel.radio.playbackKind === "recording" && panel.radio.wanted }, 5000)
          compare(panel.radio.recordingId, "test-recording")
          console.log("QA: waiting for file playback")
          try { tryVerify(function() { return panel.radio.playbackState === "playing" }, 8000) } catch(e) { console.log("QA: playback state", panel.radio.playbackState, panel.radio.error, panel.radio.wanted); throw e }
          console.log("QA: pause")
          panel.radio.togglePause(); tryVerify(function() { return panel.radio.paused }, 5000)
          console.log("QA: seek")
          panel.radio.seekRecording(20); tryVerify(function() { return panel.radio.position > 18 }, 5000)
          console.log("QA: resume")
          panel.radio.togglePause(); tryVerify(function() { return !panel.radio.paused }, 5000)
          capture("file-player")
          panel.radio.goLive(); tryVerify(function() { return panel.radio.playbackKind === "live" }, 5000)
          panel.radio.stop()
          panel.cursor = 14; panel.activate(); verify(panel.recordingsOpen)
          panel.testView.beginEdit(null); tryVerify(function() { return panel.testView.testLabel.activeFocus }, 2000)
          keyClick(Qt.Key_Escape); verify(!panel.recordingsOpen, "Escape did not return to player")
          panel.settingsOpen = true; verify(panel.testStorageButton.visible)
          panel.cursor = 17; panel.activate(); verify(panel.recordingsOpen); verify(panel.testView.storageEditing)
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          tryVerify(function() { var y = panel.testView.testFolder.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testFolder.height <= window.height }, 2000)
          capture("storage")
          window.height = 300
          tryVerify(function() { var y = panel.testView.testFolder.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testFolder.height <= window.height }, 2000)
          capture("storage-small")
          keyClick(Qt.Key_Escape); verify(!panel.recordingsOpen)
          panel.radio.testHelper.running = false
          tryVerify(function() { return !panel.radio.ready }, 3000)
          tryVerify(function() { return panel.radio.ready && panel.radio.recordings.available }, 10000)
          verify(!panel.radio.wanted, "helper recovery started foreground playback")
          compare(panel.radio.recordings.schedules.length, 1)
          panel.settingsOpen = false; panel.cursor = 13
          var was = panel.radio.favoriteIds.indexOf(panel.radio.stationId) >= 0
          panel.activate(); compare(panel.radio.favoriteIds.indexOf(panel.radio.stationId) >= 0, !was)
          panel.settingsOpen = true; panel.openStationEditor(false)
          tryVerify(function() { return panel.testName.activeFocus }, 2000)
          keyClick(Qt.Key_P); keyClick(Qt.Key_M); compare(panel.testName.text, "pm")
          console.log("YAKKER_FULL_RECORDINGS_REAL_CONTROLLER_PASS")
        } catch(e) { console.error("YAKKER_FULL_RECORDINGS_REAL_CONTROLLER_FAIL", e) }
        panel.radio.release(); Qt.quit()
      }
    }
  }
}
