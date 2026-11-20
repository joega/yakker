package recording

import "time"

type Settings struct {
	Folder                string `json:"folder"`
	StorageCapBytes       int64  `json:"storageCapBytes"`
	FreeSpaceReserveBytes int64  `json:"freeSpaceReserveBytes"`
	Concurrency           int    `json:"concurrency"`
}

type Schedule struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	StationID   string `json:"stationId"`
	StationName string `json:"stationName"`
	StreamURL   string `json:"streamUrl"`
	Weekdays    []int  `json:"weekdays"`
	StartTime   string `json:"startTime"`
	EndTime     string `json:"endTime"`
	Timezone    string `json:"timezone"`
	Enabled     bool   `json:"enabled"`
	NextStart   string `json:"nextStart"`
	NextEnd     string `json:"nextEnd"`
}

type Recording struct {
	ID              string  `json:"id"`
	ScheduleID      string  `json:"scheduleId"`
	Label           string  `json:"label"`
	StationID       string  `json:"stationId"`
	StationName     string  `json:"stationName"`
	PlannedStart    string  `json:"plannedStart"`
	PlannedEnd      string  `json:"plannedEnd"`
	StartedAt       string  `json:"startedAt"`
	EndedAt         string  `json:"endedAt"`
	Status          string  `json:"status"`
	Reason          string  `json:"reason"`
	Bytes           int64   `json:"bytes"`
	DurationSeconds float64 `json:"durationSeconds"`
	Folder          string  `json:"folder"`
	Filename        string  `json:"filename"`
	ParentID        string  `json:"parentId,omitempty"`
	Playable        bool    `json:"playable"`
}

type Snapshot struct {
	LocalTimezone string      `json:"localTimezone"`
	Revision      int64       `json:"revision"`
	Settings      Settings    `json:"settings"`
	Schedules     []Schedule  `json:"schedules"`
	Recordings    []Recording `json:"recordings"`
	Available     bool        `json:"available"`
	Error         string      `json:"error"`
	UsedBytes     int64       `json:"usedBytes"`
	ActiveCount   int         `json:"activeCount"`
}

type Config struct {
	DataDir, DefaultFolder, FFmpeg, FFprobe string
	PollInterval, StopGrace                 time.Duration
	Now                                     func() time.Time
}
