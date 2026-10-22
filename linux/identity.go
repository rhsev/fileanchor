//go:build linux

package main

// save and resolve. Linux has no bookmark and, without root, no way from an
// inode back to a path (open_by_handle_at needs CAP_DAC_READ_SEARCH, measured
// on 6.8). So a blob records which file it was — file system, inode,
// generation, birth time — and where it was; resolving looks for that file at
// the recorded path, then in the old folder (a rename), then in the walk over
// the roots (roots.go). Only when it is nowhere does a file now at the
// recorded path count, as a macOS bookmark falls back to its path: an editor
// that saves by writing a new file and renaming it over the old one leaves a
// new inode in the old place, and that is still the file.
//
// The inode number alone is not enough: ext4 hands a freed inode to the next
// new file at once, with the same birth time to the nanosecond (the kernel
// stamps with a coarse clock). The generation number, which ext4, btrfs and
// xfs bump on every reuse, tells the two apart, so a new file elsewhere that
// got the old number is not taken for the old file. tmpfs has none; there the
// birth time has to do.

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

// identity is what makes a file the same file.
type identity struct {
	FS    string    `json:"fs"` // uuid:<fs uuid>, else fsid:<statfs f_fsid>
	Ino   uint64    `json:"ino"`
	Gen   *uint32   `json:"gen,omitempty"`
	Btime *[2]int64 `json:"btime,omitempty"`
}

// blob is the opaque value save hands out: version, identity, and the path
// as bytes, so a name in any byte form survives the round trip.
type blob struct {
	V int `json:"v"`
	identity
	Path []byte `json:"path"`
}

const blobVersion = 1

func (a identity) same(b identity) bool {
	if a.FS != b.FS || a.Ino != b.Ino {
		return false
	}
	if a.Gen != nil && b.Gen != nil {
		return *a.Gen == *b.Gen
	}
	if a.Btime != nil && b.Btime != nil {
		return *a.Btime == *b.Btime
	}
	return true
}

// identify reads the identity of the file at path, not following a final
// symlink.
func identify(path string) (identity, error) {
	var sx unix.Statx_t
	if err := unix.Statx(unix.AT_FDCWD, path, unix.AT_SYMLINK_NOFOLLOW, unix.STATX_TYPE|unix.STATX_INO|unix.STATX_BTIME, &sx); err != nil {
		return identity{}, err
	}
	id := identity{Ino: sx.Ino, FS: fsKey(unix.Mkdev(sx.Dev_major, sx.Dev_minor), path)}
	if sx.Mask&unix.STATX_BTIME != 0 {
		id.Btime = &[2]int64{sx.Btime.Sec, int64(sx.Btime.Nsec)}
	}
	mode := uint32(sx.Mode) & unix.S_IFMT
	if mode == unix.S_IFREG || mode == unix.S_IFDIR {
		id.Gen = generation(path)
	}
	return id, nil
}

// generation asks the file system for the inode's generation number
// (FS_IOC_GETVERSION; no privilege needed, measured as uid 1000). nil where
// the file cannot be opened or the file system keeps none. O_NONBLOCK keeps a
// FIFO that took the file's place from blocking the open.
func generation(path string) *uint32 {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil
	}
	defer unix.Close(fd)
	const fsIocGetversion = 0x80087601 // _IOR('v', 1, long)
	v, err := unix.IoctlGetInt(fd, fsIocGetversion)
	if err != nil {
		return nil
	}
	g := uint32(v)
	return &g
}

var (
	fsKeys    = map[uint64]string{}
	uuidByDev map[uint64]string
	uuidOnce  sync.Once
)

// fsKey names the file system a device number belongs to, stable across
// mounts and reboots where it can be: the file system's UUID, found by
// matching the device against /dev/disk/by-uuid (readable without root).
// Where nothing matches — btrfs, whose files carry an anonymous device per
// subvolume, tmpfs — statfs's f_fsid, which btrfs derives from its UUID.
func fsKey(dev uint64, path string) string {
	if k, ok := fsKeys[dev]; ok {
		return k
	}
	uuidOnce.Do(func() {
		uuidByDev = map[uint64]string{}
		entries, _ := os.ReadDir("/dev/disk/by-uuid")
		for _, e := range entries {
			var st unix.Stat_t
			if unix.Stat(filepath.Join("/dev/disk/by-uuid", e.Name()), &st) == nil {
				uuidByDev[uint64(st.Rdev)] = e.Name()
			}
		}
	})
	k := ""
	if u, ok := uuidByDev[dev]; ok {
		k = "uuid:" + u
	} else {
		var sf unix.Statfs_t
		if unix.Statfs(path, &sf) == nil {
			k = fmt.Sprintf("fsid:%08x%08x", uint32(sf.Fsid.Val[0]), uint32(sf.Fsid.Val[1]))
		} else {
			k = fmt.Sprintf("dev:%d", dev)
		}
	}
	fsKeys[dev] = k
	return k
}

// save records the file at path. The path is stored with symlinks resolved,
// as the macOS engine's bookmark resolves to the target.
func save(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	real, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", noSuchFile(path)
	}
	id, err := identify(real)
	if err != nil {
		return "", noSuchFile(path)
	}
	data, err := json.Marshal(blob{V: blobVersion, identity: id, Path: []byte(real)})
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(data), nil
}

func decodeBlob(s string) (blob, bool) {
	if s == "" {
		return blob{}, false
	}
	data, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return blob{}, false
	}
	var b blob
	if json.Unmarshal(data, &b) != nil || b.V != blobVersion || len(b.Path) == 0 {
		return blob{}, false
	}
	return b, true
}

// resolved is a successful resolve: the path as the file system holds it,
// and whether the file has moved since the blob was made.
type resolved struct {
	path  string
	stale bool
}

// resolve finds the file a blob recorded. Nothing is mounted on the way.
func (e *engine) resolve(s string) (resolved, string, bool) {
	b, ok := decodeBlob(s)
	if !ok {
		return resolved{}, "", false
	}
	last := string(b.Path)
	if res, found := e.locate(b); found {
		if !utf8.ValidString(res.path) {
			// JSON cannot carry the name's bytes; the consumer could not
			// open what it got.
			return resolved{}, last, false
		}
		return res, last, true
	}
	return resolved{}, last, false
}

func (e *engine) locate(b blob) (resolved, bool) {
	last := string(b.Path)
	if id, err := identify(last); err == nil && id.same(b.identity) {
		return resolved{path: last}, true
	}
	// Renamed in place: the old folder, one level.
	dir := filepath.Dir(last)
	if entries, err := os.ReadDir(dir); err == nil {
		for _, ent := range entries {
			p := filepath.Join(dir, ent.Name())
			if info, err := ent.Info(); err == nil && inodeOf(info) == b.Ino {
				if id, err := identify(p); err == nil && id.same(b.identity) {
					return resolved{path: p, stale: true}, true
				}
			}
		}
	}
	// Anywhere under the roots.
	for _, p := range e.walk().byIno[b.Ino] {
		if id, err := identify(p); err == nil && id.same(b.identity) {
			return resolved{path: p, stale: true}, true
		}
	}
	// Nowhere: whatever now has the recorded path.
	if info, err := os.Lstat(last); err == nil && (info.Mode().IsRegular() || info.IsDir()) {
		return resolved{path: last, stale: true}, true
	}
	return resolved{}, false
}
