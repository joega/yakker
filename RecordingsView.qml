import QtQuick
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
  readonly property string uiFontFamily: "Adwaita Sans"
  property var ensureVisible: function(item) {}
  signal back()
  signal playbackShortcut(string text)
  signal storageClosed()
  spacing: Style.space(8)
  readonly property var snapshot: radio.recordings || ({})
  readonly property bool available: radio.ready && snapshot.available === true
  property bool editing: false
  property string editingId: ""
  property int editRevision: 0
  property var days: []
  property bool scheduleEnabled: true
  property int pendingSerial: 0
  property int playbackSerial: 0
  property string playbackId: ""
  property string pendingKind: ""
  property string localError: ""
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
  readonly property string viewMode: editing ? "editor" : storageEditing ? "storage" : nowEditing ? "now" : tab
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
    syncRows(scheduleRows, snapshot.schedules || [])
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
  onFormKeyChanged: { previewSerial = 0; previewText = "" }

  function activate() { focusItem(backButton.visible ? backButton : tab === "schedules" ? newScheduleButton : searchField) }
  function goBack() {
    if (pending) return
    localError = ""; confirmation = ""
    if (editing) { editing = false; tab = "schedules" }
    else if (storageEditing) { storageEditing = false; storageClosed() }
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
  function focusItem(item) { Qt.callLater(function() { item.forceActiveFocus(); root.ensureVisible(item) }) }
  function beginEdit(s) {
    if (pending) return
    storageEditing = false; nowEditing = false; tab = "schedules"
    s = s || {}
    scheduleKind = s.kind || "weekly"
    dateField.text = s.date || ""
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
    storageEditing = true; localError = ""; focusItem(folderField)
  }
  function beginNow() {
    if (pending || !available) return
    editing = false; storageEditing = false; nowEditing = true
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
      root.previewText = root.radio.schedulePreviewError || (p.nextStart ? "Next: " + root.dateText(p.nextStart, true) + " – " + root.dateText(p.nextEnd, true) + " · " + p.timezone : (root.scheduleEnabled ? "No upcoming occurrence." : "This schedule is disabled."))
    }
    function onRecordingMutationSerialChanged() {
      if (!root.pendingSerial || root.radio.recordingMutationSerial !== root.pendingSerial) return
      const kind = root.pendingKind
      root.pendingSerial = 0; root.pendingKind = ""
      root.localError = root.radio.recordingError || ""
      if (root.radio.recordingMutationOK) {
        if (kind === "schedule") root.editing = false
        if (kind === "settings") { root.storageEditing = false; root.storageClosed() }
        if (kind === "now") { root.nowEditing = false; root.tab = "library" }
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
  Radio.FocusButton { id: backButton; visible: !root.externalBack && (!root.embedded || root.editing || root.storageEditing || root.nowEditing); width: parent.width; text: root.editing ? "← Back to schedules" : (root.storageEditing || root.nowEditing) ? "← Back" : "← Back to player"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.goBack() }
  Text { width: parent.width; visible: !root.externalBack; text: root.storageEditing ? "STORAGE" : root.nowEditing ? "RECORD NOW" : root.tab === "schedules" ? "SCHEDULES" : "RECORDINGS"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); font.bold: true }
  Text { width: parent.width; visible: !root.available || !!root.snapshot.error; text: !root.radio.ready ? "Recording manager disconnected." : (root.snapshot.error || "Recording manager unavailable."); textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); wrapMode: Text.Wrap }
  Text { width: parent.width; visible: root.localError.length > 0; text: root.localError; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
  Text { width: parent.width; visible: root.pending; text: "Working…"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
  Row { width: parent.width; spacing: Style.space(4); visible: !root.embedded && (root.viewMode === "library" || root.viewMode === "schedules")
    Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Library"; selected: root.tab === "library"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.tab = "library" }
    Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Schedules"; selected: root.tab === "schedules"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.tab = "schedules" }
  }
  Column { width: parent.width; spacing: Style.space(8); visible: root.viewMode === "schedules"
  Text { width: parent.width; text: "Schedules"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); font.bold: true }
  Radio.FocusButton { id: newScheduleButton; width: parent.width; text: "New schedule"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.beginEdit(null) }
  }
  Column {
    width: parent.width; spacing: Style.space(6); visible: root.editing
    Ui.SearchableDropdown { fontFamily: root.uiFontFamily; id: stationPicker; width: parent.width; showLabel: false; placeholderText: "Choose station"; value: root.stationValue; options: root.radio.stationOptions; foreground: root.foreground; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onChanged: value => { root.stationValue = value } }
    Text { width: parent.width; visible: root.editingId.length > 0; text: "Saving uses the station's latest available stream for future recordings."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
    Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: labelField; width: parent.width; placeholderText: "Label (optional)"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 160; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Row { width: parent.width; spacing: Style.space(4)
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Weekly"; selected: root.scheduleKind === "weekly"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.scheduleKind = "weekly" }
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Once"; selected: root.scheduleKind === "once"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.scheduleKind = "once" }
    }
    Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: dateField; width: parent.width; visible: root.scheduleKind === "once"; placeholderText: "Date YYYY-MM-DD"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 10; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Text { width: parent.width; visible: root.scheduleKind === "weekly"; text: "Days"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
    Row { width: parent.width; spacing: Style.space(2); visible: root.scheduleKind === "weekly"
      Repeater { model: ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        Radio.FocusButton { required property int index; required property string modelData; width: (parent.width - parent.spacing * 6) / 7; text: modelData; Accessible.name: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][index]; Accessible.checkable: true; Accessible.checked: selected; selected: root.days.indexOf(index) >= 0; foreground: root.foreground; bordered: true; focusable: true; horizontalPadding: 0; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.toggleDay(index) }
      }
    }
    Text { width: parent.width; text: "Start / end · 24-hour time"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
    Row { width: parent.width; spacing: Style.space(6)
      Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: startField; width: (parent.width-parent.spacing)/2; placeholderText: "Start HH:mm"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 5; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
      Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: endField; width: (parent.width-parent.spacing)/2; placeholderText: "End HH:mm"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 5; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    }
    Text { width: parent.width; text: "An end time before the start ends the next day."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
    Text { width: parent.width; text: "Timezone"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
    Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: zoneField; width: parent.width; placeholderText: "IANA timezone (e.g. America/New_York)"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 128; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Radio.FocusButton { width: parent.width; text: root.scheduleEnabled ? "Enabled" : "Disabled"; selected: root.scheduleEnabled; Accessible.checkable: true; Accessible.checked: selected; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.scheduleEnabled = !root.scheduleEnabled }
    Radio.FocusButton { width: parent.width; text: "Preview next time"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.radio.ready && !root.previewSerial; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.previewNext() }
    Text { width: parent.width; visible: root.previewText.length > 0; text: root.previewText; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
    Radio.FocusButton { width: parent.width; text: root.pending && root.pendingKind === "schedule" ? "Saving…" : "Save schedule"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.save() }
    Radio.FocusButton { id: refreshDraftButton; width: parent.width; visible: root.editRevision !== Number(root.snapshot.revision); text: "Refresh and keep this draft"; foreground: root.foreground; bordered: true; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.refreshDraft() }
    Radio.FocusButton { width: parent.width; text: "Cancel"; foreground: root.foreground; bordered: true; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.goBack() }
  }
  Column { width: parent.width; spacing: Style.space(8); visible: root.viewMode === "schedules"
  Text { width: parent.width; visible: root.available && (root.snapshot.schedules || []).length === 0; text: "No schedules yet."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
  Repeater { model: scheduleRows
    Column { required property var rowData; readonly property var modelData: rowData; readonly property bool playingHere: root.radio.playbackKind === "recording" && root.radio.recordingId === rowData.id && root.radio.wanted; width: root.width; spacing: Style.space(4)
      Ui.PanelSeparator { width: parent.width }
      Text { width: parent.width; text: (parent.modelData.label || parent.modelData.stationName) + (parent.modelData.enabled ? " · Enabled" : " · Disabled"); textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); font.bold: true; wrapMode: Text.Wrap }
      Text { width: parent.width; text: parent.modelData.stationName + " · " + (parent.modelData.kind === "once" ? parent.modelData.date : (parent.modelData.weekdays || []).map(function(d) { return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d] }).join(", ")) + " · " + root.scheduleTimeText(parent.modelData.startTime) + "–" + root.scheduleTimeText(parent.modelData.endTime) + " · " + parent.modelData.timezone + "\n" + (parent.modelData.nextStart ? "Next: " + root.dateText(parent.modelData.nextStart, true) + " – " + root.dateText(parent.modelData.nextEnd, true) : "No upcoming occurrence"); textFormat: Text.PlainText; color: root.foreground; opacity: 0.8; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
      Row { width: parent.width; spacing: Style.space(4)
        Radio.FocusButton { width: (parent.width-parent.spacing*2)/3; text: "Edit"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.beginEdit(parent.parent.modelData) }
        Radio.FocusButton { width: (parent.width-parent.spacing*2)/3; text: parent.parent.modelData.enabled ? "Disable" : "Enable"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: { const s = parent.parent.modelData; root.submit(root.radio.upsertSchedule(root.snapshot.revision, {id:s.id, stationId:s.stationId, label:s.label, kind:s.kind || "weekly", date:s.date || "", weekdays:s.weekdays, startTime:s.startTime, endTime:s.endTime, timezone:s.timezone, enabled:!s.enabled}), "toggle") } }
        Radio.FocusButton { width: (parent.width-parent.spacing*2)/3; text: root.confirmation === "deleteSchedule:" + parent.parent.modelData.id ? "Confirm" : "Delete"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.action("deleteSchedule", parent.parent.modelData.id, root.snapshot.revision) }
      }
    }
  }
  }
  Column { width: parent.width; spacing: Style.space(8); visible: root.viewMode === "library"
    Row { width: parent.width; spacing: Style.space(4)
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Record now"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.available && !root.pending; onClicked: root.beginNow() }
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Storage"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.available && !root.pending; onClicked: root.beginStorage() }
    }
    Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: searchField; width: parent.width; placeholderText: "Search title or station"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 160; onTextChanged: root.searchText = text; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Ui.SearchableDropdown { fontFamily: root.uiFontFamily; id: statusPicker; width: parent.width; showLabel: false; placeholderText: "Status"; value: root.statusFilter; foreground: root.foreground; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); options: [{value:"all", label:"All statuses"}, {value:"recording", label:"Recording"}, {value:"complete", label:"Completed"}, {value:"partial", label:"Partial"}, {value:"error", label:"Failed"}, {value:"missing", label:"Missing"}, {value:"missed", label:"Missed"}]; onChanged: value => { root.statusFilter = value } }
    Text { width: parent.width; visible: root.available && root.filteredRecordings.length === 0; text: (root.snapshot.recordings || []).length ? "No recordings match." : "No recordings yet."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
    Repeater { id: libraryRepeater; model: libraryRows
      Column { id: recordRow; required property var rowData; readonly property bool expanded: !!root.expandedRecordings[rowData.id]; readonly property var modelData: rowData; readonly property bool playingHere: root.radio.playbackKind === "recording" && root.radio.recordingId === rowData.id && root.radio.wanted; width: root.width; spacing: Style.space(4)
        Text { width: parent.width; text: parent.modelData.label || parent.modelData.stationName; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); font.bold: true; wrapMode: Text.Wrap }
        Text { width: parent.width; text: parent.modelData.stationName + " · " + root.dateText(parent.modelData.startedAt || parent.modelData.plannedStart) + (parent.modelData.status === "recording" ? "" : " · " + root.radio.clock(parent.modelData.durationSeconds || 0)) + " · " + root.statusText(parent.modelData.status); textFormat: Text.PlainText; color: root.foreground; opacity: 0.8; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
        Row { width: parent.width; spacing: Style.space(4)
          Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: recordRow.modelData.status === "recording" ? "Stop capture" : recordRow.playingHere ? (root.radio.paused ? "Resume" : "Pause") : Number(recordRow.modelData.resumePosition) > 0 ? "Resume" : "Play"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.radio.ready && !root.pending && (recordRow.modelData.status === "recording" ? root.available : recordRow.modelData.playable === true); onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: { const r = recordRow.modelData; if (r.status === "recording") root.action("stopRecording", r.id, root.snapshot.revision); else if (recordRow.playingHere) root.radio.togglePause(); else root.playItem(r.id) } }
          Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: recordRow.expanded ? "Hide details" : "Details"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.toggleDetails(recordRow.modelData.id) }
        }
        Text { width: parent.width; visible: recordRow.expanded; text: "Planned: " + root.dateText(recordRow.modelData.plannedStart) + " – " + root.dateText(recordRow.modelData.plannedEnd) + (recordRow.modelData.startedAt ? "\nActual: " + root.dateText(recordRow.modelData.startedAt) + (recordRow.modelData.endedAt ? " – " + root.dateText(recordRow.modelData.endedAt) : "") : "") + "\nSize: " + root.sizeText(recordRow.modelData.bytes) + (recordRow.modelData.reason ? "\n" + recordRow.modelData.reason : ""); textFormat: Text.PlainText; color: root.foreground; opacity: 0.8; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
        Row { width: parent.width; spacing: Style.space(4); visible: recordRow.expanded
          Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Restart from beginning"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: recordRow.modelData.playable === true && root.radio.ready && !root.pending; onClicked: root.playItem(recordRow.modelData.id, true) }
          Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: root.confirmation === "deleteRecording:" + recordRow.modelData.id ? "Confirm delete" : "Delete"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.available && !root.pending && recordRow.modelData.status !== "recording"; onClicked: root.action("deleteRecording", recordRow.modelData.id, root.snapshot.revision) }
        }
        Ui.PanelSeparator { width: parent.width }
      }
    }
    Row { width: parent.width; spacing: Style.space(4); visible: root.libraryPages > 1
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "← Previous"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.libraryPage > 0; onClicked: root.libraryPage-- }
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Next →"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.libraryPage + 1 < root.libraryPages; onClicked: root.libraryPage++ }
    }
    Text { width: parent.width; visible: root.libraryPages > 1; text: "Page " + (root.libraryPage + 1) + " of " + root.libraryPages; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
  }
  Column { width: parent.width; spacing: Style.space(6); visible: root.nowEditing
    Text { width: parent.width; text: "Record now"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); font.bold: true }
    Ui.SearchableDropdown { fontFamily: root.uiFontFamily; width: parent.width; showLabel: false; placeholderText: "Choose station"; value: root.nowStation; options: root.radio.stationOptions; foreground: root.foreground; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onChanged: value => { root.nowStation = value } }
    Text { width: parent.width; text: "Duration in minutes (1–720)"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
    Row { width: parent.width; spacing: Style.space(4)
      Repeater { model: [15, 30, 60]; Radio.FocusButton { required property int modelData; width: (parent.width-parent.spacing*2)/3; text: modelData + " min"; selected: Number(durationField.text) === modelData; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: durationField.text = String(modelData) } }
    }
    Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: durationField; width: parent.width; placeholderText: "Duration in minutes"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 3; inputMethodHints: Qt.ImhDigitsOnly; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Radio.FocusButton { width: parent.width; text: root.pending && root.pendingKind === "now" ? "Starting…" : "Start recording"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.available && !root.pending; onClicked: root.startNow() }
    Radio.FocusButton { width: parent.width; visible: root.nowRevision !== Number(root.snapshot.revision); text: "Refresh and keep this draft"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: !root.pending; onClicked: { root.nowRevision = Number(root.snapshot.revision) || 0; root.localError = "" } }
  }
  FolderDialog { id: folderDialog; title: "Choose recording folder"; onAccepted: { const path = root.pathFromFolderUrl(selectedFolder); if (path) { folderField.text = path; root.localError = "" } else root.localError = "Choose a local folder." } }
  Column { width: parent.width; spacing: Style.space(6); visible: root.storageEditing
    Text { width: parent.width; text: "Storage · " + root.sizeText(root.snapshot.usedBytes) + " of " + root.sizeText((root.snapshot.settings || {}).storageCapBytes) + " used"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); font.bold: true }
    Radio.FocusButton { width: parent.width; text: root.radio.recordingNotifications ? "Recording notifications: On" : "Recording notifications: Off"; selected: root.radio.recordingNotifications; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.radio.setRecordingNotifications(!root.radio.recordingNotifications) }
    Radio.FocusButton { width: parent.width; text: root.radio.recordingStartNotifications ? "Start notifications: On" : "Start notifications: Off"; selected: root.radio.recordingStartNotifications; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); enabled: root.radio.recordingNotifications; onClicked: root.radio.setRecordingStartNotifications(!root.radio.recordingStartNotifications) }
    Text { width: parent.width; text: "Recording folder (absolute path)"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
    Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: folderField; width: parent.width; placeholderText: "Absolute folder path"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 4096; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Row { width: parent.width; spacing: Style.space(4)
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Choose folder"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: { const url = root.folderUrl(folderField.text); if (url) folderDialog.currentFolder = url; folderDialog.open() } }
      Radio.FocusButton { width: (parent.width-parent.spacing)/2; text: "Open folder"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: { const url = root.folderUrl(folderField.text); if (!url || !Qt.openUrlExternally(url)) root.localError = "Enter a local absolute folder path to open." } }
    }
    Text { width: parent.width; text: "Library cap (GiB)"; textFormat: Text.PlainText; color: root.foreground; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1) }
    Ui.TextField { font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1.167); id: capField; width: parent.width; placeholderText: "Library cap (GiB)"; Accessible.name: placeholderText; foreground: root.foreground; inputMethodHints: Qt.ImhFormattedNumbersOnly; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Text { width: parent.width; text: "Keeps " + root.sizeText((root.snapshot.settings || {}).freeSpaceReserveBytes) + " free on disk · up to " + ((root.snapshot.settings || {}).concurrency || 3) + " simultaneous recordings"; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
    Text { width: parent.width; text: "Folder changes apply to future recordings. Existing files remain in place."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: root.uiFontFamily; font.pixelSize: Style.fontPx(1); wrapMode: Text.Wrap }
    Radio.FocusButton { width: parent.width; text: root.pending && root.pendingKind === "settings" ? "Saving…" : "Save storage settings"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.saveStorage() }
    Radio.FocusButton { width: parent.width; visible: root.storageRevision !== Number(root.snapshot.revision); text: "Refresh and keep these settings"; foreground: root.foreground; bordered: true; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: { root.storageRevision = Number(root.snapshot.revision) || 0; root.localError = "" } }
    Radio.FocusButton { width: parent.width; text: "Cancel"; foreground: root.foreground; bordered: true; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.goBack() }
  }
}
