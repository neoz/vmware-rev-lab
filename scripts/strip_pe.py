#!/usr/bin/env python3
"""strip_pe.py - anonymize PE files and do same-length string/regex replacement.

Structural stripping (applied to a copy by default):
  * Authenticode signature  - clears the Security data-directory entry and
                              truncates (or zeroes) the certificate table.
  * File properties         - removes the RT_VERSION resource (type 16, the
                              Windows "Details" tab) and zeroes its data blob.
  * Manifest                - removes the RT_MANIFEST resource (type 24, the
                              embedded assembly manifest) and zeroes its blob.
  * Rich header             - zeroes the toolchain fingerprint block.
  * COFF timestamp          - zeroes the build time.
  * OptionalHeader CheckSum - zeroes the checksum.

Generic string replacement (never changes the file length, so the PE stays
valid):
  * literal / regex rules, explicit via config or CLI;
  * mask rules ("mask": true) that overwrite each match with a repeated
    character - safe even for variable-length regex matches;
  * auto_identity - reads the PE's own VS_VERSIONINFO fields (CompanyName,
    ProductName, LegalCopyright, ...) and neutralises those values;
  * heuristics - built-in regexes for urls / emails / winpaths / uncpaths /
    copyright notices.

Config file (JSON) is the convenient way to hold everything:

    {
      "encoding": "auto",
      "pad": "space",
      "mask_char": "X",
      "strip": {"signature": true, "version": true, "manifest": true,
                "rich": true, "timestamp": true},
      "auto_identity": {
        "enabled": true,
        "mode": "template",
        "fields": ["CompanyName", "ProductName", "FileDescription",
                   "LegalCopyright", "LegalTrademarks", "Comments",
                   "OriginalFilename", "InternalName"],
        "identity": {"CompanyName": "Anon Inc.", "ProductName": "Anon Installer"}
      },
      "heuristics": ["url", "email", "winpath", "uncpath", "copyright"],
      "replace": [
        {"type": "literal", "find": "Tonec", "replace": "Vendo"},
        {"type": "regex", "find": "(IDM)([0-9.]+)", "replace": "APP\\\\1"},
        {"type": "regex", "find": "https?://[^\\s]+", "mask": true}
      ]
    }

Usage:
    python strip_pe.py                         # scan dir of this script
    python strip_pe.py path/ --config profile.json
    python strip_pe.py f.exe --auto-version    # mask the version-info fields
    python strip_pe.py f.exe --heuristics all
    python strip_pe.py f.exe --extract > profile.json   # build a profile
    python strip_pe.py f.exe --list            # report matches only

Any replacement longer than its match is skipped; shorter replacements are
padded (spaces by default, NULs with --pad-null). Pure standard library.
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path

DEFAULT_EXTS = (".exe", ".dll", ".sys", ".ocx", ".scr")
DIR_SECURITY = 4
DIR_RESOURCE = 2
RT_VERSION = 16
RT_MANIFEST = 24

DEFAULT_VERSION_FIELDS = (
    "CompanyName", "ProductName", "FileDescription", "LegalCopyright",
    "LegalTrademarks", "Comments", "OriginalFilename", "InternalName",
)

# Built-in heuristics: name -> Python regex (bytes/latin-1). All are applied
# with mask replacement so their variable length stays intact.
HEURISTICS = {
    "url": r"https?://[^\s\"'<>\)\]\x00]+",
    "email": r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}",
    "winpath": r"[A-Za-z]:\\[^\x00\"'<>|\r\n]*",
    "uncpath": r"\\\\[A-Za-z0-9._$\-]+\\[^\x00\"'<>|\r\n]*",
    "copyright": (r"(?i)(?:copyright|\(c\))[\x20-\x7e]{0,80}"
                  r"|\xa9\x00[\x20-\x7e\x00]{0,80}"),
}


class LengthError(Exception):
    """Replacement length does not match the match length."""

    def __init__(self, repl_len: int, match_len: int):
        self.repl_len = repl_len
        self.match_len = match_len
        super().__init__(
            f"replacement is {repl_len} bytes but match is {match_len} bytes"
        )


# --------------------------------------------------------------------------- #
# PE parsing
# --------------------------------------------------------------------------- #
def parse_pe(data) -> dict | None:
    """Return a header description dict, or None if not a supported PE."""
    if len(data) < 0x40 or data[0:2] != b"MZ":
        return None
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if e_lfanew + 24 > len(data) or data[e_lfanew:e_lfanew + 4] != b"PE\x00\x00":
        return None
    coff = e_lfanew + 4
    (machine, nsec, tstamp, sym, nsym, optsz, chars) = struct.unpack_from(
        "<HHIIIHH", data, coff
    )
    opt = coff + 20
    if opt + 2 > len(data):
        return None
    magic = struct.unpack_from("<H", data, opt)[0]
    if magic == 0x20B:  # PE32+
        nrva_off, dd_off = opt + 0x6C, opt + 0x70
    elif magic == 0x10B:  # PE32
        nrva_off, dd_off = opt + 0x5C, opt + 0x60
    else:
        return None
    if nrva_off + 4 > len(data):
        return None
    nrva = struct.unpack_from("<I", data, nrva_off)[0]
    dirs = []
    for i in range(min(nrva, 16)):
        off = dd_off + i * 8
        if off + 8 > len(data):
            dirs.append((0, 0))
        else:
            dirs.append(struct.unpack_from("<II", data, off))

    sh = opt + optsz
    secs = []
    for s in range(nsec):
        o = sh + s * 40
        if o + 40 > len(data):
            break
        name = data[o:o + 8].rstrip(b"\x00")
        vsize, vaddr, rsize, praw = struct.unpack_from("<IIII", data, o + 8)
        secs.append(dict(name=name, va=vaddr, vsize=vsize, raw=praw, rsize=rsize))

    return dict(
        e_lfanew=e_lfanew, coff=coff, machine=machine, nsec=nsec,
        tstamp_off=coff + 4, opt=opt, optsz=optsz, is64=(magic == 0x20B),
        magic=magic, nrva=nrva, dirs=dirs, dd_off=dd_off,
        cksum_off=opt + 0x40, secs=secs,
    )


def rva_to_off(pe: dict, rva: int) -> int | None:
    for s in pe["secs"]:
        span = max(s["vsize"], s["rsize"])
        if s["va"] <= rva < s["va"] + span:
            return s["raw"] + (rva - s["va"])
    return None


# --------------------------------------------------------------------------- #
# Structural stripping
# --------------------------------------------------------------------------- #
def strip_signature(data: bytearray, pe: dict) -> tuple[int, str]:
    """Clear the Authenticode certificate table + entry.  Returns (size, how)."""
    off, size = pe["dirs"][DIR_SECURITY]
    if not size:
        return 0, "none"
    how = ""
    if off + size == len(data):        # cert sits at end of file -> truncate
        del data[off:]
        how = "truncated"
    elif off < len(data):              # otherwise just scrub the bytes
        end = min(off + size, len(data))
        for i in range(off, end):
            data[i] = 0
        how = "zeroed"
    struct.pack_into("<II", data, pe["dd_off"] + DIR_SECURITY * 8, 0, 0)
    return size, how


def _iter_res_leaves(data, pe, base, sub_off):
    """Yield (rva, size) for every data leaf under a resource sub-directory."""
    d = base + sub_off
    if d + 16 > len(data):
        return
    nn, ni = struct.unpack_from("<HH", data, d + 12)
    for j in range(nn + ni):
        e = d + 16 + j * 8
        if e + 8 > len(data):
            return
        _name, off = struct.unpack_from("<II", data, e)
        if off & 0x80000000:
            yield from _iter_res_leaves(data, pe, base, off & 0x7FFFFFFF)
        else:
            de = base + off
            if de + 8 > len(data):
                continue
            rva, size = struct.unpack_from("<II", data, de)
            yield rva, size


def _find_res_type_entry(data, pe, type_id):
    """Return (base, entry_index, entry_offset, count, nn, ni) for a type."""
    rva, size = pe["dirs"][DIR_RESOURCE]
    if not size:
        return None
    base = rva_to_off(pe, rva)
    if base is None or base + 16 > len(data):
        return None
    nn, ni = struct.unpack_from("<HH", data, base + 12)
    count = nn + ni
    for i in range(count):
        e = base + 16 + i * 8
        if e + 8 > len(data):
            break
        name, off = struct.unpack_from("<II", data, e)
        if not (name & 0x80000000) and name == type_id:
            return dict(base=base, index=i, entry=e, count=count, nn=nn, ni=ni)
    return None


def _zero_resource_data(data: bytearray, pe: dict, base: int, sub_off: int) -> int:
    """Recursively zero every data leaf under a resource sub-directory."""
    total = 0
    for rva, size in _iter_res_leaves(data, pe, base, sub_off):
        o = rva_to_off(pe, rva)
        if o is not None:
            end = min(o + size, len(data))
            for k in range(o, end):
                data[k] = 0
            total += end - o
    return total


def strip_resource_type(data: bytearray, pe: dict, type_id: int) -> tuple[bool, int]:
    """Remove a top-level resource type entry and zero all its data blobs.

    Works for RT_VERSION (16), RT_MANIFEST (24), etc.  The entry is spliced out
    of the fixed-size top-level array and the count decremented; offsets inside
    the resource tree are relative to the tree base, so nothing relocates.
    """
    info = _find_res_type_entry(data, pe, type_id)
    if info is None:
        return False, 0
    base, i, e, count, nn, ni = (
        info["base"], info["index"], info["entry"], info["count"], info["nn"], info["ni"]
    )
    off = struct.unpack_from("<I", data, e + 4)[0]
    if not (off & 0x80000000):
        return False, 0
    zeroed = _zero_resource_data(data, pe, base, off & 0x7FFFFFFF)
    ent = base + 16
    array_end = ent + count * 8
    remaining = count - i - 1
    if remaining > 0:
        data[e:e + remaining * 8] = data[e + 8:array_end]
    struct.pack_into("<II", data, ent + (count - 1) * 8, 0, 0)
    struct.pack_into("<HH", data, base + 12, nn, ni - 1)
    return True, zeroed


def strip_rich(data: bytearray, pe: dict) -> int:
    """Zero the Rich header block (toolchain fingerprint). Returns bytes zeroed."""
    end = pe["e_lfanew"]
    ri = data.rfind(b"Rich", 0x40, end)
    if ri < 0 or ri + 8 > len(data):
        return 0
    key = struct.unpack_from("<I", data, ri + 4)[0]
    enc = struct.pack("<I", struct.unpack("<I", b"DanS")[0] ^ key)
    ds = data.rfind(enc, 0x40, ri)
    if ds < 0:
        return 0
    for i in range(ds, ri + 8):
        data[i] = 0
    return ri + 8 - ds


# --------------------------------------------------------------------------- #
# VERSIONINFO parsing
# --------------------------------------------------------------------------- #
def _u16(buf, off):
    return buf[off] | (buf[off + 1] << 8)


def _align4(n):
    return (n + 3) & ~3


def _read_utf16z(buf, off):
    i, n = off, len(buf)
    while i + 1 < n and not (buf[i] == 0 and buf[i + 1] == 0):
        i += 2
    return buf[off:i].decode("utf-16le", "replace"), i + 2


def _parse_version_node(buf, off, parent=None):
    if off + 6 > len(buf):
        return None, len(buf)
    w_length = _u16(buf, off)
    w_value_length = _u16(buf, off + 2)
    w_type = _u16(buf, off + 4)
    key, p = _read_utf16z(buf, off + 6)
    p = _align4(p)
    node = {"key": key, "value": None, "children": []}
    end = off + w_length if w_length else len(buf)
    if end > len(buf):
        end = len(buf)
    # A node is a directory if it is VS_VERSION_INFO / StringFileInfo /
    # VarFileInfo, or a StringTable (whose key is a lang-codepage string such
    # as "040904b0", hence the parent test).
    is_container = (key in ("VS_VERSION_INFO", "StringFileInfo", "VarFileInfo")
                    or parent == "StringFileInfo")
    if key == "VS_VERSION_INFO":
        p += w_value_length          # skip VS_FIXEDFILEINFO
        p = _align4(p)
    if is_container:
        while p + 6 <= end:
            child, nxt = _parse_version_node(buf, p, key)
            if child is None or nxt <= p:
                break
            node["children"].append(child)
            p = nxt
    else:
        if w_type == 1 and w_value_length:
            val, _ = _read_utf16z(buf, p)
            node["value"] = val
    return node, _align4(end)


def parse_version_fields(data, pe) -> dict:
    """Return {field: value} from the PE's VS_VERSIONINFO resources."""
    info = _find_res_type_entry(data, pe, RT_VERSION)
    fields: dict[str, str] = {}
    if info is None:
        return fields
    off = struct.unpack_from("<I", data, info["entry"] + 4)[0]
    if not (off & 0x80000000):
        return fields
    for rva, size in _iter_res_leaves(data, pe, info["base"], off & 0x7FFFFFFF):
        o = rva_to_off(pe, rva)
        if o is None:
            continue
        blob = bytes(data[o:o + size])
        root, _ = _parse_version_node(blob, 0)

        def walk(n):
            if n is None:
                return
            if n["value"] and n["key"] not in ("VS_VERSION_INFO",):
                fields[n["key"]] = n["value"]
            for c in n["children"]:
                walk(c)

        walk(root)
    return fields


# --------------------------------------------------------------------------- #
# Search / replace (same length only)
# --------------------------------------------------------------------------- #
def _encodings(kind: str, enc: str) -> list[str]:
    if enc == "auto":
        return ["latin-1", "utf-16le"] if kind == "literal" else ["latin-1"]
    if enc == "ascii":
        return ["latin-1"]
    if enc == "utf16le":
        return ["utf-16le"]
    return ["latin-1"]


def _mask_bytes(mask_char: str, enc: str, nbytes: int) -> bytes:
    try:
        mb = mask_char.encode(enc)
    except UnicodeError:
        mb = b" "
    if not mb:
        mb = b" "
    return (mb * (nbytes // len(mb) + 1))[:nbytes]


def apply_literal(data: bytearray, find: str, repl: str, enc: str, pad: int,
                  mask_char: str | None = None) -> int:
    total = 0
    for e in _encodings("literal", enc):
        try:
            fb = find.encode(e)
        except UnicodeError:
            continue
        if mask_char is not None:
            rb = _mask_bytes(mask_char, e, len(fb))
        else:
            try:
                rb = repl.encode(e)
            except UnicodeError:
                continue
            if len(rb) > len(fb):
                raise LengthError(len(rb), len(fb))
            if len(rb) < len(fb):
                rb = rb + bytes([pad]) * (len(fb) - len(rb))
        start = 0
        while True:
            i = data.find(fb, start)
            if i < 0:
                break
            data[i:i + len(fb)] = rb
            total += 1
            start = i + len(fb)
    return total


def apply_regex(data: bytearray, pattern: str, repl: str, enc: str, pad: int,
                mask_char: str | None = None) -> int:
    if enc == "utf16le":
        raise ValueError("regex rules do not support utf-16le; use a literal rule")
    try:
        rx = re.compile(pattern.encode("latin-1"))
        repl_b = repl.encode("latin-1")
    except UnicodeError as ex:
        raise ValueError(f"pattern/replacement must be latin-1 for regex: {ex}")

    def _sub(m):
        orig = m.group(0)
        if mask_char is not None:
            return _mask_bytes(mask_char, "latin-1", len(orig))
        new = m.expand(repl_b)
        if len(new) > len(orig):
            raise LengthError(len(new), len(orig))
        if len(new) < len(orig):
            new = new + bytes([pad]) * (len(orig) - len(new))
        return new

    new_data, n = rx.subn(_sub, bytes(data))
    if n:
        data[:] = new_data
    return n


def count_matches(data: bytes, find: str, kind: str, enc: str) -> list[tuple[str, int]]:
    """Return [(encoding, count), ...] for reporting in --list mode."""
    hits = []
    if kind == "literal":
        for e in _encodings("literal", enc):
            try:
                fb = find.encode(e)
            except UnicodeError:
                continue
            c, start = 0, 0
            while True:
                i = data.find(fb, start)
                if i < 0:
                    break
                c += 1
                start = i + len(fb)
            if c:
                hits.append((e, c))
    else:
        try:
            rx = re.compile(find.encode("latin-1"))
            n = len(rx.findall(data))
        except (re.error, UnicodeError):
            n = 0
        if n:
            hits.append(("latin-1/regex", n))
    return hits


def _apply_rule(data: bytearray, rule: dict, settings: dict) -> int:
    mask = settings["mask_char"] if rule.get("mask") else None
    if rule["type"] == "literal":
        return apply_literal(data, rule["find"], rule.get("replace", ""),
                             settings["encoding"], settings["pad"], mask)
    return apply_regex(data, rule["find"], rule.get("replace", ""),
                       settings["encoding"], settings["pad"], mask)


# --------------------------------------------------------------------------- #
# Rules / config
# --------------------------------------------------------------------------- #
def normalize_rule(d: dict) -> dict:
    t = d.get("type", "literal")
    if t not in ("literal", "regex"):
        raise ValueError(f"unknown rule type: {t!r}")
    if "find" not in d:
        raise ValueError("rule is missing 'find'")
    return {"type": t, "find": d["find"], "replace": d.get("replace", ""),
            "mask": bool(d.get("mask", False))}


def load_rules_file(path: str) -> list[dict]:
    """Line-based rules: 'literal:PATTERN=REPL' or 'regex:PATTERN=REPL'."""
    rules = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        t = "literal"
        if line.startswith("literal:"):
            line = line[len("literal:"):]
        elif line.startswith("regex:"):
            t = "regex"
            line = line[len("regex:"):]
        if "=" not in line:
            raise ValueError(f"bad rule (need PATTERN=REPL): {raw!r}")
        find, _, repl = line.partition("=")
        rules.append({"type": t, "find": find, "replace": repl})
    return rules


def auto_rules(fields: dict, settings: dict) -> list[dict]:
    """Build literal rules that neutralise the PE's own version-info values."""
    ai = settings["auto_identity"]
    identity = ai.get("identity", {})
    rules = []
    for field in ai["fields"]:
        val = fields.get(field)
        if not val or not val.strip():
            continue
        if ai["mode"] == "template" and identity.get(field):
            rules.append({"type": "literal", "find": val,
                          "replace": identity[field], "mask": False,
                          "_field": field})
        else:
            rules.append({"type": "literal", "find": val,
                          "replace": "", "mask": True, "_field": field})
    return rules


def heuristic_rules(settings: dict) -> list[dict]:
    return [{"type": "regex", "find": HEURISTICS[name], "replace": "",
             "mask": True, "_heuristic": name}
            for name in settings["heuristics"] if name in HEURISTICS]


def extract_strings(data: bytes, minlen: int, cap: int = 2000) -> list[str]:
    """Return distinct printable strings (ASCII + UTF-16LE) of length >= minlen."""
    found: list[str] = []
    seen: set[str] = set()

    def add(s: str):
        if len(s) >= minlen and s not in seen:
            seen.add(s)
            found.append(s)

    run = bytearray()

    def flush_ascii():
        if len(run) >= minlen:
            add(run.decode("latin-1"))
        run.clear()

    for b in data:
        if 32 <= b < 127:
            run.append(b)
        else:
            flush_ascii()
    flush_ascii()

    run_u = bytearray()
    i = 0
    n = len(data)
    while i + 1 < n:
        ch = data[i:i + 2]
        if ch[1] == 0 and 32 <= ch[0] < 127:
            run_u.append(ch[0])
            i += 2
        else:
            if len(run_u) >= minlen:
                add(run_u.decode("latin-1"))
            run_u.clear()
            i += 2
    if len(run_u) >= minlen:
        add(run_u.decode("latin-1"))
    return found[:cap]


# --------------------------------------------------------------------------- #
# Driver
# --------------------------------------------------------------------------- #
def collect(paths: list[Path], exts: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    for p in paths:
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and f.suffix.lower() in exts:
                    files.append(f)
        elif p.is_file():
            files.append(p)
        else:
            print(f"! not found: {p}", file=sys.stderr)
    return files


def process_file(path: Path, settings: dict) -> str:
    try:
        data = bytearray(path.read_bytes())
    except OSError as ex:
        return f"read error: {ex}"
    pe = parse_pe(data)
    if pe is None or pe["magic"] not in (0x10B, 0x20B):
        return "not a PE (skipped)"

    # Build the per-file rule set (auto rules need the file's own fields).
    rules = list(settings["rules"])
    if settings["auto_identity"]["enabled"]:
        fields = parse_version_fields(data, pe)
        rules = auto_rules(fields, settings) + rules
    rules = heuristic_rules(settings) + rules

    if settings["list"]:
        lines = []
        for r in rules:
            kind = "mask" if r.get("mask") else r["type"]
            for enc, n in count_matches(bytes(data), r["find"], r["type"],
                                        settings["encoding"]):
                lines.append(f"    [{kind}] {r['find']!r} ({enc}) x{n}")
        return "\n".join(lines) if lines else "    (no matches)"

    actions: list[str] = []

    if settings["strip"]["signature"]:
        size, how = strip_signature(data, pe)
        if size:
            actions.append(f"signature {size}B {how}")

    if settings["strip"]["version"]:
        ok, zeroed = strip_resource_type(data, pe, RT_VERSION)
        if ok:
            actions.append(f"RT_VERSION removed ({zeroed}B zeroed)")

    if settings["strip"]["manifest"]:
        ok, zeroed = strip_resource_type(data, pe, RT_MANIFEST)
        if ok:
            actions.append(f"RT_MANIFEST removed ({zeroed}B zeroed)")

    if settings["strip"]["rich"]:
        n = strip_rich(data, pe)
        if n:
            actions.append(f"rich-header {n}B zeroed")

    if settings["strip"]["timestamp"]:
        old = struct.unpack_from("<I", data, pe["tstamp_off"])[0]
        if old:
            struct.pack_into("<I", data, pe["tstamp_off"], 0)
            actions.append(f"timestamp {old} -> 0")

    struct.pack_into("<I", data, pe["cksum_off"], 0)

    for r in rules:
        label = f"{r['type']}{'*mask' if r.get('mask') else ''} {r['find']!r}"
        try:
            n = _apply_rule(data, r, settings)
            if n:
                actions.append(f"replace {label} x{n}")
        except (LengthError, ValueError) as ex:
            actions.append(f"replace {label} SKIPPED: {ex}")

    if parse_pe(bytes(data)) is None:
        return "ERROR: post-edit parse failed (file left unchanged)"

    out = path if settings["in_place"] else path.with_name(path.stem + "_anon" + path.suffix)
    try:
        out.write_bytes(data)
    except OSError as ex:
        return f"write error: {ex}"
    detail = "; ".join(actions) if actions else "nothing to do"
    return f"{detail}  ->  {out.name}"


def build_extract_config(targets: list[Path], settings: dict) -> dict:
    """Scan targets and emit a ready-to-edit profile config."""
    rules: list[dict] = []
    seen: set = set()

    def add(rule: dict):
        key = (rule["type"], rule["find"], rule.get("mask"), rule.get("replace"))
        if key not in seen:
            seen.add(key)
            rules.append(rule)

    for path in targets:
        try:
            data = bytes(path.read_bytes())
        except OSError:
            continue
        pe = parse_pe(data)
        if pe is None or pe["magic"] not in (0x10B, 0x20B):
            continue
        fields = parse_version_fields(data, pe)
        for field in settings["auto_identity"]["fields"]:
            val = fields.get(field)
            if val and val.strip():
                add({"type": "literal", "find": val, "replace": "", "mask": True,
                     "_field": field})
        for name in settings["heuristics"]:
            pat = HEURISTICS.get(name)
            if not pat:
                continue
            try:
                rx = re.compile(pat.encode("latin-1"))
            except re.error:
                continue
            examples = [m.group(0).decode("latin-1", "replace")[:80]
                        for m in list(rx.finditer(data))[:3]]
            if examples:
                add({"type": "regex", "find": pat, "replace": "", "mask": True,
                     "_heuristic": name, "_examples": examples})
        if settings["extract_strings"]:
            for s in extract_strings(data, settings["extract_strings"]):
                add({"type": "literal", "find": s, "replace": "", "mask": True})

    return {
        "_readme": "Profile generated by strip_pe.py --extract. Edit replace[] "
                   "values (or add identity) and pass back with --config.",
        "encoding": settings["encoding"],
        "pad": "null" if settings["pad"] == 0 else "space",
        "mask_char": settings["mask_char"],
        "strip": settings["strip"],
        "heuristics": [],
        "_heuristics_note": "heuristic hits below are already materialised as "
                            "replace rules; set this list to re-enable built-ins",
        "replace": rules,
    }


def _all_heuristics(sel: str) -> list[str]:
    if sel in ("all", "true", ""):
        return list(HEURISTICS)
    return [s.strip() for s in sel.split(",") if s.strip() in HEURISTICS]


def build_settings(args) -> dict:
    cfg: dict = {}
    if args.config:
        cfg = json.loads(Path(args.config).read_text(encoding="utf-8"))

    scfg = cfg.get("strip", {})
    strip = {
        "signature": scfg.get("signature", True) and not args.no_signature,
        "version": scfg.get("version", True) and not args.no_version,
        "manifest": scfg.get("manifest", True) and not args.no_manifest,
        "rich": scfg.get("rich", True) and not args.no_rich,
        "timestamp": scfg.get("timestamp", True) and not args.no_timestamp,
    }

    ai_cfg = cfg.get("auto_identity", {}) or {}
    enabled = ai_cfg.get("enabled", False) or args.auto_version is not None
    if args.auto_version:
        mode = args.auto_version
    else:
        mode = ai_cfg.get("mode", "mask")
    auto_identity = {
        "enabled": enabled,
        "mode": mode if mode in ("mask", "template") else "mask",
        "fields": ai_cfg.get("fields") or list(DEFAULT_VERSION_FIELDS),
        "identity": ai_cfg.get("identity", {}) or {},
    }

    if args.heuristics is not None:
        heuristics = _all_heuristics(args.heuristics)
    elif isinstance(cfg.get("heuristics"), list):
        heuristics = [h for h in cfg["heuristics"] if h in HEURISTICS]
    elif cfg.get("heuristics") is True:
        heuristics = list(HEURISTICS)
    else:
        heuristics = []

    rules: list[dict] = []
    for d in cfg.get("replace", []):
        rules.append(normalize_rule(d))
    if args.rules:
        rules.extend(normalize_rule(r) for r in load_rules_file(args.rules))
    for s in args.replace or []:
        find, _, repl = s.partition("=")
        rules.append({"type": "literal", "find": find, "replace": repl, "mask": False})
    for s in args.replace_regex or []:
        find, _, repl = s.partition("=")
        rules.append({"type": "regex", "find": find, "replace": repl, "mask": False})

    pad = 0x00 if (args.pad_null or cfg.get("pad") == "null") else 0x20
    return {
        "encoding": args.encoding or cfg.get("encoding") or "auto",
        "pad": pad,
        "mask_char": args.mask_char or cfg.get("mask_char") or "X",
        "in_place": args.in_place,
        "list": args.list,
        "extract": args.extract,
        "extract_strings": args.extract_strings,
        "extract_out": args.extract_out,
        "strip": strip,
        "rules": rules,
        "auto_identity": auto_identity,
        "heuristics": heuristics,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Anonymize PE files and do same-length string/regex replacement.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("paths", nargs="*", type=Path,
                    help="files or directories (default: directory of this script)")
    ap.add_argument("--config", help="JSON config file with rules / options")
    ap.add_argument("--rules", help="line-based rules file")
    ap.add_argument("--replace", action="append", metavar="OLD=NEW",
                    help="literal replace rule (repeatable)")
    ap.add_argument("--replace-regex", action="append", metavar="PATTERN=NEW",
                    help="regex replace rule (repeatable)")
    ap.add_argument("--auto-version", nargs="?", const="mask",
                    choices=["mask", "template"],
                    help="auto-replace the PE's own version-info fields")
    ap.add_argument("--heuristics", metavar="LIST|all",
                    help="built-in heuristic rules: url,email,winpath,uncpath,copyright")
    ap.add_argument("--mask-char", help="character used by mask rules (default X)")
    ap.add_argument("--encoding", choices=["auto", "ascii", "utf16le"],
                    help="string encoding to search (default: auto = both)")
    ap.add_argument("--pad-null", action="store_true",
                    help="pad shorter replacements with NUL instead of spaces")
    ap.add_argument("--ext", help="comma-separated extensions to scan")
    ap.add_argument("--in-place", action="store_true",
                    help="overwrite originals instead of writing *_anon copies")
    ap.add_argument("--list", action="store_true",
                    help="only report rule matches, do not modify anything")
    ap.add_argument("--extract", action="store_true",
                    help="emit a profile config instead of modifying files")
    ap.add_argument("--extract-strings", type=int, metavar="MINLEN",
                    help="with --extract, also include printable strings this long")
    ap.add_argument("--extract-out", metavar="FILE",
                    help="with --extract, write the profile to FILE")
    ap.add_argument("--no-signature", action="store_true")
    ap.add_argument("--no-version", action="store_true")
    ap.add_argument("--no-manifest", action="store_true")
    ap.add_argument("--no-rich", action="store_true")
    ap.add_argument("--no-timestamp", action="store_true")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args(argv)

    settings = build_settings(args)

    exts = DEFAULT_EXTS
    if args.ext:
        exts = tuple((e if e.startswith(".") else "." + e).lower()
                     for e in args.ext.split(","))

    paths = args.paths or [Path(__file__).resolve().parent]
    targets = [t for t in collect(paths, exts) if not t.stem.endswith("_anon")]

    if not targets:
        print("no PE files found", file=sys.stderr)
        return 1

    if settings["extract"]:
        profile = build_extract_config(targets, settings)
        text = json.dumps(profile, indent=2, ensure_ascii=False)
        if settings["extract_out"]:
            Path(settings["extract_out"]).write_text(text + "\n", encoding="utf-8")
            if not args.quiet:
                print(f"wrote profile: {settings['extract_out']} "
                      f"({len(profile['replace'])} rules)")
        else:
            print(text)
        return 0

    rc = 0
    for path in targets:
        result = process_file(path, settings)
        if result.startswith(("read error", "write error", "ERROR")):
            rc = 1
        if not args.quiet:
            print(f"{path}:")
            print(f"    {result}")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
