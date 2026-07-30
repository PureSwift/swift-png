#!/usr/bin/env python3
"""Emit the linker export lists that pin the library's dynamic symbol table.

The library links Swift objects and internal shim helpers, all of which would
otherwise appear in the dynamic symbol table.  Restricting exports to exactly the
published libpng API keeps us substitutable for the reference build and prevents
a client from binding to something that is not part of the contract.

Two formats, one input:
  png16.exp    Mach-O -exported_symbols_list (leading underscore)
  png16.vers   ELF version script, tagging the API as PNG16_0
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SYMBOLS = ROOT / "scripts" / "symbols.txt"

VERSION_TAG = "PNG16_0"


def read_symbols() -> list[str]:
    names = sorted(
        line.strip()
        for line in SYMBOLS.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    )
    if not names:
        sys.exit(f"{SYMBOLS} is empty")
    return names


def write_macho(path: pathlib.Path, names: list[str]) -> None:
    lines = [f"_{name}" for name in names]
    path.write_text("\n".join(lines) + "\n")


def write_elf(path: pathlib.Path, names: list[str]) -> None:
    body = "\n".join(f"    {name};" for name in names)
    path.write_text(f"{VERSION_TAG} {{\n  global:\n{body}\n  local:\n    *;\n}};\n")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: gen_symbols.py <output-directory>")

    output = pathlib.Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)

    names = read_symbols()
    write_macho(output / "png16.exp", names)
    write_elf(output / "png16.vers", names)
    print(f"wrote export lists for {len(names)} symbols to {output}")


if __name__ == "__main__":
    main()
