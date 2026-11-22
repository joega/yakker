package recording

import (
	"crypto/sha256"
	"fmt"
)

// Show identity belongs to a frozen occurrence, never to a label or station
// alone. Parent links cover indexes written before occurrence keys were saved.
// Virtual parent nodes keep siblings together when their original file is gone.
func recordingShowIDs(records []entry) map[string]string {
	parents := map[string]string{}
	var find func(string) string
	find = func(key string) string {
		parent, ok := parents[key]
		if !ok {
			parents[key] = key
			return key
		}
		if parent != key {
			parents[key] = find(parent)
		}
		return parents[key]
	}
	join := func(a, b string) {
		a, b = find(a), find(b)
		// Occurrence keys sort before IDs, so identity survives part deletion.
		if a > b {
			a, b = b, a
		}
		parents[b] = a
	}
	scope := func(r entry) string {
		return r.ScheduleID + "\x00" + r.StationID + "\x00" + r.PlannedStart + "\x00" + r.PlannedEnd + "\x00"
	}
	for _, r := range records {
		base := scope(r)
		key := base + "id:" + r.ID
		find(key)
		if r.Occurrence != "" {
			join(key, base+"0occurrence:"+r.Occurrence)
		}
		if r.ParentID != "" {
			join(key, base+"id:"+r.ParentID)
		}
	}
	ids := make(map[string]string, len(records))
	for _, r := range records {
		key := find(scope(r) + "id:" + r.ID)
		ids[r.ID] = fmt.Sprintf("show-%x", sha256.Sum256([]byte(key)))
	}
	return ids
}
