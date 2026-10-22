//go:build linux

package main

// Extended attributes, with the failures a Linux file system can give named
// for what they mean. An attribute that is not there is not an error; a file
// system that cannot hold one is, for reads too, so a consumer never takes
// "cannot carry" for "carries nothing".

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// The names this engine stores under (PLATFORMS.md).
const (
	tagsAttr    = "user.xdg.tags"
	commentAttr = "user.xdg.comment"
	groupsAttr  = "user.fileanchor.groups"
	idAttr      = "user.fileanchor.id"
)

// getAttr reads an attribute: its bytes and whether it is there. Follows a
// symlink to its target, like getxattr(2) without XATTR_NOFOLLOW on macOS.
func getAttr(path, name string) ([]byte, bool, error) {
	buf := make([]byte, 256)
	for {
		n, err := unix.Getxattr(path, name, buf)
		switch {
		case err == nil:
			return buf[:n], true, nil
		case errors.Is(err, unix.ENODATA):
			return nil, false, nil
		case errors.Is(err, unix.ERANGE):
			size, serr := unix.Getxattr(path, name, nil)
			if serr != nil {
				return nil, false, attrError(path, name, serr, false)
			}
			buf = make([]byte, size+64)
		default:
			return nil, false, attrError(path, name, err, false)
		}
	}
}

func setAttr(path, name string, value []byte) error {
	if err := unix.Setxattr(path, name, value, 0); err != nil {
		return attrError(path, name, err, true)
	}
	return nil
}

// removeAttr deletes an attribute; one that is already gone is fine.
func removeAttr(path, name string) error {
	if err := unix.Removexattr(path, name); err != nil && !errors.Is(err, unix.ENODATA) {
		return attrError(path, name, err, true)
	}
	return nil
}

// attrError names why an attribute could not be read or written.
func attrError(path, name string, err error, write bool) error {
	switch {
	case errors.Is(err, unix.ENOTSUP):
		return engineError(fmt.Sprintf("no extended attributes on this file system (%s): %s", fsTypeName(path), path))
	case errors.Is(err, unix.ENOSPC), errors.Is(err, unix.E2BIG):
		return engineError(fmt.Sprintf("no room for attribute %s on %s", name, path))
	case errors.Is(err, unix.EPERM):
		// user.* is refused outright on device files, FIFOs and sockets.
		if st, serr := os.Stat(path); serr == nil && !st.Mode().IsRegular() && !st.IsDir() {
			return engineError("no user attributes on this kind of file: " + path)
		}
		return engineError("permission denied: " + path)
	case errors.Is(err, unix.EACCES), errors.Is(err, unix.EROFS):
		if errors.Is(err, unix.EROFS) {
			return engineError("read-only file system: " + path)
		}
		return engineError("permission denied: " + path)
	}
	verb := "read"
	if write {
		verb = "write"
	}
	return engineError(fmt.Sprintf("%s failed: %s: %v", verb, name, err))
}

// fsTypeName names the file system path lies on, for messages.
func fsTypeName(path string) string {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return "unknown"
	}
	switch uint32(st.Type) {
	case 0xEF53:
		return "ext2/3/4"
	case 0x9123683E:
		return "btrfs"
	case 0x58465342:
		return "xfs"
	case 0x01021994:
		return "tmpfs"
	case 0x4D44:
		return "vfat"
	case 0x2011BAB0:
		return "exfat"
	case 0x5346544E, 0x7366746E:
		return "ntfs"
	case 0x6969:
		return "nfs"
	case 0xFF534D42, 0xFE534D42, 0x517B:
		return "smb"
	case 0x65735546:
		return "fuse"
	case 0x794C7630:
		return "overlay"
	case 0x9660:
		return "iso9660"
	case 0x9FA0:
		return "proc"
	case 0x62656572:
		return "sysfs"
	}
	return fmt.Sprintf("type %#x", uint32(st.Type))
}
