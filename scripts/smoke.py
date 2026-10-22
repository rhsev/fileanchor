#!/usr/bin/env python3
"""Conformance test for a fileanchor engine, driving the real binary over the
stdio protocol against the actual filesystem.

Everything not marked macOS or Linux is the specification (SPEC.md,
PLATFORMS.md): both engines must pass it unchanged. The macOS checks pin down
where that engine stores things (_kMDItemUserTags, the #S name, the
binary-plist comment, blobs from the `bookmark` CLI). The Linux checks cover
what that engine decides for itself: its user.* names, the roots it walks, and
file identity by inode and generation. Each set is skipped on the other system.

Run: python3 scripts/smoke.py [path-to-binary]
Runs every check, then exits non-zero if any failed.
"""
import json, os, shutil, subprocess, sys, tempfile, unicodedata

MACOS = sys.platform == "darwin"
LINUX = sys.platform.startswith("linux")

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

# The Linux engine searches only its roots (PLATFORMS.md). The checks run
# with the temp dir as the one root, unless a check sets its own.
ROOTS_ENV = {}

def run_batch(requests, env=None):
    """Send a list of request dicts, return the list of response dicts (in order)."""
    payload = "".join(json.dumps(r) + "\n" for r in requests)
    full_env = {**os.environ, **ROOTS_ENV, **(env or {})}
    full_env = {k: v for k, v in full_env.items() if v is not None}  # None unsets
    proc = subprocess.run([BINARY, "--sync-name", SYNC_NAME],
                          input=payload, capture_output=True, text=True, env=full_env)
    lines = [l for l in proc.stdout.splitlines() if l.strip()]
    return [json.loads(l) for l in lines]

def xattr_names(path):
    out = subprocess.run(["xattr", path], capture_output=True, text=True).stdout
    return set(l.strip() for l in out.splitlines() if l.strip())

print(f"binary: {BINARY}")
if not os.path.exists(BINARY):
    print("binary not built — run `swift build` first"); sys.exit(2)

tmp = os.path.realpath(tempfile.mkdtemp(prefix="fileanchor-smoke-"))
if LINUX:
    ROOTS_ENV["FILEANCHOR_ROOTS"] = tmp
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

print("\n# resolve returns the path in the bytes the file system holds")
# A name can be stored precomposed (NFC) or decomposed (NFD), and a directory
# and the file in it can differ. macOS hands a resolved bookmark back with every
# name decomposed, whatever the volume holds; on Linux the two forms are even
# two different files. The engine returns what is on disk, compared byte for
# byte against the directory listing.
forms = os.path.join(tmp, unicodedata.normalize("NFC", "Verträge"))
os.mkdir(forms)
for name in (unicodedata.normalize("NFC", "Pässe-nfc.md"), unicodedata.normalize("NFD", "Pässe-nfd.md")):
    p = os.path.join(forms, name)
    with open(p, "w") as fh: fh.write("x")
    b = run_batch([{"op": "save", "path": p}])[0].get("blob", "")
    got = run_batch([{"op": "resolve", "blob": b}])[0].get("path", "")
    listed = [e for e in os.listdir(forms) if unicodedata.normalize("NFC", e) == unicodedata.normalize("NFC", name)]
    # The folder is compared with the listing too: an SMB mount on macOS lists
    # every name decomposed, whatever form it was created in.
    folder = [e for e in os.listdir(tmp) if unicodedata.normalize("NFC", e) == unicodedata.normalize("NFC", os.path.basename(forms))]
    want = (folder[0] if folder else None, listed[0] if listed else None)
    have = (os.path.basename(os.path.dirname(got)), os.path.basename(got))
    form = "NFC" if name == unicodedata.normalize("NFC", name) else "NFD"
    check(want[1] is not None and have == want, f"{form} file in an NFC directory resolves byte for byte")

print("\n# searchable answers for a place, also one whose file is gone")
resp = run_batch([
    {"op": "searchable", "path": tmp},
    {"op": "searchable", "path": os.path.join(tmp, "no-such-dir", "gone.pdf")},
    {"op": "searchable"},
])
check(resp[0].get("ok") and isinstance(resp[0].get("searchable"), bool), "searchable answers yes or no for a directory")
check(resp[1].get("ok") and resp[1].get("searchable") == resp[0].get("searchable"),
      "a path that does not exist gets the answer of the place it was in")
check(not resp[2].get("ok"), "searchable without a path → ok:false")
if not MACOS:
    resp = run_batch([{"op": "searchable", "path": tmp}], env={"FILEANCHOR_ROOTS": ""})
    check(resp[0].get("searchable") is False, "an engine with no configured roots searches nowhere completely")

print("\n# a renamed or moved file still resolves, marked stale")
m = os.path.join(tmp, "moving.txt")
with open(m, "w") as fh: fh.write("m")
mblob = run_batch([{"op": "save", "path": m}])[0].get("blob", "")
renamed = os.path.join(tmp, "moved-name.txt")
os.rename(m, renamed)
resp = run_batch([{"op": "resolve", "blob": mblob}])
check(resp[0].get("ok") and resp[0].get("path") == renamed and resp[0].get("stale") is True,
      "renamed in its folder → new path, stale")
os.makedirs(os.path.join(tmp, "deeper", "still"))
deep = os.path.join(tmp, "deeper", "still", "moved-name.txt")
os.rename(renamed, deep)
resp = run_batch([{"op": "resolve", "blob": mblob}])
check(resp[0].get("ok") and resp[0].get("path") == deep and resp[0].get("stale") is True,
      "moved into another folder → new path, stale")
resp = run_batch([{"op": "resolve", "blob": run_batch([{"op": "save", "path": deep}])[0].get("blob", "")}])
check(resp[0].get("ok") and "stale" not in resp[0], "a file where it was saved is not stale")
# An editor that saves by renaming a new file over the old one leaves a new
# file in the old place; when the saved file is nowhere, that is the answer.
saved = os.path.join(tmp, "edited.txt")
with open(saved, "w") as fh: fh.write("v1")
sblob = run_batch([{"op": "save", "path": saved}])[0].get("blob", "")
with open(saved + ".tmp", "w") as fh: fh.write("v2")
os.rename(saved + ".tmp", saved)
resp = run_batch([{"op": "resolve", "blob": sblob}])
check(resp[0].get("ok") and resp[0].get("path") == saved and resp[0].get("stale") is True,
      "a file saved over by rename resolves at its path, stale")

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

print("\n# Linux: where values live, the roots, the walk, file identity")
if not LINUX:
    skip("Linux only")
else:
    L = os.path.join(tmp, "linux")
    os.mkdir(L)
    lf = os.path.join(L, "Bericht.txt")
    with open(lf, "w") as fh: fh.write("b")
    resp = run_batch([
        {"op": "tag", "path": lf, "value": unicodedata.normalize("NFD", "Geschäftsbericht")},
        {"op": "tag", "path": lf, "value": "★"},
        {"op": "set_meta", "path": lf, "key": "groups", "value": "linux-alpha", "mode": "add"},
        {"op": "set_meta", "path": lf, "key": "id", "value": "4711", "mode": "add"},
        {"op": "set_meta", "path": lf, "key": "id", "value": "4712", "mode": "add"},
        {"op": "set_meta", "path": lf, "key": "sync", "value": "4711", "mode": "set"},
        {"op": "set_meta", "path": lf, "key": "comment", "value": "Notiz", "mode": "set"},
    ])
    check(all(r.get("ok") for r in resp), "Linux: all writes succeed on this file system")
    def attr(name):
        try: return os.getxattr(lf, name)
        except OSError: return None
    check(attr("user.xdg.tags") == "Geschäftsbericht,★".encode(), "Linux: tags in user.xdg.tags, comma-separated, NFC")
    check(attr("user.fileanchor.groups") == b"linux-alpha", "Linux: groups in user.fileanchor.groups")
    check(attr("user.fileanchor.id") == b"4711 4712", "Linux: id in user.fileanchor.id, space-separated")
    check(attr("user.com.fileregister.id") == b"4711", "Linux: sync under user. without the #S flag")
    check(attr("user.xdg.comment") == b"Notiz", "Linux: comment in user.xdg.comment, plain")
    check(not any("#" in n for n in os.listxattr(lf)), "Linux: no attribute name carries #")
    other = os.path.join(L, "dolphin.txt")
    with open(other, "w") as fh: fh.write("d")
    os.setxattr(other, "user.xdg.tags", "rot, grün".encode())
    resp = run_batch([{"op": "tags", "path": other}])
    check(resp[0].get("tags") == ["rot", "grün"], "Linux: a list another tool wrote as 'a, b' reads back clean")

    resp = run_batch([
        {"op": "query", "by": "id", "value": "4711"},
        {"op": "query", "by": "id", "value": "471"},
        {"op": "query", "by": "tag", "value": "Geschäftsbericht"},
        {"op": "query", "by": "groups", "value": "linux-alpha"},
        {"op": "query", "by": "filename", "value": "Bericht.txt"},
    ])
    check(resp[0].get("paths") == [lf], "Linux: query by id finds the file under a root")
    check(resp[1].get("paths") == [], "Linux: query by id matches whole tokens only")
    check(resp[2].get("paths") == [lf], "Linux: query by tag")
    check(resp[3].get("paths") == [lf], "Linux: query by groups")
    check(resp[4].get("paths") == [lf], "Linux: query by filename")
    resp = run_batch([
        {"op": "set_meta", "path": other, "key": "id", "value": "4711", "mode": "add"},
        {"op": "query", "by": "id", "value": "4711"},
    ])
    check(resp[1].get("paths") == sorted([lf, other]), "Linux: a query sees the engine's own writes from earlier in the batch")

    hid = os.path.join(tmp, ".versteckt")
    os.mkdir(hid)
    hf = os.path.join(hid, "x.txt")
    with open(hf, "w") as fh: fh.write("h")
    os.setxattr(hf, "user.fileanchor.id", b"4800")
    trash = os.path.join(tmp, ".Trash")
    os.mkdir(trash)
    tf = os.path.join(trash, "y.txt")
    with open(tf, "w") as fh: fh.write("t")
    os.setxattr(tf, "user.fileanchor.id", b"4801")
    resp = run_batch([
        {"op": "query", "by": "id", "value": "4800"},
        {"op": "searchable", "path": hf},
        {"op": "searchable", "path": os.path.join(hid, "gone", "z.txt")},
        {"op": "query", "by": "id", "value": "4801"},
        {"op": "searchable", "path": tf},
    ])
    check(resp[0].get("paths") == [] and resp[1].get("searchable") is False and resp[2].get("searchable") is False,
          "Linux: a dot directory is neither walked nor searchable")
    check(resp[3].get("paths") == [tf] and resp[4].get("searchable") is True,
          "Linux: .Trash is walked and searchable")
    tz = os.path.join(L, "papierkorb.txt")
    with open(tz, "w") as fh: fh.write("z")
    zblob = run_batch([{"op": "save", "path": tz}])[0].get("blob", "")
    os.rename(tz, os.path.join(trash, "papierkorb.txt"))
    resp = run_batch([{"op": "resolve", "blob": zblob}])
    check(resp[0].get("path") == os.path.join(trash, "papierkorb.txt") and resp[0].get("stale") is True,
          "Linux: resolve follows a file into the Trash")
    resp = run_batch([{"op": "resolve", "blob": zblob}], env={"FILEANCHOR_ROOTS": ""})
    check(not resp[0].get("ok") and resp[0].get("last_path") == tz,
          "Linux: with no roots a file moved out of its folder is not found")

    # ext4 gives a freed inode to the next new file at once; only the
    # generation number tells the two apart.
    r = os.path.join(L, "reuse.txt")
    with open(r, "w") as fh: fh.write("1")
    rblob = run_batch([{"op": "save", "path": r}])[0].get("blob", "")
    first = os.stat(r).st_ino
    os.remove(r)
    other_new = os.path.join(L, "reuse-new.txt")
    with open(other_new, "w") as fh: fh.write("2")
    resp = run_batch([{"op": "resolve", "blob": rblob}])
    same = " (it got the same inode number)" if os.stat(other_new).st_ino == first else ""
    check(not resp[0].get("ok") and resp[0].get("last_path") == r,
          "Linux: a new file under another name is not taken for a deleted one" + same)

    cfg = tempfile.mkdtemp(prefix="fileanchor-cfg-")
    os.makedirs(os.path.join(cfg, "fileanchor"))
    with open(os.path.join(cfg, "fileanchor", "roots"), "w") as fh:
        fh.write(f"# the test folder only\n\n{L}\n")
    from_file = {"FILEANCHOR_ROOTS": None, "XDG_CONFIG_HOME": cfg}
    resp = run_batch([{"op": "searchable", "path": L}, {"op": "searchable", "path": tmp}], env=from_file)
    check(resp[0].get("searchable") is True and resp[1].get("searchable") is False,
          "Linux: roots come from $XDG_CONFIG_HOME/fileanchor/roots")
    empty_cfg = tempfile.mkdtemp(prefix="fileanchor-cfg-")
    by_home = {"FILEANCHOR_ROOTS": None, "XDG_CONFIG_HOME": empty_cfg, "HOME": L, "XDG_DATA_HOME": None}
    resp = run_batch([{"op": "searchable", "path": lf}, {"op": "searchable", "path": tmp}], env=by_home)
    check(resp[0].get("searchable") is True and resp[1].get("searchable") is False,
          "Linux: without a roots file $HOME is the root")
    shutil.rmtree(cfg, ignore_errors=True)
    shutil.rmtree(empty_cfg, ignore_errors=True)

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
