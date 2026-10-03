#!/usr/bin/env python3
"""Conformance test for a fileanchor engine, driving the real binary over the
stdio protocol against the actual filesystem.

Everything not marked macOS is the contract (SPEC.md, PLATFORMS.md): an engine
for another OS must pass it unchanged. The macOS checks pin down where this
engine stores things (_kMDItemUserTags, the #S name, the binary-plist comment,
blobs from the `bookmark` CLI) and are skipped elsewhere.

Run: python3 scripts/smoke.py [path-to-binary]
Runs every check, then exits non-zero if any failed.
"""
import json, os, shutil, subprocess, sys, tempfile, unicodedata

MACOS = sys.platform == "darwin"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "debug", "fileanchor")
SYNC_NAME = "com.fileregister.id#S"

fails = 0
def check(cond, label):
    global fails
    mark = "ok  " if cond else "FAIL"
    if not cond: fails += 1
    print(f"  [{mark}] {label}")

def skip(label):
    print(f"  [skip] {label}")

def run_batch(requests):
    """Send a list of request dicts, return the list of response dicts (in order)."""
    payload = "".join(json.dumps(r) + "\n" for r in requests)
    proc = subprocess.run([BINARY, "--sync-name", SYNC_NAME],
                          input=payload, capture_output=True, text=True)
    lines = [l for l in proc.stdout.splitlines() if l.strip()]
    return [json.loads(l) for l in lines]

def xattr_names(path):
    out = subprocess.run(["xattr", path], capture_output=True, text=True).stdout
    return set(l.strip() for l in out.splitlines() if l.strip())

print(f"binary: {BINARY}")
if not os.path.exists(BINARY):
    print("binary not built — run `swift build` first"); sys.exit(2)

tmp = tempfile.mkdtemp(prefix="fileanchor-smoke-")
f = os.path.join(tmp, "sample.txt")
with open(f, "w") as fh: fh.write("hello")

print("\n# bookmark save → resolve round-trip")
resp = run_batch([{"op": "save", "path": f}])
check(resp[0].get("ok") and resp[0].get("blob"), "save returns a blob")
blob = resp[0].get("blob", "")
resp = run_batch([{"op": "resolve", "blob": blob}])
check(resp[0].get("ok"), "resolve ok")
check(os.path.realpath(resp[0].get("path", "")) == os.path.realpath(f), "resolve returns the original path")

print("\n# batch resolve preserves order, empty blob → negative")
resp = run_batch([
    {"op": "resolve", "blob": blob},
    {"op": "resolve", "blob": ""},
    {"op": "resolve", "blob": blob},
])
check(len(resp) == 3, "three responses for three requests")
check(resp[0].get("ok") and not resp[1].get("ok") and resp[2].get("ok"),
      "order preserved: ok, negative, ok")

print("\n# an unresolvable blob names the path it recorded")
gone = os.path.join(tmp, "gone.txt")
with open(gone, "w") as fh: fh.write("x")
gblob = run_batch([{"op": "save", "path": gone}])[0].get("blob", "")
os.remove(gone)
resp = run_batch([{"op": "resolve", "blob": gblob}])
check(not resp[0].get("ok") and os.path.basename(resp[0].get("last_path", "")) == "gone.txt",
      "resolve → ok:false with last_path")

print("\n# macOS: a blob from ttscoff's `bookmark` CLI is resolvable (migration-safe)")
legacy = os.environ.get("BOOKMARK") or shutil.which("bookmark")
if not MACOS:
    skip("macOS only")
elif legacy:
    vblob = subprocess.run([legacy, "save", f], capture_output=True, text=True).stdout.strip()
    resp = run_batch([{"op": "resolve", "blob": vblob}])
    check(resp[0].get("ok") and os.path.realpath(resp[0].get("path","")) == os.path.realpath(f),
          f"fileanchor resolves a blob made by {legacy}")
else:
    skip("no `bookmark` on PATH (or $BOOKMARK)")

print("\n# tags: ★ marker + umlaut, idempotent")
resp = run_batch([
    {"op": "tag", "path": f, "value": "★"},
    {"op": "tag", "path": f, "value": "★"},
    {"op": "tag", "path": f, "value": "Geschäft"},
    {"op": "tags", "path": f},
])
check(resp[0].get("action") == "added", "★ added")
check(resp[1].get("action") == "noop", "★ re-add is noop")
check(resp[2].get("action") == "added", "umlaut tag added")
check(set(resp[3].get("tags", [])) == {"★", "Geschäft"}, "tags lists ★ and Geschäft cleanly")
if MACOS:
    check("com.apple.metadata:_kMDItemUserTags" in xattr_names(f),
          "macOS: stored under the canonical _kMDItemUserTags key (with underscore)")
if MACOS:
    # A tag's color is stored with it ("name\n<index>"); adding or removing
    # another tag must not touch it.
    import plistlib
    c = os.path.join(tmp, "color.txt")
    open(c, "w").close()
    key = "com.apple.metadata:_kMDItemUserTags"
    subprocess.run(["xattr", "-wx", key, plistlib.dumps(["Rot\n6"], fmt=plistlib.FMT_BINARY).hex(), c], check=True)
    run_batch([{"op": "tag", "path": c, "value": "Neu"}, {"op": "untag", "path": c, "value": "Neu"}])
    h = subprocess.run(["xattr", "-px", key, c], capture_output=True, text=True).stdout
    check(plistlib.loads(bytes.fromhex(h.replace(" ", "").replace("\n", ""))) == ["Rot\n6"],
          "macOS: tag/untag keeps another tag's color")
resp = run_batch([{"op": "untag", "path": f, "value": "★"}, {"op": "tags", "path": f}])
check(resp[0].get("action") == "removed", "★ removed")
check(resp[1].get("tags") == ["Geschäft"], "only umlaut tag remains")

print("\n# groups: array add/remove")
resp = run_batch([
    {"op": "set_meta", "path": f, "key": "groups", "value": "alpha", "mode": "add"},
    {"op": "set_meta", "path": f, "key": "groups", "value": "beta", "mode": "add"},
    {"op": "set_meta", "path": f, "key": "groups", "value": "alpha", "mode": "add"},
    {"op": "get_meta", "path": f, "key": "groups"},
])
check(resp[2].get("action") == "noop", "duplicate group is noop")
check(resp[3].get("values") == ["alpha", "beta"], "groups keeps both values in order")

print("\n# id: multi-value (bookmark-id cache)")
resp = run_batch([
    {"op": "set_meta", "path": f, "key": "id", "value": "111", "mode": "add"},
    {"op": "set_meta", "path": f, "key": "id", "value": "222", "mode": "add"},
    {"op": "get_meta", "path": f, "key": "id"},
])
check(resp[2].get("values") == ["111", "222"], "id multi-value preserved")

print("\n# sync: single-valued")
resp = run_batch([
    {"op": "set_meta", "path": f, "key": "sync", "value": "789", "mode": "set"},
    {"op": "set_meta", "path": f, "key": "sync", "value": "789", "mode": "set"},
    {"op": "get_meta", "path": f, "key": "sync"},
    {"op": "set_meta", "path": f, "key": "sync", "value": "999", "mode": "set"},
    {"op": "get_meta", "path": f, "key": "sync"},
])
check(resp[0].get("action") == "set", "sync set")
check(resp[1].get("action") == "noop", "sync re-set is noop")
check(resp[2].get("value") == "789", "sync reads back")
check(resp[3].get("action") == "set", "sync overwrite to a new value")
check(resp[4].get("value") == "999", "sync reads back the overwritten value")
if MACOS:
    names = xattr_names(f)
    check(SYNC_NAME in names, "macOS: stored name carries the #S suffix")
    check(SYNC_NAME.split("#")[0] not in names, "macOS: the base name (no #S) is absent")

print("\n# an empty set deletes; whitespace in an id token is refused; a missing file errors")
resp = run_batch([
    {"op": "set_meta", "path": f, "key": "sync", "value": "", "mode": "set"},
    {"op": "set_meta", "path": f, "key": "sync", "value": "", "mode": "set"},
    {"op": "set_meta", "path": f, "key": "id", "value": "a b", "mode": "add"},
    {"op": "get_meta", "path": os.path.join(tmp, "gone.txt"), "key": "groups"},
    {"op": "get_meta", "path": f, "key": "sync"},
])
check(resp[0].get("action") == "removed", "empty sync set removes it")
check(resp[1].get("action") == "noop", "and again is a noop")
check(resp[4].get("ok") and "value" not in resp[4], "and it reads back as absent")
if MACOS:
    check(SYNC_NAME not in xattr_names(f), "macOS: no empty #S attribute left behind")
check(not resp[2].get("ok"), "id token with a space is refused")
check(not resp[3].get("ok") and "no such file" in resp[3].get("error", ""),
      "missing file → ok:false, not empty metadata")

print("\n# value rules: strict on write, stored NFC (PLATFORMS.md)")
g = os.path.join(tmp, "rules.txt")
with open(g, "w") as fh: fh.write("rules")
nfd = unicodedata.normalize("NFD", "Übersicht")
resp = run_batch([
    {"op": "tag", "path": g, "value": "Müller, Hans"},
    {"op": "tag", "path": g, "value": "work "},
    {"op": "set_meta", "path": g, "key": "groups", "value": "a,b", "mode": "add"},
    {"op": "set_meta", "path": g, "key": "sync", "value": "1 2", "mode": "set"},
    {"op": "set_meta", "path": g, "key": "comment", "value": "c" * 1025, "mode": "set"},
    {"op": "tag", "path": g, "value": nfd},
    {"op": "tags", "path": g},
    {"op": "set_meta", "path": g, "key": "comment", "value": "Rechnung\n", "mode": "set"},
    {"op": "get_meta", "path": g, "key": "comment"},
])
check(not resp[0].get("ok"), "a tag with a comma is refused")
check(not resp[1].get("ok"), "a tag with trailing whitespace is refused")
check(not resp[2].get("ok"), "a group with a comma is refused")
check(not resp[3].get("ok"), "a sync id with a space is refused")
check(not resp[4].get("ok"), "a comment over 1 KiB is refused")
check(resp[5].get("action") == "added" and "Übersicht" in resp[6].get("tags", [])
      and nfd not in resp[6].get("tags", []), "an NFD tag is stored and read back NFC")
check(resp[8].get("value") == "Rechnung\n", "a comment keeps its newline")

print("\n# comment: single string, idempotent, clears on empty")
resp = run_batch([
    {"op": "get_meta", "path": f, "key": "comment"},
    {"op": "set_meta", "path": f, "key": "comment", "value": "Original im Schließfach", "mode": "set"},
    {"op": "set_meta", "path": f, "key": "comment", "value": "Original im Schließfach", "mode": "set"},
    {"op": "get_meta", "path": f, "key": "comment"},
    {"op": "set_meta", "path": f, "key": "comment", "value": "", "mode": "set"},
    {"op": "get_meta", "path": f, "key": "comment"},
])
check(resp[0].get("ok") and resp[0].get("value") is None, "absent comment reads back empty")
check(resp[1].get("action") == "set", "comment set")
check(resp[2].get("action") == "noop", "re-set same comment is noop")
check(resp[3].get("value") == "Original im Schließfach", "comment reads back")
check(resp[4].get("action") == "removed", "empty value clears the comment")
check(resp[5].get("value") is None, "cleared comment reads back empty")
# macOS: the on-disk encoding is the binary-plist <string> Finder/backups use.
if MACOS:
    run_batch([{"op": "set_meta", "path": f, "key": "comment", "value": "Beleg 2026", "mode": "set"}])
    hexed = subprocess.run(["xattr", "-px", "com.apple.metadata:kMDItemFinderComment", f],
                           capture_output=True, text=True).stdout
    raw = bytes.fromhex(hexed.replace(" ", "").replace("\n", ""))
    decoded = subprocess.run(["plutil", "-convert", "raw", "-o", "-", "--", "-"],
                             input=raw, capture_output=True).stdout.decode("utf-8").rstrip("\n")
    check(decoded == "Beleg 2026", "macOS: comment is a binary-plist string (plutil round-trips it)")
# Umlauts must round-trip precomposed (NFC). Finder re-exports the xattr in NFD
# whenever it takes a comment; the engine normalizes reads. ß alone won't catch
# this (it has no decomposition), so test real umlauts.
resp = run_batch([
    {"op": "set_meta", "path": f, "key": "comment", "value": "Geschäftsbeleg äöü", "mode": "set"},
    {"op": "get_meta", "path": f, "key": "comment"},
])
value = resp[1].get("value") or ""
check(value == "Geschäftsbeleg äöü" and unicodedata.is_normalized("NFC", value),
      "umlaut comment reads back NFC-precomposed")

print("\n# soft errors never halt the batch")
resp = run_batch([
    {"op": "frobnicate"},
    {"op": "tags", "path": f},
])
check(len(resp) == 2 and not resp[0].get("ok") and resp[1].get("ok"),
      "unknown op → ok:false, next op still runs")

shutil.rmtree(tmp, ignore_errors=True)
print(f"\n{'PASSED' if fails == 0 else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
