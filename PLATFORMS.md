# fileanchor on other platforms

What binds every fileanchor engine, and what each platform decides for itself.
Recorded 2026-09-26, with the macOS engine at 1.1.0.

Each OS gets its own engine: its own code, if it likes its own language. What
makes them one tool is that a consumer (fileregister first) cannot tell them
apart over the wire. So the contract is shared and the storage is not.

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
  marked macOS must pass unchanged against another engine.

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

Where a value lives and how it is encoded is each engine's business. The
table records the macOS engine as built and a proposal for Linux.

| logical | macOS (built) | Linux (proposal) |
|---|---|---|
| `tag` | `com.apple.metadata:_kMDItemUserTags`, binary-plist array. Entries carry the Finder color (`name\n<index>`), which a write keeps | `user.xdg.tags`, comma-separated (the freedesktop convention Dolphin reads) |
| `comment` | `com.apple.metadata:kMDItemFinderComment`, binary-plist string, plus a write-through to Finder | `user.xdg.comment`, plain UTF-8 |
| `groups` | `com.apple.metadata:kMDItemProjects`, binary-plist array | `user.fileanchor.groups`, comma-separated |
| `id` | `com.apple.metadata:kMDItemInformation`, space-separated | `user.fileanchor.id`, space-separated |
| `sync` | the name from `--sync-name`, literally (`com.fileregister.id#S`) | the same name under `user.`, without `#S` (`user.com.fileregister.id`) |
| `save`/`resolve` | Foundation bookmark, base64; resolved without mounting, `last_path` read from the bookmark data | its own opaque blob, e.g. device + inode + last path. `stale` when the path moved, `last_path` when it does not resolve |
| `query` | synchronous Spotlight (`MDQuery`) | no system index: `plocate` for `filename`, otherwise a walk that reads xattrs, or an empty result |

**`#S` stays on the wire.** `--sync-name com.fileregister.id#S` is what
fileregister passes, and it passes it on every OS. `#S` is macOS's flag for an
xattr that iCloud and AirDrop preserve. It is part of the attribute name there
and meaningless elsewhere, so another engine drops it and maps the rest to its
own namespace. The consumer never needs to know.

**Blobs are opaque** and only valid for the engine that made them, like a macOS
bookmark is only valid on the Mac that made it. Consumers store them and hand
them back.

**`query` is a recovery path.** An engine without a system index may answer
slowly or return nothing. That is within the contract, and consumers treat
their own index as primary.

Things a Linux engine will run into:

- `user.*` xattrs are not allowed on symlinks or device files.
- tmpfs supports them only since kernel 6.6, and many network mounts not at all.
- `cp` and `rsync` drop xattrs unless told otherwise (`--preserve=xattr`, `-X`).

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
