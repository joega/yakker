import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "." as Radio

Ui.Panel {
  id: root
  moduleName: "io.github.joega.yakker"
  manageIpc: false
  property var anchorItem: null
  property var hostWidget: null
  property int cursor: 1
  property bool settingsOpen: false
  property string settingsReturnView: "listen"
  property real settingsReturnScroll: 0
  property string settingsTab: "listening"
  readonly property bool settingsStorage: settingsOpen && (settingsTab === "storage" || settingsTab === "alerts")
  readonly property bool auxiliaryView: recordingsOpen || settingsOpen
  property bool recordingsOpen: false
  property bool stationEditorOpen: false
  property int pendingStationSerial: 0
  readonly property bool stationMutationPending: pendingStationSerial !== 0
  property string stationError: ""
  onStationErrorChanged: if (stationError && settingsOpen && settingsTab === "stations") Qt.callLater(function() { root.ensureItemVisible(stationErrorText) })
  property bool confirmStationDelete: false
  property string editingStationId: ""
  readonly property var radio: Radio.RadioService
  property var scrollTarget: null
  property string sleepError: ""
  readonly property string uiFontFamily: "Adwaita Sans"
  readonly property var favoritePresets: radio.favoriteIds.map(function(id) {
    return root.radio.stations.find(function(station) { return station.id === id })
  }).filter(function(station) { return !!station }).slice(0, 6)
  readonly property bool seekable: radio.wanted && (radio.playbackState === "playing" || radio.paused)
    && (radio.playbackKind === "recording" ? radio.duration > 0 : radio.dvr)
  readonly property bool canRewind: seekable && radio.position > (radio.playbackKind === "recording" ? 0 : radio.bufferStart) + 0.5
  readonly property bool canForward: seekable && (radio.playbackKind === "recording" ? radio.duration - radio.position > 0.5 : radio.behindLive > 3)
  readonly property bool canPlay: (radio.hasStation || radio.wanted) && (!radio.wanted || radio.paused || radio.playbackState === "playing")
  readonly property string playTooltip: !radio.hasStation && !radio.wanted ? "Choose a station first" : radio.wanted ? (radio.paused ? "Resume" : "Pause") : radio.playbackState === "error" ? "Retry" : "Play"
  readonly property string listeningStatus: radio.playbackKind === "recording"
    ? (radio.paused ? "Paused recording" : radio.statusText)
    : radio.dvr && (radio.paused || radio.behindLive > 3)
      ? (radio.paused ? "Paused · " : "") + radio.clock(radio.behindLive) + " behind live"
      : radio.statusText

  component SettingLabel: Text {
    width: parent.width
    textFormat: Text.PlainText
    color: root.barForeground
    font.family: root.uiFontFamily
    font.pixelSize: Style.fontPx(1.083)
    font.weight: Font.DemiBold
  }
  component SettingTitle: SettingLabel { font.pixelSize: Style.fontPx(1.5) }
  component SettingHint: Text {
    width: parent.width
    textFormat: Text.PlainText
    color: Qt.alpha(root.barForeground, 0.65)
    font.family: root.uiFontFamily
    font.pixelSize: Style.fontPx(1)
    wrapMode: Text.Wrap
  }

  function togglePlayback() { radio.wanted ? radio.togglePause() : radio.play() }
  function playbackShortcut(text) {
    if (text.toLowerCase() === "p") radio.togglePause()
    if (text === "[") radio.skip(-30)
    if (text === "]") radio.skip(30)
    if (text.toLowerCase() === "g") radio.goLive()
    if (text.toLowerCase() === "m") radio.toggleMute()
    if (text.toLowerCase() === "r" && !radio.wanted) radio.play()
  }
  function openSettings() {
    if (settingsOpen) { closeSettings(); return }
    settingsReturnView = recordingsOpen ? recordingsView.tab : "listen"
    settingsReturnScroll = scroller.contentY
    recordingsOpen = false
    settingsOpen = true
    settingsTab = "listening"
    recordingsView.storageEditing = false
    stationPicker.close(); speedPicker.close(); sleepPopup.close()
    scroller.contentY = 0
    cursor = 4
    keyCatcher.forceActiveFocus()
  }
  function closeSettings() {
    if (stationMutationPending || recordingsView.pending) return
    settingsOpen = false
    recordingsOpen = settingsReturnView !== "listen"
    if (recordingsOpen) {
      recordingsView.tab = settingsReturnView
      recordingsView.editing = false
      recordingsView.nowEditing = false
      recordingsView.storageEditing = false
      recordingsView.activate()
    } else { cursor = 4; keyCatcher.forceActiveFocus() }
    Qt.callLater(function() { scroller.contentY = Math.min(settingsReturnScroll, Math.max(0, scroller.contentHeight - scroller.height)) })
  }
  function backFromSettings() {
    if (stationMutationPending || recordingsView.pending) return
    if (settingsTab === "stations" && stationEditorOpen) {
      stationEditorOpen = false; confirmStationDelete = false
      Qt.callLater(function() { addStationButton.forceActiveFocus() })
    } else closeSettings()
  }
  function selectSettingsTab(section) {
    if (stationMutationPending || recordingsView.pending) return
    settingsTab = section
    cursor = section === "listening" ? 30 : -1
    confirmStationDelete = false
    recordingsView.localError = ""
    recordingsOpen = false
    if (settingsStorage && !recordingsView.storageEditing) recordingsView.beginStorage()
    scroller.contentY = 0
    Qt.callLater(function() {
      if (!root.settingsOpen || root.settingsTab !== section) return
      if (section === "storage") recordingsView.focusStorage()
      else if (section === "alerts") recordingsView.focusNotifications()
      else if (section === "stations") (stationEditorOpen ? stationName : addStationButton).forceActiveFocus()
      else { cursor = 30; keyCatcher.forceActiveFocus() }
    })
  }
  function openSettingsStorage() {
    if (!settingsOpen) openSettings()
    selectSettingsTab("storage")
  }
  function finishSettingsStorage() {
    // Standalone library storage returns to its library; tabbed settings stay put.
    if (settingsStorage) recordingsView.beginStorage()
  }
  function showPlayer() {
    recordingsOpen = false
    settingsOpen = false
    cursor = 1
    scroller.contentY = 0
    keyCatcher.forceActiveFocus()
  }
  function openSchedules() {
    openRecordings(false)
    recordingsView.tab = "schedules"
    Qt.callLater(function() { recordingsView.activate() })
  }
  function recordNow() {
    openRecordings(false)
    recordingsView.beginNow()
  }

  function applySleepTimer() {
    const minutes = Number(sleepMinutes.text)
    if (!Number.isInteger(minutes) || minutes < 1 || minutes > 240) {
      sleepError = "Choose 1 to 240 minutes."
      return
    }
    radio.setSleepTimer(minutes)
    sleepPopup.close(); sleepError = ""
    keyCatcher.forceActiveFocus()
  }

  function chooseStation() {
    root.showPlayer()
    root.open()
    Qt.callLater(function() { root.cursor = 0; stationPicker.open() })
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }
  function advanceCursor(direction) {
    let order = [4,20,14,21]
    if (settingsOpen) {
      order = [4,30,31,32,33]
      if (settingsTab === "listening") order.push(5)
      order = order.concat([2,3])
      const index = Math.max(0, order.indexOf(cursor))
      cursor = order[(index + direction + order.length) % order.length]
      Qt.callLater(ensureCursorVisible)
      return
    }
    order.push(0)
    if (favoriteButton.visible && favoriteButton.enabled) order.push(13)
    if (radio.playbackKind !== "recording")
      for (let i = 0; i < favoritePresets.length; i++) order.push(100 + i)
    if (timelineSlider.visible && timelineSlider.enabled) order.push(22)
    if (liveButton.visible && liveButton.enabled) order.push(9)
    if (backButton.enabled) order.push(7)
    if (playButton.enabled) order.push(1)
    if (forwardButton.enabled) order.push(8)
    order.push(23)
    if (sleepButton.enabled) order.push(19)
    if (stopButton.enabled) order.push(6)
    if (speedPicker.visible) order.push(18)
    if (radio.playbackKind === "recording") {
      if (radio.wanted && radio.duration > 0 && (radio.playbackState === "playing" || radio.paused)) order.push(15)
      if (radio.wanted || radio.bufferActive) order.push(16)
    }
    order = order.concat([2,3])
    const index = Math.max(0, order.indexOf(cursor))
    cursor = order[(index + direction + order.length) % order.length]
    Qt.callLater(ensureCursorVisible)
  }
  function ensureCursorVisible() {
    const targets = [stationPicker, playButton, volumeSlider, muteButton, settingsButton,
                     bufferPicker, stopButton, backButton, forwardButton, liveButton,
                     addStationButton, addStationButton, deleteStationButton, favoriteButton, recordingsButton, fileTimeline, returnLiveButton, addStationButton, speedPicker, sleepButton, listenButton, schedulesButton, timelineSlider, recordNowButton, addStationButton]
    ensureItemVisible(cursor >= 100 ? presetRepeater.itemAt(cursor - 100) : cursor >= 30 && cursor <= 33 ? settingsTabs.itemAt(cursor - 30) : targets[cursor])
  }
  function ensureItemVisible(item) {
    scrollTarget = item
    if (item) scrollEnsure.restart()
  }
  Timer {
    id: scrollEnsure
    interval: 16
    onTriggered: {
      const item = root.scrollTarget
      if (!item || !item.visible) return
      let ancestor = item.parent
      while (ancestor && ancestor !== panelContent) ancestor = ancestor.parent
      if (!ancestor) return
      const top = item.mapToItem(panelContent, 0, 0).y
      if (top < scroller.contentY) scroller.contentY = Math.max(0, top)
      else if (top + item.height > scroller.contentY + scroller.height)
        scroller.contentY = Math.min(Math.max(0, scroller.contentHeight - scroller.height), top + item.height - scroller.height)
    }
  }
  function activate() {
    if (cursor === 0) stationPicker.toggle()
    else if (cursor === 1 && playButton.enabled) playButton.clicked()
    else if (cursor === 3) radio.toggleMute()
    else if (cursor === 4) openSettings()
    else if (cursor === 5 && settingsOpen) bufferPicker.toggle()
    else if (cursor === 6 && stopButton.enabled) radio.stop()
    else if (cursor === 7 && backButton.enabled) radio.skip(-30)
    else if (cursor === 8 && forwardButton.enabled) radio.skip(30)
    else if (cursor === 9 && radio.dvr) radio.goLive()
    else if (cursor === 10) openStationEditor(false)
    else if (cursor === 11 && radio.station.custom) openStationEditor(true)
    else if (cursor === 12 && radio.station.custom) deleteStation()
    else if (cursor === 13 && favoriteButton.enabled) radio.toggleFavorite(radio.stationId)
    else if (cursor === 14) openRecordings(false)
    else if (cursor === 16) returnLiveButton.clicked()
    else if (cursor === 17 && settingsOpen) openSettingsStorage()
    else if (cursor === 18 && speedPicker.visible) speedPicker.toggle()
    else if (cursor === 19 && sleepButton.enabled) sleepButton.clicked()
    else if (cursor === 20) showPlayer()
    else if (cursor === 21) openSchedules()
    else if (cursor === 23) recordNow()
    else if (cursor === 24) backFromSettings()
    else if (cursor >= 30 && cursor <= 33) selectSettingsTab(["listening", "storage", "alerts", "stations"][cursor - 30])
    else if (cursor >= 100 && cursor < 100 + favoritePresets.length) radio.selectStation(favoritePresets[cursor - 100].id)
  }
  function openRecordings(storage) {
    if (storage) { openSettingsStorage(); return }
    settingsOpen = false
    recordingsOpen = true
    recordingsView.editing = false
    recordingsView.storageEditing = false
    recordingsView.nowEditing = false
    recordingsView.tab = "library"
    recordingsView.activate()
    scroller.contentY = 0
  }
  function openStationEditor(edit) {
    if (stationMutationPending) return
    const s = typeof edit === "object" ? edit : edit ? radio.station : {}
    settingsTab = "stations"
    editingStationId = s.id || ""
    stationName.text = s.name || ""; stationURL.text = s.streamUrl || ""
    stationCity.text = s.city || ""; stationCountry.text = s.country || ""; stationWebsite.text = s.website || ""
    stationError = ""
    confirmStationDelete = false; stationEditorOpen = true
    Qt.callLater(function() { if (root.settingsOpen && root.settingsTab === "stations" && root.stationEditorOpen) stationName.forceActiveFocus() })
  }
  function deleteStation() {
    if (stationMutationPending) return
    if (!confirmStationDelete) { confirmStationDelete = true; return }
    stationError = ""
    pendingStationSerial = radio.deleteCustomStation(editingStationId || radio.station.id)
    if (!pendingStationSerial) stationError = radio.customStationError
    confirmStationDelete = false
  }
  function saveStation() {
    if (stationMutationPending) return
    stationError = ""
    pendingStationSerial = radio.saveCustomStation({id: editingStationId, name: stationName.text.trim(), streamUrl: stationURL.text.trim(), city: stationCity.text.trim(), country: stationCountry.text.trim(), website: stationWebsite.text.trim()})
    if (!pendingStationSerial) stationError = radio.customStationError
  }
  onSettingsOpenChanged: if (!settingsOpen) {
    stationEditorOpen = false
    confirmStationDelete = false
    keyCatcher.forceActiveFocus()
  }
  onOpenedChanged: {
    if (!opened) { stationPicker.close(); bufferPicker.close(); speedPicker.close(); sleepPopup.close(); stationEditorOpen = false; confirmStationDelete = false }
    else if (!radio.hasStation && radio.playbackKind !== "recording") cursor = 0
  }
  Connections {
    target: root.radio
    function onWantedChanged() { if (!root.radio.wanted) sleepPopup.close() }
    function onStationIdChanged() { stationPicker.value = root.radio.stationId; root.confirmStationDelete = false }
    function onBufferMinutesChanged() { bufferPicker.value = String(root.radio.bufferMinutes) }
    function onReadyChanged() {
      if (!root.radio.ready && root.stationMutationPending) {
        root.pendingStationSerial = 0
        root.stationError = "Station manager disconnected. Please try again."
      }
    }
    function onCustomMutationSerialChanged() {
      if (!root.pendingStationSerial || root.radio.customMutationSerial !== root.pendingStationSerial) return
      root.pendingStationSerial = 0
      root.stationError = root.radio.customStationError
      if (root.radio.customMutationOK) {
        root.stationEditorOpen = false
        Qt.callLater(function() { addStationButton.forceActiveFocus() })
      }
    }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: (stationPicker.popupOpen || bufferPicker.popupOpen || speedPicker.popupOpen || sleepPopup.opened || stationEditorOpen || recordingsOpen || settingsStorage || settingsOpen && settingsTab === "stations") ? null : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(header.implicitHeight + panelContent.implicitHeight + playbackDock.implicitHeight + Style.space(28))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.recordingsOpen || root.settingsOpen && (root.settingsStorage || root.settingsTab === "stations") || sleepPopup.opened || speedPicker.popupOpen || stationPicker.popupOpen || bufferPicker.popupOpen || stationName.activeFocus || stationURL.activeFocus || stationCity.activeFocus || stationCountry.activeFocus || stationWebsite.activeFocus || saveStationButton.activeFocus || cancelStationButton.activeFocus
      Keys.onEscapePressed: event => {
        if (root.settingsOpen) { root.backFromSettings(); event.accepted = true }
        else event.accepted = false
      }
      onCloseRequested: root.settingsOpen ? root.backFromSettings() : root.close()
      onTabRequested: direction => root.advanceCursor(direction)
      onMoveRequested: (dx, dy) => {
        if (dy) root.advanceCursor(dy)
        if (dx) {
          if (root.cursor === 15 && root.radio.playbackKind === "recording") root.radio.seekRecording(root.radio.position + dx * 30)
          else if (root.cursor === 22 && root.radio.dvr) root.radio.seek(root.radio.position + dx * 30)
          else { root.cursor = 2; root.radio.commitVolume(root.radio.volume + dx * 5) }
        }
      }
      onActivateRequested: root.activate()
      onTextKey: text => root.playbackShortcut(text)

      Column {
        anchors.fill: parent
        spacing: Style.space(14)
        Column {
          id: header
          width: parent.width
          spacing: Style.space(4)
          Row {
            width: parent.width
            spacing: Style.space(8)
            Row {
              width: parent.width - captureIndicator.width - settingsButton.width - parent.spacing * 2
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)
              Text {
                id: appTitle
                text: "YAKKER"
                font.letterSpacing: Style.space(2)
                textFormat: Text.PlainText
                color: root.barForeground
                font.family: root.uiFontFamily
                font.pixelSize: Style.fontPx(1.167)
                font.weight: Font.DemiBold
              }
              Text {
                id: settingsSectionTitle
                visible: root.settingsOpen
                width: Math.max(0, parent.width - appTitle.width - parent.spacing)
                text: "· Settings"
                textFormat: Text.PlainText
                color: Qt.alpha(root.barForeground, 0.8)
                font.family: root.uiFontFamily
                font.pixelSize: Style.fontPx(1.167)
                font.weight: Font.Medium
                elide: Text.ElideRight
              }
            }
            Radio.FocusButton {
              id: captureIndicator
              visible: Number(root.radio.recordings.activeCount) > 0
              width: visible ? implicitWidth : 0
              text: "● REC " + root.radio.recordings.activeCount
              fontSize: Style.fontPx(1)
              foreground: Commons.Color.urgent
              tooltipText: "Background captures · Open recordings"
              focusable: root.auxiliaryView
              onClicked: root.openRecordings(false)
            }
            Radio.FocusButton {
              id: settingsButton
              iconName: root.settingsOpen ? "close" : "settings"
              tooltipText: root.settingsOpen ? "Close settings" : "Open settings"
              Accessible.role: Accessible.Button
              Accessible.name: tooltipText
              foreground: root.barForeground
              selected: root.settingsOpen
              focusable: root.auxiliaryView
              hasCursor: root.cursor === 4
              onHovered: hovered => { if (hovered) root.cursor = 4 }
              onClicked: root.settingsOpen ? root.closeSettings() : root.openSettings()
            }
          }
          Row {
            visible: !root.settingsOpen
            width: parent.width
            spacing: Style.space(6)
            Radio.FocusButton {
              id: listenButton
              width: Style.space(72)
              text: "Listen"
              height: Style.space(38)
              leftAlign: true
              horizontalPadding: 0
              radius: 0
              color: hot ? Qt.alpha(root.barForeground, 0.04) : "transparent"
              borderSpec: hasCursor || activeFocus ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
              foreground: root.barForeground
              selected: !root.recordingsOpen
              focusable: root.auxiliaryView
              hasCursor: root.cursor === 20
              onHovered: hovered => { if (hovered) root.cursor = 20 }
              onClicked: root.showPlayer()
              Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.bottomMargin: -Style.space(4); height: Style.space(2); color: Commons.Color.accent; visible: parent.selected }
            }
            Radio.FocusButton {
              id: recordingsButton
              width: Style.space(74)
              text: "Library"
              tooltipText: "Open recordings" + (Number(root.radio.recordings.activeCount) > 0 ? " · " + root.radio.recordings.activeCount + " active" : "")
              Accessible.role: Accessible.Button
              Accessible.name: tooltipText
              height: Style.space(38)
              leftAlign: true
              horizontalPadding: 0
              radius: 0
              color: hot ? Qt.alpha(root.barForeground, 0.04) : "transparent"
              borderSpec: hasCursor || activeFocus ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
              foreground: root.barForeground
              selected: root.recordingsOpen && recordingsView.tab === "library"
              focusable: root.auxiliaryView
              hasCursor: root.cursor === 14
              onHovered: hovered => { if (hovered) root.cursor = 14 }
              onClicked: root.openRecordings(false)
              Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.bottomMargin: -Style.space(4); height: Style.space(2); color: Commons.Color.accent; visible: parent.selected }
            }
            Radio.FocusButton {
              id: schedulesButton
              width: Style.space(90)
              text: "Schedules"
              height: Style.space(38)
              leftAlign: true
              horizontalPadding: 0
              radius: 0
              color: hot ? Qt.alpha(root.barForeground, 0.04) : "transparent"
              borderSpec: hasCursor || activeFocus ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
              foreground: root.barForeground
              selected: root.recordingsOpen && recordingsView.tab === "schedules"
              focusable: root.auxiliaryView
              hasCursor: root.cursor === 21
              onHovered: hovered => { if (hovered) root.cursor = 21 }
              onClicked: root.openSchedules()
              Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.bottomMargin: -Style.space(4); height: Style.space(2); color: Commons.Color.accent; visible: parent.selected }
            }
          }
          Row {
            width: parent.width
            visible: root.settingsOpen
            spacing: Style.space(6)
            Repeater {
              id: settingsTabs
              model: [{key:"listening",label:"Listening"}, {key:"storage",label:"Storage"}, {key:"alerts",label:"Alerts"}, {key:"stations",label:"Stations"}]
              Radio.FocusButton {
                required property var modelData
                required property int index
                width: (parent.width - parent.spacing * 3) / 4
                height: Style.space(38)
                text: modelData.label
                fontSize: Style.fontPx(1)
                horizontalPadding: 0
                radius: 0
                color: hot ? Qt.alpha(root.barForeground, 0.04) : "transparent"
                borderSpec: hasCursor || activeFocus ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
                foreground: root.barForeground
                selected: root.settingsTab === modelData.key
                focusable: true
                enabled: !root.stationMutationPending && !recordingsView.pending
                hasCursor: root.cursor === 30 + index
                Accessible.role: Accessible.PageTab
                Accessible.name: text
                onHovered: hovered => { if (hovered) root.cursor = 30 + index }
                onClicked: root.selectSettingsTab(modelData.key)
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.bottomMargin: -Style.space(4); height: Style.space(2); color: Commons.Color.accent; visible: parent.selected }
              }
            }
          }
          Ui.PanelSeparator { width: parent.width }
        }
        Flickable {
          id: scroller
          width: parent.width
          height: Math.max(0, parent.height - header.height - playbackDock.height - parent.spacing * 2)
          onHeightChanged: if (root.scrollTarget) scrollEnsure.restart()
          onContentHeightChanged: if (root.scrollTarget) scrollEnsure.restart()
          contentWidth: width
          contentHeight: panelContent.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          clip: true
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
          Column {
            id: panelContent
            width: parent.width
            spacing: Style.space(16)
            Radio.RecordingsView {
              id: recordingsView
              width: parent.width
              visible: root.recordingsOpen || root.settingsStorage
              embedded: true
              externalBack: root.settingsStorage
              settingsTabbed: root.settingsOpen
              storageSection: root.settingsTab === "alerts" ? "alerts" : "storage"
              radio: root.radio
              foreground: root.barForeground
              bar: root.bar
              ensureVisible: root.ensureItemVisible
              onBack: root.settingsOpen ? root.closeSettings() : root.showPlayer()
              onPlaybackShortcut: text => root.playbackShortcut(text)
              onStorageClosed: root.finishSettingsStorage()
              onRequestStorage: root.openSettingsStorage()
            }
            Column {
              id: settingsView
              width: parent.width
              spacing: Style.space(12)
              visible: root.settingsOpen && !root.settingsStorage
              Text { width: parent.width; visible: root.settingsTab === "listening"; text: "Listening"; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.25); font.weight: Font.DemiBold }
              Ui.Dropdown {
                id: bufferPicker
                visible: root.settingsTab === "listening"
                fontFamily: root.uiFontFamily
                width: parent.width
                label: "Listening buffer"
                options: [{value:"0",label:"Live only"}, {value:"5",label:"5 minutes"}, {value:"15",label:"15 minutes"}, {value:"30",label:"30 minutes"}]
                value: String(root.radio.bufferMinutes)
                foreground: root.barForeground
                hasCursor: root.cursor === 5
                onHovered: hovered => { if (hovered) root.cursor = 5 }
                onChanged: value => { root.radio.setBufferMinutes(Number(value)); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
              }
              Text {
                width: parent.width
                visible: root.settingsTab === "listening"
                text: "Replay stays in memory. In Live only, Pause starts a temporary 15-minute buffer. Changing this setting clears history and returns to live."
                textFormat: Text.PlainText
                color: root.barForeground
                opacity: 0.8
                font.family: root.uiFontFamily
                font.pixelSize: Style.fontPx(1)
                wrapMode: Text.WordWrap
              }
              Column {
                width: parent.width
                spacing: Style.space(12)
                visible: root.settingsTab === "stations" && !root.stationEditorOpen
                SettingTitle { text: "Custom stations" }
                SettingHint { text: "Add a direct audio stream, then find it in the station picker or save it as a favorite." }
                Radio.FocusButton {
                  id: addStationButton
                  text: "Add station"
                  iconName: "plus"
                  color: Qt.alpha(Commons.Color.accent, 0.16)
                  foreground: root.barForeground
                  focusable: true
                  enabled: root.radio.ready && !root.stationMutationPending
                  onActiveFocusChanged: if (activeFocus) root.ensureItemVisible(this)
                  onClicked: root.openStationEditor(false)
                }
                SettingHint { visible: !customStations.count; text: "No custom stations yet." }
                Repeater {
                  id: customStations
                  model: root.radio.stations.filter(function(station) { return station.custom === true })
                  Column {
                    id: customStationRow
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(6)
                    Ui.PanelSeparator { width: parent.width }
                    SettingLabel { id: customStationTitle; text: parent.modelData.name; wrapMode: Text.Wrap }
                    SettingHint { text: [parent.modelData.city, parent.modelData.country].filter(function(value) { return !!value }).join(" · "); visible: !!text }
                    Radio.FocusButton {
                      id: customStationEdit
                      text: "Edit station"
                      fontSize: Style.fontPx(1)
                      horizontalPadding: 0
                      foreground: Qt.alpha(root.barForeground, 0.8)
                      focusable: true
                      enabled: root.radio.ready && !root.stationMutationPending
                      onActiveFocusChanged: if (activeFocus) root.ensureItemVisible(this)
                      onClicked: root.openStationEditor(parent.modelData)
                    }
                  }
                }
              }
              Column {
                width: parent.width
                spacing: Style.space(10)
                visible: root.settingsTab === "stations" && root.stationEditorOpen
                enabled: !root.stationMutationPending
                SettingTitle { text: root.editingStationId ? "Edit station" : "New station" }
                SettingHint { text: "Name and audio stream are required. Location and website are optional." }
                SettingLabel { text: "Station name" }
                Ui.TextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationName
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationName) })
                  width: parent.width
                  placeholderText: "e.g. Community Radio"
                  Accessible.name: "Station name (required)"
                  foreground: root.barForeground
                  maximumLength: 160
                  KeyNavigation.tab: stationURL
                  Keys.onEscapePressed: root.backFromSettings()
                }
                SettingLabel { text: "Audio stream URL" }
                Ui.TextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationURL
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationURL) })
                  width: parent.width
                  placeholderText: "https://…/stream"
                  Accessible.name: "Audio stream URL"
                  foreground: root.barForeground
                  maximumLength: 2048
                  KeyNavigation.tab: stationCity
                  Keys.onEscapePressed: root.backFromSettings()
                }
                SettingHint { text: "Use a direct HTTP or HTTPS audio stream, rather than a station web page." }
                Ui.PanelSeparator { width: parent.width }
                SettingLabel { text: "City · optional" }
                Ui.TextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationCity
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationCity) })
                  width: parent.width
                  placeholderText: "e.g. Boston"
                  Accessible.name: "City · optional"
                  foreground: root.barForeground
                  maximumLength: 100
                  KeyNavigation.tab: stationCountry
                  Keys.onEscapePressed: root.backFromSettings()
                }
                SettingLabel { text: "Country · optional" }
                Ui.TextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationCountry
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationCountry) })
                  width: parent.width
                  placeholderText: "e.g. United States"
                  Accessible.name: "Country · optional"
                  foreground: root.barForeground
                  maximumLength: 100
                  KeyNavigation.tab: stationWebsite
                  Keys.onEscapePressed: root.backFromSettings()
                }
                SettingLabel { text: "Website · optional" }
                Ui.TextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationWebsite
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationWebsite) })
                  width: parent.width
                  placeholderText: "https://…"
                  Accessible.name: "Website · optional"
                  foreground: root.barForeground
                  maximumLength: 2048
                  KeyNavigation.tab: saveStationButton
                  Keys.onReturnPressed: root.saveStation()
                  Keys.onEscapePressed: root.backFromSettings()
                }
                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Radio.FocusButton {
                    id: saveStationButton
                    width: (parent.width - parent.spacing) * 0.65
                    text: root.stationMutationPending ? "Saving…" : root.editingStationId ? "Save changes" : "Add station"
                    color: Qt.alpha(Commons.Color.accent, 0.16)
                    foreground: root.barForeground
                    focusable: true
                    enabled: root.radio.ready && !root.stationMutationPending
                    onActiveFocusChanged: if (activeFocus) root.ensureItemVisible(this)
                    KeyNavigation.tab: cancelStationButton
                    Keys.onEscapePressed: root.backFromSettings()
                    onClicked: root.saveStation()
                  }
                  Radio.FocusButton {
                    id: cancelStationButton
                    width: (parent.width - parent.spacing) * 0.35
                    text: "Cancel"
                    foreground: root.barForeground
                    focusable: true
                    onActiveFocusChanged: if (activeFocus) root.ensureItemVisible(this)
                    KeyNavigation.tab: deleteStationButton.visible ? deleteStationButton : stationName
                    Keys.onEscapePressed: root.backFromSettings()
                    onClicked: root.backFromSettings()
                  }
                }
                Radio.FocusButton {
                  id: deleteStationButton
                  visible: !!root.editingStationId
                  KeyNavigation.tab: stationName
                  text: root.confirmStationDelete ? "Confirm delete station" : "Delete station"
                  fontSize: Style.fontPx(1)
                  horizontalPadding: 0
                  foreground: Commons.Color.urgent
                  focusable: true
                  onActiveFocusChanged: if (activeFocus) root.ensureItemVisible(this)
                  Keys.onEscapePressed: root.backFromSettings()
                  onClicked: root.deleteStation()
                }
              }
              Text {
                id: stationErrorText
                width: parent.width
                visible: root.settingsTab === "stations" && text.length > 0
                text: root.stationError || root.radio.customCatalogError
                textFormat: Text.PlainText
                color: Commons.Color.urgent
                font.family: root.uiFontFamily
                font.pixelSize: Style.fontPx(1)
                wrapMode: Text.Wrap
              }
              Text { width: parent.width; visible: root.settingsTab === "listening"; text: "Keyboard shortcuts"; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.25); font.weight: Font.DemiBold }
              Repeater {
                model: root.settingsTab !== "listening" ? [] : [ {key:"P", action:"Pause / resume"}, {key:"[  /  ]", action:"Skip 30 seconds"}, {key:"G", action:"Return to live"}, {key:"M", action:"Mute / unmute"}, {key:"←  /  →", action:"Adjust volume"} ]
                Row {
                  required property var modelData
                  width: settingsView.width
                  Text { width: parent.width * 0.64; text: modelData.action; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.8; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                  Text { width: parent.width * 0.36; text: modelData.key; textFormat: Text.PlainText; color: root.barForeground; horizontalAlignment: Text.AlignRight; font.family: Style.font.family; font.pixelSize: Style.fontPx(0.917) }
                }
              }
            }
            Column {
              id: playerView
              width: parent.width
              visible: !root.auxiliaryView
              spacing: Style.space(16)


              Row {
                width: parent.width
                spacing: Style.space(14)
                Rectangle {
                  width: Style.space(88)
                  height: width
                  radius: Style.cornerRadius
                  color: Qt.alpha(root.barForeground, 0.05)
                  Radio.StationLogo { anchors.fill: parent; anchors.margins: Style.space(8); station: root.radio.playbackStation; fallbackColor: Commons.Color.accent }
                }
                Column {
                  width: parent.width - Style.space(102) - favoriteButton.width - parent.spacing
                  spacing: Style.space(5)
                  Text {
                    width: parent.width
                    text: root.radio.playbackKind === "recording" ? "SAVED RECORDING" : root.radio.station.subtitle
                    textFormat: Text.PlainText
                    color: root.barForeground
                    opacity: 0.8
                    font.family: root.uiFontFamily
                    font.pixelSize: Style.fontPx(1)
                    wrapMode: Text.Wrap
                  }
                  Radio.MarqueeText {
                    id: stationHeading
                    scrolling: root.opened
                    width: parent.width
                    text: root.radio.playbackKind === "recording" ? root.radio.recordingTitle : root.radio.station.name
                    textFormat: Text.PlainText
                    color: root.barForeground
                    font.family: root.uiFontFamily
                    font.pixelSize: Style.fontPx(2)
                    font.weight: Font.DemiBold
                  }
                  Radio.StationPicker {
                    id: stationPicker
                    width: parent.width
                    popupWidth: panelContent.width
                    popupX: -stationPicker.mapToItem(panelContent, 0, 0).x
                    triggerLabel: root.radio.playbackKind === "recording" ? "Live station" : "Change station"
                    placeholderText: root.radio.hasStation ? "Station, city or country" : "Choose a station"
                    emptyText: "No matching stations"
                    value: root.radio.stationId
                    options: root.radio.stationOptions
                    foreground: root.barForeground
                    hasCursor: root.cursor === 0
                    onHovered: hovered => { if (hovered) root.cursor = 0 }
                    onChanged: value => { root.radio.selectStation(value); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
                  }
                }
                Radio.FocusButton {
                  id: favoriteButton
                  visible: root.radio.playbackKind !== "recording"
                  width: visible ? implicitWidth : 0
                  iconName: "heart"
                  selected: root.radio.favoriteIds.indexOf(root.radio.stationId) !== -1
                  tooltipText: selected ? "Remove from favorites" : "Add to favorites"
                  Accessible.role: Accessible.Button
                  Accessible.name: tooltipText
                  Accessible.checkable: true
                  Accessible.checked: selected
                  enabled: root.radio.hasStation
                  opacity: enabled ? 1 : 0.35
                  foreground: root.barForeground
                  hasCursor: root.cursor === 13
                  onHovered: hovered => { if (hovered) root.cursor = 13 }
                  onClicked: root.radio.toggleFavorite(root.radio.stationId)
                }
              }
              Column {
                width: parent.width
                visible: root.favoritePresets.length > 0 && root.radio.playbackKind !== "recording"
                spacing: Style.space(6)
                Text { text: "FAVORITES"; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                Grid {
                  id: presetGrid
                  width: parent.width
                  columns: width < Style.space(340) ? 2 : 3
                  spacing: Style.space(6)
                  Repeater {
                    id: presetRepeater
                    model: root.favoritePresets
                    Radio.FocusButton {
                      required property var modelData
                      required property int index
                      width: (presetGrid.width - presetGrid.spacing * (presetGrid.columns - 1)) / presetGrid.columns
                      height: Style.space(46)
                      selected: root.radio.stationId === modelData.id
                      foreground: root.barForeground
                      tooltipText: modelData.name + (modelData.city ? " · " + modelData.city : "")
                      Accessible.role: Accessible.Button
                      Accessible.name: tooltipText
                      Accessible.checkable: true
                      Accessible.checked: selected
                      hasCursor: root.cursor === 100 + index
                      onHovered: hovered => { if (hovered) root.cursor = 100 + index }
                      onClicked: root.radio.selectStation(modelData.id)
                      Column {
                        anchors.fill: parent
                        anchors.margins: Style.space(7)
                        spacing: Style.space(2)
                        Radio.MarqueeText { scrolling: false; width: parent.width; text: modelData.name; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                        Text { width: parent.width; text: modelData.city || modelData.country || ""; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; font.family: root.uiFontFamily; font.pixelSize: Style.space(11); elide: Text.ElideRight }
                      }
                    }
                  }
                }
              }
              Text {
                width: parent.width
                visible: text.length > 0 && root.radio.playbackKind !== "recording" && root.radio.playbackState === "playing" && (!root.radio.dvr || root.radio.behindLive <= 3)
                text: root.radio.title
                textFormat: Text.PlainText
                color: root.barForeground
                font.family: root.uiFontFamily
                font.pixelSize: Style.fontPx(1.167)
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }
              Column {
                width: parent.width
                spacing: Style.space(6)
                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Rectangle { width: Style.space(6); height: width; radius: width / 2; color: root.radio.playbackState === "error" ? Commons.Color.urgent : root.radio.playbackState === "playing" ? Commons.Color.accent : root.barForeground; anchors.verticalCenter: parent.verticalCenter }
                  Text {
                    width: parent.width - liveButton.width - Style.space(6) - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.listeningStatus
                    textFormat: Text.PlainText
                    color: root.radio.playbackState === "error" ? Commons.Color.urgent : root.barForeground
                    font.family: root.uiFontFamily
                    font.pixelSize: Style.fontPx(1)
                    wrapMode: Text.Wrap
                  }
                  Radio.FocusButton {
                    id: liveButton
                    visible: root.radio.playbackKind !== "recording" && root.radio.dvr && (root.radio.behindLive > 3 || root.radio.paused)
                    width: visible ? implicitWidth : 0
                    text: "Go live"
                    fontSize: Style.fontPx(1)
                    height: Style.space(30)
                    foreground: Commons.Color.accent
                    background: Qt.alpha(Commons.Color.accent, 0.1)
                    enabled: root.radio.dvr
                    hasCursor: root.cursor === 9
                    onHovered: hovered => { if (hovered) root.cursor = 9 }
                    onClicked: root.radio.goLive()
                  }
                }
                Ui.BorderSurface {
                  width: parent.width
                  implicitHeight: timelineSlider.implicitHeight + Style.space(4)
                  visible: root.radio.bufferActive && root.radio.playbackKind !== "recording"
                  color: "transparent"
                  radius: Style.cornerRadius
                  borderSpec: root.cursor === 22 ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
                  Ui.PanelSlider {
                    id: timelineSlider
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    minimum: root.radio.bufferStart
                    maximum: Math.max(minimum + 1, root.radio.bufferEnd)
                    value: root.radio.position
                    step: 30
                    bar: root.bar
                    enabled: root.radio.dvr
                    fillColor: Commons.Color.accent
                    knobColor: Commons.Color.accent
                    trackColor: Qt.alpha(root.barForeground, 0.15)
                    Accessible.name: "Live replay position"
                    onReleased: value => root.radio.seek(value)
                  }
                }
                Row {
                  width: parent.width
                  visible: timelineSlider.visible
                  Text { width: parent.width / 2; text: "−" + root.radio.clock(root.radio.bufferEnd - root.radio.bufferStart); textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; font.family: Style.font.family; font.pixelSize: Style.fontPx(1) }
                  Text { width: parent.width / 2; text: "LIVE"; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; horizontalAlignment: Text.AlignRight; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                }
                Ui.BorderSurface {
                  width: parent.width
                  implicitHeight: fileTimeline.implicitHeight + Style.space(4)
                  visible: root.radio.playbackKind === "recording"
                  color: "transparent"
                  radius: Style.cornerRadius
                  borderSpec: root.cursor === 15 ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
                  Ui.PanelSlider {
                    id: fileTimeline
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    minimum: 0
                    maximum: Math.max(1, root.radio.duration)
                    value: root.radio.position
                    step: 1
                    bar: root.bar
                    enabled: root.seekable
                    fillColor: Commons.Color.accent
                    knobColor: Commons.Color.accent
                    trackColor: Qt.alpha(root.barForeground, 0.15)
                    Accessible.name: "Recording position"
                    onReleased: value => root.radio.seekRecording(value)
                  }
                }
                Text { width: parent.width; visible: root.radio.playbackKind === "recording"; text: root.radio.clock(root.radio.position) + " / " + root.radio.clock(root.radio.duration); textFormat: Text.PlainText; color: root.barForeground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                Text { width: parent.width; visible: root.radio.bufferExpired; text: "Older audio expired. Playback moved to the available buffer."; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
              }
              Text { width: parent.width; visible: text.length > 0; text: root.radio.error || root.radio.playbackProgressError; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
              Row {
                width: implicitWidth
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(24)
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  Radio.FocusButton {
                    id: backButton
                    width: Style.space(48)
                    height: Style.space(36)
                    iconName: "back"
                    iconSize: Style.space(23)
                    tooltipText: "Rewind 30 seconds"
                    Accessible.role: Accessible.Button
                    Accessible.name: tooltipText
                    foreground: root.barForeground
                    enabled: root.canRewind
                    opacity: enabled ? 1 : 0.35
                    hasCursor: root.cursor === 7
                    onHovered: hovered => { if (hovered) root.cursor = 7 }
                    onClicked: root.radio.skip(-30)
                  }
                  Text { width: parent.width; text: "30 sec"; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                }
                Radio.FocusButton {
                  id: playButton
                  width: Style.space(64)
                  height: width
                  radius: width / 2
                  iconName: root.radio.wanted && !root.radio.paused ? "pause" : "play"
                  iconSize: Style.space(25)
                  tooltipText: root.playTooltip
                  Accessible.role: Accessible.Button
                  Accessible.name: tooltipText
                  foreground: Commons.Color.background
                  color: Commons.Color.accent
                  borderSpec: hasCursor ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
                  enabled: root.canPlay
                  opacity: enabled ? 1 : 0.35
                  hasCursor: root.cursor === 1
                  onHovered: hovered => { if (hovered) root.cursor = 1 }
                  onClicked: root.togglePlayback()
                }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  Radio.FocusButton {
                    id: forwardButton
                    width: Style.space(48)
                    height: Style.space(36)
                    iconName: "forward"
                    iconSize: Style.space(23)
                    tooltipText: "Forward 30 seconds"
                    Accessible.role: Accessible.Button
                    Accessible.name: tooltipText
                    foreground: root.barForeground
                    enabled: root.canForward
                    opacity: enabled ? 1 : 0.35
                    hasCursor: root.cursor === 8
                    onHovered: hovered => { if (hovered) root.cursor = 8 }
                    onClicked: root.radio.skip(30)
                  }
                  Text { width: parent.width; text: "30 sec"; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                }
              }
              Row {
                width: implicitWidth
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(6)
                Radio.FocusButton {
                  id: recordNowButton
                  iconSize: Style.space(16)
                  text: "Record"
                  iconName: "record"
                  foreground: root.barForeground
                  fontSize: Style.fontPx(1)
                  tooltipText: "Record a live stream starting now"
                  hasCursor: root.cursor === 23
                  onHovered: hovered => { if (hovered) root.cursor = 23 }
                  onClicked: root.recordNow()
                }
                Radio.FocusButton {
                  id: sleepButton
                  iconSize: Style.space(16)
                  iconName: "moon" // nf-md-timer_outline
                  text: "Sleep"
                  fontSize: Style.fontPx(1)
                  tooltipText: root.radio.sleepRemaining > 0 ? "Sleep in " + root.radio.clock(root.radio.sleepRemaining) : "Sleep timer"
                  Accessible.role: Accessible.Button
                  Accessible.name: tooltipText
                  foreground: root.barForeground
                  enabled: root.radio.wanted || root.radio.sleepRemaining > 0
                  opacity: enabled ? 1 : 0.35
                  selected: root.radio.sleepRemaining > 0
                  hasCursor: root.cursor === 19
                  onHovered: hovered => { if (hovered) root.cursor = 19 }
                  onClicked: sleepPopup.opened ? sleepPopup.close() : sleepPopup.open()
                  QQC.Popup {
                    id: sleepPopup
                    x: Math.max(-sleepButton.mapToItem(panelContent, 0, 0).x, Math.min(0, panelContent.width - sleepButton.mapToItem(panelContent, 0, 0).x - width))
                    y: sleepButton.height + Style.space(4)
                    width: Math.min(Style.space(260), panelContent.width)
                    padding: Style.space(12)
                    focus: true
                    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutsideParent
                    onOpened: { root.sleepError = ""; Qt.callLater(function() { sleepPresets.itemAt(0).forceActiveFocus() }) }
                    onClosed: if (!root.recordingsOpen && root.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                    background: Ui.BorderSurface {
                      color: Commons.Color.popups.background
                      radius: Style.cornerRadius
                      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
                    }
                    contentItem: Column {
                      spacing: Style.space(8)
                      Text { width: parent.width; text: root.radio.sleepRemaining > 0 ? "Sleep in " + root.radio.clock(root.radio.sleepRemaining) : "Sleep timer"; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167) }
                      Row {
                        width: parent.width
                        spacing: Style.space(6)
                        Repeater {
                          id: sleepPresets
                          model: [15, 30, 60]
                          Radio.FocusButton {
                            required property int modelData
                            width: (parent.width - parent.spacing * 2) / 3
                            text: modelData + " min"
                            foreground: root.barForeground
                            bordered: true
                            focusable: true
                            onClicked: { root.radio.setSleepTimer(modelData); sleepPopup.close() }
                          }
                        }
                      }
                      Text { width: parent.width; text: "Custom minutes (1–240)"; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                      Row {
                        width: parent.width
                        spacing: Style.space(6)
                        Ui.TextField {
                          id: sleepMinutes
                          width: parent.width - sleepApply.width - parent.spacing
                          text: "30"
                          maximumLength: 3
                          Accessible.name: "Sleep timer minutes"
                          foreground: root.barForeground
                          inputMethodHints: Qt.ImhDigitsOnly
                          KeyNavigation.tab: sleepApply
                          onAccepted: root.applySleepTimer()
                        }
                        Radio.FocusButton { id: sleepApply; text: "Set"; foreground: root.barForeground; bordered: true; focusable: true; onClicked: root.applySleepTimer() }
                      }
                      Text { width: parent.width; text: root.sleepError; visible: text.length > 0; wrapMode: Text.Wrap; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                      Radio.FocusButton { width: parent.width; text: "Turn timer off"; enabled: root.radio.sleepRemaining > 0; opacity: enabled ? 1 : 0.35; foreground: root.barForeground; bordered: true; focusable: true; onClicked: { root.radio.setSleepTimer(0); sleepPopup.close() } }
                    }
                  }
                }

                Radio.FocusButton {
                  id: stopButton
                  iconSize: Style.space(16)
                  iconName: "stop"
                  text: "Stop"
                  fontSize: Style.fontPx(1)
                  tooltipText: "Stop listening" + (root.radio.playbackKind === "recording" ? "" : " and clear replay history")
                  Accessible.role: Accessible.Button
                  Accessible.name: tooltipText
                  foreground: root.barForeground
                  enabled: root.radio.wanted
                  opacity: enabled ? 1 : 0.35
                  hasCursor: root.cursor === 6
                  onHovered: hovered => { if (hovered) root.cursor = 6 }
                  onClicked: root.radio.stop()
                }
              }
              Row {
                width: parent.width
                spacing: Style.space(8)
                visible: root.radio.playbackKind === "recording"
                Ui.Dropdown {
                  id: speedPicker
                  width: (parent.width - parent.spacing) / 2
                  showLabel: false
                  value: String(root.radio.playbackSpeed)
                  options: [{value:"0.75",label:"Speed · 0.75×"}, {value:"1",label:"Speed · 1×"}, {value:"1.25",label:"Speed · 1.25×"}, {value:"1.5",label:"Speed · 1.5×"}, {value:"2",label:"Speed · 2×"}]
                  foreground: root.barForeground
                  hasCursor: root.cursor === 18
                  onHovered: hovered => { if (hovered) root.cursor = 18 }
                  onChanged: value => { root.radio.setPlaybackSpeed(Number(value)); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
                }
                Radio.FocusButton {
                  id: returnLiveButton
                  width: speedPicker.width
                  text: root.radio.hasStation ? "Return to live" : "Choose live station"
                  foreground: root.barForeground
                  hasCursor: root.cursor === 16
                  onHovered: hovered => { if (hovered) root.cursor = 16 }
                  onClicked: root.radio.hasStation ? root.radio.goLive() : root.chooseStation()
                }
              }
            }
          }
        }
        Column {
          id: playbackDock
          width: parent.width
          spacing: Style.space(8)
          Keys.onPressed: event => {
            if (event.modifiers === Qt.NoModifier && event.text && "p[]gmr".indexOf(event.text.toLowerCase()) >= 0) {
              root.playbackShortcut(event.text)
              event.accepted = true
            }
          }
          Ui.PanelSeparator { width: parent.width }
          Row {
            width: parent.width
            visible: root.auxiliaryView
            spacing: Style.space(8)
            Radio.StationLogo { width: Style.space(36); height: width; station: root.radio.playbackStation; fallbackColor: Commons.Color.accent; anchors.verticalCenter: parent.verticalCenter }
            Column {
              width: parent.width - Style.space(44) - dockBack.width - dockPlay.width - dockForward.width - dockStop.width - parent.spacing * 4
              spacing: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter
              Radio.MarqueeText { scrolling: false; width: parent.width; text: root.radio.playbackKind === "recording" ? root.radio.recordingTitle : root.radio.station.name; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); font.weight: Font.DemiBold }
              Text { width: parent.width; text: root.radio.playbackKind === "recording" ? root.radio.clock(root.radio.position) + " / " + root.radio.clock(root.radio.duration) : root.listeningStatus; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); elide: Text.ElideRight }
            }
            Radio.FocusButton { id: dockBack; width: Style.space(30); horizontalPadding: 0; iconName: "back"; tooltipText: "Rewind 30 seconds"; Accessible.role: Accessible.Button; Accessible.name: tooltipText; foreground: root.barForeground; enabled: root.canRewind; opacity: enabled ? 1 : 0.35; focusable: true; onClicked: root.radio.skip(-30) }
            Radio.FocusButton { id: dockPlay; width: Style.space(34); horizontalPadding: 0; iconName: playButton.iconName; tooltipText: root.playTooltip; Accessible.role: Accessible.Button; Accessible.name: tooltipText; foreground: root.barForeground; selected: true; enabled: root.canPlay; opacity: enabled ? 1 : 0.35; focusable: true; onClicked: root.togglePlayback() }
            Radio.FocusButton { id: dockForward; width: Style.space(30); horizontalPadding: 0; iconName: "forward"; tooltipText: "Forward 30 seconds"; Accessible.role: Accessible.Button; Accessible.name: tooltipText; foreground: root.barForeground; enabled: root.canForward; opacity: enabled ? 1 : 0.35; focusable: true; onClicked: root.radio.skip(30) }
            Radio.FocusButton { id: dockStop; width: Style.space(30); horizontalPadding: 0; iconName: "stop"; tooltipText: "Stop listening"; Accessible.role: Accessible.Button; Accessible.name: tooltipText; foreground: root.barForeground; enabled: root.radio.wanted; opacity: enabled ? 1 : 0.35; focusable: true; onClicked: root.radio.stop() }
          }
          Text { width: parent.width; visible: root.auxiliaryView && text.length > 0; text: root.radio.error || root.radio.playbackProgressError; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Radio.FocusButton {
              id: muteButton
              width: Style.space(32)
              horizontalPadding: 0
              iconName: root.radio.muted ? "muted" : "volume"
              tooltipText: root.radio.muted ? "Unmute" : "Mute"
              Accessible.role: Accessible.Button
              Accessible.name: tooltipText
              foreground: root.barForeground
              focusable: root.auxiliaryView
              hasCursor: root.cursor === 3
              onHovered: hovered => { if (hovered) root.cursor = 3 }
              onClicked: root.radio.toggleMute()
            }
            Ui.BorderSurface {
              width: parent.width - muteButton.width - volumeLabel.width - parent.spacing * 2
              implicitHeight: volumeSlider.implicitHeight + Style.space(4)
              color: "transparent"
              radius: Style.cornerRadius
              borderSpec: (root.cursor === 2) || volumeSlider.activeFocus ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
              Ui.PanelSlider {
                id: volumeSlider
                anchors.fill: parent
                anchors.margins: Style.space(2)
                bar: root.bar
                value: root.radio.volume
                minimum: 0
                maximum: 100
                step: 5
                integer: true
                fillColor: Qt.alpha(root.barForeground, 0.6)
                knobColor: root.barForeground
                trackColor: Qt.alpha(root.barForeground, 0.15)
                Accessible.name: "Volume"
                activeFocusOnTab: root.auxiliaryView
                Keys.onLeftPressed: root.radio.commitVolume(root.radio.volume - 5)
                Keys.onRightPressed: root.radio.commitVolume(root.radio.volume + 5)
                onMoved: value => { root.cursor = 2; root.radio.setVolume(value) }
                onReleased: value => root.radio.commitVolume(value)
                onRightClicked: root.radio.toggleMute()
              }
            }
            Text { id: volumeLabel; width: Style.space(36); anchors.verticalCenter: parent.verticalCenter; text: root.radio.muted ? "Muted" : Math.round(volumeSlider.dragging ? volumeSlider.liveValue : root.radio.volume) + "%"; textFormat: Text.PlainText; horizontalAlignment: Text.AlignRight; color: root.barForeground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
          }
          Text {
            width: parent.width
            text: root.radio.sleepRemaining > 0 ? "Sleep in " + root.radio.clock(root.radio.sleepRemaining)
              : root.radio.playbackKind === "recording" ? "Saved recording · Position saved as you listen"
              : root.radio.temporaryBuffer ? "Temporary 15 min replay · In memory"
              : root.radio.bufferMinutes > 0 ? root.radio.bufferMinutes + " min replay · In memory" : "Live only · Pause to keep your place"
            textFormat: Text.PlainText
            color: root.barForeground
            opacity: 0.75
            font.family: root.uiFontFamily
            font.pixelSize: Style.fontPx(1)
            wrapMode: Text.Wrap
          }
        }
      }
    }
  }
}
