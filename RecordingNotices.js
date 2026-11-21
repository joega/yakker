.pragma library

// Pure transition detection. The singleton owns one tracker for all monitors.
// Baseline historic rows without announcing them when the helper first connects.
function update(previous, snapshot, enabled, includeStarts) {
  const old = previous || {initialized: false, rows: {}, error: ""}
  const rows = Object.create(null), notices = []
  const items = Array.isArray(snapshot.recordings) ? snapshot.recordings.slice(0, 4096) : []
  for (const item of items) {
    const id = String(item.id || "")
    if (!id) continue
    const status = String(item.status || "")
    rows[id] = status
    if (!enabled || !old.initialized || old.rows[id] === status) continue
    const label = String(item.label || item.stationName || "Recording").slice(0, 200)
    const reason = item.reason ? "\n" + String(item.reason).slice(0, 240) : ""
    if (status === "recording" && includeStarts)
      notices.push({kind: "start", title: "Recording started", body: label})
    else if (status === "complete")
      notices.push({title: "Recording finished", body: label})
    else if (status === "partial" && old.rows[id] !== "missing")
      notices.push({title: "Partial recording saved", body: label + reason})
    else if (status === "error" || status === "missed")
      notices.push({title: status === "missed" ? "Recording missed" : "Recording failed", body: label + reason})
  }
  const error = String(snapshot.error || "").slice(0, 240)
  if (enabled && error && error !== old.error)
    notices.push({title: "Recordings need attention", body: error})
  // A resume can add many missed rows at once. Summarize instead of flooding
  // the notification daemon, while retaining the detailed history in Library.
  const bounded = notices.length > 5 ? notices.slice(0, 4).concat([
    {title: "More recording updates", body: String(notices.length - 4) + " additional updates. Open Recordings for details."}
  ]) : notices
  return {state: {initialized: true, rows: rows, error: error}, notices: bounded}
}

function escapeMarkup(value) {
  return String(value).slice(0, 600).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;")
}
