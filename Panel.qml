import QtQuick
import QtQuick.Window
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
  property bool keyboardNavigation: true
  readonly property bool virtualFocus: keyboardNavigation && keyCatcher.activeFocus
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
  readonly property bool compactNavigation: header.width < Style.space(340)
  readonly property bool compactDock: auxiliaryView && panel.contentHeight < Style.space(400)
  readonly property real navigationFontSize: compactNavigation ? Math.min(13, Style.fontPx(1)) : Style.fontPx(1.083)
  readonly property real navigationPadding: Style.space(compactNavigation ? 3 : 8)
  readonly property var favoritePresets: radio.favoriteIds.map(function(id) {
    return root.radio.stations.find(function(station) { return station.id === id })
  }).filter(function(station) { return !!station }).slice(0, 6)
  readonly property bool seekable: radio.wanted && (radio.playbackState === "playing" || radio.paused)
    && (radio.playbackKind === "recording" ? radio.duration > 0 : radio.dvr)
  readonly property bool canRewind: seekable && radio.position > (radio.playbackKind === "recording" ? 0 : radio.bufferStart) + 0.5
  readonly property bool canForward: seekable && (radio.playbackKind === "recording" ? radio.duration - radio.position > 0.5 : radio.behindLive > 3)
  readonly property string retryCountdown: Math.max(0, radio.retryDelay) + (radio.retryDelay === 1 ? " second" : " seconds")
  readonly property bool connectionIssue: radio.playbackKind === "live" && (radio.playbackState === "error" || radio.playbackState === "retrying")
  readonly property bool canPlay: (radio.hasStation || radio.wanted) && (!radio.wanted || radio.paused || radio.playbackState === "playing")
  readonly property string playTooltip: !radio.hasStation && !radio.wanted ? "Choose a station first" : radio.wanted ? (radio.paused ? "Resume" : "Pause") : radio.playbackState === "error" ? "Retry" : "Play"
  readonly property bool pausedLive: radio.playbackKind === "live" && radio.playbackPaused
  readonly property string listeningStatus: radio.playbackKind === "live" && radio.wanted && radio.dvr
      && (radio.playbackPaused || radio.playbackState === "playing" && radio.behindLive > 3)
    ? (pausedLive ? "Paused · buffering · " : "") + radio.clock(radio.behindLive) + " behind live"
    : radio.statusText
  readonly property string playbackHint: connectionIssue ? ""
    : radio.playbackStopped || radio.playbackPaused ? radio.playbackDetail
    : radio.playbackKind === "recording" ? "Saved recording · Position saved as you listen"
    : radio.playbackState === "connecting" ? "Connecting to the station"
    : radio.temporaryBuffer ? "Temporary 15 min replay · In memory"
    : radio.bufferMinutes > 0 ? radio.bufferMinutes + " min replay · In memory" : "Live only · Pause to keep your place"
  readonly property string playbackDescription: radio.playbackPaused ? (pausedLive
      ? "Resume from your paused position. The station is still buffering." : "Resume this recording from the paused position.")
    : radio.playbackStopped ? (radio.playbackKind === "recording"
      ? "Start live radio. Resume the saved recording from Library." : "Start a fresh live stream.")
    : radio.playbackKind === "recording" ? "Pause this recording and keep your position."
    : "Pause and keep your place while the station continues buffering."

  component PlaybackStatusIndicator: Item {
    width: Style.space(12)
    height: width
    Rectangle {
      anchors.centerIn: parent
      width: Style.space(6); height: width; radius: width / 2
      visible: !root.radio.playbackPaused && !root.radio.playbackStopped
      color: root.radio.playbackState === "playing" ? Commons.Color.accent : root.barForeground
    }
    Radio.FocusIcon {
      anchors.fill: parent
      visible: root.radio.playbackPaused || root.radio.playbackStopped
      name: root.radio.playbackPaused ? "pause" : "stop"
      foreground: root.pausedLive ? Commons.Color.accent : root.barForeground
    }
  }
  component PlaybackButton: Radio.FocusButton {
    width: Style.space(64)
    height: width
    radius: width / 2
    iconName: root.radio.wanted && !root.radio.paused ? "pause" : "play"
    iconSize: Style.space(25)
    tooltipText: root.playTooltip
    Accessible.description: root.playbackDescription
    foreground: Commons.Color.background
    color: Commons.Color.accent
    borderSpec: hasCursor || activeFocus ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent)
      : hot ? Border.controlSpec("hover-cursor", root.barForeground, Commons.Color.accent) : Border.none()
    enabled: root.canPlay
    opacity: enabled ? 1 : 0.35
    onClicked: root.togglePlayback()
  }
  component SettingsControl: Radio.FocusButton {
    width: Style.space(32)
    height: Style.space(32)
    foreground: root.barForeground
    hasCursor: root.virtualFocus && root.cursor === 4
    onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 4 } }
  }
  component NavigationRow: Row {
    width: parent.width
    spacing: Style.space(root.compactNavigation ? 3 : 4)
  }
  component NavigationTab: Radio.FocusButton {
    property int cursorId: -1
    function traverse(direction, event) {
      if (!root.recordingsOpen && (!root.settingsOpen || root.settingsTab === "listening")) {
        root.cursor = cursorId
        root.advanceCursor(direction)
        event.accepted = true
      } else event.accepted = false
    }
    Keys.onTabPressed: event => traverse(1, event)
    Keys.onBacktabPressed: event => traverse(-1, event)
    // Reserve both native text measurements so selection and focus never
    // squeeze a label or move the neighboring tabs.
    width: Math.ceil(Math.max(regularLabelSize.implicitWidth, selectedLabelSize.implicitWidth)) + horizontalPadding * 2 + _reservedBorderLeft + _reservedBorderRight
    Text {
      id: regularLabelSize
      visible: false
      text: parent.text
      textFormat: Text.PlainText
      font.family: parent.fontFamily
      font.pixelSize: parent.fontSize
      font.bold: false
    }
    Text {
      id: selectedLabelSize
      visible: false
      text: parent.text
      textFormat: Text.PlainText
      font.family: parent.fontFamily
      font.pixelSize: parent.fontSize
      font.bold: true
    }
    height: Style.space(38)
    horizontalPadding: root.navigationPadding
    fontSize: root.navigationFontSize
    leftAlign: true
    radius: 0
    color: hasCursor || activeFocus ? Style.focusFillFor(root.barForeground, Commons.Color.accent)
      : hot ? Style.hoverFillFor(root.barForeground, Commons.Color.accent) : "transparent"
    borderSpec: hasCursor || activeFocus ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent)
      : hot ? Border.controlSpec("hover-cursor", root.barForeground, Commons.Color.accent) : Border.none()
    foreground: root.barForeground
    Accessible.role: Accessible.PageTab
    Accessible.selected: selected
    Rectangle {
      anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
      anchors.bottomMargin: -Style.space(4)
      height: Style.space(2)
      color: Commons.Color.accent
      visible: parent.selected
    }
  }
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
    cursor = 30
    keyboardNavigation = true
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
  function selectSettingsTab(section, keepTabFocus) {
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
      if (keepTabFocus) {
        root.keyboardNavigation = true
        root.cursor = 30 + ["listening", "storage", "alerts", "stations"].indexOf(section)
        settingsTabs.itemAt(root.cursor - 30).forceActiveFocus()
      }
      else if (section === "storage") recordingsView.focusStorage()
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
    keyboardNavigation = true
    scroller.contentY = 0
    keyCatcher.forceActiveFocus()
  }
  function openSchedules(keepTabFocus) {
    openRecordings(false, keepTabFocus)
    recordingsView.tab = "schedules"
    if (!keepTabFocus) Qt.callLater(function() { recordingsView.activate() })
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
  function moveTab(direction, settingsIndex) {
    keyboardNavigation = true
    if (settingsOpen) {
      const current = settingsIndex === undefined ? cursor - 30 : settingsIndex
      const next = (current + direction + 4) % 4
      selectSettingsTab(["listening", "storage", "alerts", "stations"][next], true)
    } else {
      const tabs = [20,14,21]
      const next = (tabs.indexOf(cursor) + direction + tabs.length) % tabs.length
      if (next === 0) showPlayer()
      else if (next === 1) openRecordings(false, true)
      else openSchedules(true)
      cursor = tabs[next]
      Qt.callLater(function() {
        if (!root.settingsOpen) {
          root.cursor = tabs[next]
          if (next === 0) keyCatcher.forceActiveFocus()
          else (next === 1 ? recordingsButton : schedulesButton).forceActiveFocus()
        }
      })
    }
  }
  function advanceCursor(direction) {
    keyboardNavigation = true
    keyCatcher.forceActiveFocus()
    let order = [20,14,21,4]
    if (settingsOpen) {
      order = [30,31,32,33,4]
      if (settingsTab === "listening") order = order.concat([40,41,42,43])
      if (captureIndicator.visible) order.push(58)
      if (dockBack.enabled) order.push(54)
      if (dockPlay.enabled) order.push(55)
      if (dockForward.enabled) order.push(56)
      if (dockStop.enabled) order.push(57)
      if (dockRetry.visible) order.push(53)
    } else {
      order.push(0)
      if (favoriteButton.visible && favoriteButton.enabled) order.push(13)
      if (radio.playbackKind !== "recording")
        for (let i = 0; i < favoritePresets.length; i++) order.push(100 + i)
      if (connectionState.visible) {
        order.push(50)
        if (connectionState.secondaryText) order.push(51)
        if (connectionState.detailText) order.push(52)
      }
      if (timelineSlider.visible && timelineSlider.enabled) order.push(22)
      if (liveButton.visible && liveButton.enabled) order.push(9)
      if (fileTimeline.visible && fileTimeline.enabled) order.push(15)
      if (backButton.enabled) order.push(7)
      if (playButton.enabled) order.push(1)
      if (forwardButton.enabled) order.push(8)
      order.push(23)
      if (stopButton.enabled) order.push(6)
      if (sleepButton.enabled) order.push(19)
      if (speedPicker.visible) order.push(18)
      if (returnLiveButton.visible && returnLiveButton.enabled) order.push(16)
    }
    order = order.concat([3,2])
    const index = order.indexOf(cursor)
    cursor = index < 0 ? order[direction > 0 ? 0 : order.length - 1]
                      : order[(index + direction + order.length) % order.length]
    Qt.callLater(ensureCursorVisible)
  }
  function ensureCursorVisible() {
    const targets = [stationPicker, playButton, volumeSlider, muteButton, root.settingsOpen ? settingsCloseButton : settingsButton,
                     bufferPicker, stopButton, backButton, forwardButton, liveButton,
                     addStationButton, addStationButton, deleteStationButton, favoriteButton, recordingsButton, fileTimeline, returnLiveButton, addStationButton, speedPicker, sleepButton, listenButton, schedulesButton, timelineSlider, recordNowButton, addStationButton]
    ensureItemVisible(cursor === 58 ? captureIndicator : cursor >= 54 && cursor <= 57 ? [dockBack, dockPlay, dockForward, dockStop][cursor - 54] : cursor === 53 ? dockRetry : cursor >= 50 && cursor <= 52 ? [connectionState.primaryControl, connectionState.secondaryControl, connectionState.detailsControl][cursor - 50] : cursor >= 40 && cursor <= 43 ? bufferPresets.itemAt(cursor - 40) : cursor >= 100 ? presetRepeater.itemAt(cursor - 100) : cursor >= 30 && cursor <= 33 ? settingsTabs.itemAt(cursor - 30) : targets[cursor])
  }
  Connections {
    target: keyCatcher.Window.window
    function onActiveFocusItemChanged() {
      // Native Tab traversal can focus inner fields and controls without
      // changing the panel cursor. Always reveal the actual focused item.
      const item = keyCatcher.Window.window.activeFocusItem
      if (item) root.ensureItemVisible(item)
    }
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
    else if (cursor === 58 && settingsOpen && captureIndicator.visible) captureIndicator.clicked()
    else if (cursor >= 54 && cursor <= 57 && auxiliaryView) {
      const target = [dockBack, dockPlay, dockForward, dockStop][cursor - 54]
      if (target.enabled) target.clicked()
    }
    else if (cursor === 53 && dockRetry.visible && dockRetry.enabled) dockRetry.clicked()
    else if (cursor >= 50 && cursor <= 52 && connectionState.visible) {
      const target = [connectionState.primaryControl, connectionState.secondaryControl, connectionState.detailsControl][cursor - 50]
      if (target.visible && target.enabled) target.clicked()
    }
    else if (cursor >= 40 && cursor <= 43 && settingsOpen) bufferPresets.itemAt(cursor - 40).clicked()
    else if (cursor >= 30 && cursor <= 33) selectSettingsTab(["listening", "storage", "alerts", "stations"][cursor - 30])
    else if (cursor >= 100 && cursor < 100 + favoritePresets.length) radio.selectStation(favoritePresets[cursor - 100].id)
  }
  function openRecordings(storage, keepTabFocus) {
    if (storage) { openSettingsStorage(); return }
    settingsOpen = false
    recordingsOpen = true
    recordingsView.editing = false
    recordingsView.storageEditing = false
    recordingsView.nowEditing = false
    recordingsView.tab = "library"
    if (!keepTabFocus) recordingsView.activate()
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
    if (!opened) { stationPicker.close(); speedPicker.close(); sleepPopup.close(); stationEditorOpen = false; confirmStationDelete = false }
    else if (!radio.hasStation && radio.playbackKind !== "recording") cursor = 0
  }
  Connections {
    target: root.radio
    function onWantedChanged() { if (!root.radio.wanted) sleepPopup.close() }
    function onStationIdChanged() { stationPicker.value = root.radio.stationId; root.confirmStationDelete = false }
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
    focusTarget: (stationPicker.popupOpen || speedPicker.popupOpen || sleepPopup.opened || stationEditorOpen || recordingsOpen || settingsStorage || settingsOpen && settingsTab === "stations") ? null : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(header.implicitHeight + panelContent.implicitHeight + playbackDock.implicitHeight + Style.space(28))

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.recordingsOpen || root.settingsOpen && (root.settingsStorage || root.settingsTab === "stations") || sleepPopup.opened || speedPicker.popupOpen || stationPicker.popupOpen || stationName.activeFocus || stationURL.activeFocus || stationCity.activeFocus || stationCountry.activeFocus || stationWebsite.activeFocus || saveStationButton.activeFocus || cancelStationButton.activeFocus
      function sliderKey(event) {
        event.accepted = false
        if (blocked) return
        const slider = root.cursor === 2 ? volumeSlider : root.cursor === 15 ? fileTimeline : root.cursor === 22 ? timelineSlider : null
        if (slider && slider.visible) slider.handleKey(event)
      }
      Keys.forwardTo: [sliderKeys]
      Item {
        id: sliderKeys
        Keys.onPressed: event => {
          event.accepted = false
          if (root.virtualFocus && [Qt.Key_Home,Qt.Key_End,Qt.Key_PageUp,Qt.Key_PageDown].indexOf(event.key) >= 0)
            keyCatcher.sliderKey(event)
        }
      }
      Keys.onEscapePressed: event => {
        if (root.settingsOpen) { root.backFromSettings(); event.accepted = true }
        else event.accepted = false
      }
      onCloseRequested: root.settingsOpen ? root.backFromSettings() : root.close()
      onTabRequested: direction => root.advanceCursor(direction)
      onMoveRequested: (dx, dy) => {
        if (dy) root.advanceCursor(dy)
        if (dx) {
          root.keyboardNavigation = true
          if (root.settingsOpen && root.cursor >= 30 && root.cursor <= 33 || !root.settingsOpen && [20,14,21].indexOf(root.cursor) >= 0) root.moveTab(dx)
          else if (root.cursor === 15 && fileTimeline.enabled) fileTimeline.adjustBy(dx * fileTimeline.step)
          else if (root.cursor === 22 && timelineSlider.enabled) timelineSlider.adjustBy(dx * timelineSlider.step)
          else { root.cursor = 2; volumeSlider.adjustBy(dx * volumeSlider.step) }
        }
      }
      onActivateRequested: { root.keyboardNavigation = true; root.activate() }
      onTextKey: (text, modifiers) => { if (modifiers === Qt.NoModifier) root.playbackShortcut(text) }

      Column {
        anchors.fill: parent
        spacing: Style.space(14)
        Column {
          id: header
          width: parent.width
          spacing: Style.space(4)
          NavigationRow {
            id: mainNavigation
            visible: !root.settingsOpen
            NavigationTab {
              id: listenButton
              cursorId: 20
              Keys.onLeftPressed: { root.cursor = 20; root.moveTab(-1) }
              Keys.onRightPressed: { root.cursor = 20; root.moveTab(1) }
              text: "Listen"
              selected: !root.recordingsOpen
              focusable: true
              hasCursor: root.virtualFocus && root.cursor === 20
              onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 20 } }
              onClicked: root.showPlayer()
            }
            NavigationTab {
              id: recordingsButton
              cursorId: 14
              Keys.onLeftPressed: { root.cursor = 14; root.moveTab(-1) }
              Keys.onRightPressed: { root.cursor = 14; root.moveTab(1) }
              text: "Library"
              tooltipText: "Open recordings" + (Number(root.radio.recordings.activeCount) > 0 ? " · " + root.radio.recordings.activeCount + " active" : "")
              Accessible.name: tooltipText
              selected: root.recordingsOpen && recordingsView.tab === "library"
              focusable: true
              hasCursor: root.virtualFocus && root.cursor === 14
              onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 14 } }
              onClicked: root.openRecordings(false)
              Rectangle {
                visible: Number(root.radio.recordings.activeCount) > 0
                width: Style.space(5); height: width; radius: width / 2
                anchors.right: parent.right; anchors.rightMargin: Style.space(5)
                anchors.top: parent.top; anchors.topMargin: Style.space(3)
                color: Commons.Color.urgent
              }
            }
            NavigationTab {
              id: schedulesButton
              cursorId: 21
              Keys.onLeftPressed: { root.cursor = 21; root.moveTab(-1) }
              Keys.onRightPressed: { root.cursor = 21; root.moveTab(1) }
              text: "Schedules"
              selected: root.recordingsOpen && recordingsView.tab === "schedules"
              focusable: true
              hasCursor: root.virtualFocus && root.cursor === 21
              onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 21 } }
              onClicked: root.openSchedules()
            }
            Item {
              width: Math.max(0, parent.width - listenButton.width - recordingsButton.width - schedulesButton.width - settingsButton.width - parent.spacing * 4)
              height: 1
            }
            SettingsControl {
              id: settingsButton
              anchors.verticalCenter: parent.verticalCenter
              iconName: "settings"
              tooltipText: "Open settings"
              focusable: root.auxiliaryView
              onClicked: root.openSettings()
            }
          }
          NavigationRow {
            id: settingsNavigation
            visible: root.settingsOpen
            Row {
              id: settingsTabGroup
              spacing: settingsNavigation.spacing
              Repeater {
                id: settingsTabs
                model: [{key:"listening",label:"Listening"}, {key:"storage",label:"Storage"}, {key:"alerts",label:"Alerts"}, {key:"stations",label:"Stations"}]
                NavigationTab {
                  required property var modelData
                  required property int index
                  text: modelData.label
                  cursorId: 30 + index
                  selected: root.settingsTab === modelData.key
                  focusable: true
                  enabled: !root.stationMutationPending && !recordingsView.pending
                  hasCursor: root.virtualFocus && root.cursor === 30 + index
                  Keys.onLeftPressed: root.moveTab(-1, index)
                  Keys.onRightPressed: root.moveTab(1, index)
                  Accessible.name: text
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 30 + index } }
                  onClicked: root.selectSettingsTab(modelData.key)
                }
              }
            }
            Item {
              width: Math.max(0, parent.width - settingsTabGroup.width - settingsCloseButton.width - parent.spacing * 2)
              height: 1
            }
            SettingsControl {
              id: settingsCloseButton
              anchors.verticalCenter: parent.verticalCenter
              iconName: "close"
              tooltipText: "Close settings"
              focusable: true
              onClicked: root.closeSettings()
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
              Column {
                width: parent.width
                spacing: Style.space(12)
                visible: root.settingsTab === "listening"
                SettingTitle { text: "Replay buffer" }
                SettingHint { text: "Choose how much live radio to keep for rewinding." }
                Grid {
                  id: bufferPicker
                  columns: width < Style.space(340) ? 2 : 4
                  width: parent.width
                  spacing: Style.space(4)
                  Repeater {
                    id: bufferPresets
                    model: [0,5,15,30]
                    Radio.FocusButton {
                      required property int modelData
                      required property int index
                      width: (parent.width - parent.spacing * (parent.columns - 1)) / parent.columns
                      text: modelData ? modelData + " min" : "Live only"
                      fontSize: Style.fontPx(1)
                      horizontalPadding: Style.space(8)
                      foreground: root.barForeground
                      selected: root.radio.bufferMinutes === modelData
                      hasCursor: root.virtualFocus && root.cursor === 40 + index
                      focusable: true
                      Accessible.role: Accessible.RadioButton
                      Accessible.name: modelData ? modelData + " minutes of replay" : "Live only"
                      Accessible.checkable: true
                      Accessible.checked: selected
                      onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 40 + index } }
                      onClicked: root.radio.setBufferMinutes(modelData)
                    }
                  }
                }
                Rectangle {
                  width: parent.width
                  implicitHeight: bufferExplanation.implicitHeight + Style.space(20)
                  radius: Style.space(8)
                  color: Qt.alpha(Commons.Color.accent, 0.06)
                  Column {
                    id: bufferExplanation
                    x: Style.space(10); y: Style.space(10)
                    width: parent.width - Style.space(20)
                    spacing: Style.space(5)
                    SettingLabel { id: bufferSummary; text: root.radio.bufferMinutes ? root.radio.bufferMinutes + " minutes of replay" : "Live only" }
                    SettingHint {
                      id: bufferDescription
                      text: root.radio.bufferMinutes
                        ? "History grows as you listen and stays in memory. No recording files are created."
                        : "Pause still keeps your place with a temporary 15-minute buffer."
                    }
                  }
                }
                SettingHint { text: "Changes apply immediately, clear replay history and return to live." }
                Ui.PanelSeparator { width: parent.width }
                Column {
                  width: parent.width
                  spacing: Style.space(8)
                  SettingLabel { text: "Keyboard shortcuts" }
                  Grid {
                    id: shortcutGrid
                    width: parent.width
                    columns: 2
                    columnSpacing: Style.space(12)
                    rowSpacing: Style.space(6)
                    Repeater {
                      model: [{key:"P",action:"Pause/resume"}, {key:"[  ]",action:"Skip 30 sec"}, {key:"G",action:"Go live"}, {key:"M",action:"Mute/unmute"}, {key:"←  →",action:"Volume / tabs"}, {key:"R",action:"Play"}]
                      Row {
                        required property var modelData
                        width: (shortcutGrid.width - shortcutGrid.columnSpacing) / 2
                        height: Math.max(shortcutKey.height, shortcutLabel.implicitHeight)
                        spacing: Style.space(8)
                        Rectangle {
                          id: shortcutKey
                          width: Style.space(44)
                          height: Style.space(24)
                          anchors.verticalCenter: parent.verticalCenter
                          radius: Style.space(4)
                          color: Qt.alpha(root.barForeground, 0.06)
                          Text { anchors.centerIn: parent; text: modelData.key; textFormat: Text.PlainText; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.fontPx(0.917) }
                        }
                        Text {
                          id: shortcutLabel
                          width: parent.width - shortcutKey.width - parent.spacing
                          anchors.verticalCenter: parent.verticalCenter
                          text: modelData.action
                          textFormat: Text.PlainText
                          color: Qt.alpha(root.barForeground, 0.8)
                          font.family: root.uiFontFamily
                          font.pixelSize: Style.fontPx(1)
                          wrapMode: Text.Wrap
                        }
                      }
                    }
                  }
                }
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
                      horizontalPadding: Style.space(6)
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
                Radio.FocusTextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationName
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationName) })
                  width: parent.width
                  placeholderText: "e.g. Community Radio"
                  Accessible.name: "Station name (required)"
                  foreground: root.barForeground
                  maximumLength: 160

                  Keys.onEscapePressed: root.backFromSettings()
                }
                SettingLabel { text: "Audio stream URL" }
                Radio.FocusTextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationURL
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationURL) })
                  width: parent.width
                  placeholderText: "https://…/stream"
                  Accessible.name: "Audio stream URL"
                  foreground: root.barForeground
                  maximumLength: 2048

                  Keys.onEscapePressed: root.backFromSettings()
                }
                SettingHint { text: "Use a direct HTTP or HTTPS audio stream, rather than a station web page." }
                Ui.PanelSeparator { width: parent.width }
                SettingLabel { text: "City · optional" }
                Radio.FocusTextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationCity
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationCity) })
                  width: parent.width
                  placeholderText: "e.g. Boston"
                  Accessible.name: "City · optional"
                  foreground: root.barForeground
                  maximumLength: 100

                  Keys.onEscapePressed: root.backFromSettings()
                }
                SettingLabel { text: "Country · optional" }
                Radio.FocusTextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationCountry
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationCountry) })
                  width: parent.width
                  placeholderText: "e.g. United States"
                  Accessible.name: "Country · optional"
                  foreground: root.barForeground
                  maximumLength: 100

                  Keys.onEscapePressed: root.backFromSettings()
                }
                SettingLabel { text: "Website · optional" }
                Radio.FocusTextField {
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1.167)
                  id: stationWebsite
                  onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationWebsite) })
                  width: parent.width
                  placeholderText: "https://…"
                  Accessible.name: "Website · optional"
                  foreground: root.barForeground
                  maximumLength: 2048

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

                    Keys.onEscapePressed: root.backFromSettings()
                    onClicked: root.backFromSettings()
                  }
                }
                Radio.FocusButton {
                  id: deleteStationButton
                  visible: !!root.editingStationId

                  text: root.confirmStationDelete ? "Confirm delete station" : "Delete station"
                  fontSize: Style.fontPx(1)
                  horizontalPadding: Style.space(6)
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
                  id: stationArtwork
                  width: Style.space(root.compactNavigation ? 64 : 88)
                  height: width
                  radius: Style.cornerRadius
                  color: Qt.alpha(root.barForeground, 0.05)
                  Radio.StationLogo { anchors.fill: parent; anchors.margins: Style.space(8); station: root.radio.playbackStation; fallbackColor: Commons.Color.accent }
                }
                Column {
                  width: parent.width - stationArtwork.width - favoriteButton.width - parent.spacing * 2
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
                    onFavoriteRequested: value => root.radio.toggleFavorite(value)
                    foreground: root.barForeground
                    hasCursor: root.virtualFocus && root.cursor === 0
                    onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 0 } }
                    onChanged: value => { root.radio.selectStation(value); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
                  }
                }
                Radio.FocusButton {
                  id: favoriteButton
                  visible: root.radio.playbackKind !== "recording"
                  width: visible ? implicitWidth : 0
                  iconName: selected ? "heart-filled" : "heart"
                  selected: root.radio.favoriteIds.indexOf(root.radio.stationId) !== -1
                  tooltipText: selected ? "Remove from favorites" : "Add to favorites"
                  Accessible.role: Accessible.Button
                  Accessible.name: tooltipText
                  Accessible.checkable: true
                  Accessible.checked: selected
                  enabled: root.radio.hasStation
                  opacity: enabled ? 1 : 0.35
                  foreground: root.barForeground
                  hasCursor: root.virtualFocus && root.cursor === 13
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 13 } }
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
                      hasCursor: root.virtualFocus && root.cursor === 100 + index
                      onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 100 + index } }
                      onClicked: root.radio.selectStation(modelData.id)
                      Column {
                        anchors.fill: parent
                        anchors.margins: Style.space(7)
                        spacing: Style.space(2)
                        Radio.MarqueeText { scrolling: false; width: parent.width; text: modelData.name; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                        Text { width: parent.width; text: modelData.city || modelData.country || ""; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(0.917); elide: Text.ElideRight }
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
                  visible: !root.connectionIssue
                  PlaybackStatusIndicator { anchors.verticalCenter: parent.verticalCenter }
                  Text {
                    id: playerStatus
                    width: parent.width - liveButton.width - Style.space(12) - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.listeningStatus
                    textFormat: Text.PlainText
                    color: root.pausedLive ? Commons.Color.accent : root.barForeground
                    font.family: root.uiFontFamily
                    font.pixelSize: Style.fontPx(1)
                    wrapMode: Text.Wrap
                  }
                  Radio.FocusButton {
                    id: liveButton
                    visible: root.radio.playbackKind !== "recording" && root.radio.wanted && root.radio.dvr && (root.radio.behindLive > 3 || root.radio.paused)
                    width: visible ? implicitWidth : 0
                    text: "Go live"
                    fontSize: Style.fontPx(1)
                    height: Style.space(30)
                    foreground: Commons.Color.accent
                    background: Qt.alpha(Commons.Color.accent, 0.1)
                    enabled: root.radio.wanted && root.radio.dvr
                    hasCursor: root.virtualFocus && root.cursor === 9
                    onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 9 } }
                    onClicked: root.radio.goLive()
                  }
                }
                Radio.FocusSlider {
                  id: timelineSlider
                  width: parent.width
                  visible: root.radio.wanted && root.radio.bufferActive && root.radio.playbackKind !== "recording"
                  minimum: root.radio.bufferStart
                  maximum: Math.max(minimum + 1, root.radio.bufferEnd)
                  value: root.radio.position
                  valueText: root.radio.clock(root.radio.bufferEnd - displayValue) + " behind live"
                  step: 30
                  pageStep: 60
                  bar: root.bar
                  foreground: root.barForeground
                  enabled: root.seekable
                  hasCursor: root.virtualFocus && root.cursor === 22
                  onActiveFocusChanged: if (activeFocus) { root.cursor = 22; root.ensureItemVisible(timelineSlider) }
                  Accessible.name: "Live replay position"
                  onPointerUsed: { root.keyboardNavigation = false; root.cursor = 22 }
                  onReleased: value => root.radio.seek(value)
                }
                Row {
                  width: parent.width
                  visible: timelineSlider.visible
                  Text { width: parent.width / 2; text: "−" + root.radio.clock(root.radio.bufferEnd - root.radio.bufferStart); textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                  Text { width: parent.width / 2; text: "LIVE"; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; horizontalAlignment: Text.AlignRight; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                }
                Radio.FocusSlider {
                  id: fileTimeline
                  width: parent.width
                  visible: root.radio.wanted && root.radio.playbackKind === "recording"
                  minimum: 0
                  maximum: Math.max(1, root.radio.duration)
                  value: root.radio.position
                  valueText: root.radio.clock(displayValue) + " of " + root.radio.clock(root.radio.duration)
                  step: 30
                  pageStep: 60
                  bar: root.bar
                  foreground: root.barForeground
                  enabled: root.seekable
                  hasCursor: root.virtualFocus && root.cursor === 15
                  onActiveFocusChanged: if (activeFocus) { root.cursor = 15; root.ensureItemVisible(fileTimeline) }
                  Accessible.name: "Recording position"
                  onPointerUsed: { root.keyboardNavigation = false; root.cursor = 15 }
                  onReleased: value => root.radio.seekRecording(value)
                }
                Row {
                  width: parent.width
                  visible: fileTimeline.visible
                  Text { width: parent.width / 2; text: root.radio.clock(fileTimeline.displayValue); textFormat: Text.PlainText; color: Qt.alpha(root.barForeground, 0.75); font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                  Text { width: parent.width / 2; text: root.radio.clock(root.radio.duration); textFormat: Text.PlainText; horizontalAlignment: Text.AlignRight; color: Qt.alpha(root.barForeground, 0.75); font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                }
                Text { width: parent.width; visible: root.radio.wanted && root.radio.playbackKind === "live" && root.radio.bufferExpired; text: "Older audio expired. Playback moved to the available buffer."; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
              }
              Radio.StateCard {
                id: connectionState
                width: parent.width
                visible: root.connectionIssue
                title: !root.radio.ready ? "Playback unavailable" : root.radio.playbackState === "retrying" ? "Reconnecting to station" : "Can’t connect to this station"
                description: root.radio.playbackState === "retrying"
                  ? "Trying again in " + root.retryCountdown + ". Retry now or choose another station."
                  : "This stream didn’t start. Try again, or choose another station."
                iconName: "radio"
                iconColor: Commons.Color.urgent
                foreground: root.barForeground
                actionText: root.radio.hasStation ? (root.radio.playbackState === "retrying" ? "Retry now" : "Retry") : "Choose station"
                secondaryText: root.radio.hasStation ? "Choose station" : ""
                detailText: root.radio.error
                primaryCursor: root.virtualFocus && root.cursor === 50
                secondaryCursor: root.virtualFocus && root.cursor === 51
                detailsCursor: root.virtualFocus && root.cursor === 52
                ensureVisible: root.ensureItemVisible
                onControlHovered: index => { root.keyboardNavigation = false; root.cursor = 50 + index }
                onAction: { if (root.radio.hasStation) { root.radio.play(); root.cursor = 1; keyCatcher.forceActiveFocus() } else root.chooseStation() }
                onSecondary: root.chooseStation()
              }
              Text { width: parent.width; visible: !root.connectionIssue && text.length > 0; text: root.radio.error || root.radio.playbackProgressError; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
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
                    hasCursor: root.virtualFocus && root.cursor === 7
                    onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 7 } }
                    onClicked: root.radio.skip(-30)
                  }
                  Text { width: parent.width; text: "30 sec"; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText; color: root.barForeground; opacity: 0.75; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                }
                PlaybackButton {
                  id: playButton
                  hasCursor: root.virtualFocus && root.cursor === 1
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 1 } }
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
                    hasCursor: root.virtualFocus && root.cursor === 8
                    onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 8 } }
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
                  horizontalPadding: Style.space(root.compactNavigation ? 5 : 10)
                  width: Math.max(implicitWidth, sleepButton.implicitWidth)
                  anchors.verticalCenter: parent.verticalCenter
                  iconSize: Style.space(16)
                  text: "Record"
                  iconName: "record"
                  foreground: root.barForeground
                  fontSize: Style.fontPx(1)
                  tooltipText: "Record a live stream starting now"
                  hasCursor: root.virtualFocus && root.cursor === 23
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 23 } }
                  onClicked: root.recordNow()
                }
                Radio.FocusButton {
                  id: stopButton
                  horizontalPadding: Style.space(root.compactNavigation ? 5 : 10)
                  iconSize: Style.space(18)
                  iconName: "stop"
                  text: "Stop"
                  fontSize: Style.fontPx(1.083)
                  verticalPadding: Style.space(8)
                  tooltipText: "Stop listening" + (root.radio.playbackKind === "recording" ? "" : " and clear replay history")
                  Accessible.role: Accessible.Button
                  Accessible.name: tooltipText
                  foreground: root.barForeground
                  enabled: root.radio.wanted
                  opacity: enabled ? 1 : 0.35
                  hasCursor: root.virtualFocus && root.cursor === 6
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 6 } }
                  onClicked: root.radio.stop()
                }
                Radio.FocusButton {
                  id: sleepButton
                  horizontalPadding: Style.space(root.compactNavigation ? 5 : 10)
                  width: Math.max(recordNowButton.implicitWidth, implicitWidth)
                  anchors.verticalCenter: parent.verticalCenter
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
                  hasCursor: root.virtualFocus && root.cursor === 19
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 19 } }
                  onClicked: sleepPopup.opened ? sleepPopup.close() : sleepPopup.open()
                  QQC.Popup {
                    id: sleepPopup
                    x: Math.max(-sleepButton.mapToItem(panelContent, 0, 0).x, Math.min(0, panelContent.width - sleepButton.mapToItem(panelContent, 0, 0).x - width))
                    y: sleepButton.height + Style.space(4)
                    width: Math.min(Style.space(260), panelContent.width)
                    padding: Style.space(12)
                    margins: Style.space(8)
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
                      spacing: Style.space(10)
                      Text { width: parent.width; text: "Sleep timer"; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.25); font.weight: Font.DemiBold }
                      Text { width: parent.width; text: "Stops listening; recordings continue."; textFormat: Text.PlainText; color: Qt.alpha(root.barForeground, 0.7); font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
                      Text { id: sleepCountdown; width: parent.width; visible: root.radio.sleepRemaining > 0; text: "Stops in " + root.radio.clock(root.radio.sleepRemaining); textFormat: Text.PlainText; color: Commons.Color.accent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); font.weight: Font.Medium }
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
                            fontSize: Style.fontPx(1)
                            horizontalPadding: Style.space(8)
                            focusable: true
                            onClicked: { root.radio.setSleepTimer(modelData); sleepPopup.close() }
                          }
                        }
                      }
                      Text { width: parent.width; text: "Custom duration · minutes"; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); font.weight: Font.DemiBold }
                      Row {
                        width: parent.width
                        spacing: Style.space(6)
                        Radio.FocusTextField {
                          id: sleepMinutes
                          width: parent.width - sleepApply.width - parent.spacing
                          text: "30"
                          font.family: root.uiFontFamily
                          font.pixelSize: Style.fontPx(1.167)
                          maximumLength: 3
                          Accessible.name: "Sleep timer minutes"
                          foreground: root.barForeground
                          inputMethodHints: Qt.ImhDigitsOnly
                          KeyNavigation.tab: sleepApply
                          onTextEdited: root.sleepError = ""
                          onAccepted: root.applySleepTimer()
                        }
                        Radio.FocusButton { id: sleepApply; height: sleepMinutes.height; text: "Set timer"; fontSize: Style.fontPx(1); color: Qt.alpha(Commons.Color.accent, 0.16); foreground: root.barForeground; focusable: true; onClicked: root.applySleepTimer() }
                      }
                      Text { width: parent.width; visible: !root.sleepError; text: "1–240 min · Applies immediately"; textFormat: Text.PlainText; color: Qt.alpha(root.barForeground, 0.65); font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
                      Text { width: parent.width; text: root.sleepError; visible: text.length > 0; wrapMode: Text.Wrap; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
                      Radio.FocusButton { id: sleepOff; visible: root.radio.sleepRemaining > 0; text: "Cancel timer"; fontSize: Style.fontPx(1); horizontalPadding: Style.space(6); foreground: Qt.alpha(root.barForeground, 0.8); focusable: true; onClicked: { root.radio.setSleepTimer(0); sleepPopup.close() } }
                    }
                  }
                }
              }
              Grid {
                width: parent.width
                columns: width < Style.space(340) ? 1 : 2
                spacing: Style.space(8)
                visible: root.radio.playbackKind === "recording"
                Radio.FocusDropdown {
                  id: speedPicker
                  label: "Playback speed"
                  fontFamily: root.uiFontFamily
                  width: (parent.width - parent.spacing * (parent.columns - 1)) / parent.columns
                  showLabel: false
                  value: String(root.radio.playbackSpeed)
                  options: [{value:"0.75",label:"Speed · 0.75×"}, {value:"1",label:"Speed · 1×"}, {value:"1.25",label:"Speed · 1.25×"}, {value:"1.5",label:"Speed · 1.5×"}, {value:"2",label:"Speed · 2×"}]
                  foreground: root.barForeground
                  hasCursor: root.virtualFocus && root.cursor === 18
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 18 } }
                  onChanged: value => { root.radio.setPlaybackSpeed(Number(value)); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
                }
                Radio.FocusButton {
                  id: returnLiveButton
                  height: speedPicker.height
                  width: speedPicker.width
                  text: root.radio.hasStation ? "Return to live" : "Choose live station"
                  foreground: root.barForeground
                  hasCursor: root.virtualFocus && root.cursor === 16
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 16 } }
                  onClicked: root.radio.hasStation ? root.radio.goLive() : root.chooseStation()
                }
              }
            }
          }
        }
        Column {
          id: playbackDock
          width: parent.width
          spacing: Style.space(root.compactDock ? 4 : 8)
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
            Radio.StationLogo {
              width: Style.space(36); height: width
              y: (dockPlay.height - height) / 2
              station: root.radio.playbackStation
              fallbackColor: Commons.Color.accent
            }
            Column {
              width: parent.width - Style.space(36) - dockControls.width - parent.spacing * 2
              y: Math.max(0, (dockPlay.height - implicitHeight) / 2)
              spacing: Style.space(3)
              Radio.MarqueeText { scrolling: false; width: parent.width; text: root.radio.playbackKind === "recording" ? root.radio.recordingTitle : root.radio.station.name; textFormat: Text.PlainText; color: root.barForeground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); font.weight: Font.DemiBold }
              Row {
                width: parent.width
                spacing: Style.space(4)
                PlaybackStatusIndicator { anchors.verticalCenter: parent.verticalCenter }
                Text {
                  id: dockStatus
                  width: parent.width - Style.space(12) - parent.spacing
                  text: root.radio.playbackKind === "recording" && root.radio.wanted
                    ? (root.radio.playbackPaused ? "Paused · " : "") + root.radio.clock(root.radio.position) + " / " + root.radio.clock(root.radio.duration)
                    : root.radio.playbackKind === "live" && root.pausedLive ? "Paused · buffering" : root.listeningStatus
                  textFormat: Text.PlainText
                  color: root.pausedLive ? Commons.Color.accent : Qt.alpha(root.barForeground, 0.8)
                  font.family: root.uiFontFamily
                  font.pixelSize: Style.fontPx(1)
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }
              }
              Radio.FocusButton {
                id: captureIndicator
                visible: root.settingsOpen && Number(root.radio.recordings.activeCount) > 0
                width: visible ? implicitWidth : 0
                text: "● REC " + root.radio.recordings.activeCount
                fontSize: Style.fontPx(1)
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(4)
                foreground: Commons.Color.urgent
                tooltipText: "Background captures · Open recordings"
                focusable: true
                hasCursor: root.virtualFocus && root.cursor === 58
                onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 58 } }
                onClicked: root.openRecordings(false)
              }
            }
            Column {
              id: dockControls
              width: dockTransport.implicitWidth
              spacing: Style.space(2)
              Row {
                id: dockTransport
                spacing: Style.space(6)
                Radio.FocusButton {
                  id: dockBack
                  width: Style.space(30)
                  horizontalPadding: 0
                  anchors.verticalCenter: parent.verticalCenter
                  iconName: "back"
                  tooltipText: "Rewind 30 seconds"
                  foreground: Qt.alpha(root.barForeground, 0.8)
                  enabled: root.canRewind
                  opacity: enabled ? 1 : 0.35
                  focusable: true
                  hasCursor: root.virtualFocus && root.cursor === 54
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 54 } }
                  onClicked: root.radio.skip(-30)
                }
                PlaybackButton {
                  id: dockPlay
                  width: Style.space(44)
                  iconSize: Style.space(21)
                  horizontalPadding: 0
                  focusable: true
                  hasCursor: root.virtualFocus && root.cursor === 55
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 55 } }
                }
                Radio.FocusButton {
                  id: dockForward
                  width: Style.space(30)
                  horizontalPadding: 0
                  anchors.verticalCenter: parent.verticalCenter
                  iconName: "forward"
                  tooltipText: "Forward 30 seconds"
                  foreground: Qt.alpha(root.barForeground, 0.8)
                  enabled: root.canForward
                  opacity: enabled ? 1 : 0.35
                  focusable: true
                  hasCursor: root.virtualFocus && root.cursor === 56
                  onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 56 } }
                  onClicked: root.radio.skip(30)
                }
              }
              Radio.FocusButton {
                id: dockStop
                anchors.horizontalCenter: parent.horizontalCenter
                iconName: "stop"
                iconSize: Style.space(14)
                text: "Stop"
                fontSize: Style.fontPx(1)
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(root.compactDock ? 2 : 4)
                tooltipText: stopButton.tooltipText
                foreground: Qt.alpha(root.barForeground, 0.85)
                enabled: root.radio.wanted
                opacity: enabled ? 1 : 0.35
                focusable: true
                hasCursor: root.virtualFocus && root.cursor === 57
                onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 57 } }
                onClicked: root.radio.stop()
              }
            }
          }
          Row {
            width: parent.width
            visible: root.auxiliaryView && root.connectionIssue
            spacing: Style.space(8)
            Text { width: parent.width - dockRetry.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; text: root.radio.playbackState === "retrying" ? "Reconnecting in " + root.retryCountdown : "Station connection unavailable"; textFormat: Text.PlainText; color: Qt.alpha(root.barForeground, 0.8); font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
            Radio.FocusButton { id: dockRetry; text: "Retry"; fontSize: Style.fontPx(1); foreground: root.barForeground; color: Qt.alpha(Commons.Color.accent, 0.12); enabled: root.radio.hasStation; focusable: true; hasCursor: root.virtualFocus && root.cursor === 53; onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 53 } }; onClicked: root.radio.play() }
          }
          Text { width: parent.width; visible: root.auxiliaryView && !root.connectionIssue && text.length > 0; text: root.radio.error || root.radio.playbackProgressError; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Radio.FocusButton {
              id: muteButton
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(32)
              horizontalPadding: 0
              iconName: root.radio.muted ? "muted" : "volume"
              tooltipText: root.radio.muted ? "Unmute" : "Mute"
              Accessible.role: Accessible.Button
              Accessible.name: tooltipText
              foreground: root.barForeground
              focusable: root.auxiliaryView
              hasCursor: root.virtualFocus && root.cursor === 3
              onHovered: hovered => { if (hovered) { root.keyboardNavigation = false; root.cursor = 3 } }
              onClicked: root.radio.toggleMute()
            }
            Radio.FocusSlider {
              id: volumeSlider
              width: parent.width - muteButton.width - volumeLabel.width - parent.spacing * 2
              anchors.verticalCenter: parent.verticalCenter
              bar: root.bar
              foreground: root.barForeground
              knobColor: root.barForeground
              value: root.radio.volume
              valueText: Math.round(displayValue) + "%" + (root.radio.muted ? ", muted" : "")
              minimum: 0
              maximum: 100
              step: 5
              pageStep: 10
              integer: true
              fillColor: Qt.alpha(root.barForeground, controlFocused || controlHovered ? 0.9 : 0.6)
              onActiveFocusChanged: if (activeFocus) root.cursor = 2
              Accessible.name: "Volume"
              hasCursor: root.virtualFocus && root.cursor === 2
              onPointerUsed: { root.keyboardNavigation = false; root.cursor = 2 }
              onMoved: value => root.radio.setVolume(value)
              onReleased: value => root.radio.commitVolume(value)
              onRightClicked: root.radio.toggleMute()
            }
            Text { id: volumeLabel; width: Math.max(Style.space(40), implicitWidth); anchors.verticalCenter: parent.verticalCenter; text: root.radio.muted ? "Muted" : Math.round(volumeSlider.dragging ? volumeSlider.liveValue : root.radio.volume) + "%"; textFormat: Text.PlainText; horizontalAlignment: Text.AlignRight; color: root.barForeground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
          }
          Text {
            width: parent.width
            id: playbackHintText
            visible: text.length > 0 && !root.compactDock
            text: root.playbackHint + (root.radio.wanted && root.radio.sleepRemaining > 0 ? " · Sleep in " + root.radio.clock(root.radio.sleepRemaining) : "")
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
