package app

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/f-bahesna/medic/internal/items"
	"github.com/f-bahesna/medic/internal/scan"
	"github.com/f-bahesna/medic/internal/sysinfo"
	"github.com/f-bahesna/medic/internal/ui"
)

// Report is everything the report, disk and memory commands show. Rendering
// it is pure, so the README screenshots can draw one with sample data.
type Report struct {
	OS           string // "macos" or "windows"
	Version      string
	Command      string
	Home         string
	Host         sysinfo.Host
	Admin        bool // Windows: running as administrator
	NoDiskAccess bool // macOS: the terminal has no Full Disk Access

	Disks      []sysinfo.Disk
	Memory     *sysinfo.Memory
	Items      []*items.Item
	Breakdowns []Breakdown
	Scanned    bool // the slow scans ran (no --quick)
	DevFolders []scan.Entry
	LargeFiles []scan.Entry
	LargeMB    int
	OlderThan  int

	Snapshots   int            // macOS: local Time Machine snapshots
	SystemFiles []sysinfo.File // Windows: pagefile.sys and friends
}

// Breakdown is the biggest entries of one app data folder.
type Breakdown struct {
	Dir     string
	Entries []scan.Entry
}

func (r *Report) mac() bool { return r.OS == "macos" }

// units for disk sizes: decimal like Finder, binary like Explorer.
func (r *Report) units() ui.Units {
	if r.mac() {
		return ui.Decimal
	}
	return ui.Binary
}

func (r *Report) size(b int64) string { return ui.Size(b, r.units()) }

func (r *Report) tilde(path string) string { return ui.Tilde(path, r.Home) }

// row is a label padded to 22 columns and a value, like "  Capacity  494 GB".
func row(p *ui.Printer, label, value, hint string) {
	p.Printf("  %-22s %s", label, value)
	if hint != "" {
		p.Printf(" %s", p.G(hint))
	}
	p.Printf("\n")
}

// RenderHeader prints the first lines: version, computer and what the run does.
func RenderHeader(p *ui.Printer, r *Report, dryRun bool) {
	p.Printf("%s %s\n", p.B("medic "+r.Version), p.G("- "+r.Host.Name+", "+r.Host.OS))
	switch r.Command {
	case "clean", "purge", "uninstall":
		if dryRun {
			p.Note("Dry run: shows what would happen, changes nothing.")
		}
	default:
		p.Note("Read-only. Nothing is deleted unless you run clean, purge or uninstall and confirm.")
	}
	if r.Command == "memory" || r.Command == "purge" || r.Command == "apps" {
		return
	}
	if r.NoDiskAccess {
		p.Warn("Your terminal has no Full Disk Access, so Trash and Mail sizes may show as empty.")
		p.Note("Grant it in System Settings > Privacy & Security > Full Disk Access for complete results.")
	}
	if r.Admin {
		p.Note("Running as administrator: system caches are included.")
	}
}

// RenderReport prints the report and disk commands.
func RenderReport(p *ui.Printer, r *Report) {
	RenderDisks(p, r)
	if r.Memory != nil {
		RenderMemory(p, r)
	}
	renderItems(p, r)
	renderCommands(p, r)
	if r.Scanned {
		renderBreakdowns(p, r)
		renderDevFolders(p, r)
		renderLargeFiles(p, r)
	}
	renderSystem(p, r)
	renderSummary(p, r)
}

// RenderDisks prints the Disk section.
func RenderDisks(p *ui.Printer, r *Report) {
	p.Section("Disk")
	for _, d := range r.Disks {
		pct := d.UsedPct()
		if r.mac() {
			other := max(d.Used-d.SystemVolume-d.DataVolume, 0)
			row(p, "Capacity", r.size(d.Total), "")
			row(p, "Used", fmt.Sprintf("%-10s %s %d%%", r.size(d.Used), p.Bar(pct), pct), "")
			row(p, "Free", p.B(r.size(d.Free)), "")
			row(p, "  macOS (read-only)", r.size(d.SystemVolume), "")
			row(p, "  Your data volume", r.size(d.DataVolume), "")
			row(p, "  Other volumes", r.size(other), "(swap, recovery, updates)")
			p.Note("Finder may show more free space: it also counts 'purgeable' space macOS can free on its own.")
			if pct >= 90 {
				p.Warn("Disk is almost full. macOS slows down and updates fail below ~10%% free.")
			}
			continue
		}
		name := d.Name
		if d.Label != "" {
			name += " " + d.Label
		}
		if d.System {
			name += " (system drive)"
		}
		p.Printf("  %s\n", name)
		row(p, "  Capacity", r.size(d.Total), "")
		row(p, "  Used", fmt.Sprintf("%-10s %s %d%%", r.size(d.Used), p.Bar(pct), pct), "")
		row(p, "  Free", p.B(r.size(d.Free)), "")
		if d.System && pct >= 90 {
			p.Warn("The Windows drive is almost full. Updates fail and Windows slows down below ~10%% free.")
		}
	}
}

// RenderMemory prints the Memory section.
func RenderMemory(p *ui.Printer, r *Report) {
	m := r.Memory
	size := func(b int64) string { return ui.Size(b, ui.Binary) }
	pct := m.UsedPct()
	p.Section("Memory (RAM)")
	row(p, "Physical memory", size(m.Total), "")
	if r.mac() {
		row(p, "Used", fmt.Sprintf("%-10s %s %d%%", size(m.Used), p.Bar(pct), pct), "")
		row(p, "  App memory", size(m.App), "")
		row(p, "  Wired", size(m.Wired), "(kernel, cannot be freed)")
		row(p, "  Compressed", size(m.Compressed), "")
		row(p, "Cached files", size(m.Cached), "(freed instantly when apps need it)")
		row(p, "Free", size(m.Free), "")
		row(p, "Swap used", size(m.SwapUsed)+" of "+size(m.SwapTotal), "")
	} else {
		row(p, "In use", fmt.Sprintf("%-10s %s %d%%", size(m.Used), p.Bar(pct), pct), "")
		if m.Compressed > 0 {
			row(p, "  Compressed", size(m.Compressed), "")
		}
		row(p, "Cached", size(m.Cached), "(freed instantly when apps need it)")
		row(p, "Available", size(m.Free), "")
		row(p, "Committed", size(m.Committed)+" of "+size(m.CommitLimit), fmt.Sprintf("(%d%%, RAM + page file)", m.CommitPct()))
		row(p, "Page file used", size(m.SwapUsed)+" of "+size(m.SwapTotal), "")
	}

	words := map[string][2]string{"normal": {"Normal", "Normal"}, "warning": {"Warning", "Elevated"}, "critical": {"Critical", "High"}}
	word, colorOf := "unknown", ""
	if w, ok := words[m.Pressure]; ok {
		word = w[0]
		if !r.mac() {
			word = w[1]
		}
		colorOf = map[string]string{"normal": p.Green, "warning": p.Yellow, "critical": p.Red}[m.Pressure]
	}
	hint := ""
	if m.AvailablePct >= 0 {
		hint = fmt.Sprintf("(%d%% available)", m.AvailablePct)
	}
	row(p, "Memory pressure", colorOf+word+p.Reset, hint)

	what := "(as in Activity Monitor)"
	if !r.mac() {
		what = "(as in Task Manager)"
	}
	p.Printf("\n  %s %s\n", p.B("Top apps by memory"), p.G(what))
	for _, a := range m.TopApps {
		p.Printf("    %-10s %s", size(a.Bytes), a.Name)
		if a.Processes > 1 {
			p.Printf(" %s", p.G(fmt.Sprintf("(%d processes)", a.Processes)))
		}
		p.Printf("\n")
	}

	switch {
	case (m.Pressure == "warning" || m.Pressure == "critical") && r.mac():
		p.Warn("Your Mac is short on memory. Quit apps at the top of this list, or restart to clear swap.")
	case m.Pressure == "warning" || m.Pressure == "critical":
		p.Warn("Your PC is short on memory. Close apps at the top of this list, or restart.")
	case r.mac():
		p.Note("High 'used' memory is normal on macOS. Only memory pressure tells you if RAM is a problem.")
	default:
		p.Note("High \"in use\" memory is normal. Only memory pressure tells you if RAM is a problem.")
	}
}

func (r *Report) itemNote(it *items.Item) string {
	if it.Admin {
		return "[admin] " + it.Note
	}
	return it.Note
}

func renderItems(p *ui.Printer, r *Report) {
	p.Section("Space hogs")
	p.Printf("  %s\n", p.G(fmt.Sprintf("%-10s %-7s  %s", "SIZE", "SAFETY", "WHAT")))
	for _, it := range items.Visible(r.Items) {
		p.Printf("  %-10s %s  %s\n", r.size(it.Bytes), p.Badge(it.Safety), p.B(it.Label))
		p.Printf("  %-10s %-7s  %s\n", "", "", p.G(r.itemNote(it)))
		where := ""
		if len(it.Paths) > 0 {
			where = it.Paths[0]
		} else if len(it.Files) > 0 {
			where = filepath.Dir(it.Files[0])
		}
		if where != "" {
			p.Printf("  %-10s %-7s  %s\n", "", "", p.G(r.tilde(where)))
		}
	}
	if !r.mac() && !r.Admin {
		p.Note("Run as administrator to also measure system caches (Windows Update, crash dumps, Windows.old).")
	}
}

func renderCommands(p *ui.Printer, r *Report) {
	var shown []*items.Item
	helper := false
	for _, it := range items.Visible(r.Items) {
		if it.CanClean() && len(it.Commands) > 0 {
			shown = append(shown, it)
			for _, c := range it.Commands {
				helper = helper || strings.HasPrefix(c, "Clear-Folder")
			}
		}
	}
	if len(shown) == 0 {
		return
	}
	p.Section("Delete commands")
	p.Note("Prefer 'medic clean': it asks first and only touches allowlisted folders.")
	if r.mac() {
		p.Note("To clean by hand, quit the related apps and copy the command under an item.")
	} else {
		p.Note("To clean by hand, close the related apps and copy the commands under an item.")
	}
	if helper {
		p.Printf("\n")
		p.Note("Paste this helper once per PowerShell window. It empties a folder without following links:")
		p.Printf("    %s\n", items.ClearFolderHelper)
	}
	for _, it := range shown {
		hint := r.size(it.Bytes)
		if it.Admin {
			hint += ", run as administrator"
		}
		p.Printf("\n  %s  %s %s\n", p.Badge(it.Safety), p.B(it.Label), p.G("("+hint+")"))
		for _, c := range it.Commands {
			p.Printf("    %s\n", c)
		}
	}
}

func renderBreakdowns(p *ui.Printer, r *Report) {
	if len(r.Breakdowns) == 0 {
		return
	}
	if r.mac() {
		p.Section("Where the space inside your Library goes")
	} else {
		p.Section("Where the space inside AppData goes")
	}
	for _, b := range r.Breakdowns {
		p.Printf("\n  %s\n", p.B(r.tilde(b.Dir)))
		for _, e := range b.Entries {
			p.Printf("    %-10s %s", r.size(e.Bytes), e.Name)
			if e.Hint != "" {
				p.Printf(" %s", p.G("("+e.Hint+")"))
			}
			p.Printf("\n")
		}
	}
	if r.mac() {
		p.Note("Application Support holds app data (settings, databases). Folders of apps you already")
		p.Note("uninstalled can be removed, but check first. medic never cleans this folder.")
	} else {
		p.Note("AppData holds app data (settings, databases). Folders of apps you already")
		p.Note("uninstalled can be removed, but check first. medic never cleans these folders.")
	}
}

func renderDevFolders(p *ui.Printer, r *Report) {
	if len(r.DevFolders) == 0 {
		return
	}
	var total int64
	for _, f := range r.DevFolders {
		total += f.Bytes
	}
	p.Section("Dev project dependencies")
	p.Printf("  %s in %d folders %s\n", p.B(r.size(total)), len(r.DevFolders), p.G("(node_modules, Python venvs)"))
	for i, f := range r.DevFolders {
		if i == 8 {
			break
		}
		p.Printf("    %-10s %s\n", r.size(f.Bytes), r.tilde(f.Path))
	}
	p.Note("REVIEW: reinstallable, but only remove them for projects you are not working on.")
	p.Note("Run 'medic purge' to pick the ones of projects untouched for %d days.", r.OlderThan)
}

func renderLargeFiles(p *ui.Printer, r *Report) {
	if len(r.LargeFiles) == 0 {
		return
	}
	p.Section(fmt.Sprintf("Large files (> %d MB)", r.LargeMB))
	p.Printf("  %s\n", p.G(fmt.Sprintf("%-10s %-11s %s", "SIZE", "MODIFIED", "FILE")))
	for _, f := range r.LargeFiles {
		p.Printf("  %-10s %-11s %s\n", r.size(f.Bytes), f.Modified.Format("2006-01-02"), r.tilde(f.Path))
	}
	p.Note("REVIEW: these are your files. Old videos, disk images and archives are the usual suspects.")
}

func renderSystem(p *ui.Printer, r *Report) {
	if r.mac() {
		p.Section("Managed by macOS (do not delete by hand)")
		p.Printf("  %-26s %d local snapshot(s)\n", "Time Machine snapshots", r.Snapshots)
		p.Note("Removed automatically when space runs low. Counted as 'purgeable' in Finder.")
		p.Printf("  %-26s %s\n", "System Data", "caches, swap, logs and snapshots owned by macOS")
		p.Note("Shrinks after a restart. Never delete files in /System, /Library or /private/var by hand.")
		return
	}
	p.Section("Managed by Windows (do not delete by hand)")
	for _, f := range r.SystemFiles {
		row(p, f.Path, r.size(f.Bytes), "")
		switch strings.ToLower(filepath.Base(f.Path)) {
		case "pagefile.sys":
			p.Note("Virtual memory. Windows sizes it automatically.")
		case "hiberfil.sys":
			p.Note("Hibernation. 'powercfg /hibernate off' (admin) frees it, but also disables Fast Startup.")
		case "swapfile.sys":
			p.Note("Used by Store apps. Managed by Windows.")
		}
	}
	row(p, "WinSxS", "Windows component store", "")
	p.Note("Looks huge in Explorer because of hard links. Never delete it by hand; as admin, run")
	p.Note("'Dism /Online /Cleanup-Image /StartComponentCleanup' to trim old versions.")
	row(p, "Restore points", "System Protection", "")
	p.Note("Manage their size in Control Panel > System > System Protection > Configure.")
	row(p, "Storage Sense", "Settings > System > Storage", "")
	p.Note("Can empty temp files and the Recycle Bin for you on a schedule.")
}

func renderSummary(p *ui.Printer, r *Report) {
	t := items.Totals(r.Items)
	p.Section("Summary")
	for _, l := range [][2]string{
		{items.Safe, "regenerated automatically, no data loss"},
		{items.Caution, "regenerable, read the note first"},
		{items.Review, "your data, check by hand (never cleaned by medic)"},
	} {
		p.Printf("  %s  %s %s\n", p.Badge(l[0]), p.B(fmt.Sprintf("%-10s", r.size(t[l[0]]))), l[1])
	}
	p.Printf("\n  Run %s to pick SAFE and CAUTION items to clean,\n", p.B("medic clean"))
	p.Printf("  or %s to preview without changing anything.\n", p.B("medic clean --dry-run"))
}
