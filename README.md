# fileanchor

![test](https://github.com/rhsev/fileanchor/actions/workflows/test.yml/badge.svg)

fileanchor is a small metadata engine. It gives files a durable identity and
reads and writes tags, comments and a few other attributes. The metadata
travels over a batch protocol: one JSON object per line on stdin, one response
per line on stdout. Each system has its own engine with its own code, a native
macOS engine in Swift (`macos/`) and a Linux engine in Go (`linux/`). A
consumer cannot tell them apart over the wire.

The macOS engine works with bookmarks, Finder tags and Finder comments. It runs
everything through in-process Foundation / CoreServices calls, no fork+exec per
file, so it is fast: 2,000 tag reads take about 50 ms. It runs on macOS 13 or
later (tested on 15).

fileanchor helps metadata survive renaming and moving files. Using
`xattr`/`plutil`/`mdfind` per file was both slow and subtly wrong. It started
as the metadata layer inside a larger file-collection tool of mine,
fileregister; once the engine proved useful on its own, it
moved into its own repo.

It operates only on `(path, id/blob, tag, key, value)` and knows nothing about
any consumer's record model, so it is reusable: an `id → bookmark → file`
resolver, a persistent-link scheme, or just a faster, batched, consolidated
`bookmark` + `tag` + `xattr` + `mdfind`. fileregister is the first consumer,
not the owner.

The Linux engine stores the same values in `user.*` extended attributes and
finds a moved file by its inode and generation number. Linux has no system
index for these attributes, so the engine walks a set of folders, its roots,
when an answer needs it. It needs kernel 6.6 or later and a file system with
user extended attributes (ext4, btrfs, xfs).

The specification lives in [SPEC.md](SPEC.md), which was written before and
during the build. It also records the results of the metadata experiments.
[PLATFORMS.md](PLATFORMS.md) records what both engines share and what each
decides for itself.

## Protocol

Batch, line-oriented, order-preserving. One JSON object per line on stdin;
one JSON object per line on stdout, in input order. A failed op returns
`{"ok":false,"error":"…"}` for that line and does not halt the stream — this
includes a path that does not exist (`no such file`), so a vanished file never
reads as a file without metadata. The
process exits 0 after the batch; it is not a daemon. It flushes after every
response line, so a consumer may hold one engine subprocess open for its whole
run and interleave requests and responses without deadlock.

Held that way it answers ~30,000 ops/sec: reading tags + comment + groups for
2,000 files (6,000 sequential round-trips) takes ~0.17s on an M-series Mac. The
round-trip itself is negligible (~0.03 ms); for a UI, driving these reads off the
main thread and folding the result into the view in one pass is what keeps it
smooth, not batching the wire.

| op | input fields | output |
|---|---|---|
| `save` | `path` | `{ok, blob}` — opaque base64 bookmark |
| `resolve` | `blob` | `{ok, path[, stale]}`; unresolvable → `{ok:false, last_path}` |
| `tag` / `untag` | `path`, `value` | `{ok, action: added\|removed\|noop}` |
| `tags` | `path` | `{ok, tags:[…]}` — names only, color suffix stripped |
| `set_meta` | `path`, `key`, `value`, `mode` | `{ok, action: added\|removed\|set\|noop}` |
| `get_meta` | `path`, `key` | `{ok, value}` (sync/comment) or `{ok, values:[…]}` (groups/id) |
| `query` | `by`, `value` | `{ok, paths:[…]}` — Spotlight on macOS, the walk over the roots on Linux |
| `searchable` | `path` | `{ok, searchable}` — whether `query` would find a file there |

- **`key`** ∈ `groups` \| `id` \| `sync` \| `comment`. `groups` is a real array
  (one element per value); `id` is space-separated multi-valued; `sync` is
  single-valued; `comment` is a single string stored as the binary-plist the
  Finder comment (`kMDItemFinderComment`) uses.
- **`mode`** (set_meta) ∈ `add` \| `remove` \| `set`. For the multi-valued keys
  (`groups`, `id`) `add`/`remove` are idempotent element ops and `set` replaces
  the whole value (for `id` a space-separated list); an `id` token passed to
  `add`/`remove` must not contain whitespace. For the single-valued
  `sync`/`comment` `add`/`set` write idempotently and `remove` deletes. An
  empty `set` deletes on every key (`removed`, or `noop` if nothing was
  there). Defaults to `add`.
- **`by`** (query) ∈ `tag` \| `groups` \| `id` \| `filename` — a *selector*,
  not a Spotlight key. The macOS backend maps each to the right `kMDItem*` key
  (note the verified asymmetry: tags are written under `_kMDItemUserTags` but
  queried under `kMDItemUserTags`). `by: id` matches whole tokens only:
  Spotlight can only match it as a substring, so the engine drops hits whose
  id merely contains the value (`rechnung-1` vs `rechnung-10`).
- **Values** are checked on write. Tags and groups may hold no comma and no
  leading or trailing whitespace. `id`/`sync` are single tokens without
  whitespace. A comment is free text up to 1 KiB. Everything is stored NFC.
  Removal takes any value, so existing ones can be cleaned up. The rules hold
  for every platform's engine; [PLATFORMS.md](PLATFORMS.md) has the reasons.
- **Paths** the engine returns (`resolve`'s `path`, `query`'s `paths`) are byte
  for byte what the file system holds, each name in the Unicode form it has on
  disk. Foundation hands a resolved bookmark back with every name decomposed;
  the engine reads the names back from the volume instead.
- **`searchable`** says whether `query` covers a place: on macOS, whether
  Spotlight indexes the volume the nearest existing ancestor of `path` lies on.
  It is yes only for an enabled index. On Linux it is yes only under a root the
  engine walked completely. A consumer asks it before it reads an
  empty `query` as "no file carries this", and only about a volume it has found
  mounted.
- **`last_path`** on a failed `resolve` is the path the blob recorded when it
  was saved. It tells a file that is gone from one on a volume that is not
  mounted. Resolving never mounts a volume or shows UI.
- **`stale`** on `resolve` means the bookmark resolved but should be regenerated
  with a fresh `save`.

Batch resolve needs no separate op — one object per line *is* the batch, and an
empty blob in yields a negative out, in order.

### Example

```
$ fileanchor --sync-name com.fileregister.id#S
{"op":"save","path":"/Users/me/doc.pdf"}
{"ok":true,"blob":"Ym9vazwD…"}
{"op":"tag","path":"/Users/me/doc.pdf","value":"★"}
{"ok":true,"action":"added"}
{"op":"get_meta","path":"/Users/me/doc.pdf","key":"sync"}
{"ok":true}
```

Fields that do not apply are left out rather than sent as `null` — an absent
`value` means no value. Keys come in sorted order, so output is byte-stable.

```
```

### The sync name

`groups` and `id` map to fixed Apple metadata keys (`kMDItemProjects` and
`kMDItemInformation`). The cross-device `sync` key does not — its xattr name
is the consumer's concept. Pass it with `--sync-name <name>` (the default for the
`sync` key) or per request via a `name` field. fileregister uses
`com.fileregister.id#S`: a custom namespace plus the `#S` syncable flag (part of
the literal attribute name), which survives iCloud Drive and AirDrop where the
Apple `kMDItem*` namespace does not.

## Build

### macOS

SwiftPM, arm64, macOS 13 or later (tested on macOS 15):

```
swift build -c release        # binary at .build/release/fileanchor
.build/release/fileanchor --version
swift run fileanchor-selftest # the checks: engine round-trips against a temp dir
python3 scripts/smoke.py      # live wire-protocol smoke against the built binary
```

The checks are a plain executable, not a `.testTarget`: the Command Line Tools
ship neither XCTest nor swift-testing, so a test target builds and reports
success without running a single check. `fileanchor-selftest` needs no
framework, prints how many checks ran, and exits non-zero if any failed.

Tags are read through the `URLResourceValues.tagNames` getter. Writes edit the
stored `_kMDItemUserTags` entries directly (via `PropertyListSerialization`),
because an entry carries the tag's color (`name\n<index>`) and `tagNames` knows
only names: writing through it would reset the color of every other tag on the
file. Up to 1.0.2 that happened on every `tag`/`untag`.

### Linux

Go 1.26 or later; the binary runs on kernel 6.6 or later, amd64 or arm64:

```
go build -o fileanchor ./linux   # or: make linux for both release binaries
./fileanchor --version
go test ./linux/                 # unit checks
python3 scripts/smoke.py ./fileanchor
```

The engine searches its roots. They are the lines of
`~/.config/fileanchor/roots` (one path per line, `#` starts a comment, `~/`
means the home folder), or `$HOME` when that file does not exist.
`FILEANCHOR_ROOTS` overrides both with a colon-separated list; set but empty
means no roots. The walk stays on each root's file system, follows no symlinks
and skips dot directories except the Trash. It runs at most once per process
and only when an answer needs it.

Files carry their metadata only on a file system with user extended
attributes. On FAT and exFAT every op that touches an attribute fails with the
name of the file system. NTFS is not supported; an SMB mount works when the
server keeps extended attributes. `cp` and `rsync` keep the attributes only with
`--preserve=xattr` and `-X`.

### Vendoring

The binary is built and vendored into a consumer's `vendor/`, mirroring how
`bookmark` is vendored in fileregister. Resolution order there is
`$FILEANCHOR` > `PATH` > `vendor/`. A ZIP-downloaded binary carries a Gatekeeper
quarantine flag — clear it with `xattr -d com.apple.quarantine fileanchor`.

## Design decisions

- **`query` is OS-neutral and minimal.** It names selectors, not Spotlight keys,
  and uses the synchronous `MDQuery` C API (no `NSMetadataQuery` runloop). It is
  the *recovery* path — a consumer's own index answers most enumeration;
  Spotlight results are subject to indexing latency.
- **Stateless about the id↔blob map.** The engine does `save`/`resolve` only; the
  consumer owns the id→blob store.

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — source-available, not OSI open source.

---

*Used by [fileregister](https://github.com/rhsev/fileregister). Part of a family of plain-text tools — the [profile page](https://github.com/rhsev) has the map.*
