import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import qs.Commons as Commons
import "plugin" as Plugin

// Uses the native card's actual padding and border, without touching the desktop.
ShellRoot {
  Window {
    id: window
    visible: true; width: 320; height: 300
    color: Commons.Color.popups.background
    Plugin.Panel { id: panel; width: window.width; height: window.height }
    Timer { interval: 300; running: true; onTriggered: audit.run() }
    TestCase {
      id: audit
      when: false
      property var issues: []
      readonly property var radio: panel.radio
      readonly property var view: panel.testView
      readonly property var savedShow: ({id:"saved",label:"The afternoon sports roundtable and listener calls",stationId:"weei-fm",stationName:"WEEI 93.7",status:"complete",bytes:3600000,durationSeconds:7200,resumePosition:3661,playable:true,plannedStart:"2026-11-19T14:00:00-05:00",plannedEnd:"2026-11-19T16:00:00-05:00",startedAt:"2026-11-19T14:00:01-05:00",endedAt:"2026-11-19T16:00:00-05:00"})
      readonly property var schedule: ({id:"future",label:"Weekend sports roundup and listener questions",stationId:"talksport",stationName:"talkSPORT",enabled:true,weekdays:[0,6],startTime:"23:00",endTime:"01:00",timezone:"America/Argentina/Buenos_Aires",nextStart:"2026-11-28T23:00:00-03:00",nextEnd:"2026-11-29T01:00:00-03:00"})
      function issue(message) { issues.push(message); console.log("COMPACT ISSUE",message) }
      function capture(name) {
        let done = false, saved = false
        window.contentItem.grabToImage(function(result) { saved = result.saveToFile("__OUTPUT__/" + name + ".png"); done = true })
        tryVerify(function() { return done },5000); verify(saved,"Could not capture " + name)
      }
      function descendants(item, visit) {
        if (!item.visible) return
        visit(item)
        for (const child of item.children) descendants(child,visit)
      }
      function checkLayout(name) {
        descendants(panel,function(item) {
          if (item.width < -0.5) issue(name + ": negative width " + item)
          if (item.text && item._contentNaturalWidth !== undefined && item.width + 1 < item.implicitWidth)
            issue(name + ": crowded button '" + item.text + "' " + item.width.toFixed(1) + "/" + item.implicitWidth.toFixed(1))
          // Intentional elision remains appropriate for station titles and fields.
          if (item.text && item.textFormat !== undefined && item.wrapMode === Text.NoWrap && item.elide === Text.ElideNone && item.contentWidth > item.width + 1)
            issue(name + ": clipped text '" + item.text + "' " + item.width.toFixed(1) + "/" + item.contentWidth.toFixed(1))
          if ((item.activeFocusOnTab || item._contentNaturalWidth !== undefined) && item.width > 0 && item.enabled) {
            const p = item.mapToItem(panel,0,0)
            if (p.x < -0.5 || p.x + item.width > window.width + 0.5)
              issue(name + ": control outside card " + (item.text || item.Accessible.name || item))
          }
        })
        verify(panel.testScroller.height > 0, name + ": body has no scrolling space")
        const dock = panel.testDock.mapToItem(panel,0,0)
        verify(dock.y + panel.testDock.height <= window.height + 0.5, name + ": dock escaped popup")
      }
      function checkFocus(name, count) {
        for (let i=0;i<count;i++) {
          keyClick(Qt.Key_Tab); wait(22)
          const focused = panel.virtualFocus ? panel.scrollTarget : window.activeFocusItem
          if (!focused || !focused.visible || !focused.enabled) { issue(name + ": Tab lost focus"); continue }
          let parent = focused
          while (parent && parent !== panel.testBody) parent = parent.parent
          if (parent !== panel.testBody) continue
          let p = focused.mapToItem(panel.testScroller,0,0)
          if (p.y < -0.5 || p.y + focused.height > panel.testScroller.height + 0.5) { wait(40); p = focused.mapToItem(panel.testScroller,0,0) }
          if (p.y < -0.5 || p.y + focused.height > panel.testScroller.height + 0.5)
            issue(name + ": focus hidden while tabbing to " + (focused.Accessible.name || focused.text || focused) + " y=" + p.y.toFixed(1) + " height=" + focused.height.toFixed(1) + " viewport=" + panel.testScroller.height.toFixed(1))
        }
      }
      function reset(index) {
        panel.showPlayer()
        view.editing = false; view.nowEditing = false; view.storageEditing = false
        view.localError = ""; view.confirmation = ""; view.expandedRecordings = ({})
        view.clearLibraryFilters()
        radio.station = radio.stations[index % radio.stations.length]; radio.stationId = radio.station.id
        radio.playbackKind = "live"; radio.wanted = true; radio.playbackState = "playing"; radio.paused = false
        radio.error = ""; radio.bufferMinutes = 0; radio.temporaryBuffer = false; radio.dvr = false; radio.sleepRemaining = 0
        radio.recordings = {available:true,revision:1,error:"",localTimezone:"America/New_York",settings:{folder:"/home/demo/Music/Yakker",storageCapBytes:5368709120,freeSpaceReserveBytes:1073741824,concurrency:3},recordings:[savedShow],schedules:[schedule],activeCount:0,usedBytes:3600000}
        panel.testScroller.contentY = 0
      }
      function run() {
        try {
          const xhr = new XMLHttpRequest(); xhr.open("GET",Qt.resolvedUrl("plugin/stations.json"),false); xhr.send()
          radio.stations = JSON.parse(xhr.responseText).concat([{id:"custom-long",name:"Community radio and neighborhood events",subtitle:"Independent radio",streamUrl:"http://127.0.0.1:1/custom",city:"San Francisco",country:"US",custom:true}])
          radio.initialized = true; radio.ready = true; radio.volume = 62
          radio.favoriteIds = radio.stations.slice(0,6).map(function(s) { return s.id })
          panel.open()
          const cases = [
            ["listen",function() {}],
            ["replay",function() { radio.paused=true;radio.playbackState="paused";radio.temporaryBuffer=true;radio.dvr=true;radio.bufferStart=0;radio.bufferEnd=900;radio.position=600 }],
            ["saved-player",function() { radio.playbackKind="recording";radio.recordingId="saved";radio.recordingTitle=savedShow.label;radio.duration=7200;radio.position=3661;radio.station=radio.noStation;radio.stationId="" }],
            ["library",function() { panel.openRecordings(false) }],
            ["details",function() { panel.openRecordings(false);view.toggleDetails("saved") }],
            ["schedules",function() { panel.openSchedules() }],
            ["weekly-editor",function() { panel.openSchedules();view.beginEdit(schedule) }],
            ["once-editor",function() { panel.openSchedules();view.beginEdit(null);view.scheduleKind="once" }],
            ["record-now",function() { panel.recordNow() }],
            ["listening",function() { panel.openSettings() }],
            ["storage",function() { panel.openSettingsStorage();view.testFolder.text+="/Draft" }],
            ["alerts",function() { panel.openSettings();panel.selectSettingsTab("alerts") }],
            ["custom-stations",function() { panel.openSettings();panel.selectSettingsTab("stations") }],
            ["station-editor",function() { panel.openSettings();panel.selectSettingsTab("stations");panel.openStationEditor({id:"custom",name:"Community Radio",streamUrl:"https://radio.example/stream",city:"Boston",country:"US",website:"https://radio.example"});panel.confirmStationDelete=true }],
            ["empty-library",function() { radio.recordings=Object.assign({},radio.recordings,{recordings:[]});panel.openRecordings(false) }],
            ["no-results",function() { panel.openRecordings(false);view.testSearch.text="Missing show" }],
            ["connection-error",function() { radio.wanted=false;radio.playbackState="error";radio.error="This station could not be reached. Try another station or reconnect." }]
          ]
          const base = Commons.Style.fontBaseSize
          let index = 0
          for (const size of [[360,420,base],[320,300,base],[288,300,base],[320,360,Math.max(14,base)]]) {
            window.width=size[0];window.height=size[1];Commons.Style.fontBaseSize=size[2]
            for (const entry of cases) {
              reset(index++); entry[1](); wait(45)
              const name = entry[0] + "-" + size.join("x")
              checkLayout(name)
              if (entry[0].indexOf("editor") >= 0 || ["library","storage","alerts","record-now","schedules","custom-stations"].indexOf(entry[0]) >= 0) checkFocus(name,16)
              if (size[0]===320 && size[2]===base) capture(name)
            }
          }
          reset(index++); window.width=320;window.height=300;Commons.Style.fontBaseSize=base
          panel.openRecordings(false); view.toggleDetails("saved"); wait(40)
          view.testLibrary.itemAt(0).testDelete.forceActiveFocus(); wait(50)
          const libraryScroll=panel.testScroller.contentY
          verify(libraryScroll>50,"Scroll-return fixture did not scroll")
          panel.testSettingsButton.clicked(); wait(30)
          panel.testSettingsClose.clicked(); wait(60)
          verify(panel.recordingsOpen && !panel.settingsOpen)
          verify(panel.testSettingsButton.activeFocus,"Closing Settings did not return to its opener")
          if (panel.testScroller.contentY !== libraryScroll) console.log("QA scroll return",panel.testScroller.contentY,libraryScroll,panel.settingsReturnScroll,panel.testScroller.contentHeight,panel.testScroller.height)
          compare(panel.testScroller.contentY,libraryScroll,"Closing Settings jumped the library scroll position")
          view.testSearch.forceActiveFocus(); wait(50)
          mouseWheel(panel.testScroller,20,panel.testScroller.height/2,0,-120)
          wait(70)
          const manualScroll=panel.testScroller.contentY
          verify(manualScroll>0,"Mouse wheel did not scroll the content")
          radio.recordings=Object.assign({},radio.recordings,{recordings:[savedShow,Object.assign({},savedShow,{id:"new",label:"Newly completed show"})]})
          wait(80)
          verify(panel.testScroller.contentY>=manualScroll-1,"Library update snapped back to the old focused field")
          // Popovers have a separate overlay: check their actual window bounds
          // and Escape/focus return at the same padded compact sizes.
          for (const font of [base,Math.max(14,base)]) {
            window.width=320; window.height=font===base ? 300 : 360
            Commons.Style.fontBaseSize=font
            function popupFits(popup,name) {
              const p=popup.background.mapToItem(window.contentItem,0,0)
              verify(p.x>=0 && p.y>=0 && p.x+popup.width<=window.width+0.5 && p.y+popup.height<=window.height+0.5,name+": overlay clipped")
            }
            reset(index++); panel.testStationPicker.open()
            tryVerify(function() { return panel.testStationPicker.testSearch.activeFocus },2000)
            popupFits(panel.testStationPicker.testPopup,"Station picker")
            panel.testStationPicker.testSearch.text="WFAN New York"
            compare(panel.testStationPicker.filtered.length,1)
            keyClick(Qt.Key_Down); keyClick(Qt.Key_Up)
            verify(panel.testStationPicker.testSearch.activeFocus)
            panel.testStationPicker.testSearch.text="No station matches"
            wait(25); popupFits(panel.testStationPicker.testPopup,"Empty station picker")
            capture("station-picker-padded-"+font)
            keyClick(Qt.Key_Escape); verify(!panel.testStationPicker.popupOpen && panel.opened)
            reset(index++); panel.openRecordings(false); wait(35)
            view.testStatus.open(); tryVerify(function() { return view.testStatus.popupOpen },2000)
            popupFits(view.testStatus.testPopup,"Library filter")
            keyClick(Qt.Key_Escape); tryVerify(function() { return !view.testStatus.popupOpen && view.testStatus.activeFocus },2000)
            reset(index++); radio.sleepRemaining=900; panel.testSleepPopup.open()
            tryVerify(function() { return panel.testSleepPresets.itemAt(0).activeFocus },2000)
            popupFits(panel.testSleepPopup,"Sleep timer")
            const cancel=panel.testSleepOff.mapToItem(window.contentItem,0,0)
            verify(cancel.y+panel.testSleepOff.height<=window.height,"Timer cancel clipped")
            capture("sleep-timer-padded-"+font)
            keyClick(Qt.Key_Escape); verify(!panel.testSleepPopup.opened && panel.opened)
          }
          verify(issues.length === 0,issues.length + " compact layout/focus issues; see COMPACT ISSUE output")
          console.log("YAKKER_COMPACT_VIEWS_PASS")
        } catch(error) { console.error("YAKKER_COMPACT_VIEWS_FAIL",error,error.stack) }
        Qt.quit()
      }
    }
  }
}
