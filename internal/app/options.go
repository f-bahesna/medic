package app

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Options are the parsed command line.
type Options struct {
	Command   string
	JSON      bool
	Quick     bool
	DryRun    bool
	Yes       bool
	NoColor   bool
	Help      bool
	Version   bool
	Only      []string
	OlderThan int
	MinFree   string
	LargeMB   int
	DevDirs   []string
}

// UsageError is wrong usage: medic exits with 2.
type UsageError struct{ msg string }

func (e UsageError) Error() string { return e.msg }

func usagef(format string, a ...any) error { return UsageError{fmt.Sprintf(format, a...)} }

var commands = map[string]string{
	"report": "report", "disk": "disk", "memory": "memory", "ram": "memory",
	"clean": "clean", "purge": "purge", "check": "check",
}

var minFreePattern = regexp.MustCompile(`(?i)^(\d+%|\d+(\.\d+)?([KMGT]B?)?)$`)

// Parse reads the command and options. Options work Mac style (--dry-run)
// and PowerShell style (-DryRun), so commands from before 0.5 keep working on
// both systems.
func Parse(args []string) (Options, error) {
	o := Options{OlderThan: 30, MinFree: "10%", LargeMB: 500}
	legacyClean := false
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			cmd, ok := commands[strings.ToLower(arg)]
			if !ok {
				return o, usagef("unknown command: %s", arg)
			}
			if o.Command != "" {
				return o, usagef("only one command at a time ('%s' and '%s')", o.Command, arg)
			}
			o.Command = cmd
			continue
		}
		name, value, hasValue := strings.Cut(strings.TrimLeft(arg, "-"), "=")
		key := strings.ToLower(strings.ReplaceAll(name, "-", ""))
		// takeValue reads the option's value, from "--x=value" or the next argument.
		takeValue := func() (string, error) {
			if hasValue {
				return value, nil
			}
			if i+1 >= len(args) || (strings.HasPrefix(args[i+1], "-") && len(args[i+1]) > 1) {
				return "", usagef("%s needs a value", arg)
			}
			i++
			return args[i], nil
		}
		flag := func(b *bool) error {
			if hasValue {
				return usagef("%s takes no value", name)
			}
			*b = true
			return nil
		}
		var err error
		switch key {
		case "clean":
			err = flag(&legacyClean)
		case "dryrun":
			err = flag(&o.DryRun)
		case "json":
			err = flag(&o.JSON)
		case "yes":
			err = flag(&o.Yes)
		case "quick":
			err = flag(&o.Quick)
		case "nocolor":
			err = flag(&o.NoColor)
		case "h", "help", "?":
			err = flag(&o.Help)
		case "v", "version":
			err = flag(&o.Version)
		case "only":
			var v string
			if v, err = takeValue(); err == nil {
				o.Only = append(o.Only, splitList(strings.ToLower(v))...)
			}
		case "devdir":
			var v string
			if v, err = takeValue(); err == nil {
				o.DevDirs = append(o.DevDirs, splitList(v)...)
			}
		case "minfree":
			o.MinFree, err = takeValue()
		case "olderthan", "large", "largemb":
			var v string
			if v, err = takeValue(); err == nil {
				n, convErr := strconv.Atoi(v)
				if convErr != nil || n < 0 || (key != "olderthan" && n == 0) {
					return o, usagef("%s needs a number, got '%s'", arg, v)
				}
				if key == "olderthan" {
					o.OlderThan = n
				} else {
					o.LargeMB = n
				}
			}
		default:
			return o, usagef("unknown option: %s", arg)
		}
		if err != nil {
			return o, err
		}
	}

	// Before 0.4 cleaning was --clean or --dry-run on the report.
	if o.Command == "" && (legacyClean || o.DryRun) {
		o.Command = "clean"
	}
	if o.Command == "" {
		o.Command = "report"
	}
	return o, o.validate()
}

func (o Options) validate() error {
	cleaning := o.Command == "clean" || o.Command == "purge"
	switch {
	case o.DryRun && !cleaning:
		return usagef("--dry-run only works with clean and purge")
	case o.Yes && !cleaning:
		return usagef("--yes only works with clean and purge")
	case o.JSON && o.Command == "clean":
		return usagef("clean has no JSON output; 'medic report --json' lists the items")
	case len(o.Only) > 0 && o.Command != "clean":
		return usagef("--only only works with clean")
	case !minFreePattern.MatchString(o.MinFree):
		return usagef("--min-free: '%s' is not a size like 20G, 500M or 10%%", o.MinFree)
	}
	return nil
}

func splitList(s string) []string {
	var out []string
	for _, f := range strings.FieldsFunc(s, func(r rune) bool { return r == ',' }) {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

// minFreeBytes turns --min-free into bytes: a share of total, or a size in
// the units medic shows on this system.
func minFreeBytes(spec string, total int64, binary bool) int64 {
	if p, ok := strings.CutSuffix(spec, "%"); ok {
		n, _ := strconv.Atoi(p)
		return total * int64(n) / 100
	}
	s := strings.TrimSuffix(strings.ToUpper(spec), "B")
	base := 1000.0
	if binary {
		base = 1024
	}
	mult := 1.0
	if s != "" {
		switch s[len(s)-1] {
		case 'K':
			mult = base
		case 'M':
			mult = base * base
		case 'G':
			mult = base * base * base
		case 'T':
			mult = base * base * base * base
		}
		if mult != 1 {
			s = s[:len(s)-1]
		}
	}
	n, _ := strconv.ParseFloat(s, 64)
	return int64(n * mult)
}

const usage = `medic %s - see what is filling up your computer and what is safe to clean.

Usage: medic [command] [options]

Commands:
  report           Full report (default)
  disk             Disk, space hogs, delete commands, dev folders and large files
  memory           Memory use and the apps using the most
  clean            Pick SAFE and CAUTION items to clean
  purge            Pick dependency and build folders of inactive projects to delete
  check            Exit with 1 when the disk is almost full or memory is critical

Options:
  --json           Print JSON instead of text (report, disk, memory, purge, check)
  --quick          Skip the slow scans: breakdowns, dev folders, large files
  --large MB       Report files bigger than MB megabytes (default: 500)
  --dev-dir DIR    Extra project folder to scan (repeatable)
  --dry-run        clean, purge: show what would happen, change nothing
  --yes            clean, purge: do not ask, take every listed item
  --only LIST      clean: only these levels (safe, caution) or item ids, comma-separated.
                   With --yes the default is safe.
  --older-than N   purge: only projects with no file changed in N days (default: 30, 0 for all)
  --min-free SIZE  check: free space needed, like 20G, 500M or 10%% (default: 10%%)
  --no-color       Disable colored output (NO_COLOR is honored too)
  -h, --help       Show this help
  -v, --version    Show version

PowerShell style works too: -DryRun, -Yes, -Only safe, -Json, -MinFree 20G.

Safety levels:
  SAFE       Regenerated automatically. No data loss.
  CAUTION    Regenerable, but you lose more than a cache (stopped containers,
             locally installed artifacts) or it costs a long rebuild.
  REVIEW     May contain personal data. Reported only, never deleted.

Exit codes: 0 ok, 1 error or failed check, 2 wrong usage.
`
