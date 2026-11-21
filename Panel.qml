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
  property bool recordingsOpen: false
  property bool stationEditorOpen: false
  property int pendingStationSerial: 0
  readonly property bool stationMutationPending: pendingStationSerial !== 0
  property string stationError: ""
  property bool confirmStationDelete: false
  property string editingStationId: ""
  readonly property var radio: Radio.RadioService
  property var scrollTarget: null
  property string sleepError: ""

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
    root.open()
    Qt.callLater(function() { root.cursor = 0; stationPicker.open() })
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }
  function advanceCursor(direction) {
    let order = [14]
    if (sleepButton.enabled) order.push(19)
    order.push(4)
    if (settingsOpen) {
      order = order.concat([5,17,10])
      if (radio.station.custom) order = order.concat([11,12])
    }
    order.push(0)
    if (favoriteButton.enabled) order.push(13)
    if (backButton.enabled) order.push(7)
    if (stopButton.enabled) order.push(6)
    if (playButton.enabled) order.push(1)
    if (forwardButton.enabled) order.push(8)
    if (speedPicker.visible) order.push(18)
    if (radio.playbackKind === "recording") {
      if (radio.wanted && radio.duration > 0 && (radio.playbackState === "playing" || radio.paused)) order.push(15)
      if (radio.wanted || radio.bufferActive) order.push(16)
    }
    if (liveButton.visible && liveButton.enabled) order.push(9)
    order = order.concat([2,3])
    const index = Math.max(0, order.indexOf(cursor))
    cursor = order[(index + direction + order.length) % order.length]
    Qt.callLater(ensureCursorVisible)
  }
  function ensureCursorVisible() {
    const targets = [stationPicker, playButton, volumeSlider, muteButton, settingsButton,
                     bufferPicker, stopButton, backButton, forwardButton, liveButton,
                     addStationButton, editStationButton, deleteStationButton, favoriteButton, recordingsButton, fileTimeline, returnLiveButton, storageButton, speedPicker, sleepButton]
    ensureItemVisible(targets[cursor])
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
    else if (cursor === 4) settingsOpen = !settingsOpen
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
    else if (cursor === 17 && settingsOpen) openRecordings(true)
    else if (cursor === 18 && speedPicker.visible) speedPicker.toggle()
    else if (cursor === 19 && sleepButton.enabled) sleepButton.clicked()
  }
  function openRecordings(storage) {
    recordingsOpen = true
    if (storage) recordingsView.beginStorage()
    else recordingsView.activate()
  }
  function openStationEditor(edit) {
    if (stationMutationPending) return
    const s = edit ? radio.station : {}
    editingStationId = s.id || ""
    stationName.text = s.name || ""; stationURL.text = s.streamUrl || ""
    stationCity.text = s.city || ""; stationCountry.text = s.country || ""; stationWebsite.text = s.website || ""
    stationError = ""
    confirmStationDelete = false; stationEditorOpen = true
    Qt.callLater(function() { stationName.forceActiveFocus() })
  }
  function deleteStation() {
    if (stationMutationPending) return
    if (!confirmStationDelete) { confirmStationDelete = true; return }
    stationError = ""
    pendingStationSerial = radio.deleteCustomStation(radio.station.id)
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
        keyCatcher.forceActiveFocus()
      } else if (root.stationEditorOpen) stationName.forceActiveFocus()
    }
  }

  Ui.KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: (stationPicker.popupOpen || bufferPicker.popupOpen || speedPicker.popupOpen || sleepPopup.opened || stationEditorOpen || recordingsOpen) ? null : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelContent.implicitHeight)

    Ui.PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.recordingsOpen || sleepPopup.opened || speedPicker.popupOpen || stationPicker.popupOpen || bufferPicker.popupOpen || stationName.activeFocus || stationURL.activeFocus || stationCity.activeFocus || stationCountry.activeFocus || stationWebsite.activeFocus || saveStationButton.activeFocus || cancelStationButton.activeFocus
      onCloseRequested: root.close()
      onTabRequested: direction => root.advanceCursor(direction)
      onMoveRequested: (dx, dy) => {
        if (dy) root.advanceCursor(dy)
        if (dx) {
          if (root.cursor === 15 && root.radio.playbackKind === "recording") root.radio.seekRecording(root.radio.position + dx * 30)
          else { root.cursor = 2; root.radio.commitVolume(root.radio.volume + dx * 5) }
        }
      }
      onActivateRequested: root.activate()
      onTextKey: text => {
        if (text.toLowerCase() === "p") root.radio.togglePause()
        if (text === "[") root.radio.skip(-30)
        if (text === "]") root.radio.skip(30)
        if (text.toLowerCase() === "g") root.radio.goLive()
        if (text.toLowerCase() === "m") root.radio.toggleMute()
        if (text.toLowerCase() === "r" && !root.radio.wanted) root.radio.play()
      }

      Flickable {
        id: scroller
        onHeightChanged: if (root.scrollTarget) scrollEnsure.restart()
        onContentHeightChanged: if (root.scrollTarget) scrollEnsure.restart()
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelContent.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
      Column {
        id: panelContent
        width: parent.width
        spacing: Style.space(14)

        Radio.RecordingsView {
          id: recordingsView
          width: parent.width
          visible: root.recordingsOpen
          radio: root.radio
          foreground: root.barForeground
          bar: root.bar
          ensureVisible: root.ensureItemVisible
          onBack: { root.recordingsOpen = false; keyCatcher.forceActiveFocus() }
        }
        Column {
          width: parent.width
          visible: !root.recordingsOpen
          spacing: Style.space(14)
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: parent.width - recordingsButton.width - sleepButton.width - settingsButton.width - parent.spacing * 3
            anchors.verticalCenter: parent.verticalCenter
            text: "YAKKER · " + root.radio.stations.length + " STATIONS"
            textFormat: Text.PlainText
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Ui.Button {
            id: recordingsButton
            iconText: "󰲸" // nf-md-playlist_music
            tooltipText: "Open recordings" + (Number(root.radio.recordings.activeCount) > 0 ? " · " + root.radio.recordings.activeCount + " active" : "")
            Accessible.role: Accessible.Button
            Accessible.name: recordingsButton.tooltipText
            foreground: root.barForeground
            bordered: true
            selected: Number(root.radio.recordings.activeCount) > 0
            hasCursor: root.cursor === 14
            onHovered: hovered => { if (hovered) root.cursor = 14 }
            onClicked: root.openRecordings(false)
          }
          Ui.Button {
            id: sleepButton
            iconText: "󰔛" // nf-md-timer_outline
            tooltipText: root.radio.sleepRemaining > 0 ? "Sleep in " + root.radio.clock(root.radio.sleepRemaining) : "Sleep timer"
            Accessible.role: Accessible.Button
            Accessible.name: tooltipText
            foreground: root.barForeground
            bordered: true
            enabled: root.radio.wanted || root.radio.sleepRemaining > 0
            opacity: enabled ? 1 : 0.35
            selected: root.radio.sleepRemaining > 0
            hasCursor: root.cursor === 19
            onHovered: hovered => { if (hovered) root.cursor = 19 }
            onClicked: sleepPopup.opened ? sleepPopup.close() : sleepPopup.open()
            QQC.Popup {
              id: sleepPopup
              x: Math.max(-sleepButton.x, sleepButton.width - width)
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
                Text { width: parent.width; text: root.radio.sleepRemaining > 0 ? "Sleep in " + root.radio.clock(root.radio.sleepRemaining) : "Sleep timer"; textFormat: Text.PlainText; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.body }
                Row {
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    id: sleepPresets
                    model: [15, 30, 60]
                    Ui.Button {
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
                Text { width: parent.width; text: "Custom minutes (1–240)"; textFormat: Text.PlainText; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
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
                  Ui.Button { id: sleepApply; text: "Set"; foreground: root.barForeground; bordered: true; focusable: true; onClicked: root.applySleepTimer() }
                }
                Text { width: parent.width; text: root.sleepError; visible: text.length > 0; wrapMode: Text.Wrap; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                Ui.Button { width: parent.width; text: "Turn timer off"; enabled: root.radio.sleepRemaining > 0; opacity: enabled ? 1 : 0.35; foreground: root.barForeground; bordered: true; focusable: true; onClicked: { root.radio.setSleepTimer(0); sleepPopup.close() } }
              }
            }
          }
          Ui.Button {
            id: settingsButton
            iconText: "󰒓"
            tooltipText: root.settingsOpen ? "Close settings" : "Open settings"
            Accessible.role: Accessible.Button
            Accessible.name: settingsButton.tooltipText
            foreground: root.barForeground
            bordered: true
            selected: root.settingsOpen
            hasCursor: root.cursor === 4
            onHovered: hovered => { if (hovered) root.cursor = 4 }
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.settingsOpen
          Ui.Dropdown {
            id: bufferPicker
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
            text: "Pause in Live only starts a temporary 15-minute buffer for this session. Audio stays in memory; no files are recorded. Changing this setting clears history and returns to live."
            textFormat: Text.PlainText
            color: root.barForeground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Ui.Button {
            id: storageButton
            width: parent.width
            text: "Recording storage settings"
            foreground: root.barForeground
            bordered: true
            hasCursor: root.cursor === 17
            onHovered: hovered => { if (hovered) root.cursor = 17 }
            onClicked: root.openRecordings(true)
          }
          Ui.Button {
            id: addStationButton
            width: parent.width
            text: "Add custom station"
            foreground: root.barForeground
            bordered: true
            hasCursor: root.cursor === 10
            onHovered: hovered => { if (hovered) root.cursor = 10 }
            onClicked: root.openStationEditor(false)
          }
          Ui.Button {
            id: editStationButton
            width: parent.width
            visible: root.radio.station.custom === true
            text: "Edit selected custom station"
            foreground: root.barForeground
            bordered: true
            hasCursor: root.cursor === 11
            onHovered: hovered => { if (hovered) root.cursor = 11 }
            onClicked: root.openStationEditor(true)
          }
          Ui.Button {
            id: deleteStationButton
            width: parent.width
            visible: root.radio.station.custom === true
            text: root.stationMutationPending && !root.stationEditorOpen ? "Deleting…"
              : root.confirmStationDelete ? "Confirm delete selected station" : "Delete selected custom station"
            foreground: root.barForeground
            bordered: true
            hasCursor: root.cursor === 12
            onHovered: hovered => { if (hovered) root.cursor = 12 }
            onClicked: root.deleteStation()
          }
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.stationEditorOpen
            Ui.TextField {
              id: stationName
              onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationName) })
              width: parent.width
              placeholderText: "Name (required)"
              Accessible.name: placeholderText
              foreground: root.barForeground
              maximumLength: 160
              KeyNavigation.tab: stationURL
              Keys.onEscapePressed: { root.stationEditorOpen = false; keyCatcher.forceActiveFocus() }
            }
            Ui.TextField {
              id: stationURL
              onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationURL) })
              width: parent.width
              placeholderText: "HTTP(S) audio URL (required)"
              Accessible.name: placeholderText
              foreground: root.barForeground
              maximumLength: 2048
              KeyNavigation.tab: stationCity
              Keys.onEscapePressed: { root.stationEditorOpen = false; keyCatcher.forceActiveFocus() }
            }
            Ui.TextField {
              id: stationCity
              onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationCity) })
              width: parent.width
              placeholderText: "City (optional)"
              Accessible.name: placeholderText
              foreground: root.barForeground
              maximumLength: 100
              KeyNavigation.tab: stationCountry
              Keys.onEscapePressed: { root.stationEditorOpen = false; keyCatcher.forceActiveFocus() }
            }
            Ui.TextField {
              id: stationCountry
              onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationCountry) })
              width: parent.width
              placeholderText: "Country (optional)"
              Accessible.name: placeholderText
              foreground: root.barForeground
              maximumLength: 100
              KeyNavigation.tab: stationWebsite
              Keys.onEscapePressed: { root.stationEditorOpen = false; keyCatcher.forceActiveFocus() }
            }
            Ui.TextField {
              id: stationWebsite
              onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(stationWebsite) })
              width: parent.width
              placeholderText: "HTTP(S) website (optional)"
              Accessible.name: placeholderText
              foreground: root.barForeground
              maximumLength: 2048
              KeyNavigation.tab: saveStationButton
              Keys.onReturnPressed: root.saveStation()
              Keys.onEscapePressed: { root.stationEditorOpen = false; keyCatcher.forceActiveFocus() }
            }
            Ui.Button {
              id: saveStationButton
              onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(saveStationButton) })
              width: parent.width
              text: root.stationMutationPending ? "Saving…" : "Save station"
              foreground: root.barForeground
              bordered: true
              focusable: true
              KeyNavigation.tab: cancelStationButton
              Keys.onEscapePressed: { root.stationEditorOpen = false; keyCatcher.forceActiveFocus() }
              onClicked: root.saveStation()
            }
            Ui.Button {
              id: cancelStationButton
              onActiveFocusChanged: if (activeFocus) Qt.callLater(function() { root.ensureItemVisible(cancelStationButton) })
              width: parent.width
              text: "Cancel"
              foreground: root.barForeground
              bordered: true
              focusable: true
              KeyNavigation.tab: stationName
              Keys.onEscapePressed: { root.stationEditorOpen = false; keyCatcher.forceActiveFocus() }
              onClicked: { root.stationEditorOpen = false; keyCatcher.forceActiveFocus() }
            }
          }
          Text {
            width: parent.width
            visible: text.length > 0
            text: root.stationError || root.radio.customCatalogError
            textFormat: Text.PlainText
            color: Commons.Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
          Ui.PanelSeparator { width: parent.width }
        }
        Row {
          width: parent.width
          spacing: Style.space(14)
          Radio.StationLogo {
            width: Style.space(56)
            height: Style.space(48)
            station: root.radio.station
            fallbackColor: Commons.Color.accent
            anchors.verticalCenter: parent.verticalCenter
          }
          Column {
            width: parent.width - Style.space(70)
            spacing: Style.space(4)
            Row {
              width: parent.width
              spacing: Style.space(6)
              Ui.SearchableDropdown {
                id: stationPicker
                width: parent.width - favoriteButton.width - parent.spacing
                showLabel: false
                placeholderText: root.radio.hasStation ? "Station, city or country" : "Choose a station"
                emptyText: "No matching stations"
                value: root.radio.stationId
                options: root.radio.stationOptions
                foreground: root.barForeground
                hasCursor: root.cursor === 0
                onHovered: hovered => { if (hovered) root.cursor = 0 }
                onChanged: value => {
                  root.radio.selectStation(value)
                  Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                }
              }
              Ui.Button {
                id: favoriteButton
                height: stationPicker.height
                iconText: root.radio.favoriteIds.indexOf(root.radio.stationId) !== -1 ? "♥" : "♡"
                selected: root.radio.favoriteIds.indexOf(root.radio.stationId) !== -1
                tooltipText: selected ? "Remove from favorites" : "Add to favorites"
                Accessible.role: Accessible.Button
                Accessible.name: favoriteButton.tooltipText
                Accessible.checkable: true
                Accessible.checked: favoriteButton.selected
                enabled: root.radio.hasStation
                opacity: enabled ? 1 : 0.35
                foreground: root.barForeground
                bordered: true
                hasCursor: root.cursor === 13
                onHovered: hovered => { if (hovered) root.cursor = 13 }
                onClicked: root.radio.toggleFavorite(root.radio.stationId)
              }
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.radio.station.subtitle
              color: root.barForeground
              opacity: 0.7
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }
        }
        Ui.PanelSeparator { width: parent.width }
        Row {
          width: parent.width
          spacing: Style.space(8)
          Rectangle {
            width: Style.space(6)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.radio.playbackState === "error" ? Commons.Color.urgent
              : root.radio.playbackState === "playing" ? Commons.Color.accent : root.barForeground
            opacity: root.radio.playbackState === "stopped" ? 0.4 : 1
          }
          Text {
            width: parent.width - Style.space(14)
            text: root.radio.playbackKind === "recording" ? (root.radio.paused ? "Paused recording" : root.radio.playbackState === "playing" ? "Playing recording" : root.radio.statusText) : root.radio.statusText
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }
        Text {
          width: parent.width
          visible: text.length > 0
          textFormat: Text.PlainText
          text: root.radio.error || root.radio.playbackProgressError
          color: Commons.Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
        Text {
          width: parent.width
          visible: text.length > 0 && (root.radio.playbackKind === "recording" || (root.radio.playbackState === "playing" && (!root.radio.dvr || root.radio.behindLive <= 3)))
          textFormat: Text.PlainText
          text: root.radio.playbackKind === "recording" ? root.radio.recordingTitle : root.radio.title
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
        Row {
          width: parent.width
          spacing: Style.space(8)
          readonly property real buttonWidth: (width - spacing * 3) / 4
          readonly property bool seekable: root.radio.wanted && (root.radio.playbackState === "playing" || root.radio.paused)
            && (root.radio.playbackKind === "recording" ? root.radio.duration > 0 : root.radio.dvr)
          Ui.Button {
            id: backButton
            width: parent.buttonWidth
            iconText: "󰑟"
            tooltipText: "Rewind 30 seconds"
            Accessible.role: Accessible.Button
            Accessible.name: tooltipText
            foreground: root.barForeground
            bordered: true
            enabled: parent.seekable && root.radio.position > (root.radio.playbackKind === "recording" ? 0 : root.radio.bufferStart) + 0.5
            opacity: enabled ? 1 : 0.35
            hasCursor: root.cursor === 7
            onHovered: hovered => { if (hovered) root.cursor = 7 }
            onClicked: root.radio.skip(-30)
          }
          Ui.Button {
            id: stopButton
            width: parent.buttonWidth
            iconText: "󰓛"
            tooltipText: "Stop"
            Accessible.role: Accessible.Button
            Accessible.name: tooltipText
            foreground: root.barForeground
            bordered: true
            enabled: root.radio.wanted
            opacity: enabled ? 1 : 0.35
            hasCursor: root.cursor === 6
            onHovered: hovered => { if (hovered) root.cursor = 6 }
            onClicked: root.radio.stop()
          }
          Ui.Button {
            id: playButton
            width: parent.buttonWidth
            iconText: root.radio.wanted && !root.radio.paused ? "󰏤" : "󰐊"
            tooltipText: !root.radio.hasStation && !root.radio.wanted ? "Choose a station first" : root.radio.wanted ? (root.radio.paused ? "Resume" : "Pause") : root.radio.playbackState === "error" ? "Retry" : "Play"
            Accessible.role: Accessible.Button
            Accessible.name: tooltipText
            foreground: root.barForeground
            selected: true
            bordered: true
            enabled: (root.radio.hasStation || root.radio.wanted) && (!root.radio.wanted || root.radio.paused || root.radio.playbackState === "playing")
            opacity: enabled ? 1 : 0.35
            hasCursor: root.cursor === 1
            onHovered: hovered => { if (hovered) root.cursor = 1 }
            onClicked: root.radio.wanted ? root.radio.togglePause() : root.radio.play()
          }
          Ui.Button {
            id: forwardButton
            width: parent.buttonWidth
            iconText: "󰈑"
            tooltipText: "Forward 30 seconds"
            Accessible.role: Accessible.Button
            Accessible.name: tooltipText
            foreground: root.barForeground
            bordered: true
            enabled: parent.seekable && (root.radio.playbackKind === "recording" ? root.radio.duration - root.radio.position > 0.5 : root.radio.behindLive > 3)
            opacity: enabled ? 1 : 0.35
            hasCursor: root.cursor === 8
            onHovered: hovered => { if (hovered) root.cursor = 8 }
            onClicked: root.radio.skip(30)
          }
        }
        Row {
          width: parent.width
          spacing: Style.space(8)
          visible: root.radio.playbackKind === "recording" && root.radio.wanted
          Ui.Dropdown {
            id: speedPicker
            width: (parent.width - parent.spacing) / 2
            visible: root.radio.playbackKind === "recording" && root.radio.wanted
            showLabel: false
            value: String(root.radio.playbackSpeed)
            options: [{value:"0.75",label:"Speed · 0.75×"}, {value:"1",label:"Speed · 1×"}, {value:"1.25",label:"Speed · 1.25×"}, {value:"1.5",label:"Speed · 1.5×"}, {value:"2",label:"Speed · 2×"}]
            foreground: root.barForeground
            hasCursor: root.cursor === 18
            onHovered: hovered => { if (hovered) root.cursor = 18 }
            onChanged: value => { root.radio.setPlaybackSpeed(Number(value)); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
          }
        }
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.radio.wanted || root.radio.bufferActive
          Text {
            width: parent.width
            visible: root.radio.playbackKind === "recording"
            text: root.radio.clock(root.radio.position) + " / " + root.radio.clock(root.radio.duration)
            textFormat: Text.PlainText
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Ui.BorderSurface {
            width: parent.width
            height: fileTimeline.implicitHeight + Style.space(8)
            color: "transparent"
            visible: root.radio.playbackKind === "recording"
            radius: Style.cornerRadius
            borderSpec: root.cursor === 15 ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
          Ui.PanelSlider {
            id: fileTimeline
            anchors.fill: parent
            anchors.margins: Style.space(4)
            bar: root.bar
            minimum: 0
            maximum: Math.max(1, root.radio.duration)
            value: root.radio.position
            step: 1
            enabled: root.radio.wanted && root.radio.duration > 0 && (root.radio.playbackState === "playing" || root.radio.paused)
            fillColor: Commons.Color.accent
            knobColor: root.barForeground
            trackColor: Style.selectedFillFor(root.barForeground, Commons.Color.accent)
            onReleased: value => root.radio.seekRecording(value)
          }
          }
          Ui.Button {
            id: returnLiveButton
            width: parent.width
            visible: root.radio.playbackKind === "recording"
            text: root.radio.hasStation ? "Return to live" : "Choose live station"
            foreground: root.barForeground
            bordered: true
            hasCursor: root.cursor === 16
            onHovered: hovered => { if (hovered) root.cursor = 16 }
            onClicked: root.radio.hasStation ? root.radio.goLive() : root.chooseStation()
          }
          Row {
            width: parent.width
            visible: root.radio.bufferActive && root.radio.playbackKind !== "recording"
            spacing: Style.space(8)
            Text {
              width: parent.width - liveButton.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: root.radio.bufferText + (root.radio.temporaryBuffer ? " · Temporary 15-minute buffer" : "")
              textFormat: Text.PlainText
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Ui.Button {
              id: liveButton
              text: "Go live"
              foreground: root.barForeground
              bordered: true
              enabled: root.radio.dvr
              opacity: enabled ? 1 : 0.35
              hasCursor: root.cursor === 9
              onHovered: hovered => { if (hovered) root.cursor = 9 }
              onClicked: root.radio.goLive()
            }
          }
          Ui.PanelSlider {
            id: timelineSlider
            visible: root.radio.bufferActive && root.radio.playbackKind !== "recording"
            width: parent.width
            step: 30
            bar: root.bar
            minimum: root.radio.bufferStart
            maximum: Math.max(minimum + 1, root.radio.bufferEnd)
            value: root.radio.position
            enabled: root.radio.dvr
            fillColor: Commons.Color.accent
            knobColor: root.barForeground
            trackColor: Style.selectedFillFor(root.barForeground, Commons.Color.accent)
            onReleased: value => root.radio.seek(value)
          }
          Text {
            width: parent.width
            visible: root.radio.bufferExpired
            text: "Older audio expired. Playback moved to the available buffer."
            textFormat: Text.PlainText
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
        Row {
          width: parent.width
          Text {
            width: parent.width / 2
            text: root.radio.muted ? "Volume · muted" : "Volume"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width / 2
            horizontalAlignment: Text.AlignRight
            text: Math.round(volumeSlider.dragging ? volumeSlider.liveValue : root.radio.volume) + "%"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }
        Ui.BorderSurface {
          width: parent.width
          implicitHeight: volumeSlider.implicitHeight + Style.space(8)
          color: "transparent"
          radius: Style.cornerRadius
          borderSpec: root.cursor === 2 ? Border.controlSpec("focus", root.barForeground, Commons.Color.accent) : Border.none()
          Ui.PanelSlider {
            id: volumeSlider
            anchors.fill: parent
            anchors.margins: Style.space(4)
            bar: root.bar
            value: root.radio.volume
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            fillColor: Commons.Color.accent
            knobColor: root.barForeground
            trackColor: Style.selectedFillFor(root.barForeground, Commons.Color.accent)
            onMoved: value => { root.cursor = 2; root.radio.setVolume(value) }
            onReleased: value => root.radio.commitVolume(value)
            onRightClicked: root.radio.toggleMute()
          }
        }
        Ui.Button {
          id: muteButton
          width: parent.width
          text: root.radio.muted ? "Unmute" : "Mute"
          iconText: root.radio.muted ? "󰝟" : "󰕾"
          foreground: root.barForeground
          bordered: true
          hasCursor: root.cursor === 3
          onHovered: hovered => { if (hovered) root.cursor = 3 }
          onClicked: root.radio.toggleMute()
        }
        Text {
          width: parent.width
          text: "Tab  Controls    ← →  Volume    P  Pause    [ ]  Seek    G  Live"
          color: root.barForeground
          opacity: 0.6
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        }
      }
      }
    }
  }
}
