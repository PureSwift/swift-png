#!/usr/bin/env python3
"""Extract the libpng public API from the vendored png.h into scripts/api.json.

png.h declares every public function through the PNG_EXPORTA macro (PNG_EXPORT,
PNG_FP_EXPORT and PNG_FIXED_EXPORT all funnel into it).  Rather than pattern
match the header text, we redefine that macro to emit a delimited record and let
the C preprocessor do the parsing, so the recorded return type and argument list
are exactly what a C compiler sees.
"""

import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
INCLUDE = ROOT / "Sources" / "CPNG" / "include"
OUTPUT = ROOT / "scripts" / "api.json"

# The bare name list, which is what the export lists and the export check read.
SYMBOLS = ROOT / "scripts" / "symbols.txt"

PROBE = r"""
#define PNG_EXPORTA(ordinal, type, name, args, attributes) \
    SPNG_BEGIN ordinal SPNG_SEP type SPNG_SEP name SPNG_SEP args SPNG_END
#include <png.h>
"""

RECORD = re.compile(
    r"SPNG_BEGIN(?P<body>.*?)SPNG_END", re.DOTALL
)


def preprocess() -> str:
    with tempfile.TemporaryDirectory() as tmp:
        probe = pathlib.Path(tmp) / "probe.c"
        probe.write_text(PROBE)
        result = subprocess.run(
            ["cc", "-E", "-P", f"-I{INCLUDE}", str(probe)],
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        sys.exit(f"preprocessing png.h failed:\n{result.stderr}")
    return result.stdout


def normalize(text: str) -> str:
    # Compilers spell the restrict qualifier differently once the preprocessor has
    # run — clang leaves `restrict`, gcc writes `__restrict` — and the recorded API
    # must not change with the machine that regenerated it.
    text = re.sub(r"\b__restrict\b", "restrict", text)
    return re.sub(r"\s+", " ", text).strip()


def parse(preprocessed: str) -> list[dict]:
    functions = []
    for match in RECORD.finditer(preprocessed):
        ordinal, ret, name, args = (
            normalize(part) for part in match.group("body").split("SPNG_SEP")
        )
        functions.append(
            {
                "ordinal": int(ordinal),
                "name": name,
                "return": ret,
                "args": args,
            }
        )
    return functions


def main() -> None:
    functions = parse(preprocess())
    if not functions:
        sys.exit("no PNG_EXPORTA declarations found; did png.h change?")

    names = [function["name"] for function in functions]
    duplicates = {name for name in names if names.count(name) > 1}
    if duplicates:
        sys.exit(f"duplicate declarations: {sorted(duplicates)}")

    functions.sort(key=lambda function: function["name"])
    OUTPUT.write_text(json.dumps(functions, indent=2) + "\n")
    SYMBOLS.write_text("\n".join(sorted(names)) + "\n")

    print(
        f"wrote {len(functions)} declarations to {OUTPUT.relative_to(ROOT)} "
        f"and {SYMBOLS.relative_to(ROOT)}"
    )


if __name__ == "__main__":
    main()
