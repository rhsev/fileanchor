# fileanchor

fileanchor started as the metadata layer inside fileregister — my
file-collection tooling kept needing durable references that survive moves, and
shelling out to `bookmark`/`xattr`/`plutil`/`mdfind` per file was both slow and
subtly wrong. Once the engine proved useful on its own, it moved into its own
repo.

It is a small native macOS metadata engine: files get a durable identity and
metadata over a batch stdio protocol, served by in-process Foundation /
CoreServices calls — no fork+exec per file, and Foundation encodes Finder tags
and metadata correctly.

It operates only on `(path, id/blob, tag, key, value)` and knows nothing about
any consumer's record model, so it is reusable: an `id → bookmark → file`
resolver, a persistent-link scheme, or just a faster, batched, consolidated
`bookmark` + `tag` + `xattr` + `mdfind`. fileregister is the first consumer,
not the owner.

> macOS only for now. The wire protocol is deliberately OS-neutral — no
> `kMDItem*` names, no `#S`, no Spotlight syntax on the wire — so a Linux
> implementation of the same contract (inode/hash resolution, `user.*` xattrs, a
> locate index) can live in this repo later. Platform is an implementation
> detail, not part of the name.

## Protocol

Batch, line-oriented, order-preserving. One JSON object per line on stdin;
one JSON object per line on stdout, in input order. A failed op returns
`{"ok":false,"error":"…"}` for that line and does not halt the stream. The
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
| `resolve` | `blob` | `{ok, path[, stale]}`; empty/unresolvable → `{ok:false}` |
| `tag` / `untag` | `path`, `value` | `{ok, action: added\|removed\|noop}` |
| `tags` | `path` | `{ok, tags:[…]}` — names only, color suffix stripped |
| `set_meta` | `path`, `key`, `value`, `mode` | `{ok, action: added\|removed\|set\|noop}` |
| `get_meta` | `path`, `key` | `{ok, value}` (sync/comment) or `{ok, values:[…]}` (groups/id) |
| `query` | `by`, `value` | `{ok, paths:[…]}` — Spotlight lookup |

- **`key`** ∈ `groups` \| `id` \| `sync` \| `comment`. `groups` is a real array
  (one element per value); `id` is space-separated multi-valued; `sync` is
  single-valued; `comment` is a single string stored as the binary-plist the
  Finder comment (`kMDItemFinderComment`) uses.
- **`mode`** (set_meta) ∈ `add` \| `remove` \| `set`. For the multi-valued keys
  (`groups`, `id`) `add`/`remove` are idempotent element ops and `set` replaces
  the whole value; for the single-valued `sync`/`comment` `add`/`set` write
  idempotently and `remove` (or an empty `set`) deletes. Defaults to `add`.
- **`by`** (query) ∈ `tag` \| `groups` \| `id` \| `filename` — a *selector*,
  not a Spotlight key. The macOS backend maps each to the right `kMDItem*` key
  (note the verified asymmetry: tags are written under `_kMDItemUserTags` but
  queried under `kMDItemUserTags`).
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
{"ok":true,"value":null}
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

SwiftPM, arm64, macOS 13+:

```
swift build -c release        # binary at .build/release/fileanchor
swift test                    # XCTest suite (needs Xcode; passes empty on CLT-only)
python3 scripts/smoke.py      # live wire-protocol smoke against the built binary
```

On macOS < 26 the `URLResourceValues.tagNames` setter is unavailable, so tag
writes go through `PropertyListSerialization` to the same canonical
`_kMDItemUserTags` key; on macOS 26+ the native setter is used. Reads always use
the `tagNames` getter.

### Vendoring

The binary is built and vendored into a consumer's `vendor/`, mirroring how
`bookmark` is vendored in fileregister. Resolution order there is
`$FILEANCHOR` > `PATH` > `vendor/`. A ZIP-downloaded binary carries a Gatekeeper
quarantine flag — clear it with `xattr -d com.apple.quarantine fileanchor`.

## Design decisions

- **Name.** `fileanchor` — neutral, reusable, not consumer-bound. A *new*
  consolidated surface, not a drop-in `bookmark` replacement.
- **Own repo.** It is a reusable tool with potentially several consumers, so it
  lives independently and is vendored into each, rather than as a subdir of any
  one consumer.
- **`query` is OS-neutral and minimal.** It names selectors, not Spotlight keys,
  and uses the synchronous `MDQuery` C API (no `NSMetadataQuery` runloop). It is
  the *recovery* path — a consumer's own index answers most enumeration;
  Spotlight results are subject to indexing latency.
- **Stateless about the id↔blob map.** The engine does `save`/`resolve` only; the
  consumer owns the id→blob store.
