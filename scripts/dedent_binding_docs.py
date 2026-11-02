#!/usr/bin/env python3
"""Remove the common indentation from the continuation lines of `/** ... */` doc blocks.

`forge bind --alloy` writes doc blocks whose first line sits on the `/**` opener
with no indentation, while the remaining lines carry the indentation of the item
they document:

    mod LibCommon {
        /**Creates a new wrapper around an on-chain contract instance.

        See the wrapper's documentation for more details.*/
        pub const fn new(...) {}
    }

Rustdoc strips only the indentation shared by every line of a block, and the
first line has none, so the continuation lines keep 4 or more leading spaces.
Markdown reads 4 or more leading spaces as an indented code block and rustdoc
compiles such a block as a Rust doctest, which fails on the prose. Removing the
shared indentation from the continuation lines leaves them as Markdown paragraphs.

Usage:
    scripts/dedent_binding_docs.py FILE...          rewrite FILE(s) in place
    scripts/dedent_binding_docs.py --check FILE...  exit 1 if any FILE needs a rewrite

Run it on crates/supra-extension/src/supra_contract_bindings/supra_contracts_bindings.rs
after regenerating the bindings (see `rebuild_rust_bindings` in crates/supra-extension/build.rs).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# A doc block runs from `/**` to the first `*/`. Non-greedy with DOTALL so that each
# block is matched separately even though blocks span several lines. Generated
# bindings do not nest block comments, so the first `*/` closes the block.
DOC_BLOCK = re.compile(r"/\*\*.*?\*/", re.DOTALL)


def _leading_spaces(line: str) -> int:
    """Number of leading space characters in `line`."""
    return len(line) - len(line.lstrip(" "))


def dedent_block(block: str) -> str:
    """Return `block` with the indentation common to its non-blank continuation lines removed.

    The first line (the one holding `/**`) is left as is: its text starts right after
    the opener and has no indentation of its own. Blank continuation lines are emptied
    so that they do not keep trailing whitespace.
    """
    first, *rest = block.split("\n")
    non_blank = [line for line in rest if line.strip()]
    if not non_blank:
        # Single-line block: the last line always holds `*/`, so a multi-line block
        # always has a non-blank continuation line.
        return block
    indent = min(_leading_spaces(line) for line in non_blank)
    # Only spaces are counted in `indent`, so slicing removes spaces and never text.
    dedented = [line[indent:] if line.strip() else "" for line in rest]
    return "\n".join([first, *dedented])


def dedent_source(source: str) -> tuple[str, int]:
    """Dedent every doc block in `source`; return the new text and the number of blocks changed."""
    changed = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal changed
        original = match.group(0)
        updated = dedent_block(original)
        if updated != original:
            changed += 1
        return updated

    return DOC_BLOCK.sub(replace, source), changed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="report files that need a rewrite and exit 1 instead of rewriting them",
    )
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args(argv)

    needs_rewrite = False
    for path in args.files:
        if not path.is_file():
            print(f"error: {path} is not a file", file=sys.stderr)
            return 2
        source = path.read_text(encoding="utf-8")
        updated, changed = dedent_source(source)
        if args.check:
            if changed:
                print(f"{path}: {changed} doc block(s) need dedenting")
                needs_rewrite = True
        elif changed:
            path.write_text(updated, encoding="utf-8")
            print(f"{path}: dedented {changed} doc block(s)")
        else:
            print(f"{path}: no change")
    return 1 if needs_rewrite else 0


if __name__ == "__main__":
    sys.exit(main())
