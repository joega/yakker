import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Column {
  id: root
  required property var radio
  property color foreground: Commons.Color.foreground
  property var bar
  property var ensureVisible: function(item) {}
  signal back()
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
  property bool storageEditing: false
  property int storageRevision: 0
  property string stationValue: ""
  property int previewSerial: 0
  property string previewKey: ""
  property string previewText: ""
  property int libraryPage: 0
  readonly property int pageSize: 20
  readonly property int libraryPages: Math.max(1, Math.ceil((snapshot.recordings || []).length / pageSize))
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
    syncRows(libraryRows, (snapshot.recordings || []).slice(libraryPage * pageSize, (libraryPage + 1) * pageSize))
  }
  onSnapshotChanged: { if (libraryPage >= libraryPages) libraryPage = libraryPages - 1; refreshRows() }
  onLibraryPageChanged: refreshRows()
  Component.onCompleted: refreshRows()
  onFormKeyChanged: { previewSerial = 0; previewText = "" }

  function activate() { focusItem(backButton) }
  Keys.onEscapePressed: event => { event.accepted = true; root.back() }
  function focusItem(item) { Qt.callLater(function() { item.forceActiveFocus(); root.ensureVisible(item) }) }
  function beginEdit(s) {
    if (pending) return
    storageEditing = false
    s = s || {}
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
    return {id: editingId, stationId: stationValue, label: labelField.text.trim(), weekdays: days, startTime: startField.text.trim(), endTime: endField.text.trim(), timezone: zoneField.text.trim(), enabled: scheduleEnabled}
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
  function playItem(id) {
    localError = ""
    playbackId = id
    playbackSerial = radio.playRecording(id)
    if (!playbackSerial) localError = "Recording manager is disconnected."
  }
  function beginStorage() {
    if (pending) return
    editing = false
    if (!available) { localError = "Recording manager is unavailable."; activate(); return }
    storageRevision = Number(snapshot.revision) || 0
    folderField.text = snapshot.settings.folder || ""
    capField.text = String((Number(snapshot.settings.storageCapBytes) || 0) / 1073741824)
    storageEditing = true; localError = ""; focusItem(folderField)
  }
  function saveStorage() {
    const old = snapshot.settings || {}
    submit(radio.recordingSettings(storageRevision, {folder: folderField.text.trim(), storageCapBytes: Math.round(Number(capField.text) * 1073741824), freeSpaceReserveBytes: old.freeSpaceReserveBytes, concurrency: old.concurrency}), "settings")
  }
  function dateText(value) {
    if (!value) return ""
    const d = new Date(value)
    return isNaN(d.getTime()) ? String(value) : d.toLocaleString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }
  function sizeText(n) {
    const bytes = Math.max(0, Number(n) || 0)
    if (bytes < 1024) return Math.round(bytes) + " B"
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KiB"
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + " MiB"
    return (bytes / 1073741824).toFixed(2) + " GiB"
  }
  Connections {
    target: root.radio
    function onSchedulePreviewSerialChanged() {
      if (!root.previewSerial || root.radio.schedulePreviewSerial !== root.previewSerial || root.previewKey !== root.formKey) return
      root.previewSerial = 0
      const p = root.radio.schedulePreview || {}
      root.previewText = root.radio.schedulePreviewError || (p.nextStart ? "Next: " + p.nextStart.replace("T", " ") + " – " + p.nextEnd.replace("T", " ") + " · " + p.timezone : "This schedule is disabled.")
    }
    function onRecordingMutationSerialChanged() {
      if (!root.pendingSerial || root.radio.recordingMutationSerial !== root.pendingSerial) return
      const kind = root.pendingKind
      root.pendingSerial = 0; root.pendingKind = ""
      root.localError = root.radio.recordingError || ""
      if (root.radio.recordingMutationOK) {
        if (kind === "schedule") root.editing = false
        if (kind === "settings") root.storageEditing = false
      }
    }
    function onStatusReceived(serial) {
      if (!root.playbackSerial || serial < root.playbackSerial) return
      if (root.radio.error) {
        root.playbackSerial = 0; root.localError = root.radio.error
      } else if (root.radio.playbackKind === "recording" && root.radio.recordingId === root.playbackId && root.radio.wanted) {
        root.playbackSerial = 0; root.back()
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
  Ui.Button { id: backButton; width: parent.width; text: "← Back to player"; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.back() }
  Text { width: parent.width; text: "RECORDINGS"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
  Text { width: parent.width; visible: !root.available || !!root.snapshot.error; text: !root.radio.ready ? "Recording manager disconnected." : (root.snapshot.error || "Recording manager unavailable."); textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.body; wrapMode: Text.Wrap }
  Text { width: parent.width; visible: root.localError.length > 0; text: root.localError; textFormat: Text.PlainText; color: Commons.Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
  Text { width: parent.width; visible: root.pending; text: "Working…"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
  Text { width: parent.width; text: "Schedules"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
  Ui.Button { width: parent.width; text: "New schedule"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.beginEdit(null) }
  Column {
    width: parent.width; spacing: Style.space(6); visible: root.editing
    Ui.SearchableDropdown { id: stationPicker; width: parent.width; showLabel: false; placeholderText: "Choose station"; value: root.stationValue; options: root.radio.stationOptions; foreground: root.foreground; onChanged: value => { root.stationValue = value } }
    Text { width: parent.width; visible: root.editingId.length > 0; text: "Saving uses the station's latest available stream for future recordings."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
    Ui.TextField { id: labelField; width: parent.width; placeholderText: "Label (optional)"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 160; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Text { width: parent.width; text: "Days"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Row { width: parent.width; spacing: Style.space(2)
      Repeater { model: ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        Ui.Button { required property int index; required property string modelData; width: (parent.width - parent.spacing * 6) / 7; text: modelData; Accessible.name: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][index]; Accessible.checkable: true; Accessible.checked: selected; selected: root.days.indexOf(index) >= 0; foreground: root.foreground; bordered: true; focusable: true; horizontalPadding: 0; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.toggleDay(index) }
      }
    }
    Text { width: parent.width; text: "Start / end · 24-hour time"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Row { width: parent.width; spacing: Style.space(6)
      Ui.TextField { id: startField; width: (parent.width-parent.spacing)/2; placeholderText: "Start HH:mm"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 5; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
      Ui.TextField { id: endField; width: (parent.width-parent.spacing)/2; placeholderText: "End HH:mm"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 5; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    }
    Text { width: parent.width; text: "An end time before the start ends the next day."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
    Text { width: parent.width; text: "Timezone"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Ui.TextField { id: zoneField; width: parent.width; placeholderText: "IANA timezone (e.g. America/New_York)"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 128; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Ui.Button { width: parent.width; text: root.scheduleEnabled ? "Enabled" : "Disabled"; selected: root.scheduleEnabled; Accessible.checkable: true; Accessible.checked: selected; foreground: root.foreground; bordered: true; focusable: true; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.scheduleEnabled = !root.scheduleEnabled }
    Ui.Button { width: parent.width; text: "Preview next time"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.radio.ready && !root.previewSerial; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.previewNext() }
    Text { width: parent.width; visible: root.previewText.length > 0; text: root.previewText; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
    Ui.Button { width: parent.width; text: root.pending && root.pendingKind === "schedule" ? "Saving…" : "Save schedule"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.save() }
    Ui.Button { id: refreshDraftButton; width: parent.width; visible: root.editRevision !== Number(root.snapshot.revision); text: "Refresh and keep this draft"; foreground: root.foreground; bordered: true; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.refreshDraft() }
    Ui.Button { width: parent.width; text: "Cancel"; foreground: root.foreground; bordered: true; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.editing = false }
  }
  Text { width: parent.width; visible: root.available && (root.snapshot.schedules || []).length === 0; text: "No schedules yet."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: Style.font.family; font.pixelSize: Style.font.caption }
  Repeater { model: scheduleRows
    Column { required property var rowData; readonly property var modelData: rowData; width: root.width; spacing: Style.space(4)
      Ui.PanelSeparator { width: parent.width }
      Text { width: parent.width; text: (parent.modelData.label || parent.modelData.stationName) + (parent.modelData.enabled ? " · Enabled" : " · Disabled"); textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true; wrapMode: Text.Wrap }
      Text { width: parent.width; text: parent.modelData.stationName + " · " + (parent.modelData.weekdays || []).map(function(d) { return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d] }).join(", ") + " · " + parent.modelData.startTime + "–" + parent.modelData.endTime + " · " + parent.modelData.timezone + "\n" + (parent.modelData.nextStart ? "Next: " + parent.modelData.nextStart.replace("T", " ") + " – " + (parent.modelData.nextEnd || "").replace("T", " ") : "No upcoming occurrence"); textFormat: Text.PlainText; color: root.foreground; opacity: 0.8; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
      Row { width: parent.width; spacing: Style.space(4)
        Ui.Button { width: (parent.width-parent.spacing*2)/3; text: "Edit"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.beginEdit(parent.parent.modelData) }
        Ui.Button { width: (parent.width-parent.spacing*2)/3; text: parent.parent.modelData.enabled ? "Disable" : "Enable"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: { const s = parent.parent.modelData; root.submit(root.radio.upsertSchedule(root.snapshot.revision, {id:s.id, stationId:s.stationId, label:s.label, weekdays:s.weekdays, startTime:s.startTime, endTime:s.endTime, timezone:s.timezone, enabled:!s.enabled}), "toggle") } }
        Ui.Button { width: (parent.width-parent.spacing*2)/3; text: root.confirmation === "deleteSchedule:" + parent.parent.modelData.id ? "Confirm" : "Delete"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.action("deleteSchedule", parent.parent.modelData.id, root.snapshot.revision) }
      }
    }
  }
  Ui.PanelSeparator { width: parent.width }
  Text { width: parent.width; text: "Library"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
  Text { width: parent.width; visible: root.available && (root.snapshot.recordings || []).length === 0; text: "No recordings yet."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: Style.font.family; font.pixelSize: Style.font.caption }
  Repeater { model: libraryRows
    Column { required property var rowData; readonly property var modelData: rowData; width: root.width; spacing: Style.space(4)
      Text { width: parent.width; text: parent.modelData.label || parent.modelData.stationName; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true; wrapMode: Text.Wrap }
      Text { width: parent.width; text: parent.modelData.stationName + " · " + parent.modelData.status + " · " + root.sizeText(parent.modelData.bytes) + "\n" + "Planned: " + root.dateText(parent.modelData.plannedStart) + " – " + root.dateText(parent.modelData.plannedEnd) + (parent.modelData.startedAt ? "\nActual: " + root.dateText(parent.modelData.startedAt) + (parent.modelData.endedAt ? " – " + root.dateText(parent.modelData.endedAt) : "") : "") + (parent.modelData.durationSeconds ? " · " + root.radio.clock(parent.modelData.durationSeconds) : "") + (parent.modelData.reason ? "\n" + parent.modelData.reason : ""); textFormat: Text.PlainText; color: root.foreground; opacity: 0.8; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
      Row { width: parent.width; spacing: Style.space(4)
        Ui.Button { width: (parent.width-parent.spacing)/2; text: parent.parent.modelData.status === "recording" ? "Stop capture" : "Play"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.radio.ready && !root.pending && (parent.parent.modelData.status === "recording" ? root.available : parent.parent.modelData.playable === true); onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: { const r = parent.parent.modelData; if (r.status === "recording") root.action("stopRecording", r.id, root.snapshot.revision); else root.playItem(r.id) } }
        Ui.Button { width: (parent.width-parent.spacing)/2; text: root.confirmation === "deleteRecording:" + parent.parent.modelData.id ? "Confirm delete" : "Delete"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending && parent.parent.modelData.status !== "recording"; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.action("deleteRecording", parent.parent.modelData.id, root.snapshot.revision) }
      }
      Ui.PanelSeparator { width: parent.width }
    }
  }
  Row {
    width: parent.width; spacing: Style.space(4); visible: root.libraryPages > 1
    Ui.Button { width: (parent.width-parent.spacing)/2; text: "← Previous"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.libraryPage > 0; onClicked: root.libraryPage-- }
    Ui.Button { width: (parent.width-parent.spacing)/2; text: "Next →"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.libraryPage + 1 < root.libraryPages; onClicked: root.libraryPage++ }
  }
  Text { width: parent.width; visible: root.libraryPages > 1; text: "Page " + (root.libraryPage + 1) + " of " + root.libraryPages; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
  Text { width: parent.width; text: "Storage · " + root.sizeText(root.snapshot.usedBytes) + " of " + root.sizeText((root.snapshot.settings || {}).storageCapBytes) + " used"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
  Ui.Button { width: parent.width; text: "Recording storage settings"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.beginStorage() }
  Column { width: parent.width; spacing: Style.space(6); visible: root.storageEditing
    Text { width: parent.width; text: "Recording folder (absolute path)"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Ui.TextField { id: folderField; width: parent.width; placeholderText: "Absolute folder path"; Accessible.name: placeholderText; foreground: root.foreground; maximumLength: 4096; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Text { width: parent.width; text: "Library cap (GiB)"; textFormat: Text.PlainText; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Ui.TextField { id: capField; width: parent.width; placeholderText: "Library cap (GiB)"; Accessible.name: placeholderText; foreground: root.foreground; inputMethodHints: Qt.ImhFormattedNumbersOnly; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this) }
    Text { width: parent.width; text: "Keeps " + root.sizeText((root.snapshot.settings || {}).freeSpaceReserveBytes) + " free on disk · up to " + ((root.snapshot.settings || {}).concurrency || 3) + " simultaneous recordings"; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
    Text { width: parent.width; text: "Folder changes apply to future recordings. Existing files remain in place."; textFormat: Text.PlainText; color: root.foreground; opacity: 0.7; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.Wrap }
    Ui.Button { width: parent.width; text: root.pending && root.pendingKind === "settings" ? "Saving…" : "Save storage settings"; foreground: root.foreground; bordered: true; focusable: true; enabled: root.available && !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.saveStorage() }
    Ui.Button { width: parent.width; visible: root.storageRevision !== Number(root.snapshot.revision); text: "Refresh and keep these settings"; foreground: root.foreground; bordered: true; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: { root.storageRevision = Number(root.snapshot.revision) || 0; root.localError = "" } }
    Ui.Button { width: parent.width; text: "Cancel"; foreground: root.foreground; bordered: true; focusable: true; enabled: !root.pending; onActiveFocusChanged: if (activeFocus) root.ensureVisible(this); onClicked: root.storageEditing = false }
  }
}
