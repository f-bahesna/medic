// Package app runs medic's commands.
package app

import (
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"

	"github.com/f-bahesna/medic/internal/items"
	"github.com/f-bahesna/medic/internal/scan"
	"github.com/f-bahesna/medic/internal/sysinfo"
	"github.com/f-bahesna/medic/internal/ui"
)

// Exit codes.
const (
	exitOK    = 0
	exitFail  = 1
	exitUsage = 2
)

// errFailed means a command ran but did not succeed, like a failed check.
var errFailed = errors.New("failed")

// osName is medic's name for the system it runs on, in JSON and for the
// differences in wording.
func osName() string {
	if runtime.GOOS == "windows" {
		return "windows"
	}
	return "macos"
}

// Run runs medic with args and returns the exit code.
func Run(version string, args []string, stdout, stderr *os.File) int {
	o, err := Parse(args)
	if err != nil {
		fmt.Fprintf(stderr, "medic: %v\nRun \"medic --help\" for usage.\n", err)
		return exitUsage
	}
	if o.Help {
		fmt.Fprintf(stdout, usage, version)
		return exitOK
	}
	if o.Version {
		fmt.Fprintf(stdout, "medic %s\n", version)
		return exitOK
	}
	if err := preflight(); err != nil {
		fmt.Fprintf(stderr, "medic: %v\n", err)
		return exitFail
	}

	color := !o.NoColor && !o.JSON && os.Getenv("NO_COLOR") == "" && enableColor(stdout)
	p := ui.NewPrinter(stdout, color)
	c := &cmd{o: o, version: version, p: p, progress: newProgress(stderr), stdout: stdout}
	switch err := c.run(); {
	case err == nil:
		return exitOK
	case errors.As(err, new(UsageError)):
		fmt.Fprintf(stderr, "medic: %v\nRun \"medic --help\" for usage.\n", err)
		return exitUsage
	case errors.Is(err, errFailed):
		return exitFail
	default:
		fmt.Fprintf(stderr, "medic: %v\n", err)
		return exitFail
	}
}

type cmd struct {
	o        Options
	version  string
	p        *ui.Printer
	progress *progress
	stdout   io.Writer
	home     string
	report   *Report
}

func (c *cmd) run() error {
	home, err := os.UserHomeDir()
	if err != nil || home == "" || home == "/" {
		return fmt.Errorf("HOME is not set to a valid folder")
	}
	c.home = home
	c.report = &Report{OS: osName(), Version: c.version, Command: c.o.Command, Home: home,
		LargeMB: c.o.LargeMB, OlderThan: c.o.OlderThan, Admin: sysinfo.IsAdmin()}
	if c.o.Command != "check" && !c.o.JSON {
		c.report.Host = sysinfo.ReadHost()
		c.report.NoDiskAccess = noDiskAccess(home)
		RenderHeader(c.p, c.report, c.o.DryRun)
	}
	switch c.o.Command {
	case "report", "disk":
		return c.storageReport(c.o.Command == "report")
	case "memory":
		m := sysinfo.ReadMemory()
		c.report.Memory = &m
		if c.o.JSON {
			return c.writeJSON(jsonFromReport(c.report, false, false))
		}
		RenderMemory(c.p, c.report)
		return nil
	case "clean":
		return c.clean()
	case "purge":
		return c.purge()
	case "check":
		return c.check()
	case "apps":
		return c.listApps()
	case "uninstall":
		return c.uninstall()
	}
	return nil
}

func (c *cmd) collectItems() {
	c.progress.Show("installers in Downloads and Desktop")
	c.report.Items = items.Collect(c.home)
	items.Measure(c.report.Items, c.progress.Show)
	items.Describe(c.report.Items, c.home)
	c.progress.Done()
}

func (c *cmd) storageReport(withMemory bool) error {
	r := c.report
	r.Disks = sysinfo.ReadDisks()
	if withMemory {
		m := sysinfo.ReadMemory()
		r.Memory = &m
	}
	c.collectItems()
	if !c.o.Quick {
		r.Scanned = true
		for _, dir := range scan.BreakdownDirs(c.home) {
			c.progress.Show(r.tilde(dir))
			if entries := scan.Breakdown(dir, 8); len(entries) > 0 {
				r.Breakdowns = append(r.Breakdowns, Breakdown{Dir: dir, Entries: entries})
			}
		}
		c.progress.Show("node_modules and Python virtualenvs")
		r.DevFolders = scan.DevFolders(scan.DevRoots(c.home, c.o.DevDirs))
		c.progress.Show(fmt.Sprintf("files larger than %d MB in your home folder", c.o.LargeMB))
		r.LargeFiles = scan.LargeFiles(c.home, int64(c.o.LargeMB)<<20)
		c.progress.Done()
	}
	r.Snapshots = sysinfo.TimeMachineSnapshots()
	r.SystemFiles = sysinfo.SystemFiles()
	if c.o.JSON {
		return c.writeJSON(jsonFromReport(r, true, true))
	}
	RenderReport(c.p, r)
	return nil
}

// noDiskAccess reports whether macOS hides other apps' data from this
// terminal: ~/Library/Safari exists but cannot be read.
func noDiskAccess(home string) bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	safari := home + "/Library/Safari"
	if _, err := os.Stat(safari); err != nil {
		return false
	}
	_, err := os.ReadDir(safari)
	return err != nil
}

// interactive opens the terminal for questions, or explains why it cannot.
func (c *cmd) asker(what string) (*ui.Asker, error) {
	in, ok := openTTY()
	if !ok {
		c.p.Warn("%s needs a terminal to ask first. Pass --yes to go ahead without asking.", what)
		return nil, errFailed
	}
	return ui.NewAsker(c.p, in), nil
}

func (c *cmd) reportFreed(before int64) {
	if c.o.DryRun {
		return
	}
	units := c.report.units()
	where := ""
	if c.report.OS == "windows" {
		where = " on " + sysinfo.SystemDrive()
	}
	c.p.Printf("\n  Free space%s went from %s to %s.\n", where, ui.Size(before, units), c.p.B(ui.Size(sysinfo.FreeBytes(), units)))
	if c.report.mac() {
		c.p.Note("APFS can take a minute to report freed space. Time Machine snapshots may hold it until they expire.")
	}
}

// ---------------------------------------------------------------------------
// medic clean
// ---------------------------------------------------------------------------

// onlyMatches reports whether an item passes --only (default: everything, or
// SAFE with --yes).
func (c *cmd) onlyMatches(it *items.Item) bool {
	only := c.o.Only
	if len(only) == 0 && c.o.Yes {
		only = []string{"safe"}
	}
	if len(only) == 0 {
		return true
	}
	for _, t := range only {
		if strings.EqualFold(t, it.Safety) || t == it.ID {
			return true
		}
	}
	return false
}

func (c *cmd) checkOnly(list []*items.Item) error {
	for _, t := range c.o.Only {
		if t == "safe" || t == "caution" {
			continue
		}
		known := false
		for _, it := range list {
			known = known || (it.ID == t && it.CanClean())
		}
		if !known {
			return usagef("--only: '%s' is not a level (safe, caution) or a cleanable item id. 'medic report --json' lists the ids.", t)
		}
	}
	return nil
}

func (c *cmd) clean() error {
	r, p := c.report, c.p
	c.progress.Show("installers in Downloads and Desktop")
	r.Items = items.Collect(c.home)
	if err := c.checkOnly(r.Items); err != nil {
		c.progress.Done()
		return err
	}
	items.Measure(r.Items, c.progress.Show)
	c.progress.Done()

	var rows []*items.Item
	var levels []string
	for _, it := range items.Visible(r.Items) {
		if it.CanClean() && c.onlyMatches(it) {
			rows = append(rows, it)
			levels = append(levels, it.Safety)
		}
	}
	p.Section("Clean up")
	if len(rows) == 0 {
		p.Note("Nothing to clean.")
		return nil
	}
	p.Printf("  %s\n", p.G(fmt.Sprintf("%-3s %-10s %-7s  %s", "#", "SIZE", "SAFETY", "WHAT")))
	for n, it := range rows {
		note := r.itemNote(it)
		if it.Admin && !r.Admin {
			note = "[admin, skipped: run as administrator] " + it.Note
		}
		p.Printf("  %-3d %-10s %s  %s\n", n+1, r.size(it.Bytes), p.Badge(it.Safety), p.B(it.Label))
		p.Printf("  %-3s %-10s %-7s  %s\n", "", "", "", p.G(note))
	}

	picked := make([]int, len(rows))
	for i := range picked {
		picked[i] = i
	}
	if !c.o.Yes {
		ask, err := c.asker("clean")
		if err != nil {
			return err
		}
		var ok bool
		if picked, ok = ask.Pick(len(rows), "numbers like 1,3 or 2-5, 'safe', 'all'", levels); !ok {
			p.Note("Nothing cleaned.")
			return nil
		}
		if !c.o.DryRun {
			var total int64
			for _, n := range picked {
				total += rows[n].Bytes
			}
			p.Note("Quit the apps whose caches you clean.")
			if !ask.Confirm(fmt.Sprintf("Clean %d item(s), %s?", len(picked), r.size(total))) {
				p.Note("Nothing cleaned.")
				return nil
			}
		}
	}

	if c.o.DryRun {
		p.Note("Dry run: nothing will be changed.")
	}
	before := sysinfo.FreeBytes()
	cleaned := 0
	for _, n := range picked {
		it := rows[n]
		p.Printf("  %s\n", p.B(it.Label))
		if it.Admin && !r.Admin {
			p.Warn("skipped: needs \"Run as administrator\"")
			continue
		}
		if items.Clean(it, c.home, c.o.DryRun, p) {
			cleaned++
		}
	}
	if !c.o.DryRun {
		p.Printf("\n  Cleaned %d item(s).", cleaned)
	}
	c.reportFreed(before)
	return nil
}

// ---------------------------------------------------------------------------
// medic purge
// ---------------------------------------------------------------------------

func (c *cmd) purge() error {
	p := c.p
	roots := scan.DevRoots(c.home, c.o.DevDirs)
	c.progress.Show("dependency and build folders")
	rows := scan.PurgeFolders(roots, c.o.OlderThan, func(path string) { c.progress.Show(c.report.tilde(path)) })
	c.progress.Done()
	if c.o.JSON {
		return c.writeJSON(jsonFromPurge(c.report, roots, rows))
	}

	p.Section("Purge")
	if c.o.OlderThan > 0 {
		p.Note("Dependency and build folders of projects with no file changed in %d days.", c.o.OlderThan)
	} else {
		p.Note("Dependency and build folders of all projects.")
	}
	where := "no project folders found"
	if len(roots) > 0 {
		var list []string
		for _, r := range roots {
			list = append(list, c.report.tilde(r))
		}
		where = strings.Join(list, ", ")
	}
	p.Note("Looked in: %s. Add more with --dev-dir DIR.", where)
	if len(rows) == 0 {
		p.Note("Nothing to purge.")
		return nil
	}
	p.Printf("\n  %s\n", p.G(fmt.Sprintf("%-3s %-10s %-13s %s", "#", "SIZE", "KIND", "FOLDER")))
	for n, e := range rows {
		p.Printf("  %-3d %-10s %-13s %s\n", n+1, c.report.size(e.Bytes), e.Kind, c.report.tilde(e.Path))
	}
	p.Note("Reinstall with 'npm install', 'pip install -r requirements.txt' or a new build when you need them.")

	picked := make([]int, len(rows))
	for i := range picked {
		picked[i] = i
	}
	if !c.o.Yes {
		ask, err := c.asker("purge")
		if err != nil {
			return err
		}
		var ok bool
		if picked, ok = ask.Pick(len(rows), "numbers like 1,3 or 2-5, 'all'", nil); !ok {
			p.Note("Nothing deleted.")
			return nil
		}
		if !c.o.DryRun {
			var total int64
			for _, n := range picked {
				total += rows[n].Bytes
			}
			if !ask.Confirm(fmt.Sprintf("Delete %d folder(s), %s?", len(picked), c.report.size(total))) {
				p.Note("Nothing deleted.")
				return nil
			}
		}
	}

	if c.o.DryRun {
		p.Note("Dry run: nothing will be changed.")
	}
	before := sysinfo.FreeBytes()
	deleted := 0
	for _, n := range picked {
		path := rows[n].Path
		// Checked again: the folder may have changed since the scan.
		if !scan.CanPurge(path, roots) {
			p.Warn("refusing to touch %s (not a dependency or build folder in a project folder)", c.report.tilde(path))
			continue
		}
		if c.o.DryRun {
			p.Note("would delete %s", c.report.tilde(path))
			continue
		}
		removeTree(path)
		if _, err := os.Lstat(path); err == nil {
			p.Warn("could not delete everything in %s", c.report.tilde(path))
		}
		deleted++
	}
	if !c.o.DryRun {
		p.Printf("\n  Deleted %d folder(s).", deleted)
	}
	c.reportFreed(before)
	return nil
}

// ---------------------------------------------------------------------------
// medic check
// ---------------------------------------------------------------------------

func (c *cmd) check() error {
	var disk sysinfo.Disk
	for _, d := range sysinfo.ReadDisks() {
		if d.System {
			disk = d
		}
	}
	mem := sysinfo.ReadMemory()
	need := minFreeBytes(c.o.MinFree, disk.Total, c.report.OS == "windows")
	diskOK := disk.Free >= need
	memOK := mem.Pressure != "critical"
	if c.o.JSON {
		err := c.writeJSON(jsonCheck{Version: c.version, OS: c.report.OS, OK: diskOK && memOK, Checks: []jsonCheckItem{
			{Name: "disk", OK: diskOK, FreeBytes: &disk.Free, MinFreeBytes: &need},
			{Name: "memory", OK: memOK, Pressure: mem.Pressure},
		}})
		if err != nil {
			return err
		}
	} else {
		line := func(ok bool, text string) {
			if ok {
				c.p.Printf("%s %s\n", c.p.Green+"OK  "+c.p.Reset, text)
			} else {
				c.p.Printf("%s %s\n", c.p.Red+"FAIL"+c.p.Reset, text)
			}
		}
		where := ""
		if c.report.OS == "windows" {
			where = " on " + disk.Name
		}
		line(diskOK, fmt.Sprintf("disk: %s free%s, needs %s", c.report.size(disk.Free), where, c.report.size(need)))
		line(memOK, "memory: pressure is "+mem.Pressure)
	}
	if !diskOK || !memOK {
		return errFailed
	}
	return nil
}
