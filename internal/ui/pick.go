package ui

import (
	"bufio"
	"io"
	"sort"
	"strconv"
	"strings"
)

// ParseSelection turns an answer like "1,3", "2-5", "all" or "safe" into
// sorted 0-based row indexes. levels holds the safety level of each row, for
// "safe" and "caution"; pass nil when rows have none. ok is false when the
// answer is not valid or picks nothing.
func ParseSelection(answer string, count int, levels []string) (picked []int, ok bool) {
	set := map[int]bool{}
	fields := strings.FieldsFunc(strings.ToLower(answer), func(r rune) bool { return r == ',' || r == ' ' || r == '\t' })
	for _, token := range fields {
		switch {
		case token == "all":
			for i := 0; i < count; i++ {
				set[i] = true
			}
		case token == "safe" || token == "caution":
			if levels == nil {
				return nil, false
			}
			for i, l := range levels {
				if strings.EqualFold(l, token) {
					set[i] = true
				}
			}
		case strings.Contains(token, "-"):
			from, err1 := strconv.Atoi(strings.SplitN(token, "-", 2)[0])
			to, err2 := strconv.Atoi(strings.SplitN(token, "-", 2)[1])
			if err1 != nil || err2 != nil || from < 1 || to > count || from > to {
				return nil, false
			}
			for n := from; n <= to; n++ {
				set[n-1] = true
			}
		default:
			n, err := strconv.Atoi(token)
			if err != nil || n < 1 || n > count {
				return nil, false
			}
			set[n-1] = true
		}
	}
	for i := range set {
		picked = append(picked, i)
	}
	sort.Ints(picked)
	return picked, len(picked) > 0
}

// Asker reads answers from the person at the terminal.
type Asker struct {
	P  *Printer
	In *bufio.Reader
}

// NewAsker reads answers from in.
func NewAsker(p *Printer, in io.Reader) *Asker { return &Asker{P: p, In: bufio.NewReader(in)} }

func (a *Asker) line() (string, bool) {
	s, err := a.In.ReadString('\n')
	if err != nil && s == "" {
		return "", false
	}
	return strings.TrimSpace(s), true
}

// Pick asks which rows to take until the answer is valid. ok is false when
// the person cancels with an empty answer.
func (a *Asker) Pick(count int, hint string, levels []string) (picked []int, ok bool) {
	for {
		a.P.Printf("\n  Which ones? %s ", a.P.G(hint+", Enter to cancel:"))
		answer, read := a.line()
		if !read || answer == "" {
			return nil, false
		}
		if picked, ok := ParseSelection(answer, count, levels); ok {
			return picked, true
		}
		a.P.Warn("'%s' is not a valid choice.", answer)
	}
}

// Confirm asks a yes/no question, no is the default.
func (a *Asker) Confirm(question string) bool {
	a.P.Printf("  %s [y/N] ", question)
	answer, _ := a.line()
	switch answer {
	case "y", "Y", "yes", "YES", "Yes":
		return true
	}
	return false
}
