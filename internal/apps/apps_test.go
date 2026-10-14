package apps

import "testing"

func TestBelongsTo(t *testing.T) {
	others := []string{"ru.keepcoder.Telegram", "com.google.Chrome", "com.google.Chrome.canary", "org.telegram.desktop"}
	tests := []struct {
		name, id string
		want     bool
	}{
		{"ru.keepcoder.Telegram", "ru.keepcoder.Telegram", true},
		{"ru.keepcoder.Telegram.plist", "ru.keepcoder.Telegram", true},
		{"ru.keepcoder.Telegram.TelegramShare", "ru.keepcoder.Telegram", true},
		{"6N38VWS5BX.ru.keepcoder.Telegram.FocusIntents", "ru.keepcoder.Telegram", true},
		{"com.postmanlabs.mac.ShipIt.F8958E2C-2261-51F9-A2C1-BEBDCA2A52B2.plist", "com.postmanlabs.mac", true},
		{"ru.keepcoder.Telegram.savedState", "ru.keepcoder.Telegram", true},
		{"org.telegram.desktop", "ru.keepcoder.Telegram", false},
		{"ru.keepcoder.TelegramX", "ru.keepcoder.Telegram", false},
		{"com.postmanlabs.agent.mac.plist", "com.postmanlabs.mac", false},
		// Another installed app has the longer id: its data is not Chrome's.
		{"com.google.Chrome.canary", "com.google.Chrome", false},
		{"com.google.Chrome.canary.plist", "com.google.Chrome", false},
		{"com.google.Chrome.helper", "com.google.Chrome", true},
		{"anything", "", false},
	}
	for _, tt := range tests {
		if got := belongsTo(tt.name, tt.id, others); got != tt.want {
			t.Errorf("belongsTo(%q, %q) = %v, want %v", tt.name, tt.id, got, tt.want)
		}
	}
}

func TestFind(t *testing.T) {
	list := []App{{Name: "Google Chrome"}, {Name: "Google Docs"}, {Name: "Zed"}, {Name: "Zed Preview"}}
	tests := []struct {
		query string
		want  int
	}{
		{"zed", 1}, // exact name wins over "Zed Preview"
		{"google", 2},
		{"google chrome", 1},
		{"preview", 1},
		{"nothing", 0},
		{" ", 0},
	}
	for _, tt := range tests {
		if got := Find(list, tt.query); len(got) != tt.want {
			t.Errorf("Find(%q) found %d apps, want %d", tt.query, len(got), tt.want)
		}
	}
}

func TestBaseName(t *testing.T) {
	tests := map[string]string{
		"Mozilla Firefox (x64 en-US)": "Mozilla Firefox",
		"Slack 4.46.99":               "Slack",
		"7-Zip 24.08 (x64)":           "7-Zip",
		"Notepad++ v8.7":              "Notepad++",
		"Git":                         "Git",
		"Python 3.13.0 (64-bit)":      "Python",
	}
	for in, want := range tests {
		if got := baseName(in); got != want {
			t.Errorf("baseName(%q) = %q, want %q", in, got, want)
		}
	}
}
