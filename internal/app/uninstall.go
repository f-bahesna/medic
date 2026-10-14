package app

import (
	"fmt"
	"strings"
	"time"

	"github.com/f-bahesna/medic/internal/apps"
	"github.com/f-bahesna/medic/internal/ui"
)

type jsonInstalledApp struct {
	Name      string `json:"name"`
	Version   string `json:"version"`
	ID        string `json:"id"`
	Publisher string `json:"publisher,omitempty"`
	Path      string `json:"path,omitempty"`
	Bytes     int64  `json:"bytes"`
	// macOS: last opened; Windows: installed. YYYY-MM-DD, empty when unknown.
	LastUsed string `json:"last_used,omitempty"`
}

type jsonApps struct {
	Version string             `json:"version"`
	OS      string             `json:"os"`
	Command string             `json:"command"`
	Apps    []jsonInstalledApp `json:"apps"`
}

func date(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.Format("2006-01-02")
}

func appTitle(a apps.App) string {
	if a.Version != "" {
		return a.Name + " " + a.Version
	}
	return a.Name
}

// listApps is medic apps: every installed app, biggest first. Read-only.
func (c *cmd) listApps() error {
	c.progress.Show("installed apps")
	list := apps.List(c.home)
	c.progress.Done()
	if c.o.JSON {
		out := jsonApps{Version: c.version, OS: c.report.OS, Command: "apps", Apps: []jsonInstalledApp{}}
		for _, a := range list {
			out.Apps = append(out.Apps, jsonInstalledApp{a.Name, a.Version, a.ID, a.Publisher, a.Path, a.Bytes, date(a.LastUsed)})
		}
		return c.writeJSON(out)
	}

	p, r := c.p, c.report
	when := "LAST USED"
	if !r.mac() {
		when = "INSTALLED"
	}
	p.Section("Apps")
	p.Printf("  %s\n", p.G(fmt.Sprintf("%-10s %-11s %s", "SIZE", when, "APP")))
	var total int64
	for _, a := range list {
		total += a.Bytes
		used := date(a.LastUsed)
		if used == "" {
			used = "-"
		}
		p.Printf("  %-10s %-11s %s\n", r.size(a.Bytes), used, appTitle(a))
	}
	p.Printf("\n  %d apps, %s in total.\n", len(list), p.B(r.size(total)))
	if r.mac() {
		p.Note("Apple's own apps are not listed: macOS protects them.")
	} else {
		p.Note("System components and Microsoft Store apps are not listed.")
	}
	p.Note("Run 'medic uninstall NAME' to review an app and what it left behind before anything is removed.")
	return nil
}

// uninstall is medic uninstall NAME: show the app and everything it left
// behind, let the person pick, then move the picked parts to the Trash.
func (c *cmd) uninstall() error {
	p, r := c.p, c.report
	c.progress.Show("installed apps")
	all := apps.List(c.home)
	c.progress.Done()

	matches := apps.Find(all, c.o.Target)
	switch {
	case len(matches) == 0:
		p.Warn("No installed app matches '%s'. 'medic apps' lists them.", c.o.Target)
		return errFailed
	case len(matches) > 1:
		p.Warn("Several apps match '%s':", c.o.Target)
		for _, a := range matches {
			p.Printf("    %s\n", appTitle(a))
		}
		p.Note("Run again with the full name, like: medic uninstall \"%s\"", matches[0].Name)
		return errFailed
	}
	app := matches[0]
	var ids []string
	for _, a := range all {
		ids = append(ids, a.ID)
	}

	p.Section("Uninstall " + appTitle(app))
	var about []string
	for _, s := range []string{app.Publisher, app.ID} {
		if s != "" {
			about = append(about, s)
		}
	}
	if !app.LastUsed.IsZero() {
		if r.mac() {
			about = append(about, "last used "+date(app.LastUsed))
		} else {
			about = append(about, "installed "+date(app.LastUsed))
		}
	}
	if len(about) > 0 {
		p.Note("%s", strings.Join(about, ", "))
	}
	if apps.Running(app) {
		p.Warn("%s is running. Quit it first, then run this again.", app.Name)
		if !c.o.DryRun {
			return errFailed
		}
	}

	if command := apps.UninstallCommand(app); command != "" {
		return c.uninstallWithUninstaller(app, command, ids)
	}

	c.progress.Show("what " + app.Name + " left behind")
	rows := []apps.Leftover{{Path: app.Path, Bytes: app.Bytes, Why: "the app"}}
	rows = append(rows, apps.Leftovers(app, c.home, ids)...)
	c.progress.Done()
	return c.reviewAndRemove(app, rows, "Nothing cleaned up.")
}

// uninstallWithUninstaller is the Windows flow: the app's own uninstaller
// runs first, then what it left behind is reviewed.
func (c *cmd) uninstallWithUninstaller(app apps.App, command string, ids []string) error {
	p := c.p
	p.Note("The app's own uninstaller runs first:")
	p.Printf("    %s\n", command)
	before := apps.Leftovers(app, c.home, ids)
	if len(before) > 0 {
		p.Note("Afterwards you can review what it left behind. Found now:")
		c.printRows(before)
	}
	if c.o.DryRun {
		p.Note("Dry run: nothing changed. Without --dry-run the uninstaller runs after you confirm.")
		return nil
	}
	ask, err := c.asker("uninstall")
	if err != nil {
		return err
	}
	if !ask.Confirm(fmt.Sprintf("Run the uninstaller of %s?", app.Name)) {
		p.Note("Nothing changed.")
		return nil
	}
	if err := apps.RunUninstaller(app); err != nil {
		p.Warn("The uninstaller ended with an error: %v", err)
	}
	// Many uninstallers start a second program and return at once.
	p.Printf("\n  Press Enter when the uninstaller has finished. ")
	_, _ = ask.In.ReadString('\n')

	rows := apps.Leftovers(app, c.home, ids)
	p.Section("Left behind by " + app.Name)
	if len(rows) == 0 {
		p.Note("Nothing left behind.")
		return nil
	}
	return c.reviewAndRemoveWith(ask, app, rows, "Kept what was left behind.")
}

func (c *cmd) printRows(rows []apps.Leftover) {
	p := c.p
	p.Printf("\n  %s\n", p.G(fmt.Sprintf("%-3s %-10s %-15s %s", "#", "SIZE", "MATCHED BY", "PATH")))
	byName := false
	for n, l := range rows {
		why := l.Why
		if why == "same name" {
			why = p.Yellow + fmt.Sprintf("%-15s", why) + p.Reset
			byName = true
		} else {
			why = fmt.Sprintf("%-15s", why)
		}
		p.Printf("  %-3d %-10s %s %s\n", n+1, c.report.size(l.Bytes), why, c.report.tilde(l.Path))
	}
	if byName {
		p.Note("'same name' rows were matched by the app's name only: check they belong to this app.")
	}
}

func (c *cmd) reviewAndRemove(app apps.App, rows []apps.Leftover, cancelled string) error {
	if c.o.DryRun {
		c.printRows(rows)
		c.p.Note("Everything you pick moves to the %s, so you can put it back.", apps.TrashName)
		c.p.Note("Dry run: nothing changed. Without --dry-run you pick from this list and confirm.")
		return nil
	}
	ask, err := c.asker("uninstall")
	if err != nil {
		c.printRows(rows)
		return err
	}
	return c.reviewAndRemoveWith(ask, app, rows, cancelled)
}

// reviewAndRemoveWith shows the rows, asks which to remove, and moves those to
// the Trash or Recycle Bin.
func (c *cmd) reviewAndRemoveWith(ask *ui.Asker, app apps.App, rows []apps.Leftover, cancelled string) error {
	p := c.p
	c.printRows(rows)
	p.Note("Everything you pick moves to the %s, so you can put it back.", apps.TrashName)
	picked, ok := ask.Pick(len(rows), "numbers like 1,3 or 2-5, 'all'", nil)
	if !ok {
		p.Note("%s", cancelled)
		return nil
	}
	var total int64
	for _, n := range picked {
		total += rows[n].Bytes
	}
	if !ask.Confirm(fmt.Sprintf("Move %d item(s), %s, to the %s?", len(picked), c.report.size(total), apps.TrashName)) {
		p.Note("%s", cancelled)
		return nil
	}
	moved := 0
	for _, n := range picked {
		path := rows[n].Path
		if !apps.Allowed(path, app, c.home) {
			p.Warn("refusing to touch %s (not an app or app data folder)", c.report.tilde(path))
			continue
		}
		if err := apps.Remove(path); err != nil {
			p.Warn("could not move %s to the %s: %v", c.report.tilde(path), apps.TrashName, err)
			continue
		}
		moved++
	}
	p.Printf("\n  Moved %d item(s) to the %s.\n", moved, apps.TrashName)
	p.Note("Empty the %s to free the space, or put things back from there if you need them.", apps.TrashName)
	return nil
}
