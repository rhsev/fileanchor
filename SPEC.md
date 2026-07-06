# fileanchor — spec

A **standalone, reusable** native macOS metadata engine: it gives files durable
identity + metadata, driven over a batch stdio protocol. It performs in-process,
via Foundation/CoreServices, what tools otherwise shell out for — bookmarks,
Finder tags, the `kMDItemProjects`/`kMDItemInformation` xattrs, a syncable
cross-device id, and Spotlight queries — so a caller never pays fork+exec per file, and
Finder tags / property lists are encoded correctly (no hand-rolled binary-plist).

> **Platform.** macOS only for now. The protocol is OS-neutral, so a Linux
> implementation of the *same contract* (inode/hash resolution, `user.*` xattrs,
> a locate index) can live in this repo later — platform is an implementation
> detail, not part of the name.

**The engine knows nothing about any consumer's data model** — it operates only
on `(path, id, tag, key, value)`. The first consumer is
fileregister (file collections), but the engine is reusable by
anything that needs durable file references + metadata: `id → bookmark → file`
resolution, persistent-link / anchor schemes, or a plain CLI (a faster, batched,
consolidated `bookmark` + `tag` + `xattr` + `mdfind`; the `#S`-syncable-xattr
capability alone is rare). Design rule: the *interface* is general, the
*implementation* covers only what a consumer needs — no feature without a caller.

## Why Swift

The operations *are* Apple Foundation/CoreServices APIs: `URL.bookmarkData` /
`URL(resolvingBookmarkData:)`, `URLResourceValues.tagNames` (Finder tags),
`getxattr`/`setxattr`, Spotlight (`NSMetadataQuery` / `MDQuery`). Swift has
first-class, ergonomic access to all of them, so the engine calls the source
rather than wrapping a wrapper.

## Scope

- **In scope:** bookmark save/resolve (batched), Finder tags, the
  `kMDItemProjects` and `kMDItemInformation` xattrs, the Finder comment
  (`kMDItemFinderComment`, a binary-plist string — written through to Finder
  itself via Apple Event, best effort, because Finder never reads that xattr
  back and Get Info would otherwise stay blank), the cross-device `#S` id
  (its name is a parameter — see below), the ★ marker, a Spotlight query.
- **OS-neutral protocol.** Linux is a *future second implementation of the same
  contract* (inode/hash resolution instead of bookmarks, `user.*` xattrs,
  `plocate`/the consumer's index instead of Spotlight). No macOS assumptions leak
  into the wire shape.
- **Not a daemon.** One process invocation handles a batch of operations, then
  exits — but the process is held open by the caller for the duration of a run.

## Verified macOS facts the engine honors

Established empirically (macOS 26.4) — full reference in fileregister's
`FINDINGS-attributes.md`.

1. **Finder tags** are stored under `com.apple.metadata:_kMDItemUserTags` (**with**
   leading underscore). The engine uses `URLResourceValues.tagNames`, which
   reads/writes the correct key and handles the binary-plist array — never the
   no-underscore `kMDItemUserTags` (a write-only dead end).
2. **Spotlight queries** use the key `kMDItemUserTags` (**no** underscore). Write
   `_kMDItemUserTags`, query `kMDItemUserTags`.
3. **Bookmark id** is also cached in `com.apple.metadata:kMDItemInformation`,
   space-separated, **multi-valued**.
4. **Cross-device id.** A custom-namespace, `#S`-flagged xattr whose name
   the caller supplies via `--sync-name` (fileregister passes
   `com.fileregister.id#S`). The `#S` is **part of the stored attribute name** —
   written/read *with* the suffix. Single-valued. It survives iCloud Drive and
   AirDrop; the Apple `com.apple.metadata:kMDItem*` namespace does **not** sync
   even with `#S`. Written via `setxattr` with the literal flagged name.
5. **★ marker** = U+2605, a Finder tag (so via `tagNames`). A status marker the
   consumer manages (fileregister: "managed", written on first membership, removed
   on last). The engine just tags/untags it like any tag.

## The contract (protocol)

Batch, line-oriented, **order-preserving**. One JSON object per input line on
stdin; one JSON object per result line on stdout, in input order. A failed or
unknown op returns `{"ok": false, "error": "..."}` for that line and does **not**
halt the stream. Exit is non-zero only on a fatal protocol error, never on per-op
failure.

| op | input | output |
|---|---|---|
| `save` | `path` | `{ok, blob}` — opaque bookmark blob (base64) |
| `resolve` | `blob` | `{ok, path}` or `{ok:false}` if unresolvable |
| `tag` / `untag` | `path`, `value` | `{ok, action: added\|noop\|removed}` |
| `tags` | `path` | `{ok, tags: [...]}` |
| `set_meta` / `get_meta` | `path`, `key` (`groups`\|`id`\|`sync`\|`comment`), `value` | `{ok, action}` / `{ok, value}` |
| `query` | `by` (`id`\|`filename`\|`groups`\|`tag`), `value` | `{ok, paths: [...]}` |

`query` takes `{by, value}` (not a bare tag) so it covers all of a consumer's
locate strategies while keeping `mdfind`/Spotlight syntax off the wire — which is
also what keeps the protocol OS-neutral for the Linux port.

**Batch resolve is mandatory** — resolving many blobs in one process is the whole
point. Every op is one object per line; blank input → null/empty out, order
preserved.

## Responsibility split

The engine is **stateless about the id↔blob map**: `save(path) → blob`,
`resolve(blob) → path`. The consumer owns the map. (fileregister keeps it in
`~/.local/share/bookmarks.json`; its `Bookmarks`/`Subject`/`Tags`/`Managed`
modules and `LocatorBackend` are thin clients with unchanged signatures, and a
`FileAnchor` client holds one engine process open for the run.)

## Implementation notes / traps

- **`NSMetadataQuery` is async/runloop-based.** A naive synchronous call in a CLI
  returns nothing; either drive the runloop to the gathering-finished
  notification, use the synchronous `MDQuery` C API, or keep `query` minimal —
  consumers with their own index (like fileregister) treat Spotlight as a *recovery*
  path, not the primary enumerator.
- **Bookmark staleness.** Handle `bookmarkDataIsStale` on resolve (regenerate the
  blob). Plain (non security-scoped) bookmarks — move-resilient references, not
  sandbox access.
- **`#S` xattr naming.** The flag is part of the name; pass the literal
  `…#S` name to `setxattr`/`getxattr`.
- **Encoding.** Foundation hands back `String`; if reading raw xattr bytes
  anywhere, treat them as UTF-8 explicitly.

## Decisions (resolved)

- **Name:** `fileanchor` (working title, renameable).
- **Own repo**, vendored into each consumer. fileregister vendors it at
  `vendor/fileanchor` with resolution `$FILEANCHOR` > `PATH` > vendored.
- **Build/dist:** SwiftPM, arm64. Gatekeeper/quarantine note for ZIP downloads
  (`xattr -d com.apple.quarantine …`) in the README.

## Tests

- XCTest suite (`Tests/FileAnchorKitTests`): tag round-trip (★ = U+2605 + an
  umlaut tag), bookmark save→resolve, `set_meta`/`get_meta` for all four keys
  (incl. the `comment` binary-plist string), the `#S` sync-xattr round-trip
  (asserts the stored name carries `#S`), multi-value `kMDItemInformation`.
  Requires full Xcode (`xctest`) to run.
- `scripts/smoke.py` drives the **real binary** over the protocol and verifies the
  same facts against the filesystem — the path a Command-Line-Tools-only machine
  can use (no `xctest`). Run: `python3 scripts/smoke.py [binary]`.

## Conformance

1. One binary performs all ops over the batch stdio protocol, order-preserving;
   per-op failures never halt the stream.
2. Finder tags via `tagNames` (no hand-rolled plist); the `#S` sync xattr written/read
   under its flagged name; `kMDItemInformation` multi-value preserved.
3. Batch resolve in a single process.
4. Protocol is OS-neutral (no macOS query syntax on the wire).
5. README documents the protocol, build, and vendoring.

## Reference consumer

fileregister — its `lib/collections_common.rb` (`Bookmarks`,
`Subject`, `Tags`, `Managed`, `LocatorBackend` → `FileAnchor` client),
`FINDINGS-attributes.md` (verified attributes), and `SPEC.md` §"macOS metadata
layer" show how the engine is used.
