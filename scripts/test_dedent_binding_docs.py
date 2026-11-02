"""Tests for scripts/dedent_binding_docs.py.

Run with: pytest scripts/test_dedent_binding_docs.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# The script lives next to this file and is not an installed package.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import dedent_binding_docs as dbd

# The shape `forge bind --alloy` emits for a method inside a contract module.
INDENTED = (
    "mod LibCommon {\n"
    "    /**Creates a new wrapper.\n"
    "\n"
    "    See the [wrapper's documentation](`Instance`) for more details.*/\n"
    "    pub fn new() {}\n"
    "}\n"
)
DEDENTED = (
    "mod LibCommon {\n"
    "    /**Creates a new wrapper.\n"
    "\n"
    "See the [wrapper's documentation](`Instance`) for more details.*/\n"
    "    pub fn new() {}\n"
    "}\n"
)


def test_dedents_continuation_lines() -> None:
    assert dbd.dedent_source(INDENTED) == (DEDENTED, 1)


def test_dedented_source_is_unchanged() -> None:
    assert dbd.dedent_source(DEDENTED) == (DEDENTED, 0)


def test_keeps_relative_indentation_inside_block() -> None:
    # A solidity listing nested deeper than the surrounding text keeps its extra indent.
    block = "/**```solidity\n        struct S {\n            uint64 a;\n        }\n        ```*/"
    expected = "/**```solidity\nstruct S {\n    uint64 a;\n}\n```*/"
    assert dbd.dedent_block(block) == expected


def test_single_line_block_untouched() -> None:
    assert dbd.dedent_block("/**One line.*/") == "/**One line.*/"


def test_blank_lines_lose_trailing_whitespace() -> None:
    assert dbd.dedent_block("/**A\n    \n    B*/") == "/**A\n\nB*/"


def test_line_comments_and_code_untouched() -> None:
    source = "    // indented line comment\n    /* plain block */\n    let x = 1;\n"
    assert dbd.dedent_source(source) == (source, 0)


def test_main_rewrites_then_check_passes(tmp_path: Path) -> None:
    path = tmp_path / "bindings.rs"
    path.write_text(INDENTED, encoding="utf-8")

    assert dbd.main(["--check", str(path)]) == 1
    assert path.read_text(encoding="utf-8") == INDENTED, "--check must not write"

    assert dbd.main([str(path)]) == 0
    assert path.read_text(encoding="utf-8") == DEDENTED
    assert dbd.main(["--check", str(path)]) == 0


def test_main_rejects_missing_file(tmp_path: Path) -> None:
    assert dbd.main([str(tmp_path / "missing.rs")]) == 2


def test_committed_bindings_are_dedented() -> None:
    # Guards the committed bindings against a regeneration that skipped this script.
    bindings = (
        Path(__file__).resolve().parent.parent
        / "crates/supra-extension/src/supra_contract_bindings/supra_contracts_bindings.rs"
    )
    if not bindings.is_file():
        pytest.skip(f"{bindings} not present")
    _, changed = dbd.dedent_source(bindings.read_text(encoding="utf-8"))
    assert changed == 0
