#!/usr/bin/env python3
"""Gather the licences of everything the Rust core is built from.

Flutter already shows the licences of the Dart packages and of the Flutter
engine on its licences page. The Rust crates compiled into libgvcore are not
Dart packages, so they are collected here, from the sources Cargo downloaded,
into assets/licenses/rust.txt.gz, which the app adds to that page.

Each crate's own licence files are used where it ships them. A crate that
ships none gets the standard text of the licence it declares, with its
authors as the copyright holders. Where a crate offers a choice ("MIT OR
Apache-2.0") the MIT terms are the ones taken. Identical texts are stored
once with the list of crates they cover, which keeps the file small.

The licences of the native libraries shipped beside the app (libmpv, FFmpeg
and what they need), and of the models and word list it uses, are kept by
hand in tool/license-texts/other and written to assets/licenses/other.txt.gz.

    tool/gen-licenses.py           # rewrite both files
    tool/gen-licenses.py --check   # fail if either is out of date

Needs `cargo` and the crates fetched (`cargo fetch` in core/).
"""

import gzip
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, "core")
OUT = os.path.join(ROOT, "assets", "licenses", "rust.txt.gz")
OTHER = os.path.join(ROOT, "assets", "licenses", "other.txt.gz")
TEXTS = os.path.join(ROOT, "tool", "license-texts")

# Which licence to take, in order of preference, where a crate offers several.
PREFERENCE = ["MIT", "Apache-2.0", "BSD-3-Clause", "BSD-2-Clause", "ISC", "Zlib",
              "BSL-1.0", "Unicode-3.0", "IJG", "0BSD", "Unlicense", "CC0-1.0"]

# Licences whose terms the app could not be released under alongside MIT.
REFUSED = re.compile(r"\b(A?GPL|LGPL|MPL|EUPL|SSPL|CDDL)", re.I)

# What a licence file of each kind is called, for picking the crate's own copy.
FILE_HINTS = {
    "MIT": ["LICENSE-MIT", "LICENSE.MIT", "LICENSE-MIT.md", "LICENSE-MIT.txt"],
    "Apache-2.0": ["LICENSE-APACHE", "LICENSE.APACHE", "LICENSE-APACHE.md", "LICENSE-APACHE.txt", "LICENSE-APACHE-2.0"],
    "BSD-3-Clause": ["LICENSE-BSD", "LICENSE-BSD-3-Clause"],
    "BSD-2-Clause": ["LICENSE-BSD", "LICENSE-BSD-2-Clause"],
    "Zlib": ["LICENSE-ZLIB", "LICENSE-ZLIB.md", "LICENSE-Zlib"],
    "Unlicense": ["UNLICENSE"],
    "BSL-1.0": ["LICENSE-BOOST", "LICENSE_1_0.txt"],
    "Unicode-3.0": ["LICENSE-UNICODE"],
}
GENERIC = ["LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING", "COPYRIGHT"]


def runtime_crates():
    """The crates linked into the shipped library (not tests or build tools)."""
    meta = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--format-version", "1", "--locked"], cwd=CORE))
    by_id = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = meta["resolve"]["root"]
    seen, queue = set(), [root]
    while queue:
        node = nodes[queue.pop()]
        for dep in node["deps"]:
            kinds = {k["kind"] for k in dep["dep_kinds"]}
            # Normal dependencies only: dev-dependencies are test-only and
            # build-dependencies run at compile time and are not shipped.
            if None in kinds and dep["pkg"] not in seen:
                seen.add(dep["pkg"])
                queue.append(dep["pkg"])
    return sorted((by_id[i] for i in seen), key=lambda p: (p["name"], p["version"]))


def choose(expr):
    """The licence to take from an SPDX expression (a simple OR / AND one)."""
    expr = expr.replace("/", " OR ")
    if " AND " in expr:
        # Every part applies: take one choice from each.
        parts = [p.strip(" ()") for p in re.split(r"\)\s+AND\s+|\s+AND\s+\(?", expr)]
        return [c for p in parts for c in choose(p)]
    options = [o.strip(" ()") for o in expr.split(" OR ")]
    options = [re.sub(r"\s+WITH\s+.*", "", o) for o in options]
    for want in PREFERENCE:
        if want in options:
            return [want]
    return [options[0]]


def own_file(directory, licence):
    names = os.listdir(directory)
    lower = {n.lower(): n for n in names}
    for hint in FILE_HINTS.get(licence, []):
        if hint.lower() in lower:
            return os.path.join(directory, lower[hint.lower()])
    # A single generic licence file is the crate's licence if it mentions it.
    for hint in GENERIC:
        if hint.lower() in lower:
            path = os.path.join(directory, lower[hint.lower()])
            text = open(path, encoding="utf-8", errors="replace").read()
            if licence == "MIT" and "Permission is hereby granted" in text:
                return path
            if licence == "Apache-2.0" and "Apache License" in text:
                return path
            if licence not in ("MIT", "Apache-2.0"):
                return path
    return None


def standard_text(licence, crate):
    path = os.path.join(TEXTS, licence + ".txt")
    if not os.path.exists(path):
        sys.exit(f"{crate['name']}: no licence file in the crate and no standard text for {licence} in tool/license-texts")
    text = open(path, encoding="utf-8").read()
    holders = ", ".join(re.sub(r"\s*<[^>]*>", "", a) for a in crate.get("authors") or []) or f"the {crate['name']} developers"
    return text.replace("<copyright holders>", holders)


def tidy(text):
    text = text.replace("\r\n", "\n").replace("\t", "    ")
    lines = [l.rstrip() for l in text.split("\n")]
    return "\n".join(lines).strip("\n")


def build():
    groups = {}  # text -> [crate names]
    for crate in runtime_crates():
        expr = crate.get("license")
        directory = os.path.dirname(crate["manifest_path"])
        if not expr:
            # No SPDX field: the crate's licence file is the licence.
            path = own_file(directory, "")
            if not path:
                sys.exit(f"{crate['name']}: no licence declared and no licence file")
            texts = [open(path, encoding="utf-8", errors="replace").read()]
        else:
            chosen = choose(expr)
            for licence in chosen:
                if REFUSED.search(licence):
                    sys.exit(f"{crate['name']} {crate['version']} is only available under {expr}, which is not compatible with releasing the app under MIT")
            texts = []
            for licence in chosen:
                path = own_file(directory, licence)
                texts.append(open(path, encoding="utf-8", errors="replace").read() if path else standard_text(licence, crate))
        for text in texts:
            groups.setdefault(tidy(text), []).append(crate["name"])

    # LicenseRegistry-style records: package names on one line, a blank line,
    # the text, and a line of 80 dashes between records.
    records = []
    for text, names in sorted(groups.items(), key=lambda kv: kv[1][0]):
        records.append(", ".join(sorted(set(names))) + "\n\n" + text)
    return ("\n" + "-" * 80 + "\n").join(records) + "\n"


def build_other():
    """The notices kept by hand in tool/license-texts/other: native libraries
    shipped beside the app, and models and data it uses. The first line of
    each file names what it covers."""
    directory = os.path.join(TEXTS, "other")
    records = []
    for name in sorted(os.listdir(directory)):
        records.append(tidy(open(os.path.join(directory, name), encoding="utf-8").read()))
    return ("\n" + "-" * 80 + "\n").join(records) + "\n"


def main():
    outputs = [(OUT, build()), (OTHER, build_other())]
    if "--check" in sys.argv:
        for path, text in outputs:
            try:
                current = gzip.decompress(open(path, "rb").read()).decode("utf-8")
            except FileNotFoundError:
                current = ""
            if current != text:
                sys.exit(f"{os.path.relpath(path, ROOT)} is out of date: run tool/gen-licenses.py")
        print("Licence notices are up to date.")
        return
    for path, text in outputs:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        data = text.encode("utf-8")
        # mtime=0 so the same input always gives the same bytes.
        with open(path, "wb") as f:
            f.write(gzip.compress(data, mtime=0))
        print(f"{os.path.relpath(path, ROOT)}: {len(data)} bytes of licence text, {os.path.getsize(path)} compressed")


if __name__ == "__main__":
    main()
