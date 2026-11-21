import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import qs.Commons as Commons
import qs.Ui as Ui
import "plugin" as Plugin
import "plugin/RecordingNotices.js" as Notices
ShellRoot {
  Window { id: window; visible: true; width: 420; height: 650
    color: Commons.Color.popups.background
    Rectangle { anchors.fill: parent; color: Commons.Color.popups.background }
    Plugin.Panel { id: panel; width: window.width; height: window.height }
    Plugin.Panel { id: peer; visible: false; width: window.width; height: window.height }
    Plugin.MarqueeText { id: marqueeFixture; visible: false; z: 100; width: 100; text: "98.5 The Sports Hub"; font.family: "Adwaita Sans"; font.pixelSize: 24; color: Commons.Color.foreground }
    QtObject {
      id: barConfig
      property bool vertical: false
      property int barSize: 32
      property string fontFamily: "Adwaita Sans"
      property color barForeground: Commons.Color.foreground
      property color background: Commons.Color.background
      property color urgent: Commons.Color.urgent
      property bool foregroundAnimationEnabled: false
      property var shell: null
      function registerClickTarget(item) {}
      function unregisterClickTarget(item) {}
      function hideTooltip(item) {}
      function showTooltip(item, text) {}
    }
    Plugin.BarWidget { id: barFixture; visible: false; z: 200; bar: barConfig; width: implicitWidth; height: implicitHeight; anchors.centerIn: parent }
    // The bar owns this native plain-text surface; render the production string
    // with the same font, border and insets in the isolated test window.
    Ui.BorderSurface {
      id: tooltipFixture
      visible: false; z: 300
      anchors.centerIn: parent
      width: tooltipPreview.implicitWidth + 20
      height: tooltipPreview.implicitHeight + 14
      color: Commons.Color.tooltip.background
      borderSpec: Commons.Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border, 1)
      radius: Commons.Style.cornerRadius
      Text {
        id: tooltipPreview
        anchors.centerIn: parent
        text: barFixture.testButton.tooltipText
        textFormat: Text.PlainText
        color: Commons.Color.tooltip.text
        font.family: barConfig.fontFamily
        font.pixelSize: Commons.Style.font.body
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
    Timer { interval: 300; running: true; onTriggered: tests.runChecks() }
    TestCase { id: tests; name: "FullRecordings"; when: false
      function capture(name) {
        var done = false, saved = false
        window.contentItem.grabToImage(function(result) { saved = result.saveToFile("__OUTPUT__/" + name + ".png"); done = true })
        tryVerify(function() { return done }, 5000); verify(saved, "screenshot failed: " + name)
      }
      function captureBar(name) {
        wait(80)
        var done = false, saved = false
        barFixture.grabToImage(function(result) { saved = result.saveToFile("__OUTPUT__/" + name + ".png"); done = true })
        tryVerify(function() { return done }, 5000); verify(saved, "bar screenshot failed: " + name)
      }
      function captureTooltip(name) {
        tooltipFixture.visible = true
        wait(60)
        verify(tooltipFixture.width <= window.width, "Tooltip exceeded the test window width")
        var done = false, saved = false
        tooltipFixture.grabToImage(function(result) { saved = result.saveToFile("__OUTPUT__/" + name + ".png"); done = true })
        tryVerify(function() { return done }, 5000); verify(saved)
        tooltipFixture.visible = false
      }
      function checkBarStates() {
        const radio = panel.radio
        const keys = ["wanted","paused","playbackState","playbackKind","bufferMinutes","temporaryBuffer","dvr","position","bufferStart","bufferEnd","bufferExpired","station","stationId","recordingId","recordingTitle","duration","title","recordings"]
        const saved = keys.map(function(key) { return radio[key] })
        try {
          barFixture.visible = true
          radio.station = radio.stations.find(function(station) { return station.id === "wip-fm" }); radio.stationId = "wip-fm"
          radio.playbackKind = "live"; radio.wanted = true; radio.paused = false; radio.playbackState = "playing"
          radio.dvr = false; radio.temporaryBuffer = false
          verify(barFixture.testButton.tooltipText.split("\n").indexOf("Live") >= 0); compare(barFixture.testStateIcon.name, "play")
          compare(barFixture.testLogo.station.id, "wip-fm")
          verify(barFixture.testButton.tooltipText.indexOf("Philadelphia · United States") >= 0)
          captureTooltip("tooltip-live")
          captureBar("bar-live")
          radio.station = radio.stations.find(function(station) { return station.id === "weei-fm" }); radio.stationId = "weei-fm"
          radio.paused = true; radio.playbackState = "paused"; radio.temporaryBuffer = true
          radio.dvr = true; radio.bufferStart = 0; radio.bufferEnd = 75; radio.position = 30
          verify(barFixture.testButton.tooltipText.indexOf("Paused · buffering") >= 0); compare(barFixture.testStateIcon.name, "pause")
          verify(barFixture.testLogo.station.id === "weei-fm", "Pausing removed the source artwork")
          verify(barFixture.testButton.tooltipText.indexOf("Stream stays connected") >= 0)
          verify(barFixture.testButton.tooltipText.indexOf("0:45 behind live") >= 0)
          verify(barFixture.testButton.tooltipText.indexOf("Temporary replay · 1:15 available") >= 0)
          captureTooltip("tooltip-paused-buffering")
          captureBar("bar-paused-buffering")
          radio.station = radio.stations.find(function(station) { return station.id === "bbc-radio-5-live" }); radio.stationId = "bbc-radio-5-live"
          barConfig.vertical = true
          captureBar("bar-vertical-paused")
          verify(barFixture.width <= barConfig.barSize, "The vertical bar expanded to fit the horizontal controls")
          barConfig.vertical = false
          radio.wanted = false; radio.paused = false; radio.playbackState = "stopped"
          verify(barFixture.testButton.tooltipText.indexOf("Listening stopped") >= 0); compare(barFixture.testStateIcon.name, "stop")
          verify(!barFixture.testLogo.station.id)
          verify(barFixture.testButton.tooltipText.indexOf("Stream disconnected · Replay cleared") >= 0)
          radio.recordings = Object.assign({}, radio.recordings, {activeCount:1})
          verify(barFixture.testRecordingIndicator.visible && barFixture.testStateIcon.name === "stop", "Recording activity hid the stopped listening state")
          const captureRows = [
            {id:"active-1",status:"recording",label:"Morning drive",stationName:"WEEI 93.7"},
            {id:"active-2",status:"recording",label:"Football review",stationName:"talkSPORT"},
            {id:"history",status:"complete",label:"Historic recording",stationName:"WFAN"}
          ]
          radio.recordings = Object.assign({}, radio.recordings, {activeCount:2,recordings:captureRows})
          verify(barFixture.testButton.tooltipText.indexOf("Recording now · 2 active shows") >= 0)
          verify(barFixture.testButton.tooltipText.indexOf("Morning drive · WEEI 93.7") >= 0)
          verify(barFixture.testButton.tooltipText.indexOf("Football review · talkSPORT") >= 0)
          verify(barFixture.testButton.tooltipText.indexOf("Historic recording") < 0, "Tooltip listed completed recordings as active")
          verify(barFixture.testButton.tooltipText.indexOf("Replay ·") < 0 && barFixture.testButton.tooltipText.indexOf("Temporary replay") < 0, "Stopped tooltip advertises active buffering")
          captureTooltip("tooltip-stopped-recordings")
          captureBar("bar-stopped-recording")
          radio.recordings = saved[keys.indexOf("recordings")]
          radio.wanted = true; radio.paused = true; radio.playbackState = "retrying"
          verify(barFixture.testButton.tooltipText.indexOf("Reconnecting") >= 0)
          verify(barFixture.testButton.tooltipText.indexOf("Stream stays connected") < 0, "Reconnect claims to preserve paused audio")
          radio.playbackState = "error"
          compare(barFixture.testStateIcon.name, "warning"); verify(barFixture.testButton.tooltipText.indexOf("Unable to play") >= 0)
          captureBar("bar-error")
          radio.playbackKind = "recording"; radio.recordingId = "test-recording"; radio.recordingTitle = "Saved show"
          radio.playbackState = "paused"
          verify(barFixture.testButton.tooltipText.indexOf("Recording paused") >= 0)
          verify(barFixture.testButton.tooltipText.indexOf("buffering") < 0, "A saved recording is labeled as buffering")
          radio.duration = 60; radio.position = 23
          verify(barFixture.testButton.tooltipText.indexOf("Saved recording · 98.5 The Sports Hub") >= 0, "Saved-show tooltip followed the selected live station")
          verify(barFixture.testButton.tooltipText.indexOf("0:23 / 1:00") >= 0)
          captureTooltip("tooltip-paused-recording")
          captureBar("bar-paused-recording")
          radio.paused = false; radio.playbackState = "playing"
          verify(barFixture.testButton.tooltipText.indexOf("Playing recording") >= 0)
          verify(!barFixture.testRecordingIndicator.visible, "Saved playback looks like a recording capture")
          radio.playbackKind = "live"; radio.station = Object.assign({}, radio.station, {name:"<b>Literal name</b>\nUntrusted title " + "long text ".repeat(40)})
          const literalTooltip = barFixture.testButton.tooltipText
          verify(literalTooltip.indexOf("<b>Literal name</b>") === 0, "Tooltip changed literal station text into markup")
          verify(literalTooltip.indexOf("\nUntrusted title") < 0, "Station metadata injected a tooltip section")
          compare(tooltipPreview.textFormat, Text.PlainText)
          captureTooltip("tooltip-long-literal")
        } finally {
          keys.forEach(function(key,index) { radio[key] = saved[index] })
          barConfig.vertical = false; barFixture.visible = false; tooltipFixture.visible = false
        }
      }
      function checkFields() {
        const view = panel.testView
        try {
          panel.openRecordings(false)
          tryVerify(function() { return view.testSearch.activeFocus }, 2000)
          compare(view.testSearch.height,view.testStatus.testTrigger.height, "Search and dropdown heights differ")
          compare(view.testSearch.font.pixelSize,view.testStatus.testTrigger.font.pixelSize)
          const inset = view.testSearch.leftPadding
          panel.testSettingsButton.forceActiveFocus()
          mouseMove(view.testSearch,12,view.testSearch.height/2); wait(30)
          compare(view.testSearch.leftPadding,inset, "Hover moved the search text")
          view.testSearch.forceActiveFocus(); compare(view.testSearch.leftPadding,inset, "Focus moved the search text")
          keyClick(Qt.Key_P); keyClick(Qt.Key_M)
          compare(view.testSearch.text,"pm")
          verify(view.testSearch.testClear.visible)
          view.testSearch.testClear.clicked()
          verify(!view.testSearch.text && view.testSearch.activeFocus)
          view.testStatus.testTrigger.forceActiveFocus(); keyClick(Qt.Key_Return)
          tryVerify(function() { return view.testStatus.popupOpen && view.testStatus.testResults.activeFocus },2000)
          keyClick(Qt.Key_Down); keyClick(Qt.Key_Down)
          console.log("QA field selection",view.testStatus.testResults.currentIndex,view.testStatus.filtered.length)
          keyClick(Qt.Key_Return)
          console.log("QA field chosen",view.statusFilter,view.testStatus.popupOpen)
          tryVerify(function() { return !view.testStatus.popupOpen && view.statusFilter === "complete" },2000)
          view.clearLibraryFilters()
          compare(view.testStatus.value,"all", "Clearing filters left the dropdown selection stale")
          window.width=288; window.height=300; wait(50)
          verify(view.testStatus.y > view.testSearch.y, "Narrow library filters did not stack")
          compare(view.testSearch.width,view.width); compare(view.testStatus.width,view.width)
          view.testStatus.testTrigger.forceActiveFocus(); wait(50); keyClick(Qt.Key_Return)
          tryVerify(function() { return view.testStatus.popupOpen },2000)
          wait(50)
          const popup=view.testStatus.testPopup, corner=popup.background.mapToItem(window.contentItem,0,0)
          verify(corner.x>=0 && corner.y>=0 && corner.x+popup.width<=window.width && corner.y+popup.height<=window.height, "Dropdown escaped the compact window")
          capture("filter-dropdown-small")
          keyClick(Qt.Key_Escape)
          tryVerify(function() { return !view.testStatus.popupOpen && view.testStatus.activeFocus },2000)
          window.width=420;window.height=650
          view.beginEdit(null)
          tryVerify(function() { return view.testLabel.activeFocus },2000)
          const picker=view.testStationPicker
          picker.testTrigger.forceActiveFocus(); wait(50); keyClick(Qt.Key_Return)
          tryVerify(function() { return picker.popupOpen && picker.testSearch.activeFocus },2000)
          picker.testSearch.text="WFAN New York"
          tryCompare(picker.testResults,"count",1)
          keyClick(Qt.Key_Return)
          tryVerify(function() { return !picker.popupOpen && view.stationValue === "wfan" },2000)
          verify(!panel.radio.wanted && !panel.radio.hasStation, "Schedule station selection tuned live playback")
          picker.open(); tryVerify(function() { return picker.testSearch.activeFocus },2000)
          picker.testSearch.text="no matching option"
          compare(picker.filtered.length,0); keyClick(Qt.Key_Return); verify(picker.popupOpen)
          keyClick(Qt.Key_Escape)
          tryVerify(function() { return !picker.popupOpen && picker.activeFocus },2000)
          compare(view.stationValue,"wfan", "Cancel changed the schedule station")
          view.beginEdit(null)
          compare(picker.value,view.stationValue, "Editing another schedule left stale station selection")
        } finally {
          view.testStatus.close(); view.testStationPicker.close()
          view.clearLibraryFilters(); view.editing=false
          window.width=420;window.height=650;panel.showPlayer()
        }
      }
      function checkNavigationRows() {
        const savedFont = Commons.Style.fontBaseSize
        function fit(tabs, action) {
          tabs.forEach(function(tab) {
            verify(tab.width + 0.5 >= tab.implicitWidth, tab.text + " label is constrained at " + window.width + "px / " + Commons.Style.fontBaseSize + "px font")
            verify(tab.leftAlign, "Tab labels use different alignment")
          })
          const last = tabs[tabs.length - 1]
          verify(last.mapToItem(panel, last.width, 0).x <= action.mapToItem(panel, 0, 0).x, "Tab labels overlap the header action")
          const center = tabs[0].mapToItem(panel, 0, tabs[0].height / 2).y
          verify(Math.abs(action.mapToItem(panel, 0, action.height / 2).y - center) <= 0.5, "Header action is vertically misaligned")
          if (action.mapToItem(panel, action.width, 0).x > panel.width + 0.5)
            console.log("QA NAV overflow",Commons.Style.fontBaseSize,window.width,action.mapToItem(panel,action.width,0).x)
          verify(action.mapToItem(panel, action.width, 0).x <= panel.width + 0.5, "Header action overflowed the available width")
        }
        try {
          for (const base of [savedFont, Math.max(savedFont, 14)]) {
            Commons.Style.fontBaseSize = base
            const widths = base === savedFont ? [420,360,320,288] : [420,360,320]
            for (const width of widths) {
              window.width = width; wait(20)
              panel.showPlayer(); wait(20)
              const main = [panel.testListenButton,panel.testRecordingsButton,panel.testSchedulesButton]
              fit(main, panel.testSettingsButton)
              const font = main[0].fontSize, padding = main[0].horizontalPadding
              const actionX = panel.testSettingsButton.mapToItem(panel, 0, 0).x
              if (base === savedFont && width === 288) capture("main-tabs-compact")
              panel.openSettings(); wait(20)
              const tabs = [0,1,2,3].map(function(i) { return panel.testSettingsTabs.itemAt(i) })
              const sizes = tabs.map(function(tab) { return tab.width })
              for (let i = 0; i < tabs.length; i++) {
                panel.selectSettingsTab(["listening","storage","alerts","stations"][i], true); wait(10)
                fit(tabs, panel.testSettingsClose)
                tabs.forEach(function(tab,j) {
                  if (tab.width !== sizes[j] || tab.fontSize !== font || tab.horizontalPadding !== padding)
                    console.log("QA NAV mismatch",base,width,i,tab.text,tab.width,sizes[j],tab.fontSize,font,tab.horizontalPadding,padding)
                  compare(tab.width,sizes[j], "Selecting " + i + " changed " + tab.text + " from " + sizes[j] + " to " + tab.width)
                  compare(tab.fontSize,font, "Tab font differs: " + tab.fontSize + " vs " + font)
                  compare(tab.horizontalPadding,padding, "Tab inset differs: " + tab.horizontalPadding + " vs " + padding)
                })
              }
              compare(panel.testSettingsClose.mapToItem(panel, 0, 0).x, actionX)
              if (base === savedFont && width === 288) { panel.selectSettingsTab("listening",true); wait(20); capture("settings-tabs-compact") }
            }
          }
          Commons.Style.fontBaseSize = savedFont; window.width = 420
          panel.showPlayer(); panel.testCatcher.forceActiveFocus(); wait(20)
          mouseMove(panel.testListenButton,8,panel.testListenButton.height/2); wait(Commons.Style.duration(160) + 20)
          const hoverFill = panel.testListenButton.color.toString()
          panel.testListenButton.forceActiveFocus(); mouseMove(panel,panel.width-2,panel.height-2); wait(Commons.Style.duration(160) + 20)
          const focusFill = panel.testListenButton.color.toString()
          panel.openSettings(); wait(Commons.Style.duration(160) + 20)
          const listening = panel.testSettingsTabs.itemAt(0)
          mouseMove(listening,8,listening.height/2); wait(Commons.Style.duration(160) + 20); if (listening.color.toString() !== hoverFill) console.log("QA NAV hover",listening.color.toString(),hoverFill,listening.hot,listening.activeFocus,listening.hasCursor,panel.keyboardNavigation)
          compare(listening.color.toString(),hoverFill)
          listening.forceActiveFocus(); mouseMove(panel,panel.width-2,panel.height-2); wait(Commons.Style.duration(160) + 20); compare(listening.color.toString(),focusFill)
        } finally {
          Commons.Style.fontBaseSize = savedFont
          window.width = 420; window.height = 650
          panel.showPlayer()
        }
      }
      function checkPlaybackStates() {
        const radio = panel.radio
        const keys = ["wanted","paused","playbackState","playbackKind","bufferMinutes","temporaryBuffer","dvr","position","bufferStart","bufferEnd","bufferExpired","station","stationId","sleepRemaining","duration","recordings"]
        const saved = keys.map(function(key) { return radio[key] })
        try {
          radio.station = radio.stations.find(function(station) { return station.id === "tsn-690" })
          radio.stationId = "tsn-690"
          radio.playbackKind = "live"; radio.wanted = true; radio.paused = true; radio.playbackState = "paused"
          radio.bufferMinutes = 0; radio.temporaryBuffer = true; radio.dvr = true
          radio.bufferStart = 0; radio.bufferEnd = 45; radio.position = 15; radio.sleepRemaining = 0
          verify(panel.testPlayerStatus.text.indexOf("Paused · buffering") === 0)
          verify(panel.testPlaybackHint.text.indexOf("Stream stays connected") === 0)
          verify(panel.testTimeline.visible && panel.testPlayButton.iconName === "play" && panel.testStopButton.enabled)
          capture("paused-live")
          panel.openRecordings(false)
          compare(panel.testDockStatus.text, "Paused · buffering")
          radio.bufferMinutes = 15; radio.temporaryBuffer = false
          panel.openSchedules(); compare(panel.testDockStatus.text, "Paused · buffering")
          radio.station = radio.stations.find(function(station) { return station.id === "weei-fm" }); radio.stationId = "weei-fm"
          panel.openSettings()
          window.width = 320; window.height = 300; wait(50)
          compare(panel.testDockStatus.text, "Paused · buffering")
          verify(!panel.testDockStatus.truncated, "The compact player hides the buffering state")
          capture("paused-buffering-dock-small")
          radio.recordings = Object.assign({}, radio.recordings, {activeCount:1})
          panel.testCatcher.forceActiveFocus(); panel.cursor = 43
          keyClick(Qt.Key_Tab); compare(panel.cursor, 58)
          keyClick(Qt.Key_Return)
          verify(panel.recordingsOpen && !panel.settingsOpen, "Settings recording indicator did not open Library")
          verify(radio.wanted && radio.paused, "Header navigation interrupted paused playback")
          panel.openSettings(); wait(50)
          capture("settings-capture-small")
          radio.bufferExpired = true
          verify(panel.testPlaybackHint.text.indexOf("Earlier audio expired") >= 0, "Expired replay still promises the original paused position")
          radio.bufferExpired = false
          radio.wanted = false; radio.paused = false; radio.playbackState = "stopped"
          radio.dvr = false; radio.position = 0; radio.bufferStart = 0; radio.bufferEnd = 0
          compare(panel.testDockStatus.text, "Listening stopped")
          verify(panel.testPlaybackHint.text.indexOf("Stream disconnected · Replay cleared") === 0)
          verify(!panel.testDockStop.enabled)
          window.width = 420; window.height = 650
          radio.station = radio.stations.find(function(station) { return station.id === "bbc-radio-5-live" }); radio.stationId = "bbc-radio-5-live"
          panel.showPlayer(); wait(50)
          verify(!panel.testTimeline.visible, "Stopped playback still displays the configured replay buffer")
          compare(panel.testPlayerStatus.text, "Listening stopped")
          capture("stopped-live")
          radio.wanted = true; radio.paused = true; radio.playbackState = "retrying"
          verify(radio.statusText.indexOf("Reconnecting") === 0 && !panel.playbackHint, "A reconnecting stream claims to preserve the paused position")
        } finally {
          keys.forEach(function(key,index) { radio[key] = saved[index] })
          window.width = 420; window.height = 650
          panel.showPlayer()
        }
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
          checkFields()
          checkNavigationRows()
          checkPlaybackStates()
          checkBarStates()
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
          console.log("QA: keyboard tab strips")
          const navigationVolume = panel.radio.volume
          panel.testCatcher.forceActiveFocus(); panel.cursor = 20
          keyClick(Qt.Key_Right)
          tryVerify(function() { return panel.recordingsOpen && panel.testRecordingsButton.activeFocus }, 2000)
          compare(panel.cursor, 14)
          keyClick(Qt.Key_Right)
          tryVerify(function() { return panel.testView.tab === "schedules" && panel.testSchedulesButton.activeFocus }, 2000)
          keyClick(Qt.Key_Left)
          tryVerify(function() { return panel.testView.tab === "library" && panel.testRecordingsButton.activeFocus }, 2000)
          keyClick(Qt.Key_Left)
          tryVerify(function() { return !panel.recordingsOpen && panel.testCatcher.activeFocus }, 2000)
          compare(panel.radio.volume, navigationVolume, "Tab arrows changed volume")
          panel.cursor = -1; keyClick(Qt.Key_Tab); compare(panel.cursor, 20)
          panel.cursor = -1; keyClick(Qt.Key_Backtab); compare(panel.cursor, 2)
          const navigationMuted = panel.radio.muted
          keyClick(Qt.Key_M, Qt.ControlModifier)
          compare(panel.radio.muted, navigationMuted, "Modified shortcut toggled mute")
          console.log("QA: station picker search and hearts")
          panel.radio.favoriteIds = []
          panel.testStationPicker.open()
          tryVerify(function() { return panel.testStationPicker.testSearch.activeFocus }, 2000)
          panel.testStationPicker.testSearch.text = "weei Boston US"
          tryVerify(function() { return panel.testStationPicker.testList.count === 1 && !!panel.testStationPicker.testList.itemAtIndex(0) }, 2000)
          var pickerRow = panel.testStationPicker.testList.itemAtIndex(0)
          compare(pickerRow.testTitle.text, "WEEI 93.7")
          pickerRow.testFavorite.clicked()
          verify(panel.radio.favoriteIds.indexOf("weei-fm") >= 0)
          verify(panel.testStationPicker.popupOpen && panel.radio.stationId === "wfan" && !panel.radio.wanted, "Favorite control tuned a station or closed the picker")
          compare(panel.testStationPicker.testSearch.text, "weei Boston US")
          tryVerify(function() { return panel.testStationPicker.highlightedValue === "weei-fm" }, 2000)
          panel.testStationPicker.testList.forceActiveFocus(); keyClick(Qt.Key_F)
          verify(panel.radio.favoriteIds.indexOf("weei-fm") < 0 && panel.testStationPicker.popupOpen)
          panel.testStationPicker.testClear.clicked()
          compare(panel.testStationPicker.testSearch.text, "")
          panel.testStationPicker.testFavorites.clicked()
          compare(panel.testStationPicker.filtered.length, 0)
          compare(panel.testStationPicker.testEmpty.title, "No favorites yet")
          panel.testStationPicker.testEmpty.primaryControl.clicked()
          verify(!panel.testStationPicker.favoritesOnly && panel.testStationPicker.filtered.length > 0)
          panel.testStationPicker.testSearch.text = "does not exist"
          compare(panel.testStationPicker.testEmpty.title, "No matching stations")
          window.width = 320; window.height = 300; wait(50)
          panel.testStationPicker.testEmpty.primaryControl.forceActiveFocus()
          tryVerify(function() { const y = panel.testStationPicker.testEmpty.primaryControl.mapToItem(panel.testStationPicker.testEmptyViewport,0,0).y; return y >= 0 && y + panel.testStationPicker.testEmpty.primaryControl.height <= panel.testStationPicker.testEmptyViewport.height }, 2000, "Station-search recovery was clipped")
          capture("station-search-empty-small")
          window.width = 420; window.height = 650; wait(50)
          panel.testStationPicker.testEmpty.primaryControl.clicked()
          compare(panel.testStationPicker.testSearch.text, "")
          verify(panel.testStationPicker.popupOpen && !panel.radio.wanted)
          panel.testStationPicker.testAll.clicked()
          const pickerStations = panel.radio.stations
          panel.radio.stations = pickerStations.concat([{id:"picker-markup",name:"<b>Literal radio</b>",city:"<img src='remote'>",country:"US",custom:true,streamUrl:"http://127.0.0.1:1/fixture"}])
          panel.testStationPicker.testSearch.text = "literal"
          tryVerify(function() { return panel.testStationPicker.testList.count === 1 && !!panel.testStationPicker.testList.itemAtIndex(0) }, 2000)
          pickerRow = panel.testStationPicker.testList.itemAtIndex(0)
          compare(pickerRow.testTitle.text, "<b>Literal radio</b>")
          compare(pickerRow.testTitle.textFormat, Text.PlainText)
          verify(pickerRow.testResult.tooltipText.indexOf("<b>Literal radio</b>") === 0)
          panel.radio.stations = pickerStations
          panel.testStationPicker.close()
          panel.radio.favoriteIds = ["weei-fm"]
          panel.testStationPicker.open()
          tryVerify(function() { return panel.testStationPicker.testSearch.activeFocus }, 2000)
          compare(panel.testStationPicker.filtered[0].value, "weei-fm", "Favorites were not sorted first on reopening")
          window.width = 320; window.height = 300
          wait(50)
          verify(panel.testStationPicker.testPopup.width <= window.width && panel.testStationPicker.testPopup.height <= window.height, "Station picker escaped the small window")
          const pickerCorner = panel.testStationPicker.testPopup.background.mapToItem(window.contentItem, 0, 0)
          verify(pickerCorner.x >= 0 && pickerCorner.x + panel.testStationPicker.testPopup.background.width <= window.width, "Picker edge was clipped by the window")
          capture("station-picker-small")
          keyClick(Qt.Key_Escape)
          tryVerify(function() { return !panel.testStationPicker.popupOpen }, 2000)
          window.width = 420; window.height = 650
          wait(50)
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
          panel.testCatcher.forceActiveFocus(); panel.keyboardNavigation = true; panel.cursor = 1
          verify(panel.testPlayButton.hasCursor)
          const tabWidth = panel.testSchedulesButton.width
          mouseMove(panel.testSchedulesButton, 8, panel.testSchedulesButton.height / 2)
          tryVerify(function() { return panel.testSchedulesButton.hot }, 2000)
          verify(!panel.testPlayButton.hasCursor && !panel.testSchedulesButton.hasCursor, "Pointer hover left a second keyboard highlight")
          compare(panel.testSchedulesButton.width, tabWidth)
          capture("tab-hover-padding")
          mouseMove(panel, panel.width - 2, panel.height - 2)
          tryVerify(function() { return !panel.testSchedulesButton.hot }, 2000, "The tab hover stuck after the pointer left")
          keyClick(Qt.Key_Tab)
          compare(panel.cursor, 4); verify(panel.testSettingsButton.hasCursor, "Keyboard focus did not return after mouse hover")
          panel.testListenButton.forceActiveFocus(); panel.cursor = 20
          keyClick(Qt.Key_Tab)
          verify(panel.testCatcher.activeFocus && panel.testRecordingsButton.hasCursor, "Tab left focus painted on the previous control")
          panel.cursor = 1
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
            {id:"partial",label:"Retained segment",stationName:"Station",status:"partial",playable:true,durationSeconds:120,resumePosition:30,
              plannedStart:new Date(2030,0,2,23,50).toISOString(),plannedEnd:new Date(2030,0,3,0,10).toISOString(),
              startedAt:new Date(2030,0,2,23,51).toISOString(),endedAt:new Date(2030,0,3,0,0).toISOString(),reason:"<b>Stream interrupted</b>"},
            {id:"missing",label:"Missing audio",stationName:"Station",status:"missing",playable:false,durationSeconds:60,resumePosition:20},
            {id:"capturing",label:"Live capture",stationName:"Station",status:"recording",playable:false,startedAt:new Date(2030,0,2,23,50).toISOString()}
          ]})
          tryCompare(panel.testView.testLibrary, "count", 5)
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
          console.log("QA: expanded recording metadata")
          unknownRow.testDetails.clicked()
          compare(unknownRow.testDuration.value, "Unknown")
          compare(unknownRow.testCaptured.value, "Time unavailable")
          partialRow.testDetails.clicked()
          verify(partialRow.testMetadata.visible)
          compare(partialRow.testReason.text, "<b>Stream interrupted</b>")
          compare(partialRow.testReason.textFormat, Text.PlainText)
          verify(partialRow.testScheduled.value.indexOf("Jan 2") >= 0 && partialRow.testScheduled.value.indexOf("Jan 3") >= 0, "Overnight range omitted a date")
          verify(partialRow.testCaptured.value.indexOf("11:51PM") >= 0 && partialRow.testScheduled.value.indexOf("11:50PM") >= 0, "Scheduled and actual capture times were conflated")
          const capturingRow = panel.testView.testLibrary.itemAt(4)
          capturingRow.testDetails.clicked()
          compare(capturingRow.testDuration.value, "In progress")
          verify(capturingRow.testCaptured.value.indexOf("In progress") >= 0)
          verify(!capturingRow.testDelete.enabled, "Active capture could be deleted")
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
          panel.openRecordings(false)
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
          verify(panel.testView.testEmptyLibrary.visible)
          compare(panel.testView.testEmptyLibrary.title, "No matching recordings")
          panel.testView.testEmptyLibrary.primaryControl.clicked()
          compare(panel.testView.searchText, ""); compare(panel.testView.statusFilter, "all")
          tryCompare(panel.testView.testLibrary, "count", 20)
          const emptySnapshot = Object.assign({}, realSnapshot, {recordings:[]})
          panel.radio.recordings = emptySnapshot
          compare(panel.testView.testEmptyLibrary.title, "No recordings yet")
          panel.testView.testEmptyLibrary.secondaryControl.clicked()
          verify(panel.testView.editing && panel.testView.tab === "schedules")
          panel.testView.goBack(); panel.testView.tab = "library"
          panel.testView.testEmptyLibrary.primaryControl.clicked()
          verify(panel.testView.nowEditing)
          panel.testView.goBack()
          panel.radio.recordings = Object.assign({}, emptySnapshot, {available:false,error:"<b>Storage unavailable</b>"})
          verify(panel.testView.testUnavailable.visible && !panel.testView.testEmptyLibrary.visible, "Unavailable library was presented as empty")
          panel.testView.testUnavailable.detailsControl.clicked()
          compare(panel.testView.testUnavailable.testDiagnostics.textFormat, Text.PlainText)
          compare(panel.testView.testUnavailable.testDiagnostics.text, "<b>Storage unavailable</b>")
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
          compare(panel.testPlayerStatus.text, "Recording paused")
          verify(panel.testPlaybackHint.text.indexOf("buffer") < 0, "A paused saved recording claims to buffer live audio")
          panel.testCatcher.forceActiveFocus(); panel.cursor = 0
          keyClick(Qt.Key_Tab); compare(panel.cursor, 15, "Recording seek is out of visual tab order")
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
          verify(panel.testSleepCountdown.visible && panel.testSleepOff.visible)
          verify(panel.testSleepCountdown.text.indexOf("Stops in ") === 0)
          panel.testSleepMinutes.text = "0"; panel.applySleepTimer()
          verify(panel.testSleepPopup.opened && panel.sleepError.length > 0)
          window.width = 320; window.height = 300
          wait(50)
          const timerCorner = panel.testSleepPopup.background.mapToItem(window.contentItem, 0, 0)
          verify(timerCorner.x >= 0 && timerCorner.y >= 0 && timerCorner.x + panel.testSleepPopup.width <= window.width && timerCorner.y + panel.testSleepPopup.height <= window.height, "Timer popover escaped the small window")
          verify(panel.testSleepOff.mapToItem(window.contentItem, 0, 0).y + panel.testSleepOff.height <= window.height, "Timer cancellation was clipped")
          capture("sleep-timer")
          window.width = 420; window.height = 650
          wait(50)
          panel.testSleepMinutes.text = "20"; panel.applySleepTimer()
          tryVerify(function() { return !panel.testSleepPopup.opened && panel.radio.sleepRemaining > 1100 }, 3000)
          panel.cursor = 19; panel.activate()
          tryVerify(function() { return panel.testSleepPopup.opened }, 2000)
          wait(150); keyClick(Qt.Key_Escape)
          verify(!panel.testSleepPopup.opened, "Escape did not close only the timer popover")
          verify(panel.opened)
          panel.cursor = 19; panel.activate()
          tryVerify(function() { return panel.testSleepPopup.opened }, 2000)
          panel.testSleepOff.clicked()
          tryVerify(function() { return !panel.testSleepPopup.opened && panel.radio.sleepRemaining === 0 }, 3000)
          verify(panel.radio.wanted, "Cancel timer stopped playback")
          capture("file-player")
          panel.openRecordings(false)
          wait(50); panel.testDockStop.forceActiveFocus(); keyClick(Qt.Key_Return)
          tryVerify(function() { return !panel.radio.wanted && panel.radio.playbackState === "stopped" }, 5000)
          verify(!panel.testDockStop.enabled && !panel.radio.paused, "Persistent Stop paused playback instead of stopping it")
          compare(panel.testDockStatus.text, "Recording stopped")
          verify(panel.testPlaybackHint.text.indexOf("Resume from Library") >= 0)
          panel.showPlayer()
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
          verify(panel.settingsOpen && panel.testSettings.visible && !panel.testPlayerView.visible)
          compare(panel.testSettingsTabs.count, 4)
          compare(panel.testSettingsClose.iconName, "close")
          const settingsVolume = panel.radio.volume
          panel.testSettingsTabs.itemAt(0).forceActiveFocus(); panel.cursor = 30
          keyClick(Qt.Key_Right)
          tryVerify(function() { return panel.settingsTab === "storage" && panel.testSettingsTabs.itemAt(1).activeFocus }, 2000)
          keyClick(Qt.Key_Right)
          tryVerify(function() { return panel.settingsTab === "alerts" && panel.testSettingsTabs.itemAt(2).activeFocus }, 2000)
          keyClick(Qt.Key_Left); keyClick(Qt.Key_Left)
          tryVerify(function() { return panel.settingsTab === "listening" && panel.testSettingsTabs.itemAt(0).activeFocus }, 2000)
          compare(panel.radio.volume, settingsVolume)
          panel.testCatcher.forceActiveFocus(); panel.cursor = 43
          keyClick(Qt.Key_Tab); compare(panel.cursor, 55, "Listening skips the persistent play control")
          keyClick(Qt.Key_Tab); compare(panel.cursor, 3)
          keyClick(Qt.Key_Backtab); compare(panel.cursor, 55)
          console.log("QA: buffer presets")
          const savedBuffer = panel.radio.bufferMinutes
          panel.testBufferPresets.itemAt(2).forceActiveFocus(); keyClick(Qt.Key_Space)
          tryCompare(panel.radio, "bufferMinutes", 15)
          compare(panel.testBufferSummary.text, "15 minutes of replay")
          verify(panel.testBufferPresets.itemAt(2).selected && !panel.radio.wanted)
          panel.testBufferPresets.itemAt(3).clicked(); tryCompare(panel.radio, "bufferMinutes", 30)
          panel.testBufferPresets.itemAt(1).clicked(); tryCompare(panel.radio, "bufferMinutes", 5)
          panel.testBufferPresets.itemAt(0).clicked(); tryCompare(panel.radio, "bufferMinutes", 0)
          verify(panel.testBufferDescription.text.indexOf("temporary 15-minute") >= 0)
          panel.cursor = 33; panel.advanceCursor(1); compare(panel.cursor, 4)
          panel.advanceCursor(1); compare(panel.cursor, 40)
          window.width = 320; window.height = 300
          wait(50); compare(panel.width, 320)
          panel.cursor = 43; panel.ensureCursorVisible()
          tryVerify(function() { var y = panel.testBufferPresets.itemAt(3).mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testBufferPresets.itemAt(3).height <= panel.testDock.mapToItem(panel, 0, 0).y }, 2000)
          capture("listening-small")
          panel.ensureItemVisible(panel.testShortcuts)
          wait(50); capture("shortcuts-small")
          window.width = 420; window.height = 650
          wait(50)
          panel.radio.setBufferMinutes(savedBuffer)
          panel.cursor = 30; panel.advanceCursor(1); compare(panel.cursor, 31)
          panel.testSettingsTabs.itemAt(1).clicked()
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          verify(panel.settingsStorage && !panel.recordingsOpen && panel.testView.testStorageContent.visible)
          verify(!panel.testView.testAlertsContent.visible && panel.testView.testStorageSave.visible)
          verify(panel.testDock.visible && !panel.testView.testStorageSave.enabled)
          console.log("QA: separate settings tabs and drafts")
          const storedFolder = panel.testView.testFolder.text, storedCap = panel.testView.testCap.text
          const storedAlerts = panel.radio.recordingNotifications, storedStarts = panel.radio.recordingStartNotifications
          panel.testView.testFolder.text = storedFolder + "/draft"
          panel.testView.testCap.text = "7"
          verify(panel.testView.testStorageSave.enabled)
          panel.testSettingsTabs.itemAt(2).clicked()
          tryVerify(function() { return panel.testView.testRecordingAlerts.activeFocus }, 2000)
          verify(panel.testView.testAlertsContent.visible && !panel.testView.testStorageContent.visible && !panel.testView.testStorageSave.visible, "Storage actions leaked into Alerts")
          panel.testView.testRecordingStarts.forceActiveFocus(); keyClick(Qt.Key_Space)
          verify(panel.radio.recordingStartNotifications)
          panel.testView.testRecordingAlerts.forceActiveFocus(); keyClick(Qt.Key_Return)
          verify(!panel.radio.recordingNotifications && !panel.testView.testRecordingStarts.enabled && panel.testView.testRecordingStarts.checked)
          panel.testView.testRecordingAlerts.forceActiveFocus(); keyClick(Qt.Key_Space)
          verify(panel.radio.recordingNotifications && panel.testView.testRecordingStarts.enabled)
          panel.testSettingsTabs.itemAt(3).clicked()
          verify(panel.testSettings.visible && !panel.testView.visible)
          panel.testSettingsTabs.itemAt(1).clicked()
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          compare(panel.testView.testFolder.text, storedFolder + "/draft"); compare(panel.testView.testCap.text, "7")
          panel.testView.testStorageCancel.clicked() // Reset this storage draft, staying on its tab.
          compare(panel.settingsTab, "storage")
          compare(panel.testView.testFolder.text, storedFolder); compare(panel.testView.testCap.text, storedCap)
          verify(!panel.testView.testStorageSave.enabled)
          verify(panel.radio.recordingStartNotifications, "Reset storage rolled back immediate alert preferences")
          panel.selectSettingsTab("alerts")
          tryVerify(function() { return panel.testView.testRecordingAlerts.activeFocus }, 2000)
          panel.testView.testRecordingStarts.forceActiveFocus(); keyClick(Qt.Key_Return)
          compare(panel.radio.recordingNotifications, storedAlerts); compare(panel.radio.recordingStartNotifications, storedStarts)
          panel.selectSettingsTab("storage")
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          const storageSnapshot = panel.radio.recordings
          panel.radio.recordings = Object.assign({}, storageSnapshot, {usedBytes:storageSnapshot.settings.storageCapBytes*2})
          compare(panel.testView.testStorageUsage.visualPosition, 1)
          panel.radio.recordings = Object.assign({}, storageSnapshot, {usedBytes:-1})
          compare(panel.testView.testStorageUsage.visualPosition, 0)
          panel.radio.recordings = storageSnapshot
          panel.testView.testFolder.text = "relative-folder"; panel.testView.testOpenFolder.clicked()
          verify(panel.testView.localError.indexOf("absolute folder") >= 0)
          panel.testView.testFolder.text = storedFolder; panel.testView.localError = ""
          wait(100); panel.testView.testFolder.forceActiveFocus()
          capture("storage")
          window.height = 300; window.width = 320
          tryVerify(function() { var y = panel.testView.testFolder.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testFolder.height <= panel.testDock.mapToItem(panel, 0, 0).y }, 2000)
          panel.selectSettingsTab("alerts")
          tryVerify(function() { return panel.testView.testRecordingAlerts.activeFocus }, 2000)
          panel.testView.testRecordingStarts.forceActiveFocus()
          tryVerify(function() { var y = panel.testView.testRecordingStarts.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testRecordingStarts.height <= panel.testDock.mapToItem(panel, 0, 0).y }, 2000)
          capture("alerts-small")
          panel.selectSettingsTab("storage")
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          panel.testView.testCap.text = "7"
          panel.testView.testStorageSave.forceActiveFocus()
          tryVerify(function() { var y = panel.testView.testStorageSave.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testView.testStorageSave.height <= panel.testDock.mapToItem(panel, 0, 0).y }, 2000)
          capture("storage-small")
          window.height = 650; window.width = 420
          panel.testSettingsClose.clicked(); verify(!panel.settingsOpen && !panel.recordingsOpen)
          panel.openSchedules(); panel.openSettings(); panel.selectSettingsTab("alerts")
          panel.testSettingsButton.clicked()
          verify(panel.recordingsOpen && panel.testView.tab === "schedules", "X lost the previous main section")
          panel.openSettingsStorage()
          tryVerify(function() { return panel.testView.testFolder.activeFocus }, 2000)
          const previousLimit = panel.radio.recordings.settings.storageCapBytes
          panel.testView.testCap.text = String((previousLimit + 1073741824) / 1073741824)
          const storageDraft = panel.testView.testCap.text, previousRevision = panel.radio.recordings.revision
          const previousSettings = panel.radio.recordings.settings
          panel.radio.recordingSettings(previousRevision, {folder:previousSettings.folder, storageCapBytes:previousLimit+1, freeSpaceReserveBytes:previousSettings.freeSpaceReserveBytes, concurrency:previousSettings.concurrency})
          tryVerify(function() { return panel.radio.recordings.revision > previousRevision }, 5000)
          panel.testView.testStorageSave.clicked()
          tryVerify(function() { return !panel.testView.pending }, 5000)
          verify(!panel.radio.recordingMutationOK && panel.testView.storageEditing)
          compare(panel.testView.testCap.text, storageDraft)
          panel.testView.testStorageRefresh.clicked(); panel.testView.testStorageSave.clicked()
          tryVerify(function() { return !panel.testView.pending && panel.testView.storageFeedback === "Storage saved." }, 5000)
          compare(panel.settingsTab, "storage"); verify(panel.settingsOpen && !panel.testView.storageDirty)
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
          verify(libraryRow.testCancelDelete.visible)
          libraryRow.testCancelDelete.clicked()
          compare(panel.testView.confirmation, "")
          verify(panel.radio.recordings.recordings.some(function(r) { return r.id === "test-recording" }), "Cancel delete removed the recording")
          window.width = 320; window.height = 300
          wait(50)
          libraryRow.testRestart.forceActiveFocus()
          tryVerify(function() { const y = libraryRow.testRestart.mapToItem(panel,0,0).y; return y >= 0 && y + libraryRow.testRestart.height <= panel.testDock.mapToItem(panel,0,0).y }, 2000)
          capture("recording-details-small")
          window.width = 420; window.height = 650; wait(50)
          libraryRow.testRestart.clicked()
          tryVerify(function() { return panel.radio.playbackState === "playing" && panel.radio.position < 5 }, 8000)
          verify(panel.recordingsOpen, "Restart left the recording library")
          panel.radio.stop()
          tryVerify(function() { return panel.radio.playbackState === "stopped" }, 5000)
          libraryRow.testDelete.clicked()
          compare(panel.testView.confirmation, "deleteRecording:test-recording")
          verify(panel.radio.recordings.recordings.some(function(r) { return r.id === "test-recording" }), "First delete click removed audio without confirmation")
          libraryRow.testDetails.clicked()
          compare(panel.testView.confirmation, "", "Hiding details retained an armed delete action")
          libraryRow.testDetails.clicked()
          libraryRow.testDelete.clicked(); libraryRow.testDelete.clicked()
          tryVerify(function() { return !panel.testView.pending && panel.radio.recordings.recordings.length === 0 }, 5000)
          tryVerify(function() { return panel.testView.testEmptyLibrary.primaryControl.activeFocus }, 2000)
          window.width = 320; window.height = 300; wait(50)
          tryVerify(function() { const y = panel.testView.testEmptyLibrary.primaryControl.mapToItem(panel,0,0).y; return y >= 0 && y + panel.testView.testEmptyLibrary.primaryControl.height <= panel.testDock.mapToItem(panel,0,0).y }, 2000, "Empty-library action was hidden behind playback controls")
          capture("empty-library-small")
          window.width = 420; window.height = 650; wait(50)
          panel.showPlayer()
          console.log("QA: custom station editor")
          panel.openSettings(); panel.selectSettingsTab("stations"); panel.openStationEditor(false)
          tryVerify(function() { return panel.testName.activeFocus }, 2000)
          keyClick(Qt.Key_P); keyClick(Qt.Key_M); compare(panel.testName.text, "pm")
          keyClick(Qt.Key_Tab); verify(panel.testStationURL.activeFocus)
          keyClick(Qt.Key_Tab); verify(panel.testStationCity.activeFocus)
          keyClick(Qt.Key_Tab); verify(panel.testStationCountry.activeFocus)
          keyClick(Qt.Key_Tab); verify(panel.testStationWebsite.activeFocus)
          keyClick(Qt.Key_Tab); verify(panel.testStationSave.activeFocus)
          keyClick(Qt.Key_Tab); verify(panel.testStationCancel.activeFocus)
          keyClick(Qt.Key_Tab); verify(!panel.testName.activeFocus, "Tab was trapped inside the custom station editor")
          keyClick(Qt.Key_Backtab); verify(panel.testStationCancel.activeFocus)

          panel.testStationURL.text = "not-a-url"
          panel.testStationSave.clicked()
          tryVerify(function() { return !panel.stationMutationPending && !!panel.stationError }, 5000)
          verify(panel.stationEditorOpen && panel.testName.text === "pm", "Invalid station discarded the draft")
          panel.testName.text = "<b>Community Radio</b>"
          panel.testStationURL.text = "http://127.0.0.1:1/community"
          panel.testStationCity.text = "Boston"; panel.testStationCountry.text = "US"
          panel.selectSettingsTab("listening"); panel.selectSettingsTab("stations")
          tryVerify(function() { return panel.testName.activeFocus }, 2000)
          compare(panel.testName.text, "<b>Community Radio</b>")
          wait(50) // Settle queued focus from the rapid tab switch.
          window.width = 320; window.height = 300
          wait(50); compare(panel.width, 320); compare(panel.height, 300)
          panel.testStationSave.forceActiveFocus()
          tryVerify(function() { var y = panel.testStationSave.mapToItem(panel, 0, 0).y; return y >= 0 && y + panel.testStationSave.height <= panel.testDock.mapToItem(panel, 0, 0).y }, 2000)
          capture("custom-station-small")
          window.width = 420; window.height = 650
          panel.testStationSave.clicked()
          tryVerify(function() { return !panel.stationMutationPending && !panel.stationEditorOpen }, 5000)
          const custom = panel.radio.stations.find(function(station) { return station.custom && station.name === "<b>Community Radio</b>" })
          verify(!!custom, panel.stationError)
          compare(panel.radio.stationId, "wfan", "Saving a station unexpectedly changed playback selection")
          compare(panel.testStationList.itemAt(0).testTitle.text, "<b>Community Radio</b>")
          compare(panel.testStationList.itemAt(0).testTitle.textFormat, Text.PlainText)
          panel.testStationList.itemAt(0).testEdit.clicked()
          tryVerify(function() { return panel.testName.activeFocus }, 2000)
          compare(panel.testStationURL.text, "http://127.0.0.1:1/community")
          panel.testStationCity.text = "Cambridge"
          panel.testStationSave.clicked()
          tryVerify(function() { return !panel.stationMutationPending && !panel.stationEditorOpen }, 5000)
          const updatedCustom = panel.radio.stations.find(function(station) { return station.id === custom.id })
          compare(updatedCustom.city, "Cambridge")
          panel.openStationEditor(updatedCustom)
          tryVerify(function() { return panel.testName.activeFocus }, 2000)
          panel.testStationDelete.clicked()
          verify(panel.confirmStationDelete && panel.radio.stations.some(function(station) { return station.id === custom.id }))
          panel.selectSettingsTab("listening"); verify(!panel.confirmStationDelete)
          panel.selectSettingsTab("stations")
          tryVerify(function() { return panel.testName.activeFocus }, 2000)
          panel.testStationDelete.clicked(); panel.testStationDelete.clicked()
          tryVerify(function() { return !panel.stationMutationPending && !panel.stationEditorOpen }, 5000)
          verify(!panel.radio.stations.some(function(station) { return station.id === custom.id }), "Delete targeted the selected station instead of the edited station")
          compare(panel.radio.stationId, "wfan")
          wait(50); keyClick(Qt.Key_Escape)
          verify(!panel.settingsOpen, "Escape from Stations did not close settings")
          panel.openSettings(); panel.selectSettingsTab("alerts")
          wait(50); panel.testSettingsTabs.itemAt(2).forceActiveFocus()
          keyClick(Qt.Key_Escape); verify(!panel.settingsOpen, "Escape from the settings tab strip was ignored")
          console.log("QA: connection recovery guidance")
          panel.showPlayer()
          panel.radio.playbackKind = "live"; panel.radio.wanted = false
          panel.radio.playbackState = "error"; panel.radio.error = "<b>Stream failed</b>"
          verify(panel.testConnectionState.visible)
          panel.testConnectionState.detailsControl.clicked()
          compare(panel.testConnectionState.testDiagnostics.textFormat, Text.PlainText)
          compare(panel.testConnectionState.testDiagnostics.text, "<b>Stream failed</b>")
          panel.cursor = 50; panel.advanceCursor(1); compare(panel.cursor, 51)
          panel.testConnectionState.secondaryControl.clicked()
          tryVerify(function() { return panel.testStationPicker.popupOpen }, 2000)
          verify(!panel.radio.wanted, "Opening alternate stations started playback")
          panel.testStationPicker.close()
          panel.radio.playbackState = "retrying"; panel.radio.retryDelay = 3
          verify(panel.testConnectionState.description.indexOf("3 seconds") >= 0)
          panel.openRecordings(false)
          verify(panel.testDockRetry.visible)
          panel.testDockRetry.clicked()
          verify(panel.radio.wanted, "Dock retry did not request playback")
          panel.radio.stop()
          tryVerify(function() { return panel.radio.playbackState === "stopped" }, 5000)
          panel.showPlayer(); panel.radio.playbackState = "error"
          panel.testConnectionState.primaryControl.clicked()
          verify(panel.radio.wanted, "Connection card retry did not request playback")
          panel.radio.stop()
          console.log("YAKKER_FULL_RECORDINGS_REAL_CONTROLLER_PASS")
        } catch(e) { console.error("YAKKER_FULL_RECORDINGS_REAL_CONTROLLER_FAIL", e, e.stack) }
        panel.radio.release(); Qt.quit()
      }
    }
  }
}
