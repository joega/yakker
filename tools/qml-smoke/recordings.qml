import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import qs.Commons as Commons
import "plugin" as Plugin
import "plugin/RecordingNotices.js" as Notices
ShellRoot {
  Window { id: window; visible: true; width: 420; height: 650
    color: Commons.Color.popups.background
    Rectangle { anchors.fill: parent; color: Commons.Color.popups.background }
    Plugin.Panel { id: panel; width: window.width; height: window.height }
    Plugin.Panel { id: peer; visible: false; width: window.width; height: window.height }
    Plugin.MarqueeText { id: marqueeFixture; visible: false; z: 100; width: 100; text: "98.5 The Sports Hub"; font.family: "Adwaita Sans"; font.pixelSize: 24; color: Commons.Color.foreground }
    Timer { interval: 300; running: true; onTriggered: tests.runChecks() }
    TestCase { id: tests; name: "FullRecordings"; when: false
      function capture(name) {
        var done = false, saved = false
        window.contentItem.grabToImage(function(result) { saved = result.saveToFile("__OUTPUT__/" + name + ".png"); done = true })
        tryVerify(function() { return done }, 5000); verify(saved, "screenshot failed: " + name)
      }
      function runChecks() {
        try {
          const reducedMotion = Commons.Style.reduceMotion
          Commons.Style.reduceMotion = false
          marqueeFixture.width = marqueeFixture.implicitWidth - 12
          marqueeFixture.visible = true
          const titleHeight = marqueeFixture.height
          verify(marqueeFixture.overflowing && marqueeFixture.motionAllowed)
          compare(marqueeFixture.offset, 0)
          wait(150); compare(marqueeFixture.offset, 0, "Long titles did not pause before scrolling")
          tryVerify(function() { return marqueeFixture.offset < -1 }, 1800)
          tryVerify(function() { return marqueeFixture.offset === -marqueeFixture.overflowDistance }, 1800)
          const endOffset = marqueeFixture.offset
          wait(200); compare(marqueeFixture.offset, endOffset, "The title did not pause at the far end")
          tryVerify(function() { return marqueeFixture.offset > endOffset + 1 }, 1800)
          tryVerify(function() { return Math.abs(marqueeFixture.offset) < 0.1 }, 1800)
          marqueeFixture.text = "TSN 690"
          verify(!marqueeFixture.overflowing && !marqueeFixture.motionAllowed)
          compare(marqueeFixture.offset, 0); compare(marqueeFixture.height, titleHeight)
          marqueeFixture.text = "<b>A very long literal station name</b>"
          compare(marqueeFixture.textFormat, Text.PlainText)
          Commons.Style.reduceMotion = true
          verify(marqueeFixture.overflowing && !marqueeFixture.motionAllowed && marqueeFixture.truncated)
          compare(marqueeFixture.offset, 0); compare(marqueeFixture.height, titleHeight)
          marqueeFixture.visible = false
          Commons.Style.reduceMotion = reducedMotion
          verify(!marqueeFixture.motionAllowed, "A hidden title kept animating")
          let state = Notices.update(null, {recordings:[{id:"old",status:"complete"}]}, true, false)
          compare(state.notices.length, 0, "Historic recording triggered a notification")
          state = Notices.update(state.state, {recordings:[{id:"new",status:"recording"}]}, true, false)
          compare(state.notices.length, 0)
          state = Notices.update(state.state, {recordings:[{id:"new",status:"complete",label:"<img src='remote'>"}]}, true, false)
          compare(state.notices.length, 1)
          verify(Notices.escapeMarkup(state.notices[0].body).indexOf("&lt;img") === 0)
          state = Notices.update(state.state, {recordings:[{id:"new",status:"complete"}]}, true, false)
          compare(state.notices.length, 0, "Duplicate completion notice")
          state = Notices.update(state.state, {recordings:[],error:"Storage full"}, true, false)
          compare(state.notices.length, 1)
          state = Notices.update(state.state, {recordings:[],error:"Storage full"}, true, false)
          compare(state.notices.length, 0)
          state = Notices.update(state.state, {recordings:[{id:"off",status:"recording"}]}, false, true)
          compare(state.notices.length, 0)
          state = Notices.update(state.state, {recordings:[{id:"off",status:"complete"}]}, false, true)
          compare(state.notices.length, 0)
          state = Notices.update(state.state, {recordings:[{id:"on",status:"recording"}]}, true, true)
          compare(state.notices.length, 1)
          panel.radio.noticeQueue = [{kind:"start",title:"queued start",body:"test"}, {title:"queued completion",body:"test"}]
          panel.radio.setRecordingStartNotifications(false)
          compare(panel.radio.noticeQueue.length, 1)
          compare(panel.radio.noticeQueue[0].title, "queued completion")
          panel.radio.configureSettings({recordingNotifications:false})
          compare(panel.radio.noticeQueue.length, 0)
          panel.radio.configureSettings({})
          panel.open(); panel.radio.acquire({})
          tryVerify(function() { return panel.radio.ready && panel.radio.recordings.available && panel.radio.stations.length > 0 }, 5000)
          wait(300)
          compare(panel.testView.dateText(new Date(2026, 10, 20, 14, 30).toISOString()), "Fri Nov 20 2026 02:30PM")
          compare(panel.testView.dateText("2026-11-20T14:30:00+09:00", true), "Fri Nov 20 2026 02:30PM")
          compare(panel.testView.dateText("2026-11-20T00:05:00+14:00", true), "Fri Nov 20 2026 12:05AM")
          compare(panel.testView.dateText("2026-11-20T12:00:00-05:00", true), "Fri Nov 20 2026 12:00PM")
          compare(panel.testView.dateText("2026-03-08T02:30:00+09:00", true), "Sun Mar 8 2026 02:30AM")
          compare(panel.testView.scheduleTimeText("23:59"), "11:59PM")
          compare(panel.testView.dateText(""), "")
          compare(panel.testView.folderUrl("/tmp/Music #1?"), "file:///tmp/Music%20%231%3F")
          compare(panel.testView.pathFromFolderUrl("file:///tmp/Music%20%231%3F"), "/tmp/Music #1?")
          compare(panel.testView.pathFromFolderUrl("file://remote/tmp"), "")
          compare(panel.testView.pathFromFolderUrl("file:///tmp/%00bad"), "")
          verify(panel.testRecordingsButton.visible, "navigation absent")
          compare(panel.radio.stationId, "")
          verify(!panel.radio.hasStation && !panel.radio.wanted)
          verify(!panel.testPlayButton.enabled && !panel.testFavoriteButton.enabled)
          compare(panel.testStationPicker.placeholderText, "Choose a station")
          capture("first-launch")
          panel.radio.play(); verify(!panel.radio.wanted, "Play started without a station choice")
          panel.radio.configureSettings({stationId: "tsn-690"})
          tryVerify(function() { return panel.radio.hasStation && panel.radio.stationId === "tsn-690" }, 3000)
          verify(!panel.radio.wanted, "Restoring the last choice started playback")
          panel.radio.configureSettings({stationId: "removed-station"})
          tryVerify(function() { return panel.radio.stationId === "" }, 3000)
          verify(!panel.radio.hasStation, "Missing saved station picked another broadcaster")
          panel.radio.playRecording("test-recording")
          tryVerify(function() { return panel.radio.playbackState === "playing" && panel.radio.playbackKind === "recording" }, 8000)
          verify(!panel.radio.hasStation && panel.testPlayButton.enabled, "Saved playback requires a live station")
          panel.cursor = 1; panel.activate(); tryVerify(function() { return panel.radio.paused }, 5000)
          panel.cursor = 1; panel.activate(); tryVerify(function() { return !panel.radio.paused }, 5000)
          panel.cursor = 16; panel.activate()
          tryVerify(function() { return panel.testStationPicker.popupOpen }, 2000)
          verify(panel.radio.wanted && panel.radio.playbackKind === "recording", "Choosing a live station interrupted the saved file")
          wait(150); keyClick(Qt.Key_Escape)
          tryVerify(function() { return !panel.testStationPicker.popupOpen }, 2000)
          panel.radio.stop()
          tryVerify(function() { return !panel.radio.wanted && panel.radio.playbackState === "stopped" }, 5000)
          panel.radio.goLive()
          tryVerify(function() { return panel.radio.playbackKind === "live" }, 3000)
          verify(!panel.radio.hasStation && !panel.radio.wanted)
          panel.chooseStation()
          tryVerify(function() { return panel.testStationPicker.popupOpen }, 2000)
          wait(150)
          keyClick(Qt.Key_W); keyClick(Qt.Key_F); keyClick(Qt.Key_A); keyClick(Qt.Key_N); keyClick(Qt.Key_Return)
          console.log("QA: chosen station", panel.radio.stationId, panel.radio.hasStation, panel.testStationPicker.popupOpen, panel.radio.error)
          tryVerify(function() { return panel.radio.stationId === "wfan" && panel.radio.hasStation }, 3000)
          verify(!panel.radio.wanted, "Choosing a station started playback")
          panel.radio.favoriteIds = ["wfan", "tsn-690"]
          tryCompare(panel.testPresets, "count", 2)
          panel.testPresets.itemAt(1).clicked()
          compare(panel.radio.stationId, "tsn-690")
          verify(!panel.radio.wanted, "A favorite preset started a stopped player")
          panel.cursor = 100; panel.activate()
          compare(panel.radio.stationId, "wfan")
          panel.radio.toggleFavorite("tsn-690")
          tryCompare(panel.testPresets, "count", 1)
          compare(panel.testHeading.text, panel.radio.station.name)
          verify(!panel.testHeading.truncated, "The station heading was truncated")
          verify(panel.testBackButton.visible && !panel.testBackButton.enabled)
          verify(panel.testForwardButton.visible && !panel.testForwardButton.enabled)
          verify(!panel.testStopButton.enabled && panel.testPlayButton.enabled)
          compare(panel.testPlayButton.tooltipText, "Play")
          var backCenter = panel.testBackButton.mapToItem(panel, panel.testBackButton.width / 2, panel.testBackButton.height / 2)
          var playCenter = panel.testPlayButton.mapToItem(panel, panel.testPlayButton.width / 2, panel.testPlayButton.height / 2)
          var forwardCenter = panel.testForwardButton.mapToItem(panel, panel.testForwardButton.width / 2, panel.testForwardButton.height / 2)
          verify(backCenter.x < playCenter.x && playCenter.x < forwardCenter.x, "Time skips must flank the primary play control")
          verify(panel.testPlayButton.height > panel.testStopButton.height, "Play/Pause lost primary emphasis")
          capture("player")
          panel.cursor = 14; panel.advanceCursor(1); compare(panel.cursor, 21)
          panel.advanceCursor(-1); compare(panel.cursor, 14)
          panel.activate(); verify(panel.recordingsOpen); verify(panel.testCatcher.blocked)
          compare(panel.testView.libraryPage, 0)
          tryVerify(function() { return panel.testView.testLibrary.count === 1 }, 2000)
          var libraryRow = panel.testView.testLibrary.itemAt(0)
          compare(libraryRow.primaryLabel, "Play")
          verify(!libraryRow.testProgress.visible, "Unstarted audio shows invented listening progress")
          const librarySnapshot = panel.radio.recordings
          panel.radio.recordings = Object.assign({}, librarySnapshot, {recordings:[
            {id:"bounds",label:"<b>Literal title</b>",stationName:"Station",status:"complete",playable:true,durationSeconds:60,resumePosition:90},
            {id:"unknown",label:"Unknown duration",stationName:"Station",status:"complete",playable:true,durationSeconds:0,resumePosition:12},
            {id:"partial",label:"Retained segment",stationName:"Station",status:"partial",playable:true,durationSeconds:120,resumePosition:30},
            {id:"missing",label:"Missing audio",stationName:"Station",status:"missing",playable:false,durationSeconds:60,resumePosition:20}
          ]})
          tryCompare(panel.testView.testLibrary, "count", 4)
          var boundedRow = panel.testView.testLibrary.itemAt(0)
          compare(boundedRow.listeningPosition, 60)
          compare(boundedRow.testProgress.visualPosition, 1)
          compare(boundedRow.primaryLabel, "Play")
          compare(boundedRow.testTitle.text, "<b>Literal title</b>")
          compare(boundedRow.testTitle.textFormat, Text.PlainText)
          var unknownRow = panel.testView.testLibrary.itemAt(1)
          verify(!unknownRow.testProgress.visible, "Unknown duration displayed a percentage")
          verify(unknownRow.progressLabel.indexOf("Duration unavailable") >= 0)
          compare(unknownRow.primaryLabel, "Resume · 0:12")
          var partialRow = panel.testView.testLibrary.itemAt(2)
          compare(partialRow.testProgress.visualPosition, 0.25)
          compare(partialRow.primaryLabel, "Resume · 0:30")
          verify(partialRow.progressLabel.indexOf("Partial") >= 0)
          var missingRow = panel.testView.testLibrary.itemAt(3)
          verify(!missingRow.testPrimary.visible && !missingRow.testProgress.visible)
          verify(missingRow.progressLabel.indexOf("File unavailable") >= 0)
          panel.radio.recordings = librarySnapshot
          tryCompare(panel.testView.testLibrary, "count", 1)
          capture("recordings")
          panel.testView.beginEdit(null)
          tryVerify(function() { return panel.testView.testLabel.activeFocus }, 2000)
          keyClick(Qt.Key_P); keyClick(Qt.Key_M); keyClick(Qt.Key_R)
          compare(panel.testView.testLabel.text, "pmr")
          panel.testView.toggleDay(5); panel.testView.testStart.text = "00:00"; panel.testView.testEnd.text = "00:20"
          var revisionBeforePreview = panel.radio.recordings.revision
          // The review updates automatically without a Preview button.
          tryVerify(function() { return panel.testView.previewSerial === 0 && panel.testView.previewText.indexOf(" · ") >= 0 }, 5000)
          verify(!/\d{4}-\d{2}-\d{2}T?/.test(panel.testView.previewText), "Preview still shows an ISO timestamp")
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
          panel.testView.beginEdit(null)
          panel.testView.scheduleKind = "once"
          panel.testView.testDate.text = "2030-01-02"
          panel.testView.testLabel.text = "One-time fixture"
          panel.testView.scheduleEnabled = false
          panel.testView.save()
          tryVerify(function() { return !panel.testView.pending }, 5000)
          verify(panel.radio.recordingMutationOK, panel.testView.localError)
          compare(panel.radio.recordings.schedules.length, 2)
          verify(panel.radio.recordings.schedules.some(function(s) { return s.kind === "once" && s.date === "2030-01-02" }))
          console.log("QA: schedule order and editor flow")
          const scheduleSnapshot = panel.radio.recordings
          const scheduleBase = {kind:"weekly", weekdays:[1,2,3,4,5], startTime:"14:00", endTime:"14:20", timezone:"America/New_York", stationName:"Station", stationId:"wfan", enabled:true}
          panel.radio.recordings = Object.assign({}, scheduleSnapshot, {schedules:[
            Object.assign({}, scheduleBase, {id:"paused",label:"Paused",enabled:false,nextStart:"2030-01-01T14:00:00-05:00"}),
            Object.assign({}, scheduleBase, {id:"later",label:"Later",nextStart:"2030-01-03T14:00:00-05:00",nextEnd:"2030-01-03T14:20:00-05:00"}),
            Object.assign({}, scheduleBase, {id:"ended",label:"Ended",kind:"once",date:"2020-01-01",nextStart:""}),
            Object.assign({}, scheduleBase, {id:"first",label:"<b>Literal show</b>",nextStart:"2030-01-02T14:00:00+09:00",nextEnd:"2030-01-02T14:20:00+09:00"})
          ]})
          tryCompare(panel.testView.testSchedules, "count", 4)
          compare(panel.testView.sortedSchedules.map(function(s) { return s.id }).join(","), "first,later,ended,paused")
          compare(panel.testView.upcomingCount, 2)
          verify(panel.testView.testSchedules.itemAt(0).nextUp)
          compare(panel.testView.testSchedules.itemAt(0).testTitle.textFormat, Text.PlainText)
          compare(panel.testView.testSchedules.itemAt(0).testTitle.text, "<b>Literal show</b>")
          verify(!panel.testView.testSchedules.itemAt(3).upcoming)
          verify(panel.testView.occurrenceText("2030-01-02T14:00:00+09:00", "2030-01-02T14:20:00+09:00").indexOf("02:00PM–02:20PM") >= 0, "Upcoming times were converted out of the saved timezone")
          verify(panel.testView.occurrenceText("2030-01-02T23:00:00+09:00", "2030-01-03T01:00:00+09:00").indexOf("Thu Jan 3") >= 0, "Overnight upcoming range omitted the end date")
          panel.testView.testSchedules.itemAt(0).testEdit.clicked()
          tryVerify(function() { return panel.testView.testLabel.activeFocus }, 2000)
          compare(panel.testView.editingId, "first")
          compare(panel.testView.testLabel.text, "<b>Literal show</b>")
          panel.testView.testStart.text = "23:00"; panel.testView.testEnd.text = "01:00"
          compare(panel.testView.durationText(), "2 hr · Ends the next day")
          panel.testView.testEnd.text = "15:00"; verify(panel.testView.durationText().indexOf("12 hours") >= 0)
          window.width = 320; window.height = 300
          panel.testView.testSaveSchedule.forceActiveFocus()
          tryVerify(function() {
            const y = panel.testView.testSaveSchedule.mapToItem(panel, 0, 0).y
            const dockTop = panel.testDock.mapToItem(panel, 0, 0).y
            return y >= 0 && y + panel.testView.testSaveSchedule.height <= dockTop
          }, 2000, "Editor Save action was hidden behind the playback dock")
          capture("schedule-editor-small")
          window.width = 420; window.height = 650
          panel.testView.goBack()
          panel.radio.recordings = scheduleSnapshot
          // Create/edit/pause/delete a future one-time schedule in the isolated controller.
          panel.testView.beginEdit(null)
          panel.testView.scheduleKind = "once"; panel.testView.testDate.text = "2030-01-02"
          panel.testView.testLabel.text = "Temporary schedule"
          panel.testView.testSaveSchedule.clicked()
          tryVerify(function() { return !panel.testView.pending }, 5000)
          verify(panel.radio.recordingMutationOK, panel.testView.localError)
          const tempSchedule = panel.radio.recordings.schedules.find(function(s) { return s.label === "Temporary schedule" })
          verify(!!tempSchedule && tempSchedule.enabled)
          panel.testView.beginEdit(tempSchedule)
          panel.testView.testEnabled.clicked()
          verify(!panel.testView.scheduleEnabled)
          panel.testView.testLabel.text = "Edited schedule"
          panel.testView.testSaveSchedule.clicked()
          tryVerify(function() { return !panel.testView.pending }, 5000)
          verify(panel.radio.recordingMutationOK, panel.testView.localError)
          const editedSchedule = panel.radio.recordings.schedules.find(function(s) { return s.id === tempSchedule.id })
          verify(!editedSchedule.enabled && editedSchedule.label === "Edited schedule" && editedSchedule.date === "2030-01-02")
          panel.testView.beginEdit(editedSchedule)
          panel.testView.testDeleteSchedule.clicked()
          compare(panel.radio.recordings.schedules.length, 3, "First delete removed the schedule")
          panel.testView.goBack(); compare(panel.testView.confirmation, "")
          panel.testView.beginEdit(editedSchedule)
          panel.testView.testDeleteSchedule.clicked(); panel.testView.testDeleteSchedule.clicked()
          tryVerify(function() { return !panel.testView.pending && !panel.testView.editing }, 5000)
          verify(panel.radio.recordingMutationOK, panel.testView.localError)
          compare(panel.radio.recordings.schedules.length, 2)
          const realSnapshot = panel.radio.recordings
          const many = []
          for (let i = 0; i < 26; i++) many.push({id:"search-"+i,label:i===25?"Needle":"Other",stationName:"Station",status:i===25?"error":"complete"})
          panel.radio.recordings = Object.assign({}, realSnapshot, {recordings:many})
          panel.testView.libraryPage = 1
          panel.testView.searchText = "needle"
          compare(panel.testView.filteredRecordings.length, 1)
          compare(panel.testView.filteredRecordings[0].id, "search-25")
          tryCompare(panel.testView.testLibrary, "count", 1)
          compare(panel.testView.libraryPage, 0)
          panel.testView.statusFilter = "complete"
          compare(panel.testView.filteredRecordings.length, 0)
          tryCompare(panel.testView.testLibrary, "count", 0)
          panel.testView.searchText = ""; panel.testView.statusFilter = "all"
          panel.radio.recordings = realSnapshot
          panel.testView.beginNow()
          compare(panel.testView.viewMode, "now"); compare(panel.testView.tab, "library")
          panel.testView.testDuration.text = "0"; panel.testView.startNow()
          verify(panel.testView.localError.length > 0 && !panel.testView.pending)
          panel.testView.goBack()
          console.log("QA: missing recording")
          panel.testView.playItem("missing-id")
          tryVerify(function() { return panel.testView.localError.length > 0 }, 5000)
          verify(panel.recordingsOpen, "failed playback left library")
          console.log("QA: recording handoff")
          panel.testView.playItem("test-recording")
          tryVerify(function() { return panel.radio.playbackKind === "recording" && panel.radio.wanted }, 5000)
          verify(panel.recordingsOpen && panel.testDock.visible, "Playing a saved show left the recording library")
          compare(panel.radio.recordingId, "test-recording")
          compare(panel.radio.playbackStation.id, "wbz-fm", "Recording artwork followed the selected live station")
          compare(panel.radio.stationId, "wfan", "Saved playback changed the selected live station")
          console.log("QA: waiting for file playback")
          try { tryVerify(function() { return panel.radio.playbackState === "playing" }, 8000) } catch(e) { console.log("QA: playback state", panel.radio.playbackState, panel.radio.error, panel.radio.wanted); throw e }
          libraryRow = panel.testView.testLibrary.itemAt(0)
          compare(libraryRow.primaryLabel, "Pause")
          libraryRow.testPrimary.clicked()
          tryVerify(function() { return panel.radio.paused }, 5000)
          panel.radio.seekRecording(20)
          tryVerify(function() { return Math.abs(panel.radio.position - 20) < 0.5 }, 5000)
          compare(libraryRow.listeningPosition, panel.radio.position)
          compare(libraryRow.primaryLabel, "Resume · " + panel.radio.clock(panel.radio.position))
          verify(libraryRow.progressLabel.indexOf("0:40 left") >= 0)
          libraryRow.testPrimary.clicked()
          tryVerify(function() { return !panel.radio.paused && panel.radio.position >= 20 }, 5000)
          verify(panel.radio.position < 25, "The row's Resume action restarted playback")
          panel.testDockPlay.clicked()
          tryVerify(function() { return panel.radio.paused }, 5000)
          panel.testDockPlay.forceActiveFocus(); keyClick(Qt.Key_P)
          tryVerify(function() { return !panel.radio.paused }, 5000)
          panel.testView.testSearch.forceActiveFocus(); keyClick(Qt.Key_P); keyClick(Qt.Key_M)
          compare(panel.testView.testSearch.text, "pm", "Library search activated a playback shortcut")
          verify(!panel.radio.paused && !panel.radio.muted)
          panel.testView.testSearch.text = ""
          window.height = 300; window.width = 320
          wait(100)
          var dockY = panel.testDock.mapToItem(panel, 0, 0).y
          verify(dockY >= 0 && dockY + panel.testDock.height <= window.height, "Playback dock fell outside the small popup")
          panel.testScroller.contentY = Math.max(0, panel.testScroller.contentHeight - panel.testScroller.height)
          compare(panel.testDock.mapToItem(panel, 0, 0).y, dockY, "Scrolling moved persistent playback controls")
          capture("library-dock-small")
          window.height = 650; window.width = 420
          panel.chooseStation()
          tryVerify(function() { return !panel.recordingsOpen && panel.testStationPicker.popupOpen }, 2000)
          verify(panel.radio.wanted && panel.radio.playbackKind === "recording", "Opening the station chooser interrupted library playback")
          keyClick(Qt.Key_Escape)
          tryVerify(function() { return !panel.testStationPicker.popupOpen }, 2000)
          // The row-resume checks intentionally advanced the shared player.
          // Reset before the independent transport boundary checks below.
          panel.radio.togglePause()
          tryVerify(function() { return panel.radio.paused }, 5000)
          panel.radio.seekRecording(0)
          tryVerify(function() { return panel.radio.position < 0.5 }, 5000)
          panel.radio.togglePause()
          tryVerify(function() { return !panel.radio.paused }, 5000)
          console.log("QA: pause")
          compare(panel.testPlayButton.tooltipText, "Pause")
          panel.cursor = 1; panel.activate(); tryVerify(function() { return panel.radio.paused }, 5000)
          compare(panel.testPlayButton.tooltipText, "Resume")
          console.log("QA: seek")
          verify(panel.testForwardButton.enabled)
          panel.cursor = 8; panel.activate(); tryVerify(function() { return panel.radio.position > 28 }, 5000)
          verify(panel.testBackButton.enabled)
          panel.cursor = 7; panel.advanceCursor(1); compare(panel.cursor, 1)
          panel.advanceCursor(1); compare(panel.cursor, 8)
          panel.cursor = 7; panel.activate(); tryVerify(function() { return panel.radio.position < 0.5 }, 5000)
          verify(!panel.testBackButton.enabled)
          panel.cursor = 8; panel.activate(); tryVerify(function() { return panel.radio.position > 28 }, 5000)
          console.log("QA: resume")
          panel.cursor = 1; panel.activate(); tryVerify(function() { return !panel.radio.paused }, 5000)
          panel.radio.setPlaybackSpeed(1.5)
          tryVerify(function() { return panel.radio.playbackSpeed === 1.5 }, 5000)
          verify(panel.testSpeedPicker.visible)
          panel.radio.setSleepTimer(15)
          tryVerify(function() { return panel.radio.sleepRemaining > 0 }, 5000)
          verify(panel.testSleepButton.visible && panel.testSleepButton.selected)
          panel.cursor = 19; panel.activate()
          tryVerify(function() { return panel.testSleepPopup.opened }, 2000)
          verify(panel.testCatcher.blocked, "Timer popover did not own keyboard input")
          panel.testSleepMinutes.text = "0"; panel.applySleepTimer()
          verify(panel.testSleepPopup.opened && panel.sleepError.length > 0)
          capture("sleep-timer")
          panel.testSleepMinutes.text = "20"; panel.applySleepTimer()
          tryVerify(function() { return !panel.testSleepPopup.opened && panel.radio.sleepRemaining > 1100 }, 3000)
          panel.cursor = 19; panel.activate()
          tryVerify(function() { return panel.testSleepPopup.opened }, 2000)
          wait(150); keyClick(Qt.Key_Escape)
          verify(!panel.testSleepPopup.opened, "Escape did not close only the timer popover")
          verify(panel.opened)
          capture("file-player")
          panel.cursor = 6; panel.activate(); tryVerify(function() { return !panel.radio.wanted && panel.radio.playbackState === "stopped" }, 5000)
          verify(!panel.testStopButton.enabled && !panel.testBackButton.enabled && !panel.testForwardButton.enabled)
          compare(panel.testPlayButton.tooltipText, "Play")
          compare(panel.radio.sleepRemaining, 0)
          tryVerify(function() { return panel.radio.recordings.recordings[0].resumePosition > 20 }, 3000)
          panel.openRecordings(false)
          libraryRow = panel.testView.testLibrary.itemAt(0)
          verify(libraryRow.primaryLabel.indexOf("Resume · ") === 0, "Saved progress was lost after Stop")
          libraryRow.testPrimary.clicked()
          tryVerify(function() { return panel.radio.playbackState === "playing" && panel.radio.position > 20 }, 8000)
          panel.showPlayer()
          panel.radio.playRecording("test-recording", true)
          tryVerify(function() { return panel.radio.playbackState === "playing" && panel.radio.position < 5 }, 8000)
          panel.radio.stop()
          tryVerify(function() { return panel.radio.playbackState === "stopped" }, 5000)
          panel.radio.goLive(); tryVerify(function() { return panel.radio.playbackKind === "live" }, 5000)
          panel.radio.stop()
          panel.cursor = 14; panel.activate(); verify(panel.recordingsOpen)
          panel.testView.beginEdit(null); tryVerify(function() { return panel.testView.testLabel.activeFocus }, 2000)
          keyClick(Qt.Key_Escape); verify(panel.recordingsOpen && panel.testView.viewMode === "schedules", "Escape did not return to schedules")
          wait(100); keyClick(Qt.Key_Escape); verify(!panel.recordingsOpen, "Second Escape did not return to player")
          panel.testSettingsButton.clicked()
          verify(panel.settingsOpen && panel.testSettings.visible && !panel.testPlayerView.visible, "Settings expanded into the player instead of replacing it")
          verify(panel.testSettingsButton.visible && panel.testSettingsButton.iconName === "close" && !panel.testSettingsBack.visible, "Settings should have one close control in the title row")
          compare(panel.testSectionTitle.text, "· Settings")
          verify(panel.testDock.visible && panel.testStorageButton.visible, "Settings lost persistent playback controls")
          panel.cursor = 4; panel.advanceCursor(1); compare(panel.cursor, 5)
          panel.cursor = 17; panel.activate(); verify(panel.recordingsOpen); verify(panel.testView.storageEditing); compare(panel.testView.tab, "library")
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          tryVerify(function() { var y = panel.testView.testFolder.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testFolder.height <= window.height }, 2000)
          console.log("QA: storage switches and drafts")
          const storedFolder = panel.testView.testFolder.text, storedCap = panel.testView.testCap.text
          const storedAlerts = panel.radio.recordingNotifications, storedStarts = panel.radio.recordingStartNotifications
          verify(panel.testView.testRecordingAlerts.checked && !panel.testView.testRecordingStarts.checked)
          panel.testView.testRecordingStarts.forceActiveFocus(); keyClick(Qt.Key_Space)
          verify(panel.radio.recordingStartNotifications && panel.testView.testRecordingStarts.checked)
          panel.testView.testRecordingAlerts.forceActiveFocus(); keyClick(Qt.Key_Return)
          verify(!panel.radio.recordingNotifications && !panel.testView.testRecordingStarts.enabled)
          verify(panel.testView.testRecordingStarts.checked, "Disabling alerts erased the start notification preference")
          panel.testView.testRecordingAlerts.forceActiveFocus(); keyClick(Qt.Key_Space)
          verify(panel.radio.recordingNotifications && panel.testView.testRecordingStarts.enabled)
          panel.testView.testFolder.text = storedFolder + "/draft"
          panel.testView.testCap.text = "7"
          panel.testView.testStorageCancel.clicked()
          verify(panel.settingsOpen && !panel.recordingsOpen)
          verify(panel.radio.recordingStartNotifications, "Cancel incorrectly rolled back immediate notification settings")
          panel.openSettingsStorage()
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          compare(panel.testView.testFolder.text, storedFolder); compare(panel.testView.testCap.text, storedCap)
          panel.testView.testRecordingStarts.forceActiveFocus(); keyClick(Qt.Key_Return)
          compare(panel.radio.recordingNotifications, storedAlerts); compare(panel.radio.recordingStartNotifications, storedStarts)
          const storageSnapshot = panel.radio.recordings
          panel.radio.recordings = Object.assign({}, storageSnapshot, {usedBytes:storageSnapshot.settings.storageCapBytes*2})
          compare(panel.testView.testStorageUsage.visualPosition, 1, "Storage usage overflowed its track")
          panel.radio.recordings = Object.assign({}, storageSnapshot, {usedBytes:-1})
          compare(panel.testView.testStorageUsage.visualPosition, 0)
          panel.radio.recordings = storageSnapshot
          panel.testView.testFolder.text = "relative-folder"
          panel.testView.testOpenFolder.clicked()
          verify(panel.testView.localError.indexOf("absolute folder") >= 0)
          panel.testView.testFolder.text = storedFolder; panel.testView.localError = ""
          wait(100) // Let the error scroll finish before testing focus navigation.
          panel.testView.testFolder.forceActiveFocus()
          capture("storage")
          window.height = 300; window.width = 320
          tryVerify(function() { var y = panel.testView.testFolder.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testFolder.height <= panel.testDock.mapToItem(panel, 0, 0).y }, 2000)
          panel.testView.testRecordingStarts.forceActiveFocus()
          tryVerify(function() { var y = panel.testView.testRecordingStarts.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testRecordingStarts.height <= panel.testDock.mapToItem(panel, 0, 0).y }, 2000, "Notification switch hidden behind playback dock")
          panel.testView.testStorageSave.forceActiveFocus()
          tryVerify(function() { var y = panel.testView.testStorageSave.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testStorageSave.height <= panel.testDock.mapToItem(panel, 0, 0).y }, 2000, "Save storage hidden behind playback dock")
          capture("storage-small")
          window.height = 650; window.width = 420
          panel.testSettingsBack.clicked()
          tryVerify(function() { return panel.settingsOpen && !panel.recordingsOpen && panel.testSettings.visible }, 2000)
          verify(!panel.testView.storageEditing, "Storage did not return to Settings")
          wait(100); panel.testSettingsButton.clicked(); verify(!panel.recordingsOpen && !panel.settingsOpen)
          panel.openSchedules(); panel.openSettings()
          verify(panel.settingsOpen && !panel.testPlayerView.visible)
          panel.closeSettings()
          verify(panel.recordingsOpen && panel.testView.tab === "schedules", "Settings did not return to the previous section")
          panel.openSettings(); panel.openSettingsStorage()
          verify(panel.testSettingsBack.visible)
          compare(panel.testSectionTitle.text, "· Recording storage")
          panel.testSettingsButton.clicked()
          verify(!panel.settingsOpen && panel.recordingsOpen && panel.testView.tab === "schedules", "X did not return from nested settings to the previous section")
          panel.openSettings(); panel.openSettingsStorage()
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          const previousLimit = panel.radio.recordings.settings.storageCapBytes
          panel.testView.testCap.text = String((previousLimit + 1073741824) / 1073741824)
          const storageDraft = panel.testView.testCap.text, previousRevision = panel.radio.recordings.revision
          const previousSettings = panel.radio.recordings.settings
          panel.radio.recordingSettings(previousRevision, {folder:previousSettings.folder, storageCapBytes:previousLimit+1, freeSpaceReserveBytes:previousSettings.freeSpaceReserveBytes, concurrency:previousSettings.concurrency})
          tryVerify(function() { return panel.radio.recordings.revision > previousRevision }, 5000)
          panel.testView.testStorageSave.clicked()
          tryVerify(function() { return !panel.testView.pending }, 5000)
          verify(!panel.radio.recordingMutationOK && panel.testView.storageEditing, "Stale storage draft was silently applied")
          compare(panel.testView.testCap.text, storageDraft)
          verify(panel.testView.testStorageRefresh.visible)
          panel.testView.testStorageRefresh.clicked()
          compare(panel.testView.testCap.text, storageDraft)
          panel.testView.testStorageSave.clicked()
          tryVerify(function() { return !panel.testView.pending && panel.settingsOpen && !panel.recordingsOpen }, 5000)
          compare(panel.radio.recordings.settings.storageCapBytes, previousLimit + 1073741824)
          panel.closeSettings(); panel.showPlayer()
          panel.radio.testHelper.running = false
          tryVerify(function() { return !panel.radio.ready }, 3000)
          tryVerify(function() { return panel.radio.ready && panel.radio.recordings.available }, 10000)
          verify(!panel.radio.wanted, "helper recovery started foreground playback")
          compare(panel.radio.stationId, "wfan")
          verify(panel.radio.hasStation, "helper recovery lost the last station choice")
          compare(panel.radio.recordings.schedules.length, 2)
          panel.settingsOpen = false; panel.cursor = 13
          var was = panel.radio.favoriteIds.indexOf(panel.radio.stationId) >= 0
          panel.activate(); compare(panel.radio.favoriteIds.indexOf(panel.radio.stationId) >= 0, !was)
          panel.openRecordings(false)
          libraryRow = panel.testView.testLibrary.itemAt(0)
          libraryRow.testDetails.clicked()
          verify(libraryRow.expanded && libraryRow.testRestart.visible)
          libraryRow.testDelete.clicked()
          compare(panel.testView.confirmation, "deleteRecording:test-recording")
          verify(panel.radio.recordings.recordings.some(function(r) { return r.id === "test-recording" }), "First delete click removed audio without confirmation")
          libraryRow.testDetails.clicked()
          compare(panel.testView.confirmation, "", "Hiding details retained an armed delete action")
          libraryRow.testDetails.clicked()
          libraryRow.testDelete.clicked(); libraryRow.testDelete.clicked()
          tryVerify(function() { return !panel.testView.pending && panel.radio.recordings.recordings.length === 0 }, 5000)
          tryVerify(function() { return panel.testView.testSearch.activeFocus }, 2000)
          panel.showPlayer()
          panel.settingsOpen = true; panel.openStationEditor(false)
          tryVerify(function() { return panel.testName.activeFocus }, 2000)
          keyClick(Qt.Key_P); keyClick(Qt.Key_M); compare(panel.testName.text, "pm")
          console.log("YAKKER_FULL_RECORDINGS_REAL_CONTROLLER_PASS")
        } catch(e) { console.error("YAKKER_FULL_RECORDINGS_REAL_CONTROLLER_FAIL", e, e.stack) }
        panel.radio.release(); Qt.quit()
      }
    }
  }
}
