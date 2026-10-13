package app

import (
	"encoding/json"
	"os"

	"github.com/f-bahesna/medic/internal/items"
	"github.com/f-bahesna/medic/internal/scan"
)

// The JSON output. Sizes are in bytes. The shape is the same on macOS and
// Windows, and stays compatible: fields are only ever added.

type jsonDisk struct {
	Name        string `json:"name"`
	System      bool   `json:"system"`
	TotalBytes  int64  `json:"total_bytes"`
	UsedBytes   int64  `json:"used_bytes"`
	FreeBytes   int64  `json:"free_bytes"`
	UsedPercent int    `json:"used_percent"`
}

type jsonApp struct {
	Name      string `json:"name"`
	Bytes     int64  `json:"bytes"`
	Processes int    `json:"processes"`
}

type jsonMemory struct {
	TotalBytes     int64     `json:"total_bytes"`
	UsedBytes      int64     `json:"used_bytes"`
	CachedBytes    int64     `json:"cached_bytes"`
	SwapUsedBytes  int64     `json:"swap_used_bytes"`
	SwapTotalBytes int64     `json:"swap_total_bytes"`
	Pressure       string    `json:"pressure"`
	TopApps        []jsonApp `json:"top_apps"`
}

type jsonItem struct {
	ID        string   `json:"id"`
	Label     string   `json:"label"`
	Safety    string   `json:"safety"`
	Bytes     int64    `json:"bytes"`
	Cleanable bool     `json:"cleanable"`
	Admin     bool     `json:"admin"`
	Note      string   `json:"note"`
	Paths     []string `json:"paths"`
}

type jsonSummary struct {
	SafeBytes    int64 `json:"safe_bytes"`
	CautionBytes int64 `json:"caution_bytes"`
	ReviewBytes  int64 `json:"review_bytes"`
}

type jsonFolder struct {
	Path     string `json:"path"`
	Kind     string `json:"kind,omitempty"`
	Bytes    int64  `json:"bytes"`
	Modified string `json:"modified,omitempty"`
}

type jsonPurge struct {
	OlderThanDays int          `json:"older_than_days"`
	Roots         []string     `json:"roots"`
	Folders       []jsonFolder `json:"folders"`
}

type jsonReport struct {
	Version    string        `json:"version"`
	OS         string        `json:"os"`
	Command    string        `json:"command"`
	Disks      *[]jsonDisk   `json:"disks,omitempty"`
	Memory     *jsonMemory   `json:"memory,omitempty"`
	Items      *[]jsonItem   `json:"items,omitempty"`
	Summary    *jsonSummary  `json:"summary,omitempty"`
	DevFolders *[]jsonFolder `json:"dev_folders,omitempty"`
	LargeFiles *[]jsonFolder `json:"large_files,omitempty"`
	Purge      *jsonPurge    `json:"purge,omitempty"`
}

type jsonCheckItem struct {
	Name         string `json:"name"`
	OK           bool   `json:"ok"`
	FreeBytes    *int64 `json:"free_bytes,omitempty"`
	MinFreeBytes *int64 `json:"min_free_bytes,omitempty"`
	Pressure     string `json:"pressure,omitempty"`
}

type jsonCheck struct {
	Version string          `json:"version"`
	OS      string          `json:"os"`
	OK      bool            `json:"ok"`
	Checks  []jsonCheckItem `json:"checks"`
}

func (c *cmd) writeJSON(v any) error {
	enc := json.NewEncoder(c.stdout)
	enc.SetEscapeHTML(false)
	return enc.Encode(v)
}

func jsonFromReport(r *Report, withDisks, withItems bool) jsonReport {
	out := jsonReport{Version: r.Version, OS: r.OS, Command: r.Command}
	if withDisks {
		disks := []jsonDisk{}
		for _, d := range r.Disks {
			disks = append(disks, jsonDisk{d.Name, d.System, d.Total, d.Used, d.Free, d.UsedPct()})
		}
		out.Disks = &disks
	}
	if m := r.Memory; m != nil {
		apps := []jsonApp{}
		for _, a := range m.TopApps {
			apps = append(apps, jsonApp{a.Name, a.Bytes, a.Processes})
		}
		out.Memory = &jsonMemory{m.Total, m.Used, m.Cached, m.SwapUsed, m.SwapTotal, m.Pressure, apps}
	}
	if withItems {
		list := []jsonItem{}
		for _, it := range items.Visible(r.Items) {
			paths := []string{}
			for _, p := range append(append([]string{}, it.Paths...), it.Files...) {
				if _, err := os.Lstat(p); err == nil {
					paths = append(paths, p)
				}
			}
			list = append(list, jsonItem{it.ID, it.Label, it.Safety, it.Bytes, it.CanClean(), it.Admin, it.Note, paths})
		}
		out.Items = &list
		t := items.Totals(r.Items)
		out.Summary = &jsonSummary{t[items.Safe], t[items.Caution], t[items.Review]}
	}
	if r.Scanned {
		dev, large := folders(r.DevFolders, false), folders(r.LargeFiles, true)
		out.DevFolders, out.LargeFiles = &dev, &large
	}
	return out
}

func folders(list []scan.Entry, modified bool) []jsonFolder {
	out := []jsonFolder{}
	for _, e := range list {
		f := jsonFolder{Path: e.Path, Kind: e.Kind, Bytes: e.Bytes}
		if modified {
			f.Modified = e.Modified.Format("2006-01-02")
		}
		out = append(out, f)
	}
	return out
}

func jsonFromPurge(r *Report, roots []string, rows []scan.Entry) jsonReport {
	if roots == nil {
		roots = []string{}
	}
	return jsonReport{Version: r.Version, OS: r.OS, Command: r.Command,
		Purge: &jsonPurge{OlderThanDays: r.OlderThan, Roots: roots, Folders: folders(rows, false)}}
}
