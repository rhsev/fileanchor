//go:build linux

package main

// The roots: the places this engine searches completely. Linux has no system
// index that knows these attributes (plocate knows names, desktop indexers
// run with their desktop), so the engine walks the roots itself, once per
// process and only when an answer needs it. One walk serves resolve (a moved
// file), query and searchable.
//
// Where the roots come from, first match wins:
//
//	FILEANCHOR_ROOTS                     colon-separated; set but empty means none
//	$XDG_CONFIG_HOME/fileanchor/roots    one path per line, # comments, ~/ for home
//	$HOME
//
// The walk stays on each root's file system, follows no symlinks and skips
// dot directories, as Spotlight does on macOS, except the Trash: .Trash,
// .Trash-<uid>, and $XDG_DATA_HOME/Trash as a root of its own when it lies
// under one. A root that is not there (a disk not mounted) is skipped.

import (
	"bufio"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"unicode/utf8"

	"golang.org/x/sys/unix"
	"golang.org/x/text/unicode/norm"
)

type root struct {
	path  string
	dev   uint64
	there bool
}

// fileAttrs are the searchable attributes of one file, as the walk read them.
type fileAttrs struct {
	tags, groups, ids []string
}

// walkIndex is what one walk over the roots found.
type walkIndex struct {
	byIno   map[uint64][]string
	byName  map[string][]string // NFC basename → paths
	attrs   map[string]fileAttrs
	errDirs []string // directories the walk could not read
}

// configuredRoots reads the roots as configured, before they are checked.
func configuredRoots() []string {
	home := os.Getenv("HOME")
	if env, ok := os.LookupEnv("FILEANCHOR_ROOTS"); ok {
		var out []string
		for _, p := range strings.Split(env, ":") {
			if p != "" {
				out = append(out, p)
			}
		}
		return out
	}
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" && home != "" {
		config = filepath.Join(home, ".config")
	}
	if f, err := os.Open(filepath.Join(config, "fileanchor", "roots")); err == nil {
		defer f.Close()
		var out []string
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if line == "~" {
				line = home
			} else if strings.HasPrefix(line, "~/") && home != "" {
				line = filepath.Join(home, line[2:])
			}
			out = append(out, line)
		}
		return out
	}
	if home != "" {
		return []string{home}
	}
	return nil
}

// loadRoots checks the configured roots: absolute, symlinks resolved so
// paths compare by prefix, device noted. Relative entries are ignored.
func loadRoots() []root {
	var out []root
	for _, p := range configuredRoots() {
		if !filepath.IsAbs(p) {
			continue
		}
		r := root{path: filepath.Clean(p)}
		if real, err := filepath.EvalSymlinks(r.path); err == nil {
			r.path = real
			var st unix.Stat_t
			if unix.Stat(real, &st) == nil && st.Mode&unix.S_IFMT == unix.S_IFDIR {
				r.dev, r.there = uint64(st.Dev), true
			}
		}
		out = append(out, r)
	}
	// The desktop Trash hides under .local/share; it is searched as a root of
	// its own wherever a root covers it.
	data := os.Getenv("XDG_DATA_HOME")
	if data == "" {
		if home := os.Getenv("HOME"); home != "" {
			data = filepath.Join(home, ".local", "share")
		}
	}
	if data != "" {
		trash := filepath.Join(data, "Trash")
		if real, err := filepath.EvalSymlinks(trash); err == nil {
			for _, r := range out {
				if r.there && under(real, r.path) && real != r.path {
					var st unix.Stat_t
					if unix.Stat(real, &st) == nil {
						out = append(out, root{path: real, dev: uint64(st.Dev), there: true})
					}
					break
				}
			}
		}
	}
	return out
}

// under reports whether p is dir itself or lies below it.
func under(p, dir string) bool {
	return p == dir || dir == "/" || strings.HasPrefix(p, dir+"/")
}

var trashName = regexp.MustCompile(`^\.Trash(-\d+)?$`)

// skippedDir reports whether the walk leaves a directory of this name out.
func skippedDir(name string) bool {
	return strings.HasPrefix(name, ".") && !trashName.MatchString(name)
}

func inodeOf(info fs.FileInfo) uint64 {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return st.Ino
	}
	return 0
}

func devOf(info fs.FileInfo) uint64 {
	if st, ok := info.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Dev)
	}
	return 0
}

// walk returns the index of the roots, walking them on first use.
func (e *engine) walk() *walkIndex {
	if e.index != nil {
		return e.index
	}
	idx := &walkIndex{byIno: map[uint64][]string{}, byName: map[string][]string{}, attrs: map[string]fileAttrs{}}
	seen := map[string]bool{}
	names := make([]byte, 4096)
	for _, r := range e.roots {
		if !r.there {
			continue
		}
		filepath.WalkDir(r.path, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				idx.errDirs = append(idx.errDirs, p)
				if d != nil && d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if d.Type()&fs.ModeSymlink != 0 {
				return nil
			}
			if d.IsDir() && p != r.path {
				if skippedDir(d.Name()) {
					return filepath.SkipDir
				}
			}
			info, ierr := d.Info()
			if ierr != nil {
				return nil
			}
			if devOf(info) != r.dev {
				// Another file system mounted below the root.
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if seen[p] {
				return nil
			}
			seen[p] = true
			idx.byIno[inodeOf(info)] = append(idx.byIno[inodeOf(info)], p)
			idx.byName[norm.NFC.String(d.Name())] = append(idx.byName[norm.NFC.String(d.Name())], p)
			if d.Type().IsRegular() || d.IsDir() {
				names = idx.readAttrs(p, names)
			}
			return nil
		})
	}
	e.index = idx
	return idx
}

// readAttrs notes the searchable attributes of p. One listxattr per file;
// values are read only for the names that are there.
func (idx *walkIndex) readAttrs(p string, buf []byte) []byte {
	n, err := unix.Llistxattr(p, buf)
	if err == unix.ERANGE {
		if size, serr := unix.Llistxattr(p, nil); serr == nil {
			buf = make([]byte, size+256)
			n, err = unix.Llistxattr(p, buf)
		}
	}
	if err != nil || n == 0 {
		return buf
	}
	var a fileAttrs
	found := false
	for _, name := range strings.Split(string(buf[:n]), "\x00") {
		switch name {
		case tagsAttr, groupsAttr, idAttr:
		default:
			continue
		}
		v, ok := lgetString(p, name)
		if !ok {
			continue
		}
		found = true
		switch name {
		case tagsAttr:
			a.tags = splitList(v)
		case groupsAttr:
			a.groups = splitList(v)
		case idAttr:
			a.ids = tokenize(v)
		}
	}
	if found {
		idx.attrs[p] = a
	}
	return buf
}

func lgetString(p, name string) (string, bool) {
	buf := make([]byte, 256)
	for {
		n, err := unix.Lgetxattr(p, name, buf)
		if err == unix.ERANGE {
			buf = make([]byte, len(buf)*4)
			continue
		}
		if err != nil {
			return "", false
		}
		return string(buf[:n]), true
	}
}

// noteWrite keeps an index already built in step with this engine's own
// writes, so a query later in the same batch sees them.
func (e *engine) noteWrite(path string) {
	if e.index == nil {
		return
	}
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return
	}
	if _, walked := e.index.attrs[real]; !walked && !e.covered(real) {
		return
	}
	delete(e.index.attrs, real)
	e.index.readAttrs(real, make([]byte, 4096))
}

// query answers from the walk. Paths come back as the walk read them, in
// the bytes the file system holds, sorted.
func (e *engine) query(by, value string) []string {
	idx := e.walk()
	v := norm.NFC.String(value)
	var out []string
	switch by {
	case "filename":
		out = append(out, idx.byName[v]...)
	default:
		for p, a := range idx.attrs {
			var hit bool
			switch by {
			case "tag":
				hit = contains(a.tags, v)
			case "groups":
				hit = contains(a.groups, v)
			case "id":
				for _, t := range a.ids {
					if t == value {
						hit = true
					}
				}
			}
			if hit {
				out = append(out, p)
			}
		}
	}
	paths := []string{}
	for _, p := range out {
		if _, err := os.Lstat(p); err == nil && utf8.ValidString(p) {
			paths = append(paths, p)
		}
	}
	sort.Strings(paths)
	return paths
}

// searchable: whether query would find a file under path if one were there.
// Yes only where the walk goes completely: under a root that is there, on
// its file system, not in a skipped dot directory, and with no directory on
// the way or below that the walk could not read. The place asked about is
// usually gone, so its nearest existing ancestor decides the file system.
func (e *engine) searchable(path string) bool {
	p := filepath.Clean(path)
	if !filepath.IsAbs(p) {
		abs, err := filepath.Abs(p)
		if err != nil {
			return false
		}
		p = abs
	}
	// The nearest existing ancestor, symlinks resolved; the missing rest is
	// kept as it was asked.
	anc, rest := p, ""
	for {
		if _, err := os.Lstat(anc); err == nil {
			break
		}
		parent := filepath.Dir(anc)
		if parent == anc {
			return false
		}
		rest = filepath.Join(filepath.Base(anc), rest)
		anc = parent
	}
	real, err := filepath.EvalSymlinks(anc)
	if err != nil {
		return false
	}
	var st unix.Stat_t
	if unix.Stat(real, &st) != nil {
		return false
	}
	isDir := st.Mode&unix.S_IFMT == unix.S_IFDIR && rest == ""
	full := real
	if rest != "" {
		full = filepath.Join(real, rest)
	}
	for _, r := range e.roots {
		if !r.there || !under(full, r.path) || uint64(st.Dev) != r.dev {
			continue
		}
		if hidden(strings.TrimPrefix(strings.TrimPrefix(full, r.path), "/"), isDir) {
			continue
		}
		complete := true
		for _, d := range e.walk().errDirs {
			if under(d, full) || under(full, d) {
				complete = false
			}
		}
		if complete {
			return true
		}
	}
	return false
}

// covered is searchable for a path known to exist.
func (e *engine) covered(path string) bool { return e.searchable(path) }

// hidden reports whether a path below a root runs through a directory the
// walk skips. The last name is a directory only when the place is one.
func hidden(rel string, lastIsDir bool) bool {
	if rel == "" {
		return false
	}
	parts := strings.Split(rel, "/")
	if !lastIsDir {
		parts = parts[:len(parts)-1]
	}
	for _, name := range parts {
		if skippedDir(name) {
			return true
		}
	}
	return false
}
