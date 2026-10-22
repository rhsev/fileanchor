//go:build linux

package main

// Unit checks for what smoke.py cannot reach from outside. The conformance
// test over the wire is scripts/smoke.py.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateFollowsTheValueRules(t *testing.T) {
	cases := []struct {
		v    string
		kind valueKind
		ok   bool
	}{
		{"Geschäft", kindLabel, true},
		{"a,b", kindLabel, false},
		{" a", kindLabel, false},
		{"a ", kindLabel, false},
		{strings.Repeat("x", 256), kindLabel, false},
		{"a b", kindToken, false},
		{strings.Repeat("x", 129), kindToken, false},
		{"Zeile\n\tzwei", kindText, true},
		{"nul\x00", kindText, false},
		{"", kindText, false},
	}
	for _, c := range cases {
		_, err := validate(c.v, c.kind, "k")
		if (err == nil) != c.ok {
			t.Errorf("validate(%q, %d) err=%v, want ok=%v", c.v, c.kind, err, c.ok)
		}
	}
	if v, _ := validate("Geschäft", kindLabel, "tag"); v != "Geschäft" {
		t.Errorf("not stored NFC: %q", v)
	}
}

func TestSyncAttrDropsTheMacFlag(t *testing.T) {
	for in, want := range map[string]string{
		"com.fileregister.id#S": "user.com.fileregister.id",
		"com.fileregister.id":   "user.com.fileregister.id",
		"user.custom":           "user.custom",
		"odd#name#1":            "user.odd#name#1",
		"#S":                    "user.#S",
	} {
		if got := syncAttr(in); got != want {
			t.Errorf("syncAttr(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHiddenSkipsDotDirectoriesButNotTheTrash(t *testing.T) {
	for rel, want := range map[string]bool{
		"":                    false,
		"a/b.txt":             false,
		".cache/x":            true,
		"a/.git/config":       true,
		".hidden.txt":         false, // a dot file is walked, a dot directory is not
		".Trash/x":            false,
		".Trash-1000/files/x": false,
	} {
		if got := hidden(rel, false); got != want {
			t.Errorf("hidden(%q) = %v, want %v", rel, got, want)
		}
	}
	if !hidden("a/.git", true) {
		t.Error("a dot directory asked about itself is hidden")
	}
}

func TestRootsComeFromEnvFileOrHome(t *testing.T) {
	home, cfg := t.TempDir(), t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", cfg)
	os.Unsetenv("FILEANCHOR_ROOTS")
	if got := configuredRoots(); len(got) != 1 || got[0] != home {
		t.Errorf("no file: %v, want [%s]", got, home)
	}
	os.MkdirAll(filepath.Join(cfg, "fileanchor"), 0o755)
	os.WriteFile(filepath.Join(cfg, "fileanchor", "roots"), []byte("# c\n~/Dokumente\n/mnt/platte\n\n"), 0o644)
	if got := configuredRoots(); len(got) != 2 || got[0] != filepath.Join(home, "Dokumente") || got[1] != "/mnt/platte" {
		t.Errorf("file: %v", got)
	}
	t.Setenv("FILEANCHOR_ROOTS", "")
	if got := configuredRoots(); len(got) != 0 {
		t.Errorf("empty variable: %v, want none", got)
	}
	t.Setenv("FILEANCHOR_ROOTS", "/a::/b")
	if got := configuredRoots(); len(got) != 2 {
		t.Errorf("variable: %v", got)
	}
}

func TestBlobRoundTripKeepsThePathBytes(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "Pässe.md") // decomposed on purpose
	os.WriteFile(p, []byte("x"), 0o644)
	b, err := save(p)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := decodeBlob(b)
	if !ok || string(got.Path) != p {
		t.Fatalf("decoded %q, want %q", got.Path, p)
	}
	if _, ok := decodeBlob("bm90IGpzb24="); ok {
		t.Error("garbage decoded as a blob")
	}
}

func TestUnreadableDirectoryWithholdsSearchable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every directory")
	}
	dir := t.TempDir()
	locked := filepath.Join(dir, "locked")
	os.Mkdir(locked, 0o000)
	defer os.Chmod(locked, 0o755)
	t.Setenv("FILEANCHOR_ROOTS", dir)
	e := newEngine("")
	if e.searchable(filepath.Join(locked, "x")) {
		t.Error("a place the walk could not read is searchable")
	}
	if e.searchable(dir) {
		t.Error("a place with an unreadable directory below is searchable")
	}
	os.Mkdir(filepath.Join(dir, "open"), 0o755)
	if !newEngine("").searchable(filepath.Join(dir, "open")) {
		t.Error("a readable sibling is not searchable")
	}
}
