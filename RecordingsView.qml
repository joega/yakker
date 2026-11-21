import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Dialogs
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "." as Radio

Column {
  id: root
  required property var radio
  property color foreground: Commons.Color.foreground
  property var bar
  property bool embedded: false
  property bool externalBack: false
  property bool settingsTabbed: false
  property string storageSection: "storage"
  property string storageFeedback: ""
  property string storageDraftFolder: ""
  property string storageDraftCap: ""
  readonly property bool storageDirty: folderField.text !== storageDraftFolder || capField.text !== storageDraftCap
  readonly property string uiFontFamily: "Adwaita Sans"
  property var ensureVisible: function(item) {}
  signal back()
  signal playbackShortcut(string text)
  signal storageClosed()
  signal requestStorage()
  spacing: Style.space(8)
  readonly property var snapshot: radio.recordings || ({})
  readonly property bool available: radio.ready && snapshot.available === true
  onAvailableChanged: if (editing && available) previewDelay.restart()
  property bool editing: false
  property string editingId: ""
  property int editRevision: 0
  property var days: []
  property bool scheduleEnabled: true
  property bool timezoneEditing: false
  property int pendingSerial: 0
  property int playbackSerial: 0
  property string playbackId: ""
  property string pendingKind: ""
  property string localError: ""
  onLocalErrorChanged: if (localError && visible) Qt.callLater(function() { root.ensureVisible(localErrorText) })
  property string confirmation: ""
  property int confirmRevision: 0
  property var expandedRecordings: ({})
  property bool storageEditing: false
  property int storageRevision: 0
  property string stationValue: ""
  property int previewSerial: 0
  property string previewKey: ""
  property string previewText: ""
  property string tab: "library"
  property bool nowEditing: false
  readonly property string viewMode: settingsTabbed ? "storage" : editing ? "editor" : storageEditing ? "storage" : nowEditing ? "now" : tab
  property string scheduleKind: "weekly"
  property string nowStation: ""
  property int nowRevision: 0
  property string searchText: ""
  property string statusFilter: "all"
  readonly property var filteredRecordings: (snapshot.recordings || []).filter(function(r) {
    const q = root.searchText.trim().toLowerCase()
    return (!q || ((r.label || "") + " " + (r.stationName || "")).toLowerCase().indexOf(q) >= 0)
      && (root.statusFilter === "all" || r.status === root.statusFilter)
  })
  property int libraryPage: 0
  readonly property int pageSize: 20
  readonly property int libraryPages: Math.max(1, Math.ceil(filteredRecordings.length / pageSize))
  readonly property string formKey: JSON.stringify(scheduleForm())
  readonly property bool pending: pendingSerial !== 0
  readonly property var sortedSchedules: (snapshot.schedules || []).slice().sort(function(a, b) {
    const rank = function(s) { return s.enabled && s.nextStart ? 0 : s.enabled ? 1 : 2 }
    const order = rank(a) - rank(b)
    if (order) return order
    const time = function(s) { const n = Date.parse(s.nextStart); return isFinite(n) ? n : Infinity }
    if (time(a) !== time(b)) return time(a) < time(b) ? -1 : 1
    return String(a.label || a.stationName).localeCompare(String(b.label || b.stationName))
  })
  readonly property int upcomingCount: sortedSchedules.filter(function(s) { return s.enabled && !!s.nextStart }).length
  onSortedSchedulesChanged: syncRows(scheduleRows, sortedSchedules)
  ListModel { id: scheduleRows; dynamicRoles: true }
  ListModel { id: libraryRows; dynamicRoles: true }

  function syncRows(model, rows) {
    for (let i = 0; i < rows.length; i++) {
      let found = -1
      for (let j = i; j < model.count; j++) if (model.get(j).rowData.id === rows[i].id) { found = j; break }
      if (found < 0) model.insert(i, {rowData: rows[i]})
      else {
        if (found !== i) model.move(found, i, 1)
        if (JSON.stringify(model.get(i).rowData) !== JSON.stringify(rows[i])) model.setProperty(i, "rowData", rows[i])
      }
    }
    if (model.count > rows.length) model.remove(rows.length, model.count - rows.length)
  }
  function refreshRows() {
    syncRows(scheduleRows, sortedSchedules)
    syncRows(libraryRows, filteredRecordings.slice(libraryPage * pageSize, (libraryPage + 1) * pageSize))
  }
  onSnapshotChanged: {
    if (confirmation && confirmRevision !== Number(snapshot.revision)) confirmation = ""
    const retained = {}, records = snapshot.recordings || []
    for (let i = 0; i < records.length; i++) if (expandedRecordings[records[i].id]) retained[records[i].id] = true
    expandedRecordings = retained
    if (libraryPage >= Math.max(1, Math.ceil(filteredRecordings.length / pageSize))) libraryPage = Math.max(0, Math.ceil(filteredRecordings.length / pageSize) - 1)
    refreshRows()
  }
  // The derived filter can update after snapshot's change handler. Refresh
  // from its own notification so a single incoming snapshot always fills the
  // visible page, including when the current page needs clamping.
  onFilteredRecordingsChanged: {
    if (libraryPage >= Math.max(1, Math.ceil(filteredRecordings.length / pageSize))) libraryPage = Math.max(0, Math.ceil(filteredRecordings.length / pageSize) - 1)
    refreshRows()
  }
  onLibraryPageChanged: { confirmation = ""; refreshRows() }
  onSearchTextChanged: { confirmation = ""; libraryPage = 0; refreshRows() }
  onStatusFilterChanged: { confirmation = ""; libraryPage = 0; refreshRows() }
  Component.onCompleted: refreshRows()
  onFormKeyChanged: { previewSerial = 0; previewText = ""; if (editing) previewDelay.restart() }
  onEditingChanged: { if (editing) previewDelay.restart(); else previewDelay.stop() }
  Timer {
    id: previewDelay
    interval: 500
    onTriggered: if (root.editing && root.available && root.stationValue && (root.scheduleKind === "once" ? dateField.text.length === 10 : root.days.length > 0)
                    && /^\d{2}:\d{2}$/.test(startField.text) && /^\d{2}:\d{2}$/.test(endField.text) && zoneField.text.trim()) root.previewNext()
  }
  component FieldLabel: Text {
    width: parent.width
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.uiFontFamily
    font.pixelSize: Style.fontPx(1)
    font.weight: Font.DemiBold
  }
  component Hint: Text {
    width: parent.width
    textFormat: Text.PlainText
    color: Qt.alpha(root.foreground, 0.65)
    font.family: root.uiFontFamily
    font.pixelSize: Style.fontPx(1)
    wrapMode: Text.Wrap
  }

  component StorageToggle: Ui.Toggle {
    width: parent.width
    foreground: root.foreground
    fontFamily: root.uiFontFamily
    titleSize: Style.fontPx(1.083)
    descriptionSize: Style.fontPx(1)
    borderSpec: activeFocus ? Border.controlSpec("focus", foreground, accent) : Border.none()
    opacity: enabled ? 1 : 0.45
    Accessible.role: Accessible.CheckBox
    Accessible.name: label
    Accessible.description: description
    Accessible.checkable: true
    Accessible.checked: checked
    onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
  }

  function activate() { focusItem(backButton.visible ? backButton : tab === "schedules" ? newScheduleButton : searchField) }
  function goBack() {
    if (pending) return
    localError = ""; confirmation = ""
    if (editing) { editing = false; tab = "schedules" }
    else if (storageEditing) { if (settingsTabbed) { back(); return }; storageEditing = false; storageClosed() }
    else if (nowEditing) nowEditing = false
    else { back(); return }
    if (visible) activate()
  }
  Keys.onEscapePressed: event => { event.accepted = true; root.goBack() }
  // Text fields consume their own letters before keys bubble to this view.
  // Keep listening shortcuts available from buttons and the library itself.
  Keys.onPressed: event => {
    if (event.modifiers !== Qt.NoModifier || "p[]gmr".indexOf(event.text.toLowerCase()) < 0 || !event.text) return
    root.playbackShortcut(event.text)
    event.accepted = true
  }
  function focusItem(item) { Qt.callLater(function() { if (!root.visible || !item.visible) return; item.forceActiveFocus(); root.ensureVisible(item) }) }
  function beginEdit(s) {
    if (pending) return
    storageEditing = false; nowEditing = false; tab = "schedules"
    s = s || {}
    scheduleKind = s.kind || "weekly"
    const today = new Date()
    dateField.text = s.date || today.getFullYear() + "-" + String(today.getMonth()+1).padStart(2, "0") + "-" + String(today.getDate()).padStart(2, "0")
    timezoneEditing = false
    editingId = s.id || ""
    editRevision = Number(snapshot.revision) || 0
    stationValue = s.stationId || radio.stationId
    labelField.text = s.label || ""
    days = (s.weekdays || []).slice()
    startField.text = s.startTime || "14:00"
    endField.text = s.endTime || "14:20"
    zoneField.text = s.timezone || snapshot.localTimezone || "UTC"
    scheduleEnabled = s.enabled === undefined ? true : s.enabled
    localError = ""; confirmation = ""; editing = true
    focusItem(labelField)
  }
  function submit(serial, kind) {
    if (!serial) { localError = "Recording manager is disconnected. Your changes are preserved."; return }
    pendingSerial = serial; pendingKind = kind; localError = ""
  }
  function save() {
    if (pending) return
    submit(radio.upsertSchedule(editRevision, scheduleForm(), true), "schedule")
  }
  function refreshDraft() {
    if (editingId && !(snapshot.schedules || []).some(function(s) { return s.id === root.editingId })) { localError = "This schedule was removed. Create a new schedule to use this draft."; return }
    editRevision = Number(snapshot.revision) || 0
    localError = ""
  }
  function scheduleForm() {
    return {id: editingId, stationId: stationValue, label: labelField.text.trim(), kind: scheduleKind, date: scheduleKind === "once" ? dateField.text.trim() : "", weekdays: scheduleKind === "weekly" ? days : [], startTime: startField.text.trim(), endTime: endField.text.trim(), timezone: zoneField.text.trim(), enabled: scheduleEnabled}
  }
  function previewNext() {
    previewDelay.stop()
    previewKey = formKey
    previewSerial = radio.previewSchedule(scheduleForm())
    previewText = previewSerial ? "Calculating…" : "Recording manager disconnected."
  }
  function toggleDay(day) {
    const d = days.slice(), i = d.indexOf(day)
    if (i < 0) d.push(day); else d.splice(i, 1)
    d.sort(function(a,b) { return a-b }); days = d
  }
  function action(kind, id, revision) {
    if (pending) return
    if (kind === "deleteSchedule" || kind === "deleteRecording") {
      const key = kind + ":" + id
      if (confirmation !== key) { confirmation = key; confirmRevision = revision; return }
      revision = confirmRevision
      confirmation = ""
    }
    submit(radio[kind](revision, id), kind)
  }
  function playItem(id, fromStart) {
    localError = ""
    playbackId = id
    playbackSerial = radio.playRecording(id, fromStart === true)
    if (!playbackSerial) localError = "Recording manager is disconnected."
  }
  function beginStorage() {
    if (pending) return
    editing = false; nowEditing = false
    if (!available) { localError = "Recording manager is unavailable."; activate(); return }
    storageRevision = Number(snapshot.revision) || 0
    folderField.text = snapshot.settings.folder || ""
    capField.text = String((Number(snapshot.settings.storageCapBytes) || 0) / 1073741824)
    storageDraftFolder = folderField.text; storageDraftCap = capField.text
    storageFeedback = ""
    storageEditing = true; localError = ""; focusItem(storageSection === "alerts" ? recordingAlertsToggle : folderField)
  }
  function focusStorage() { focusItem(folderField) }
  function focusNotifications() { focusItem(recordingAlertsToggle) }
  function beginNow() {
    if (pending || !available) return
    editing = false; storageEditing = false; nowEditing = true; tab = "library"
    nowStation = radio.stationId || ""; nowRevision = Number(snapshot.revision) || 0
    durationField.text = "30"; localError = ""; focusItem(durationField)
  }
  function startNow() {
    const value = Number(durationField.text)
    if (!nowStation || !/^\d+$/.test(durationField.text) || value < 1 || value > 720) {
      localError = "Choose a station and a duration from 1 to 720 minutes."; return
    }
    submit(radio.startRecording(nowRevision, nowStation, value), "now")
  }
  function toggleDetails(id) {
    const next = Object.assign({}, expandedRecordings)
    if (next[id]) { delete next[id]; if (confirmation === "deleteRecording:" + id) confirmation = "" }
    else next[id] = true
    expandedRecordings = next
  }
  function folderUrl(path) {
    if (!path || path[0] !== "/" || path.indexOf("//") === 0 || path.indexOf("\0") >= 0) return ""
    return "file://" + path.split("/").map(function(part) { return encodeURIComponent(part) }).join("/")
  }
  function pathFromFolderUrl(value) {
    const url = String(value)
    // Only hostless local file URLs are accepted. URL query and fragment
    // delimiters must be percent encoded when they are part of a filename.
    if (url.indexOf("file:///") !== 0 || /[?#]/.test(url)) return ""
    try {
      const path = decodeURIComponent(url.substring(7))
      return folderUrl(path) ? path : ""
    } catch (e) { return "" }
  }
  function saveStorage() {
    const old = snapshot.settings || {}
    submit(radio.recordingSettings(storageRevision, {folder: folderField.text, storageCapBytes: Math.round(Number(capField.text) * 1073741824), freeSpaceReserveBytes: old.freeSpaceReserveBytes, concurrency: old.concurrency}), "settings")
  }
  function timeText(hours, minutes) {
    const locale = Qt.locale(Commons.I18n.formatLocale)
    return String(hours % 12 || 12).padStart(2, "0") + ":" + String(minutes).padStart(2, "0")
      + (hours < 12 ? locale.amText : locale.pmText).toUpperCase()
  }
  function scheduleTimeText(value) {
    const parts = /^(\d{2}):(\d{2})$/.exec(String(value || ""))
    return parts ? timeText(Number(parts[1]), Number(parts[2])) : String(value || "")
  }
  function dateText(value, sourceTime) {
    if (!value) return ""
    let d = new Date(value)
    if (isNaN(d.getTime())) return String(value)
    // Schedule occurrences already carry their saved timezone's UTC offset.
    // Read their wall-clock fields in UTC to avoid converting them to the
    // machine timezone (or applying the machine's different DST rules).
    if (sourceTime) d = new Date(String(value).replace(/(?:Z|[+-]\d{2}:\d{2})$/, "Z"))
    const day = sourceTime ? d.getUTCDay() : d.getDay()
    const month = sourceTime ? d.getUTCMonth() : d.getMonth()
    const date = sourceTime ? d.getUTCDate() : d.getDate()
    const year = sourceTime ? d.getUTCFullYear() : d.getFullYear()
    const hours = sourceTime ? d.getUTCHours() : d.getHours()
    const minutes = sourceTime ? d.getUTCMinutes() : d.getMinutes()
    const locale = Qt.locale(Commons.I18n.formatLocale)
    return locale.dayName(day, Locale.ShortFormat) + " " + locale.monthName(month, Locale.ShortFormat)
      + " " + date + " " + year + " " + timeText(hours, minutes)
  }
  function shortDateText(value) {
    const date = new Date(value)
    if (!value || isNaN(date.getTime())) return "Date unavailable"
    const locale = Qt.locale(Commons.I18n.formatLocale)
    return locale.dayName(date.getDay(), Locale.ShortFormat) + " " + locale.monthName(date.getMonth(), Locale.ShortFormat)
      + " " + date.getDate() + (date.getFullYear() !== new Date().getFullYear() ? " " + date.getFullYear() : "")
      + " · " + timeText(date.getHours(), date.getMinutes())
  }
  function seconds(value) {
    const number = Number(value)
    return isFinite(number) && number > 0 ? number : 0
  }
  function recordingStation(recording) {
    return radio.stations.find(function(station) { return station.id === recording.stationId })
      || {name: recording.stationName || "Saved recording", icon: "󰲸"}
  }
  function repeatText(schedule) {
    if (schedule.kind === "once") return "One time · " + schedule.date
    const days = (schedule.weekdays || []).slice().sort(function(a,b) { return a-b })
    if (days.join(",") === "1,2,3,4,5") return "Weekdays"
    if (days.length === 7) return "Every day"
    return days.map(function(day) { return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][day] }).join(", ") || "No days selected"
  }
  function occurrenceText(start, end) {
    // Keep saved schedule wall-clock fields, including their timezone offset.
    const wall = function(value) { return new Date(String(value).replace(/(?:Z|[+-]\d{2}:\d{2})$/, "Z")) }
    const a = wall(start), b = wall(end)
    if (isNaN(a.getTime())) return "Time unavailable"
    const locale = Qt.locale(Commons.I18n.formatLocale)
    const day = function(d) { return locale.dayName(d.getUTCDay(), Locale.ShortFormat) + " " + locale.monthName(d.getUTCMonth(), Locale.ShortFormat) + " " + d.getUTCDate() + (d.getUTCFullYear() !== new Date().getFullYear() ? " " + d.getUTCFullYear() : "") }
    return day(a) + " · " + timeText(a.getUTCHours(), a.getUTCMinutes())
      + (isNaN(b.getTime()) ? "" : "–" + (a.getUTCDate() !== b.getUTCDate() || a.getUTCMonth() !== b.getUTCMonth() || a.getUTCFullYear() !== b.getUTCFullYear() ? day(b) + " · " : "") + timeText(b.getUTCHours(), b.getUTCMinutes()))
  }
  function durationText() {
    if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(startField.text) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(endField.text)) return ""
    const minutes = function(value) { return Number(value.slice(0,2))*60 + Number(value.slice(3)) }
    const a = minutes(startField.text), b = minutes(endField.text), span = (b-a+1440)%1440
    if (!span) return "Choose different start and end times."
    if (span > 720) return "Choose a recording up to 12 hours."
    return (span >= 60 ? Math.floor(span/60) + " hr" + (span%60 ? " " + span%60 + " min" : "") : span + " min") + (b < a ? " · Ends the next day" : " recording")
  }
  function sizeText(n) {
    const bytes = Math.max(0, Number(n) || 0)
    if (bytes < 1024) return Math.round(bytes) + " B"
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KiB"
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + " MiB"
    return (bytes / 1073741824).toFixed(2) + " GiB"
  }
  function statusText(value) {
    return ({recording:"Recording", complete:"Complete", partial:"Partial", error:"Failed", missed:"Missed", missing:"Missing"})[value] || String(value || "")
  }
  Connections {
    target: root.radio
    function onSchedulePreviewSerialChanged() {
      if (!root.previewSerial || root.radio.schedulePreviewSerial !== root.previewSerial || root.previewKey !== root.formKey) return
      root.previewSerial = 0
      const p = root.radio.schedulePreview || {}
      root.previewText = root.radio.schedulePreviewError || (p.nextStart ? root.occurrenceText(p.nextStart, p.nextEnd) + " · " + p.timezone : (root.scheduleEnabled ? "No upcoming occurrence." : "This schedule is disabled."))
    }
    function onRecordingMutationSerialChanged() {
      if (!root.pendingSerial || root.radio.recordingMutationSerial !== root.pendingSerial) return
      const kind = root.pendingKind
      root.pendingSerial = 0; root.pendingKind = ""
      root.localError = root.radio.recordingError || ""
      if (root.radio.recordingMutationOK) {
        if (kind === "schedule" || kind === "deleteSchedule") {
          root.editing = false
          if (root.visible) root.activate()
        }
        if (kind === "settings") {
          if (root.settingsTabbed) { root.beginStorage(); root.storageFeedback = "Storage saved." }
          else { root.storageEditing = false; root.storageClosed() }
        }
        if (kind === "now") { root.nowEditing = false; root.tab = "library" }
        if (kind === "deleteRecording" && root.visible && root.viewMode === "library") root.activate()
      }
    }
    function onStatusReceived(serial) {
      if (!root.playbackSerial || serial < root.playbackSerial) return
      if (root.radio.error) {
        root.playbackSerial = 0; root.localError = root.radio.error
      } else if (root.radio.playbackKind === "recording" && root.radio.recordingId === root.playbackId && root.radio.wanted) {
        root.playbackSerial = 0
        if (!root.embedded) root.back()
      }
    }
    function onReadyChanged() {
      if (!root.radio.ready && root.previewSerial) { root.previewSerial = 0; root.previewText = "Recording manager disconnected." }
      if (!root.radio.ready && root.playbackSerial) { root.playbackSerial = 0; root.localError = "Recording manager disconnected." }
      if (!root.radio.ready && root.pending) {
        root.pendingSerial = 0; root.pendingKind = ""
        root.localError = "Recording manager disconnected. Your changes are preserved."
      }
    }
  }
  Radio.FocusButton {
    id: backButton
    visible: !root.externalBack && (!root.embedded || root.editing || root.storageEditing || root.nowEditing)
    text: root.editing ? "Schedules" : root.nowEditing ? "Library" : "Back"
    iconName: "left"
    foreground: Qt.alpha(root.foreground, 0.8)
    fontSize: Style.fontPx(1)
    horizontalPadding: 0
    focusable: true
    enabled: !root.pending
    onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
    onClicked: root.goBack()
  }
  Text {
    width: parent.width
    visible: !root.externalBack
    text: root.storageEditing ? "Recording storage" : root.nowEditing ? "Record now" : root.editing ? (root.editingId ? "Edit schedule" : "New schedule") : root.tab === "schedules" ? "Upcoming recordings" : "Your recordings"
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.uiFontFamily
    font.pixelSize: Style.fontPx(1.5)
    font.weight: Font.DemiBold
  }
  Text { width: parent.width; visible: !root.available || !!root.snapshot.error; text: !root.radio.ready ? "Recording manager disconnected." : (root.snapshot.error || "Recording manager unavailable."); textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); wrapMode: Text.Wrap }
  Text { id: localErrorText; width: parent.width; visible: root.localError.length > 0; text: root.localError; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
  Text { width: parent.width; visible: root.pending; text: "Working…"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
  Row { width: parent.width; spacing: Style.space(4); visible: !root.embedded && (root.viewMode === "library" || root.viewMode === "schedules")
    Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Library"; selected: root.tab === "library"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.tab = "library" }
    Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Schedules"; selected: root.tab === "schedules"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.tab = "schedules" }
  }
  Column {
    width: parent.width
    spacing: Style.space(12)
    visible: root.viewMode === "schedules"
    Row {
      width: parent.width
      spacing: Style.space(8)
      Hint {
        width: Math.max(0, parent.width - newScheduleButton.width - parent.spacing)
        anchors.verticalCenter: parent.verticalCenter
        text: root.upcomingCount ? root.upcomingCount + (root.upcomingCount === 1 ? " upcoming schedule" : " upcoming schedules") : "Plan a show for later"
      }
      Radio.FocusButton {
        id: newScheduleButton
        text: "New schedule"
        iconName: "plus"
        fontSize: Style.fontPx(1)
        color: Qt.alpha(Commons.Color.accent, 0.12)
        foreground: root.foreground
        focusable: true
        enabled: root.available && !root.pending
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        onClicked: root.beginEdit(null)
      }
    }
    Hint { visible: root.available && !(root.snapshot.schedules || []).length; text: "Record a favorite show once or every week. Your saved shows will appear in Library." }
    Repeater {
      id: scheduleRepeater
      model: scheduleRows
      Column {
        id: scheduleRow
        required property var rowData
        required property int index
        readonly property bool upcoming: rowData.enabled && !!rowData.nextStart
        readonly property bool nextUp: upcoming && index === 0
        width: root.width
        spacing: Style.space(8)
        Ui.PanelSeparator { width: parent.width }
        Item { width: 1; height: Style.space(2) }
        FieldLabel {
          visible: scheduleRow.nextUp || !scheduleRow.rowData.enabled && (scheduleRow.index === 0 || !!root.sortedSchedules[scheduleRow.index-1] && root.sortedSchedules[scheduleRow.index-1].enabled)
          text: scheduleRow.nextUp ? "NEXT UP" : "PAUSED"
          color: scheduleRow.nextUp ? Commons.Color.accent : Qt.alpha(root.foreground, 0.6)
          font.pixelSize: Style.fontPx(0.833)
          font.letterSpacing: Style.space(1)
        }
        Row {
          width: parent.width
          spacing: Style.space(12)
          Radio.StationLogo { width: Style.space(36); height: width; station: root.recordingStation(scheduleRow.rowData); fallbackColor: root.foreground }
          Column {
            width: parent.width - Style.space(36) - parent.spacing
            spacing: Style.space(3)
            Text { id: scheduleTitle; width: parent.width; text: scheduleRow.rowData.label || scheduleRow.rowData.stationName; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.25); font.weight: Font.DemiBold; wrapMode: Text.Wrap }
            Hint { text: scheduleRow.rowData.stationName }
          }
        }
        Text {
          width: parent.width
          text: scheduleRow.upcoming ? root.occurrenceText(scheduleRow.rowData.nextStart, scheduleRow.rowData.nextEnd)
            : scheduleRow.rowData.enabled ? "No upcoming recording" : "Schedule paused"
          textFormat: Text.PlainText
          color: scheduleRow.nextUp ? Commons.Color.accent : root.foreground
          font.family: root.uiFontFamily
          font.pixelSize: Style.fontPx(1.083)
          font.weight: Font.Medium
          wrapMode: Text.Wrap
        }
        Hint { text: root.repeatText(scheduleRow.rowData) + (scheduleRow.upcoming ? "" : " · " + root.scheduleTimeText(scheduleRow.rowData.startTime) + "–" + root.scheduleTimeText(scheduleRow.rowData.endTime)) + " · " + scheduleRow.rowData.timezone }
        Radio.FocusButton {
          id: scheduleEditButton
          text: "Edit schedule"
          fontSize: Style.fontPx(1)
          horizontalPadding: 0
          foreground: Qt.alpha(root.foreground, 0.8)
          focusable: true
          enabled: root.available && !root.pending
          onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
          onClicked: root.beginEdit(scheduleRow.rowData)
        }
      }
    }
  }
  Column {
    width: parent.width
    spacing: Style.space(16)
    visible: root.editing
    enabled: !root.pending
    Column {
      width: parent.width; spacing: Style.space(6)
      FieldLabel { text: "Show name" }
      Ui.TextField { id: labelField; width: parent.width; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); placeholderText: "Optional · e.g. Morning drive"; Accessible.name: "Show name (optional)"; foreground: root.foreground; maximumLength: 160; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
      FieldLabel { text: "Station" }
      Ui.SearchableDropdown { id: stationPicker; fontFamily: root.uiFontFamily; width: parent.width; showLabel: false; placeholderText: "Choose station"; value: root.stationValue; options: root.radio.stationOptions; foreground: root.foreground; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onChanged: value => { root.stationValue = value } }
    }
    Ui.PanelSeparator { width: parent.width }
    Column {
      width: parent.width; spacing: Style.space(8)
      FieldLabel { text: "When" }
      Row {
        width: parent.width; spacing: Style.space(4)
        Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Every week"; selected: root.scheduleKind === "weekly"; foreground: root.foreground; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.scheduleKind = "weekly" }
        Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "One time"; selected: root.scheduleKind === "once"; foreground: root.foreground; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.scheduleKind = "once" }
      }
      Column {
        width: parent.width; spacing: Style.space(6); visible: root.scheduleKind === "once"
        FieldLabel { text: "Date · YYYY-MM-DD" }
        Ui.TextField { id: dateField; width: parent.width; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); placeholderText: "YYYY-MM-DD"; Accessible.name: "Recording date YYYY-MM-DD"; foreground: root.foreground; maximumLength: 10; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
      }
      Row {
        width: parent.width; spacing: Style.space(2); visible: root.scheduleKind === "weekly"
        Repeater { model: ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
          Radio.FocusButton { required property int index; required property string modelData; width: (parent.width - parent.spacing * 6) / 7; text: modelData; Accessible.name: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][index]; Accessible.checkable: true; Accessible.checked: selected; selected: root.days.indexOf(index) >= 0; foreground: root.foreground; focusable: true; horizontalPadding: 0; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.toggleDay(index) }
        }
      }
      Row {
        width: parent.width; spacing: Style.space(12)
        Column {
          width: (parent.width-parent.spacing)/2; spacing: Style.space(6)
          FieldLabel { text: "Start · 24h" }
          Ui.TextField { id: startField; width: parent.width; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); placeholderText: "HH:mm"; Accessible.name: "Start time in 24-hour format"; foreground: root.foreground; maximumLength: 5; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
        }
        Column {
          width: (parent.width-parent.spacing)/2; spacing: Style.space(6)
          FieldLabel { text: "End · 24h" }
          Ui.TextField { id: endField; width: parent.width; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); placeholderText: "HH:mm"; Accessible.name: "End time in 24-hour format"; foreground: root.foreground; maximumLength: 5; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
        }
      }
      Hint { text: root.durationText() || "Enter start and end times." }
      Row {
        width: parent.width; spacing: Style.space(8)
        Hint { width: Math.max(0, parent.width - changeZone.width - parent.spacing); anchors.verticalCenter: parent.verticalCenter; text: zoneField.text }
        Radio.FocusButton { id: changeZone; text: root.timezoneEditing ? "Done" : "Change zone"; fontSize: Style.fontPx(1); horizontalPadding: 0; foreground: root.foreground; focusable: true; onClicked: { root.timezoneEditing = !root.timezoneEditing; if (root.timezoneEditing) root.focusItem(zoneField) } }
      }
      Ui.TextField { id: zoneField; visible: root.timezoneEditing; width: parent.width; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); placeholderText: "e.g. America/New_York"; Accessible.name: "Recording timezone"; foreground: root.foreground; maximumLength: 128; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    }
    Ui.Toggle {
      id: scheduleEnabledToggle
      width: parent.width
      label: "Schedule enabled"
      description: root.scheduleEnabled ? "Records automatically at the chosen time" : "Keep this schedule paused"
      checked: root.scheduleEnabled
      foreground: root.foreground
      fontFamily: root.uiFontFamily
      titleSize: Style.fontPx(1.083)
      descriptionSize: Style.fontPx(1)
      Accessible.role: Accessible.CheckBox
      Accessible.name: label
      Accessible.checked: checked
      onClicked: root.scheduleEnabled = !root.scheduleEnabled
      onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
    }
    Rectangle {
      width: parent.width
      implicitHeight: review.implicitHeight + Style.space(20)
      radius: Style.space(8)
      color: Qt.alpha(Commons.Color.accent, 0.07)
      Column {
        id: review
        x: Style.space(10); y: Style.space(10); width: parent.width - Style.space(20); spacing: Style.space(5)
        FieldLabel { text: "Next recording" }
        Hint { text: !root.scheduleEnabled ? "Paused · enable this schedule to record automatically." : root.previewText || (root.previewSerial ? "Checking next recording…" : root.scheduleKind === "weekly" && !root.days.length ? "Choose at least one day." : "Your next recording time will appear here."); color: Qt.alpha(root.foreground, 0.8) }
      }
    }
    Radio.FocusButton { id: refreshDraftButton; width: parent.width; visible: root.editRevision !== Number(root.snapshot.revision); text: "Refresh and keep this draft"; foreground: root.foreground; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.refreshDraft() }
    Row {
      width: parent.width; spacing: Style.space(8)
      Radio.FocusButton { id: saveScheduleButton; width: (parent.width-parent.spacing)*0.65; text: root.pending && root.pendingKind === "schedule" ? "Saving…" : root.editingId ? "Save changes" : "Create schedule"; color: Qt.alpha(Commons.Color.accent, 0.16); foreground: root.foreground; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.save() }
      Radio.FocusButton { width: (parent.width-parent.spacing)*0.35; text: "Cancel"; foreground: root.foreground; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.goBack() }
    }
    Radio.FocusButton { id: deleteScheduleButton; visible: !!root.editingId; text: root.confirmation === "deleteSchedule:" + root.editingId ? "Confirm delete schedule" : "Delete schedule"; fontSize: Style.fontPx(1); horizontalPadding: 0; foreground: Commons.Color.urgent; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.action("deleteSchedule", root.editingId, root.editRevision) }
  }
  Column {
    width: parent.width
    spacing: Style.space(12)
    visible: root.viewMode === "library"
    Row {
      width: parent.width
      spacing: Style.space(8)
      Radio.FocusButton {
        id: libraryRecordButton
        text: "Record now"
        iconName: "record"
        iconSize: Style.space(16)
        fontSize: Style.fontPx(1)
        foreground: root.foreground
        focusable: true
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        enabled: root.available && !root.pending
        onClicked: root.beginNow()
      }
      Item { width: Math.max(0, parent.width - libraryRecordButton.width - libraryStorageButton.width - parent.spacing * 2); height: 1 }
      Radio.FocusButton {
        id: libraryStorageButton
        text: "Storage"
        iconName: "folder"
        iconSize: Style.space(16)
        fontSize: Style.fontPx(1)
        foreground: Qt.alpha(root.foreground, 0.8)
        focusable: true
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        enabled: root.available && !root.pending
        onClicked: root.embedded ? root.requestStorage() : root.beginStorage()
      }
    }
    Row {
      width: parent.width
      spacing: Style.space(8)
      Ui.TextField {
        id: searchField
        width: parent.width - statusPicker.width - parent.spacing
        font.family: root.uiFontFamily
        font.pixelSize: Style.fontPx(1.167)
        placeholderText: "Search recordings"
        Accessible.name: "Search title or station"
        foreground: root.foreground
        maximumLength: 160
        onTextChanged: root.searchText = text
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
      }
      Ui.Dropdown {
        id: statusPicker
        width: Math.min(Style.space(132), parent.width * 0.44)
        fontFamily: root.uiFontFamily
        showLabel: false
        value: root.statusFilter
        foreground: root.foreground
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        options: [{value:"all", label:"All statuses"}, {value:"recording", label:"Recording"}, {value:"complete", label:"Saved"}, {value:"partial", label:"Partial"}, {value:"error", label:"Failed"}, {value:"missing", label:"Missing"}, {value:"missed", label:"Missed"}]
        onChanged: value => { root.statusFilter = value }
      }
    }
    Text { width: parent.width; visible: root.available && root.filteredRecordings.length === 0; text: (root.snapshot.recordings || []).length ? "No recordings match." : "No recordings yet."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
    Repeater {
      id: libraryRepeater
      model: libraryRows
      Column {
        id: recordRow
        required property var rowData
        readonly property var modelData: rowData
        readonly property bool expanded: !!root.expandedRecordings[rowData.id]
        readonly property bool capturing: rowData.status === "recording"
        readonly property bool playingHere: root.radio.playbackKind === "recording" && root.radio.recordingId === rowData.id && root.radio.wanted
        readonly property bool opening: playingHere && !root.radio.paused && root.radio.playbackState !== "playing"
        readonly property real durationSeconds: playingHere && root.seconds(root.radio.duration) > 0 ? root.seconds(root.radio.duration) : root.seconds(rowData.durationSeconds)
        readonly property real rawPosition: playingHere ? root.seconds(root.radio.position) : Math.floor(root.seconds(rowData.resumePosition))
        readonly property real listeningPosition: durationSeconds > 0 ? Math.min(rawPosition, durationSeconds) : rawPosition
        readonly property bool hasResume: listeningPosition > 0.5 && (durationSeconds === 0 || listeningPosition < durationSeconds - 0.5)
        readonly property string primaryLabel: capturing ? "Stop capture" : opening ? "Opening…" : playingHere && !root.radio.paused ? "Pause"
          : hasResume ? "Resume · " + root.radio.clock(listeningPosition) : "Play"
        readonly property string progressLabel: (rowData.status !== "complete" && !capturing ? root.statusText(rowData.status) + " · " : "") + (capturing ? "Recording live audio"
          : rowData.playable !== true ? (rowData.status === "missing" ? "File unavailable" : "No playable audio")
          : opening ? "Opening recording…"
          : durationSeconds > 0 ? ((playingHere ? (root.radio.paused ? "Paused · " : "Playing · ") : "")
              + (listeningPosition > 0 || playingHere ? root.radio.clock(listeningPosition) + " / " + root.radio.clock(durationSeconds) + " · " + root.radio.clock(durationSeconds - listeningPosition) + " left" : root.radio.clock(durationSeconds) + " · Not started"))
          : (listeningPosition > 0 ? root.radio.clock(listeningPosition) + " listened · " : "") + "Duration unavailable")
        width: root.width
        spacing: Style.space(8)
        Item { width: 1; height: Style.space(2) }
        Row {
          width: parent.width
          spacing: Style.space(12)
          Radio.StationLogo {
            width: Style.space(40)
            height: width
            station: root.recordingStation(recordRow.rowData)
            fallbackColor: Commons.Color.accent
          }
          Column {
            width: parent.width - Style.space(52)
            spacing: Style.space(3)
            Text {
              id: recordTitle
              width: parent.width
              text: recordRow.rowData.label || recordRow.rowData.stationName || "Saved recording"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.uiFontFamily
              font.pixelSize: Style.fontPx(1.25)
              font.weight: Font.DemiBold
              wrapMode: Text.Wrap
            }
            Text { width: parent.width; text: (recordRow.rowData.stationName || "Unknown station") + " · " + root.shortDateText(recordRow.rowData.startedAt || recordRow.rowData.plannedStart); textFormat: Text.PlainText; color: root.foreground; opacity: 0.8; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
          }
        }
        Column {
          width: parent.width
          spacing: Style.space(6)
          QQC.ProgressBar {
            id: listeningProgress
            width: parent.width
            height: Style.space(3)
            visible: recordRow.rowData.playable === true && !recordRow.capturing && recordRow.durationSeconds > 0 && (recordRow.listeningPosition > 0 || recordRow.playingHere)
            from: 0
            to: recordRow.durationSeconds > 0 ? recordRow.durationSeconds : 1
            value: recordRow.listeningPosition
            Accessible.name: "Listening progress for " + (recordRow.rowData.label || recordRow.rowData.stationName)
            Accessible.description: root.radio.clock(recordRow.listeningPosition) + " of " + root.radio.clock(recordRow.durationSeconds)
            background: Rectangle { radius: height / 2; color: Qt.alpha(root.foreground, 0.14) }
            contentItem: Item { Rectangle { width: parent.width * listeningProgress.visualPosition; height: parent.height; radius: height / 2; color: Commons.Color.accent } }
          }
          Text { width: parent.width; text: recordRow.progressLabel; textFormat: Text.PlainText; color: recordRow.capturing ? Commons.Color.urgent : recordRow.playingHere ? Commons.Color.accent : root.foreground; opacity: recordRow.playingHere || recordRow.capturing ? 1 : 0.8; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
        }
        Row {
          width: parent.width
          spacing: Style.space(8)
          Radio.FocusButton {
            id: rowPrimary
            visible: recordRow.capturing || recordRow.rowData.playable === true
            text: recordRow.primaryLabel
            iconName: recordRow.capturing ? "stop" : recordRow.playingHere && !root.radio.paused ? "pause" : "play"
            iconSize: Style.space(16)
            fontSize: Style.fontPx(1)
            foreground: recordRow.capturing ? Commons.Color.urgent : Commons.Color.accent
            background: Qt.alpha(foreground, 0.09)
            tooltipText: text + " · " + (recordRow.rowData.label || recordRow.rowData.stationName)
            focusable: true
            enabled: root.radio.ready && !root.pending && !recordRow.opening && (recordRow.capturing ? root.available : recordRow.rowData.playable === true)
            opacity: enabled ? 1 : 0.4
            onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
            onClicked: {
              if (recordRow.capturing) root.action("stopRecording", recordRow.rowData.id, root.snapshot.revision)
              else if (recordRow.playingHere) root.radio.togglePause()
              else root.playItem(recordRow.rowData.id, recordRow.durationSeconds > 0 && recordRow.listeningPosition >= recordRow.durationSeconds - 0.5)
            }
          }
          Item { width: Math.max(0, parent.width - (rowPrimary.visible ? rowPrimary.width + parent.spacing : 0) - rowDetails.width - parent.spacing); height: 1 }
          Radio.FocusButton {
            id: rowDetails
            text: recordRow.expanded ? "Hide details" : "Details"
            fontSize: Style.fontPx(1)
            foreground: Qt.alpha(root.foreground, 0.8)
            focusable: true
            Accessible.checkable: true
            Accessible.checked: recordRow.expanded
            onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
            onClicked: root.toggleDetails(recordRow.rowData.id)
          }
        }
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: recordRow.expanded
          Text {
            width: parent.width
            text: "Planned: " + root.dateText(recordRow.rowData.plannedStart) + " – " + root.dateText(recordRow.rowData.plannedEnd)
              + (recordRow.rowData.startedAt ? "\nActual: " + root.dateText(recordRow.rowData.startedAt) + (recordRow.rowData.endedAt ? " – " + root.dateText(recordRow.rowData.endedAt) : "") : "")
              + "\nSize: " + root.sizeText(recordRow.rowData.bytes) + " · " + root.statusText(recordRow.rowData.status)
              + (recordRow.rowData.reason ? "\n" + recordRow.rowData.reason : "")
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.8
            font.family: root.uiFontFamily
            font.pixelSize: Style.fontPx(1)
            wrapMode: Text.Wrap
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Radio.FocusButton {
              id: rowRestart
              visible: recordRow.rowData.playable === true
              text: "Play from start"
              fontSize: Style.fontPx(1)
              foreground: root.foreground
              focusable: true
              enabled: root.radio.ready && !root.pending
              onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
              onClicked: root.playItem(recordRow.rowData.id, true)
            }
            Radio.FocusButton {
              id: rowDelete
              text: root.confirmation === "deleteRecording:" + recordRow.rowData.id ? "Confirm delete" : "Delete"
              fontSize: Style.fontPx(1)
              foreground: Commons.Color.urgent
              focusable: true
              enabled: root.available && !root.pending && !recordRow.capturing
              onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
              onClicked: root.action("deleteRecording", recordRow.rowData.id, root.snapshot.revision)
            }
          }
        }
        Item { width: 1; height: Style.space(2) }
        Ui.PanelSeparator { width: parent.width }
      }
    }
    Row { width: parent.width; spacing: Style.space(4); visible: root.libraryPages > 1
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "← Previous"; foreground: root.foreground; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.libraryPage > 0; onClicked: root.libraryPage-- }
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Next →"; foreground: root.foreground; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.libraryPage + 1 < root.libraryPages; onClicked: root.libraryPage++ }
    }
    Text { width: parent.width; visible: root.libraryPages > 1; text: "Page " + (root.libraryPage + 1) + " of " + root.libraryPages; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
  }
  Column {
    width: parent.width
    spacing: Style.space(16)
    visible: root.nowEditing
    enabled: !root.pending
    Hint { text: "Save a show while you listen, or record another station in the background." }
    Column {
      width: parent.width; spacing: Style.space(6)
      FieldLabel { text: "Station" }
      Ui.SearchableDropdown { fontFamily: root.uiFontFamily; width: parent.width; showLabel: false; placeholderText: "Choose station"; value: root.nowStation; options: root.radio.stationOptions; foreground: root.foreground; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onChanged: value => { root.nowStation = value } }
    }
    Column {
      width: parent.width; spacing: Style.space(8)
      FieldLabel { text: "Record for" }
      Row {
        width: parent.width; spacing: Style.space(4)
        Repeater { model: [15, 30, 60]; Radio.FocusButton { required property int modelData; width: (parent.width-parent.spacing*2)/3; text: modelData + " min"; selected: Number(durationField.text) === modelData; foreground: root.foreground; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: durationField.text = String(modelData) } }
      }
      Row {
        width: parent.width; spacing: Style.space(12)
        Ui.TextField { id: durationField; width: Style.space(88); font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); placeholderText: "30"; Accessible.name: "Recording duration in minutes"; foreground: root.foreground; maximumLength: 3; inputMethodHints: Qt.ImhDigitsOnly; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
        Hint { width: parent.width - durationField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; text: "minutes · up to 12 hours" }
      }
    }
    Hint { text: "Stops automatically. Find the recording and its progress in Library." }
    Radio.FocusButton { id: startNowButton; width: parent.width; text: root.pending && root.pendingKind === "now" ? "Starting…" : "Start recording"; iconName: "record"; color: Qt.alpha(Commons.Color.accent, 0.16); foreground: root.foreground; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.available && !root.pending; onClicked: root.startNow() }
    Radio.FocusButton { width: parent.width; visible: root.nowRevision !== Number(root.snapshot.revision); text: "Refresh and keep this draft"; foreground: root.foreground; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: !root.pending; onClicked: { root.nowRevision = Number(root.snapshot.revision) || 0; root.localError = "" } }
  }
  FolderDialog { id: folderDialog; title: "Choose recording folder"; onAccepted: { const path = root.pathFromFolderUrl(selectedFolder); if (path) { folderField.text = path; root.localError = "" } else root.localError = "Choose a local folder." } }
  Column {
    id: storageSettings
    width: parent.width
    spacing: Style.space(18)
    visible: (root.storageEditing || root.settingsTabbed) && root.storageSection === "storage"
    enabled: !root.pending
    Column {
      width: parent.width
      spacing: Style.space(8)
      FieldLabel { text: "Storage"; font.pixelSize: Style.fontPx(1.25) }
      Row {
        width: parent.width
        spacing: Style.space(8)
        Hint { width: (parent.width - parent.spacing) / 2; text: root.sizeText(root.snapshot.usedBytes) + " used"; color: root.foreground }
        Hint { width: (parent.width - parent.spacing) / 2; text: root.sizeText((root.snapshot.settings || {}).storageCapBytes) + " limit"; horizontalAlignment: Text.AlignRight }
      }
      QQC.ProgressBar {
        id: storageUsage
        width: parent.width
        height: Style.space(4)
        visible: root.available && Number((root.snapshot.settings || {}).storageCapBytes) > 0
        from: 0
        to: Math.max(1, Number((root.snapshot.settings || {}).storageCapBytes) || 0)
        value: Math.min(to, Math.max(0, Number(root.snapshot.usedBytes) || 0))
        Accessible.name: "Recording storage usage"
        Accessible.description: root.sizeText(root.snapshot.usedBytes) + " of " + root.sizeText((root.snapshot.settings || {}).storageCapBytes)
        background: Rectangle { radius: height / 2; color: Qt.alpha(root.foreground, 0.14) }
        contentItem: Item { Rectangle { width: parent.width * storageUsage.visualPosition; height: parent.height; radius: height / 2; color: Commons.Color.accent } }
      }
    }
    Column {
      width: parent.width
      spacing: Style.space(6)
      FieldLabel { text: "Save recordings to" }
      Ui.TextField {
        id: folderField
        width: parent.width
        font.family: root.uiFontFamily
        font.pixelSize: Style.fontPx(1.167)
        placeholderText: "Absolute folder path"
        Accessible.name: "Recording folder (absolute path)"
        foreground: root.foreground
        maximumLength: 4096
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
      }
      Row {
        width: parent.width
        spacing: Style.space(18)
        Radio.FocusButton {
          id: chooseFolderButton
          text: "Choose folder"
          iconName: "folder"
          iconSize: Style.space(16)
          fontSize: Style.fontPx(1)
          horizontalPadding: 0
          foreground: Qt.alpha(root.foreground, 0.8)
          focusable: true
          onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
          onClicked: { const url = root.folderUrl(folderField.text); if (url) folderDialog.currentFolder = url; folderDialog.open() }
        }
        Radio.FocusButton {
          id: openFolderButton
          text: "Open folder"
          fontSize: Style.fontPx(1)
          horizontalPadding: 0
          foreground: Qt.alpha(root.foreground, 0.8)
          focusable: true
          onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
          onClicked: { const url = root.folderUrl(folderField.text); if (!url || !Qt.openUrlExternally(url)) root.localError = "Enter a local absolute folder path to open." }
        }
      }
      Hint { text: "Applies to future recordings. Existing files stay in place." }
    }
    Column {
      width: parent.width
      spacing: Style.space(6)
      FieldLabel { text: "Library limit" }
      Row {
        width: parent.width
        spacing: Style.space(10)
        Ui.TextField {
          id: capField
          width: Style.space(100)
          font.family: root.uiFontFamily
          font.pixelSize: Style.fontPx(1.167)
          placeholderText: "5"
          Accessible.name: "Library limit in GiB"
          foreground: root.foreground
          inputMethodHints: Qt.ImhFormattedNumbersOnly
          onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        }
        Hint { width: parent.width - capField.width - parent.spacing; text: "GiB"; anchors.verticalCenter: parent.verticalCenter }
      }
      Hint { text: "Saved shows are kept when the library is full." }
      Hint { text: "Keeps " + root.sizeText((root.snapshot.settings || {}).freeSpaceReserveBytes) + " free on disk · up to " + ((root.snapshot.settings || {}).concurrency || 3) + " recordings at once" }
    }
    Radio.FocusButton {
      id: refreshStorageButton
      visible: root.storageRevision !== Number(root.snapshot.revision)
      text: "Refresh and keep these settings"
      fontSize: Style.fontPx(1)
      horizontalPadding: 0
      foreground: root.foreground
      focusable: true
      onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
      onClicked: { root.storageRevision = Number(root.snapshot.revision) || 0; root.localError = "" }
    }
    Hint { visible: !!root.storageFeedback && !root.storageDirty; text: root.storageFeedback; color: Commons.Color.accent }
    Row {
      width: parent.width
      spacing: Style.space(8)
      Radio.FocusButton {
        id: saveStorageButton
        width: (parent.width - parent.spacing) * 0.65
        text: root.pending && root.pendingKind === "settings" ? "Saving…" : "Save storage"
        color: Qt.alpha(Commons.Color.accent, 0.16)
        foreground: root.foreground
        focusable: true
        opacity: enabled ? 1 : 0.45
        enabled: root.available && !root.pending && (!root.settingsTabbed || root.storageDirty)
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        onClicked: root.saveStorage()
      }
      Radio.FocusButton {
        id: cancelStorageButton
        width: (parent.width - parent.spacing) * 0.35
        text: root.settingsTabbed ? "Reset" : "Cancel"
        foreground: root.foreground
        focusable: true
        opacity: enabled ? 1 : 0.45
        enabled: !root.pending && (!root.settingsTabbed || root.storageDirty)
        onActiveFocusChanged: if (activeFocus) root.ensureVisible(this)
        onClicked: root.settingsTabbed ? root.beginStorage() : root.goBack()
      }
    }
  }
  Column {
    id: notificationSettings
    visible: (root.storageEditing || root.settingsTabbed) && root.storageSection === "alerts"
    width: parent.width
    spacing: Style.space(6)
    FieldLabel { text: "Notifications"; font.pixelSize: Style.fontPx(1.25) }
    Hint { text: "Changes apply immediately." }
    StorageToggle {
      id: recordingAlertsToggle
      label: "Recording alerts"
      description: "Completed shows, missed recordings and problems"
      checked: root.radio.recordingNotifications
      onClicked: root.radio.setRecordingNotifications(!checked)
    }
    StorageToggle {
      id: recordingStartToggle
      label: "When recording starts"
      description: enabled ? "Also notify when a capture begins" : "Turn on recording alerts to enable"
      checked: root.radio.recordingStartNotifications
      enabled: root.radio.recordingNotifications
      onClicked: if (enabled) root.radio.setRecordingStartNotifications(!checked)
    }
  }
}
