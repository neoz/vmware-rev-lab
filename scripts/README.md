# strip_pe.py

Anonymize Windows PE files and perform same-length string / regex replacement.

`strip_pe.py` removes identifying metadata from `.exe` / `.dll` / `.sys` /
`.ocx` / `.scr` files and overwrites chosen strings (product names, company,
URLs, paths, …) **without changing the file length**, so the PE stays valid.

Pure Python standard library — no dependencies, no installation.

---

## Requirements

- Python 3.8+ (tested on 3.14).

---

## Quick start

Run from this `workspace/` directory. By default the tool scans its own folder
and writes `*_anon` copies — **originals are never modified** unless you pass
`--in-place`.

```bash
# Structural strip only (to a copy)
python3 strip_pe.py

# Full anonymize: strip + version-info fields + built-in heuristics
python3 strip_pe.py case.exe --auto-version --heuristics all

# Apply a config file (rules + options)
python3 strip_pe.py case.exe --config replace.config.json

# Only report what would match, change nothing
python3 strip_pe.py case.exe --list --replace "Tonec=X"
```

Output is written next to the input as `<name>_anon<ext>`
(`case.exe` -> `case_anon.exe`).

---

## What it removes

Structural stripping (each toggleable):

| Item | What it is | Flag to keep |
|------|------------|--------------|
| Authenticode signature | Certificate table (`Security` data directory) | `--no-signature` |
| File properties | `RT_VERSION` resource (Windows "Details" tab) | `--no-version` |
| Manifest | `RT_MANIFEST` resource (embedded assembly manifest, `assemblyIdentity` name, `requireAdministrator`, …) | `--no-manifest` |
| Rich header | Compiler/toolchain fingerprint | `--no-rich` |
| COFF timestamp | Build time | `--no-timestamp` |
| CheckSum | Optional-header checksum | always zeroed |

String replacement (never changes file length):

- **explicit rules** you provide (`literal` or `regex`);
- **`auto_identity`** — reads the PE's own VERSIONINFO fields
  (`CompanyName`, `ProductName`, `LegalCopyright`, …) and neutralises them;
- **`heuristics`** — built-in rules for URLs, e-mails, Windows/UNC paths and
  copyright notices.

### Why same-length matters

RVAs, section offsets and the resource tree all encode absolute positions. Any
length change would shift them and corrupt the file. Therefore:

- a replacement **shorter** than the match is right-padded (spaces by default,
  NULs with `--pad-null`);
- a replacement **longer** than the match makes that rule be **skipped** (a
  warning is printed), never a corrupt file;
- **mask rules** (`"mask": true`) size themselves to each match and can never
  overflow.
- a post-edit re-parse guards every file before it is written.

---

## Rule types

| Form | Matches | Length handling |
|------|---------|-----------------|
| `literal` | ASCII **and** UTF-16LE (under `--encoding auto`) | pad shorter / skip longer |
| `regex` | raw bytes (latin-1); may use backreferences like `\1` | pad shorter / skip longer |
| `regex` + `"mask": true` | raw bytes | each match overwritten with `mask_char` |

`literal` is found in both ASCII and UTF-16LE by default, which is what you want
for VERSIONINFO and Windows APIs. `regex` always runs on raw bytes, so
UTF-16-only strings need a `literal` rule.

---

## CLI reference

```
python3 strip_pe.py [paths ...] [options]
```

`paths` may be files or directories (recursed). If omitted, the script's own
directory is scanned.

| Option | Description |
|--------|-------------|
| `--config FILE` | JSON config with rules and options |
| `--rules FILE` | line-based rules: `literal:PAT=REPL` / `regex:PAT=REPL` |
| `--replace OLD=NEW` | inline literal rule (repeatable) |
| `--replace-regex PAT=NEW` | inline regex rule (repeatable) |
| `--auto-version [mask\|template]` | replace the PE's own version-info fields |
| `--heuristics LIST\|all` | built-ins: `url,email,winpath,uncpath,copyright` |
| `--mask-char CH` | mask character (default `X`) |
| `--encoding auto\|ascii\|utf16le` | encoding to search (default `auto`) |
| `--pad-null` | pad shorter replacements with NUL instead of space |
| `--ext .exe,.dll` | extensions to scan |
| `--in-place` | overwrite originals instead of writing `*_anon` copies |
| `--list` | report rule matches only; modify nothing |
| `--extract` | emit a profile config instead of modifying files |
| `--extract-strings MINLEN` | with `--extract`, also include printable strings |
| `--extract-out FILE` | with `--extract`, write profile to FILE |
| `--no-signature` `--no-version` `--no-manifest` `--no-rich` `--no-timestamp` | skip a strip step |
| `-q`, `--quiet` | suppress the per-file report |

---

## Config file

JSON. Keys starting with `_` are documentation only and ignored. CLI flags
override config values. See `replace.config.json` for a fully commented example.

```json
{
  "encoding": "auto",
  "pad": "space",
  "mask_char": "X",
  "strip": { "signature": true, "version": true, "manifest": true, "rich": true, "timestamp": true },

  "auto_identity": {
    "enabled": true,
    "mode": "template",
    "fields": ["CompanyName", "ProductName", "FileDescription",
               "LegalCopyright", "LegalTrademarks", "Comments",
               "OriginalFilename", "InternalName"],
    "identity": { "CompanyName": "Anon Inc.", "ProductName": "Anon Suite" }
  },

  "heuristics": ["url", "email", "winpath", "uncpath", "copyright"],

  "replace": [
    { "type": "literal", "find": "Tonec", "replace": "Vendo" },
    { "type": "regex",   "find": "(IDM)([0-9.]+)", "replace": "APP\\2" },
    { "type": "regex",   "find": "https?://[^\\s\"'<>]+", "mask": true }
  ]
}
```

- `encoding`: `auto` (byte + UTF-16LE) | `ascii` | `utf16le`.
- `pad`: `space` (0x20) | `null` (0x00).
- `strip`: set any of `signature` / `version` / `rich` / `timestamp` to `false`
  to keep it.
- `auto_identity.mode`: `mask` (overwrite with `mask_char`) or `template`
  (use `identity`, fall back to mask per field).
- `heuristics`: `true` for all, a list for a subset, `false`/`[]` for none.

---

## Extract -> edit -> apply (recommended for a new app)

Let the tool read the file and draft a profile, then curate it:

```bash
# 1. dump a profile
python3 strip_pe.py case.exe --extract --heuristics all \
    --extract-strings 14 --extract-out profile.json

# 2. edit profile.json (remove noise, set better replacements)

# 3. apply it
python3 strip_pe.py case.exe --config profile.json
```

`--extract` lists the PE's version-info fields, every heuristic hit, and (with
`--extract-strings`) long printable strings, each as a same-length mask rule
annotated with `_field` / `_heuristic` / `_examples`. The profile is
self-contained and loads straight back with `--config`.

---

## Examples

```bash
# Mask everything identifying, keep it a copy
python3 strip_pe.py app.exe --auto-version --heuristics all

# Rename product/company instead of masking
cat > id.json <<'EOF'
{ "auto_identity": { "enabled": true, "mode": "template",
  "identity": { "CompanyName": "Anon Inc.", "ProductName": "Anon Suite" } } }
EOF
python3 strip_pe.py app.exe --config id.json

# Ad-hoc fixes
python3 strip_pe.py app.exe --replace "Original Name=New Name Here"
python3 strip_pe.py app.exe --encoding utf16le --replace "installer.exe=setup.exe"

# In place, no copies
python3 strip_pe.py app.exe --auto-version --in-place

# Batch a directory
python3 strip_pe.py build/ --heuristics all --ext .exe,.dll
```

---

## Caveats

- **Self-extracting / packed stubs.** A stub that carries a compressed payload
  (a large overlay after the last section containing zlib/other streams that
  inflate to PE images) cannot be anonymized by metadata stripping. The stub's
  own strings and manifest are removed, but the *bundled payload is the original
  product* and is recoverable by running or unpacking the stub. Fully
  de-identifying it means unpacking, anonymizing each inner PE, and repacking in
  the archive's format — outside this tool's scope.
- **`--extract-strings` is powerful but blunt.** It masks *every* long printable
  string, including API names used by `GetProcAddress`, which can break the
  program. Curate the generated profile.
- `auto_identity` replaces whole field values. A brand token that also appears
  standalone (e.g. `Tonec` alone) is not covered by it — add a `literal` rule or
  use `--extract-strings`.
- `regex` operates on raw bytes; non-ASCII literal text is safer as a `literal`
  rule.
- Files whose name already ends in `_anon` are skipped, so re-running does not
  reprocess generated output.
