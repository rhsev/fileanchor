# fileanchor on other platforms

What binds every fileanchor engine, and what each platform decides for itself.
Recorded 2026-09-26, with the macOS engine at 1.1.0. The Linux engine was built
on 2026-10-17 (`linux/`).

Each OS gets its own engine: its own code, if it likes its own language. What
makes them one tool is that a consumer (fileregister first) cannot tell them
apart over the wire. So the specification is shared and the storage is not.

## Shared by every engine

- **The protocol** in [SPEC.md](SPEC.md): ops, fields, response shapes, the
  action words (`added`, `removed`, `set`, `noop`). One line in, one line out,
  in order. A failed op is `{"ok":false,"error":…}` and never halts the batch,
  a blank line included. A path that does not exist is `no such file`, never
  empty metadata. A blob that does not resolve comes back with `last_path`,
  the path it recorded, and resolving never mounts anything.
- **The semantics:** writes are idempotent (`noop` when nothing changes). An
  empty `set` deletes on every key. `remove`/`untag` take any value that is
  there. Reads come back NFC. Fields that do not apply are omitted, not `null`.
- **The value rules** below.
- **Conformance:** [scripts/smoke.py](scripts/smoke.py). Every check not
  marked macOS or Linux must pass unchanged against both engines.

## Value rules

Strict on write, tolerant on read and removal. Only `tag` and
`set_meta add|set` validate. Anything already on a file, written by Finder or
an older engine, can still be read and removed. A value that breaks a rule is
rejected (`invalid value: …`), never repaired. The one exception is Unicode:
values are stored NFC, because the same text has to be the same bytes
everywhere, and neither APFS xattrs nor Linux filesystems normalize.

| kind | keys | rule |
|---|---|---|
| all | | not empty, no control characters, stored NFC |
| label | `tag`, `groups` | no comma, no leading or trailing whitespace, ≤ 255 bytes |
| token | `id`, `sync` | no whitespace, no comma, ≤ 128 bytes. `set` on `id` takes a space-separated list of tokens |
| text | `comment` | newline and tab allowed, ≤ 1 KiB |

Why each rule:

- **No comma in labels.** Linux desktops keep tags in `user.xdg.tags` as a
  comma-separated list with no escaping. Groups follow the same rule because
  fileregister stores a binder either as a group or as a tag (its `xattr`
  backend), and switching backends must not fail on the name.
- **No control characters.** On macOS a newline ends a Finder tag name (the
  color index follows it). NUL ends C strings everywhere.
- **Tokens without whitespace.** `id` is stored space-separated. A token with
  a space in it would be stored as two tokens and never match again.
- **Comments stay free text.** Finder lets people type anything, newlines
  included. A restore has to be able to write back what Finder wrote.
- **Size limits.** On ext4 all xattrs of a file share one block, about 4 KiB,
  so no single value may take most of it.

When the rules were set, every tag, group and id on the author's volumes
already met them. Comments did not, which is why the text rule stays loose.

## Decided per platform

Where a value lives and how it is encoded is each engine's business.

| logical | macOS | Linux |
|---|---|---|
| `tag` | `com.apple.metadata:_kMDItemUserTags`, binary-plist array. Entries carry the Finder color (`name\n<index>`), which a write keeps | `user.xdg.tags`, comma-separated (the freedesktop convention Dolphin reads) |
| `comment` | `com.apple.metadata:kMDItemFinderComment`, binary-plist string, plus a write-through to Finder | `user.xdg.comment`, plain UTF-8 |
| `groups` | `com.apple.metadata:kMDItemProjects`, binary-plist array | `user.fileanchor.groups`, comma-separated |
| `id` | `com.apple.metadata:kMDItemInformation`, space-separated, as a binary-plist string (Spotlight indexes nothing else once there are two ids) | `user.fileanchor.id`, space-separated |
| `sync` | the name from `--sync-name`, literally (`com.fileregister.id#S`) | the same name under `user.`, without `#S` (`user.com.fileregister.id`) |
| `save`/`resolve` | Foundation bookmark, base64; resolved without mounting, the path read back with realpath(3), because Foundation decomposes every name it resolves; `last_path` read from the bookmark data | base64 JSON with the file system (UUID, else `f_fsid`), inode, generation (else creation time) and the path as bytes. Looked up at the recorded path, then in its old folder, then by the walk over the roots, and when it is nowhere, whatever now has the recorded path; `stale` when it moved or was replaced, `last_path` when nothing is found |
| `query` | synchronous Spotlight (`MDQuery`) | the walk over the roots, which reads the `user.*` attributes of every file it passes |
| `searchable` | `mdutil -s` on the volume root, cached per volume; yes only for "Indexing enabled." | yes only under a root that is there, on the root's file system, outside skipped dot directories, with no unreadable directory on the way or below |

**`#S` stays on the wire.** `--sync-name com.fileregister.id#S` is what
fileregister passes, and it passes it on every OS. `#S` is macOS's flag for an
xattr that iCloud and AirDrop preserve. It is part of the attribute name there
and meaningless elsewhere, so another engine drops it and maps the rest to its
own namespace. The consumer never needs to know.

**Blobs are opaque** and only valid for the engine that made them, like a macOS
bookmark is only valid on the Mac that made it. Consumers store them and hand
them back.

**`query` is a recovery path.** An engine without a system index may answer
slowly or return nothing. The specification allows that, and consumers treat
their own index as primary.

**A new file in the old place.** Both engines first look for the saved file
wherever it went, and only when it is nowhere take what now has the recorded
path, with `stale`. A macOS bookmark does that on its own; the Linux engine
does it because editors save by writing a new file and renaming it over the
old one, which leaves a new inode in the old place. ext4 gives a freed inode
number to the next new file at once, with the same creation time to the
nanosecond (the kernel stamps with a coarse clock), so the Linux engine
compares the generation number too: a new file elsewhere that got the old
number is not taken for the old file.

## Linux

Requirements, decided 2026-10-17:

- Kernel 6.6 or later, amd64 or arm64. The binary is static and needs no
  desktop.
- Files that carry metadata live on a file system with `user.*` attributes:
  ext4, btrfs or xfs (tmpfs too since 6.6). On FAT and exFAT every op that
  touches an attribute fails with the name of the file system, reads
  included, so a consumer never takes "cannot carry" for "carries nothing";
  `save` and `resolve` still work. NTFS (`ntfs3`) carries the attributes but
  gives no generation number, so a new file that gets a deleted file's number
  can be taken for it; it is not supported. An SMB mount works when the server
  keeps extended attributes (Samba with `ea support = yes`); its identity is
  `f_fsid` and the creation time. NFS is not supported.
- Every file a consumer registers lies under a root. The roots come from
  `FILEANCHOR_ROOTS` (colon-separated, empty means none), else
  `$XDG_CONFIG_HOME/fileanchor/roots` (one path per line), else `$HOME`.
- File names are NFC. On ext4 the precomposed and the decomposed spelling of a
  name are two files.
- Copies keep their metadata only with `cp --preserve=xattr` or `rsync -X`.

The walk:

- Runs at most once per process, when `resolve` misses at the recorded path
  and in the old folder, or for `query` or `searchable`. On a small VPS
  (x86_64, ext4, kernel 6.8) it passed 110,000 files in 1.7 seconds, with the
  directory cache warm; a cold walk was not measured. The engine keeps it in
  step with its own writes, so a query later in the same batch sees them.
- Stays on each root's file system, follows no symlinks and skips dot
  directories, as Spotlight does on macOS. The Trash is walked: `.Trash`,
  `.Trash-<uid>`, and `$XDG_DATA_HOME/Trash` as a root of its own when a root
  covers it. A root that is not there, a disk not mounted, is skipped.
- `plocate` is not used. Every registered file lies under a root, so a name
  index would add nothing the walk lacks, and it cannot say whether its
  answer is complete.

Measured on a 6.8 kernel as an ordinary user:

- `open_by_handle_at` is refused (EPERM, also with `O_PATH`), so there is no
  way from an inode back to a path without root; hence the walk.
- `FS_IOC_GETVERSION` reads the generation number without privilege.
- `user.*` attributes are refused on a symlink itself (`lsetxattr`, EPERM);
  the engine follows a symlink to its target, like the macOS engine.
- On procfs an attribute op fails with ENOTSUP, on a FIFO with EPERM; both
  come back as their own message.

Measured later (2026-10-22): smoke.py passes on arm64 (Debian 13, and Alpine
with musl) as on amd64, and on xfs as on ext4, btrfs and tmpfs. A loop-mounted disk taken away and
mounted again, also through another device or at another mount point listed
as a root, resolves; while it is away its files are unreachable, not gone. An
SMB mount from a Samba share passes smoke.py; NTFS passes all but the check
for a reused file number.

## Considered and dropped

- **A strict default plus an open mode.** Every relaxation would be a value
  one engine writes and another cannot store, which is exactly what the rules
  prevent. One rule set.
- **Validating in the consumer.** Each consumer would have to repeat the rules
  exactly. The engine is the one place every write passes through.
- **A neutral sync name on the wire** (`com.fileregister.id`, with each engine
  adding its own flag). It would be cleaner, but the mapping belongs to each
  engine anyway, and the current flag keeps working without a change.

## Consumers

- fileregister checks binder names against the label rule where a name is
  introduced (add, rename's new name, write, unmarshal), since a binder is
  written as a tag or a group. Binders with a comma were allowed before and
  are refused since then; existing ones can still be renamed away.
