#!/usr/bin/env python3
"""Live smoke test for fileanchor, driving the real binary over the stdio
protocol. Verifies the wire contract end to end plus the hard-won macOS facts
(★ U+2605, umlaut tag, the #S sync name, multi-value id) against the
actual filesystem — the parts a CLT-only machine can't reach via XCTest.

Run: python3 scripts/smoke.py [path-to-binary]
Exits non-zero on the first failure.
"""
import json, os, subprocess, sys, tempfile, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "debug", "fileanchor")
SYNC_NAME = "com.markbinder.id#S"

fails = 0
def check(cond, label):
    global fails
    mark = "ok  " if cond else "FAIL"
    if not cond: fails += 1
    print(f"  [{mark}] {label}")

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

print("\n# vendored bookmark blob is resolvable (migration-safe)")
vendored = os.path.join(os.path.dirname(ROOT), "markbinder", "vendor", "bookmark")
if os.path.exists(vendored):
    vblob = subprocess.run([vendored, "save", f], capture_output=True, text=True).stdout.strip()
    resp = run_batch([{"op": "resolve", "blob": vblob}])
    check(resp[0].get("ok") and os.path.realpath(resp[0].get("path","")) == os.path.realpath(f),
          "fileanchor resolves a blob made by the vendored `bookmark`")
else:
    print(f"  [skip] vendored bookmark not found at {vendored}")

print("\n# Finder tags: ★ marker + umlaut, idempotent")
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
check("com.apple.metadata:_kMDItemUserTags" in xattr_names(f),
      "stored under the canonical _kMDItemUserTags key (with underscore)")
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

print("\n# sync: the #S syncable name is stored literally, single-valued")
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
names = xattr_names(f)
check(SYNC_NAME in names, "stored name carries the #S suffix")
check(SYNC_NAME.split("#")[0] not in names, "the base name (no #S) is absent")

print("\n# comment: single string, binary-plist encoded, idempotent, clears on empty")
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
# Cross-check the on-disk encoding is the binary-plist <string> Finder/backups use.
run_batch([{"op": "set_meta", "path": f, "key": "comment", "value": "Beleg 2026", "mode": "set"}])
hexed = subprocess.run(["xattr", "-px", "com.apple.metadata:kMDItemFinderComment", f],
                       capture_output=True, text=True).stdout
raw = bytes.fromhex(hexed.replace(" ", "").replace("\n", ""))
decoded = subprocess.run(["plutil", "-convert", "raw", "-o", "-", "--", "-"],
                         input=raw, capture_output=True).stdout.decode("utf-8").rstrip("\n")
check(decoded == "Beleg 2026", "comment is a binary-plist string (plutil round-trips it)")
# Umlauts must round-trip precomposed (NFC). Finder re-exports the xattr in NFD
# whenever it takes a comment; the engine normalizes reads. ß alone won't catch
# this (it has no decomposition), so test real umlauts.
resp = run_batch([
    {"op": "set_meta", "path": f, "key": "comment", "value": "Geschäftsbeleg äöü", "mode": "set"},
    {"op": "get_meta", "path": f, "key": "comment"},
])
import unicodedata
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

import shutil; shutil.rmtree(tmp, ignore_errors=True)
print(f"\n{'PASSED' if fails == 0 else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
