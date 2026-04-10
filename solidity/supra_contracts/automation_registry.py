#!/usr/bin/env python3
"""
Automation Registry CLI
Uses Foundry's `cast` for all on-chain operations.
Run: python automation_registry.py

Dependencies:
    pip install eth-utils
"""

import json
import os
import readline
import sys
import subprocess
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Callable, Optional
try:
    from eth_utils import is_address, to_checksum_address
except ImportError:
    print("❌ Missing dependency: eth-utils")
    print("   Install with:  pip install eth-utils")
    sys.exit(1)

# ─────────────────────────────────────────────
# Environment
# ─────────────────────────────────────────────

ENV: dict[str, str] = {}


def load_env_file(path: str) -> dict[str, str]:
    """Parse a simple KEY=VALUE .env file (no shell substitution)."""
    result: dict[str, str] = {}
    p = Path(path)
    if not p.exists():
        return result
    for raw_line in p.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        result[key.strip()] = value.strip().strip("'\"")
    return result


def load_environments() -> None:
    """Load .env and deployed.env, validate required keys."""
    global ENV
    ENV = {**load_env_file(".env"), **load_env_file("deployed.env")}
    for k, v in ENV.items():
        os.environ.setdefault(k, v)
    required = ["RPC_URL", "ERC20_SUPRA", "ERC20_SUPRA_HANDLER", "DIAMOND"]
    missing = [k for k in required if not ENV.get(k)]
    if missing:
        print(f"❌ Missing required environment variables: {', '.join(missing)}")
        print("   Check .env and deployed.env")
        sys.exit(1)


def cfg(key: str) -> str:
    return ENV[key]


# ─────────────────────────────────────────────
# Cast helpers
# ─────────────────────────────────────────────

def run_cast(args: list[str]) -> str:
    """Run a cast command; return stripped stdout. Raises RuntimeError on failure."""
    result = subprocess.run(["cast"] + args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def cast_call(contract: str, sig: str, *args: str) -> str:
    return run_cast(["call", contract, sig, *args, "--rpc-url", cfg("RPC_URL")])


def send_tx(account: str, contract: str, sig: str, *tx_args: str, value_wei: Optional[str] = None) -> None:
    """
    Send a transaction via the Foundry keystore account.
    cast handles the password prompt and prints tx output directly to the terminal.
    Pass value_wei to attach native SUPRA to the call.
    """
    cmd = [
        "cast", "send",
        "--rpc-url", cfg("RPC_URL"),
        "--account", account,
        "--gas-limit", "3000000",
    ]
    if value_wei is not None:
        cmd += ["--value", value_wei]
    cmd += [contract, sig, *tx_args]
    # capture_output intentionally omitted: cast needs the terminal for keystore password.
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print("❌ Transaction failed.")


# ─────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────
#
# Input types and their validators:
#
#   validate_address(raw, label)
#       Ethereum address — delegates to eth_utils for checksum + format.
#
#   validate_decimal_amount(raw, label, *, unit)
#       Positive decimal in SUPRA (unit="ether") or GWEI (unit="gwei").
#       Used for: deposit amount, approval amount, automation fee cap, gas price cap.
#       Returns the wei string produced by cast.
#
#   validate_int(raw, label, *, min_value)
#       Integer with a configurable floor.
#       min_value=1  → positive integers only  (maxGasAmount, duration in seconds)
#       min_value=0  → non-negative integers    (priority, task indexes)
#
#   validate_bytes_hex(raw, label)
#       0x-prefixed hex string for ABI-encoded bytes payloads.
#
#   validate_index_array(raw)
#       Comma-separated or bracketed list of non-negative task indexes.

import re as _re
_DECIMAL_RE = _re.compile(r"^[0-9]+(\.[0-9]+)?$")
_HEX_RE     = _re.compile(r"^0x[a-fA-F0-9]*$")


def validate_address(raw: str, label: str = "Address") -> str:
    """Validate and return a checksummed Ethereum address."""
    s = raw.strip()
    if not s:
        raise ValueError(f"{label} cannot be empty.")
    if not is_address(s):
        raise ValueError(f"{label} '{s}' is not a valid Ethereum address.")
    return to_checksum_address(s)


def validate_decimal_amount(raw: str, label: str, *, unit: str) -> str:
    """
    Validate a positive decimal string and convert to wei via cast.

    unit="ether"  → SUPRA amounts  (deposit, approval, automation fee cap)
    unit="gwei"   → gas price cap

    Returns the wei string. Raises ValueError on any invalid input.
    """
    s = raw.strip()
    if not s:
        raise ValueError(f"{label} cannot be empty.")
    if not _DECIMAL_RE.match(s):
        raise ValueError(
            f"{label} '{s}' is invalid. "
            "Use a plain positive number, e.g. 1 or 0.5. "
            "No scientific notation or leading/trailing dot."
        )
    try:
        if Decimal(s) <= 0:
            raise ValueError(f"{label} must be greater than zero.")
    except InvalidOperation:
        raise ValueError(f"{label} '{s}' could not be parsed.")
    try:
        wei = run_cast(["--to-wei", s] + ([unit] if unit != "ether" else []))
    except RuntimeError as e:
        raise ValueError(f"cast conversion failed: {e}")
    if not wei or wei == "0":
        raise ValueError(f"{label} is too small (rounds to 0 wei).")
    return wei


def validate_int(raw: str, label: str, *, min_value: int) -> int:
    """
    Validate an integer with a configurable minimum.

    min_value=1  → strictly positive  (maxGasAmount, duration in seconds)
    min_value=0  → non-negative        (priority, task indexes)
    """
    s = raw.strip()
    if not s.isdigit():
        bound = "positive integer (> 0)" if min_value > 0 else "non-negative integer (>= 0)"
        raise ValueError(f"{label} must be a {bound}, got '{s}'.")
    value = int(s)
    if value < min_value:
        raise ValueError(f"{label} must be >= {min_value}, got {value}.")
    return value


def validate_bytes_hex(raw: str, label: str = "Bytes") -> str:
    """Validate a 0x-prefixed hex string (ABI-encoded bytes payload)."""
    s = raw.strip()
    if not _HEX_RE.match(s):
        raise ValueError(f"{label} must be a 0x-prefixed hex string, got '{s}'.")
    return s


def validate_index_array(raw: str) -> list[int]:
    """
    Parse a task index list in any of these forms:
        '4'          →  [4]
        '1,2,3'      →  [1, 2, 3]
        '[1,2,3]'    →  [1, 2, 3]
    Every element must be >= 0.
    """
    s = raw.strip().strip("[]").strip()
    if not s:
        raise ValueError("Task index list cannot be empty.")
    indexes: list[int] = []
    for part in s.split(","):
        p = part.strip()
        if not p.isdigit():
            raise ValueError(f"Invalid task index '{p}'. Must be a non-negative integer.")
        indexes.append(int(p))
    return indexes


def fmt_index_array(indexes: list[int]) -> str:
    return "[" + ",".join(str(i) for i in indexes) + "]"


# ─────────────────────────────────────────────
# Prompt helpers
# ─────────────────────────────────────────────

def prompt(label: str) -> str:
    try:
        return input(f"  {label}: ").strip()
    except EOFError:
        return ""


def prompt_validated(label: str, validator, *args, **kwargs):
    """Loop, re-prompting on validation error, until validator succeeds."""
    while True:
        raw = prompt(label)
        try:
            return validator(raw, *args, **kwargs)
        except ValueError as e:
            print(f"  ⚠  {e}")


def get_keystore_account() -> str:
    """Prompt for a Foundry keystore account name and verify the file exists on disk."""
    keystore_dir = Path.home() / ".foundry" / "keystores"
    while True:
        account = prompt("Keystore account name")
        if not account:
            print("  ⚠  Account name cannot be empty.")
            continue
        if not (keystore_dir / account).exists():
            print(f"  ❌ Account '{account}' not found in {keystore_dir}")
            print("  Available accounts:")
            try:
                for line in run_cast(["wallet", "list"]).splitlines():
                    print(f"    - {line}")
            except RuntimeError:
                print("    (could not list accounts)")
            continue
        return account


# ─────────────────────────────────────────────
# Shared internal utilities
# ─────────────────────────────────────────────

def _first_token(raw: str) -> str:
    """Return the first whitespace-separated token from cast output (the wei integer)."""
    return raw.split()[0] if raw else "0"


def _print_supra(label: str, wei_str: str) -> None:
    print(f"  {label}: {run_cast(['--from-wei', wei_str])} SUPRA")


def _cancel_or_stop(method_sig: str) -> None:
    """Shared flow for cancel/stop commands: collect indexes, get account, send tx."""
    indexes = prompt_validated(
        "Task index(es)  (e.g. 4  or  1,2,3  or  [0,1,2,3])",
        validate_index_array,
    )
    account = get_keystore_account()
    send_tx(account, cfg("DIAMOND"), method_sig, fmt_index_array(indexes))


# ─────────────────────────────────────────────
# Commands — read / view
# ─────────────────────────────────────────────

def cmd_list_accounts() -> None:
    print("\n=== Available Keystore Accounts ===")
    try:
        output = run_cast(["wallet", "list"])
        if output:
            for line in output.splitlines():
                print(f"  - {line}")
        else:
            print("  No accounts found.")
            print("  Import one with:  cast wallet import <name> --interactive")
    except RuntimeError as e:
        print(f"  ❌ {e}")
    print()


def cmd_native_balance() -> None:
    address = prompt_validated("Address", validate_address)
    try:
        raw = run_cast(["balance", address, "--rpc-url", cfg("RPC_URL")]) or "0"
        _print_supra("SUPRA Balance", raw)
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_erc20_supra_balance() -> None:
    address = prompt_validated("Address", validate_address)
    try:
        raw = run_cast(["balance", "--erc20", cfg("ERC20_SUPRA"), address, "--rpc-url", cfg("RPC_URL")])
        _print_supra("ERC20Supra Balance", _first_token(raw))
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_allowance() -> None:
    address = prompt_validated("Address", validate_address)
    try:
        raw = cast_call(
            cfg("ERC20_SUPRA"), "allowance(address,address)(uint256)",
            address, cfg("DIAMOND"),
        )
        _print_supra("Allowance to Automation Registry", _first_token(raw))
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_is_submitter() -> None:
    address = prompt_validated("Address", validate_address)
    try:
        raw = cast_call(cfg("DIAMOND"), "isAuthorizedSubmitter(address)(bool)", address)
        print(f"  Is authorized submitter: {raw}")
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_view_task_details() -> None:
    index = prompt_validated("Task index", validate_int, "Task index", min_value=0)
    print("\n=== Task Details ===")
    try:
        raw = run_cast([
            "call", cfg("DIAMOND"),
            "getTaskDetails(uint64)((uint128,uint128,uint128,uint128,bytes32,"
            "uint64,uint64,uint64,uint64,address,uint8,uint8,bytes,bytes,bytes[]))",
            str(index), "--rpc-url", cfg("RPC_URL"), "--json",
        ])
        if not raw or raw == "null":
            print(f"  ❌ Task {index} does not exist.")
            return
        t = json.loads(raw)[0]
        task_types  = {0: "UST", 1: "GST"}
        task_states = {0: "PENDING", 1: "ACTIVE", 2: "CANCELLED"}
        fmt_supra = lambda v: f"{Decimal(str(v)) / Decimal('1e18'):.6f} SUPRA"
        fmt_gwei  = lambda v: f"{Decimal(str(v)) / Decimal('1e9'):.6f} Gwei"
        rows = [
            ("maxGasAmount",             str(t[0])),
            ("gasPriceCap",              fmt_gwei(t[1])),
            ("automationFeeCapForCycle", fmt_supra(t[2])),
            ("depositFee",               fmt_supra(t[3])),
            ("txHash",                   t[4]),
            ("taskIndex",                str(t[5])),
            ("registrationTime",         str(t[6])),
            ("expiryTime",               str(t[7])),
            ("priority",                 str(t[8])),
            ("owner",                    t[9]),
            ("taskType",                 task_types.get(t[10], "UNKNOWN")),
            ("taskState",                task_states.get(t[11], "UNKNOWN")),
            ("payloadTx",                t[12]),
            ("predicate",                t[13]),
            ("auxData",                  str(t[14])),
        ]
        col = max(len(k) for k, _ in rows)
        for k, v in rows:
            print(f"  {k:<{col}}  {v}")
    except RuntimeError as e:
        print(f"  ❌ {e}")
    print()


def cmd_registry_locked_balance() -> None:
    try:
        raw = cast_call(cfg("DIAMOND"), "getTotalLockedBalance()(uint256)")
        _print_supra("Registry Locked SUPRA", _first_token(raw))
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_registry_balance() -> None:
    try:
        raw = run_cast(["balance", "--erc20", cfg("ERC20_SUPRA"), cfg("DIAMOND"), "--rpc-url", cfg("RPC_URL")])
        _print_supra("Automation Registry ERC20Supra Balance", _first_token(raw))
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_task_list() -> None:
    try:
        raw = cast_call(cfg("DIAMOND"), "getTaskIdList()(uint256[])")
        print(f"\n=== Task IDs ===\n  {raw}\n")
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_total_tasks() -> None:
    try:
        raw = cast_call(cfg("DIAMOND"), "totalTasks()(uint256)")
        print(f"  Total Task Count: {raw}")
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_user_tasks() -> None:
    address = prompt_validated("User address", validate_address)
    try:
        raw = cast_call(cfg("DIAMOND"), "getTasksByAddress(address)(uint256[])", address)
        print(f"\n=== User Task IDs ===\n  {raw}\n")
    except RuntimeError as e:
        print(f"  ❌ {e}")


def cmd_task_exists() -> None:
    index = prompt_validated("Task index", validate_int, "Task index", min_value=0)
    try:
        raw = cast_call(cfg("DIAMOND"), "ifTaskExists(uint64)(bool)", str(index))
        if raw.lower() == "true":
            print(f"  ✅ Task {index} EXISTS")
        else:
            print(f"  ❌ Task {index} does NOT exist")
    except RuntimeError as e:
        print(f"  ❌ {e}")
    print()


# ─────────────────────────────────────────────
# Commands — write / send
# ─────────────────────────────────────────────

def cmd_native_to_erc20() -> None:
    print("Deposit native SUPRA → mint ERC20Supra")
    wei = prompt_validated(
        "Amount to deposit (SUPRA, e.g. 0.5 or 10)",
        validate_decimal_amount, "Amount", unit="ether",
    )
    account = get_keystore_account()
    send_tx(account, cfg("ERC20_SUPRA_HANDLER"), "nativeToErc20Supra()", value_wei=wei)


def cmd_approve() -> None:
    print("Approve ERC20Supra spending for Automation Registry")
    wei = prompt_validated(
        "Amount to approve (SUPRA, e.g. 0.5 or 10)",
        validate_decimal_amount, "Amount", unit="ether",
    )
    account = get_keystore_account()
    send_tx(account, cfg("ERC20_SUPRA"), "approve(address,uint256)", cfg("DIAMOND"), wei)


def _prompt_register_common() -> tuple[str, str, int]:
    """Collect payloadTx, predicate, and expiryTime — shared by both register commands."""
    payload_tx = prompt_validated("payloadTx (0x-prefixed hex bytes)", validate_bytes_hex, "payloadTx")
    predicate  = prompt_validated("predicate  (0x-prefixed hex bytes)", validate_bytes_hex, "predicate")
    duration   = prompt_validated("Duration   (seconds, > 0)", validate_int, "Duration", min_value=1)
    try:
        block_output = run_cast(["block", "latest", "--rpc-url", cfg("RPC_URL")])
    except RuntimeError as e:
        raise RuntimeError(f"Could not fetch latest block: {e}")
    for line in block_output.splitlines():
        if line.strip().startswith("timestamp"):
            parts = line.split()
            if len(parts) >= 2:
                expiry_time = int(parts[1]) + duration
                print(f"  Computed expiryTime = {expiry_time}")
                return payload_tx, predicate, expiry_time
    raise RuntimeError("Could not parse block timestamp from cast output.")


def cmd_register() -> None:
    print("Register user task")
    try:
        payload_tx, predicate, expiry_time = _prompt_register_common()
    except RuntimeError as e:
        print(f"  ❌ {e}")
        return
    max_gas       = prompt_validated("maxGasAmount (gas units, e.g. 300000)", validate_int, "maxGasAmount", min_value=1)
    gas_price_wei = prompt_validated("Gas price cap (GWEI, e.g. 1 or 0.005)", validate_decimal_amount, "Gas price cap", unit="gwei")
    fee_cap_wei   = prompt_validated("Automation fee cap for cycle (SUPRA, e.g. 1 or 0.01)", validate_decimal_amount, "Fee cap", unit="ether")
    priority      = prompt_validated("Priority     (integer >= 0)", validate_int, "Priority", min_value=0)
    account       = get_keystore_account()
    send_tx(
        account, cfg("DIAMOND"),
        "register(bytes,bytes,uint64,uint128,uint128,uint128,uint64,bytes[])",
        payload_tx, predicate, str(expiry_time),
        str(max_gas), gas_price_wei, fee_cap_wei, str(priority), "[]",
    )


def cmd_register_system() -> None:
    print("Register system task")
    try:
        payload_tx, predicate, expiry_time = _prompt_register_common()
    except RuntimeError as e:
        print(f"  ❌ {e}")
        return
    max_gas  = prompt_validated("maxGasAmount (gas units, e.g. 300000)", validate_int, "maxGasAmount", min_value=1)
    priority = prompt_validated("Priority     (integer >= 0)", validate_int, "Priority", min_value=0)
    account  = get_keystore_account()
    send_tx(
        account, cfg("DIAMOND"),
        "registerSystemTask(bytes,bytes,uint64,uint128,uint64,bytes[])",
        payload_tx, predicate, str(expiry_time), str(max_gas), str(priority), "[]",
    )


def cmd_cancel()        -> None: _cancel_or_stop("cancelTasks(uint64[])")
def cmd_cancel_system() -> None: _cancel_or_stop("cancelSystemTasks(uint64[])")
def cmd_stop()          -> None: _cancel_or_stop("stopTasks(uint64[])")
def cmd_stop_system()   -> None: _cancel_or_stop("stopSystemTasks(uint64[])")


def cmd_grant_authorization() -> None:
    address = prompt_validated("Address to grant authorization to", validate_address)
    account = get_keystore_account()
    send_tx(account, cfg("DIAMOND"), "grantAuthorization(address)", address)


def cmd_revoke_authorization() -> None:
    address = prompt_validated("Address to revoke authorization on", validate_address)
    account = get_keystore_account()
    send_tx(account, cfg("DIAMOND"), "revokeAuthorization(address)", address)


# ─────────────────────────────────────────────
# Menu
# ─────────────────────────────────────────────

COMMANDS: dict[str, tuple[str, Optional[Callable]]] = {
    "list-accounts":           ("List available keystore accounts",             cmd_list_accounts),
    "native-balance":          ("Show native SUPRA balance",                    cmd_native_balance),
    "erc20Supra-balance":      ("Show ERC20Supra balance",                      cmd_erc20_supra_balance),
    "allowance":               ("Check ERC20 approval to registry",             cmd_allowance),
    "nativeToErc20Supra":      ("Deposit native → mint ERC20Supra",             cmd_native_to_erc20),
    "approve":                 ("Approve ERC20Supra for fees",                  cmd_approve),
    "register":                ("Register a user task",                         cmd_register),
    "register-system":         ("Register a system task",                       cmd_register_system),
    "cancel":                  ("Cancel user task(s)",                          cmd_cancel),
    "cancel-system":           ("Cancel system task(s)",                        cmd_cancel_system),
    "stop":                    ("Stop user task(s)",                            cmd_stop),
    "stop-system":             ("Stop system task(s)",                          cmd_stop_system),
    "grant-authorization":     ("Grant authorization to submit GST",            cmd_grant_authorization),
    "revoke-authorization":    ("Revoke authorization to submit GST",           cmd_revoke_authorization),
    "is-submitter":            ("Check if address is authorized submitter",     cmd_is_submitter),
    "task-details":            ("View details of a task",                       cmd_view_task_details),
    "registry-locked-balance": ("View registry locked balance",                 cmd_registry_locked_balance),
    "registry-balance":        ("View ERC20Supra balance of registry contract", cmd_registry_balance),
    "task-list":               ("View all task IDs",                            cmd_task_list),
    "total-tasks":             ("View total task count",                        cmd_total_tasks),
    "user-tasks":              ("View tasks belonging to a user",               cmd_user_tasks),
    "task-exists":             ("Check whether a task exists",                  cmd_task_exists),
    "exit":                    ("Quit",                                         None),
}


def print_menu() -> None:
    col = max(len(k) for k in COMMANDS)
    print("\nAutomation Registry CLI\n")
    for name, (desc, _) in COMMANDS.items():
        print(f"  {name:<{col}}  {desc}")
    print(f"\n  {'help or ?':<{col}}  Show this menu again")


def main() -> None:
    load_environments()

    command_names = list(COMMANDS.keys())
    readline.set_completer(lambda text, state: (
        [c for c in command_names if c.startswith(text)] + [None]
    )[state])
    readline.set_completer_delims("")
    readline.parse_and_bind("tab: complete")

    print("\n=== Contracts Loaded ===")
    print(f"  ERC20_SUPRA:         {cfg('ERC20_SUPRA')}")
    print(f"  ERC20_SUPRA_HANDLER: {cfg('ERC20_SUPRA_HANDLER')}")
    print(f"  DIAMOND:             {cfg('DIAMOND')}")

    print_menu()
    while True:
        try:
            cmd = input("\nCommand> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nExiting.")
            sys.exit(0)

        print()

        if cmd in ("help", "?"):
            print_menu()
            continue

        if cmd == "exit":
            print("Exiting.")
            sys.exit(0)

        if cmd not in COMMANDS:
            print(f"  Unknown command: '{cmd}'  (type 'help' to list commands, Tab to autocomplete)")
            continue

        _, fn = COMMANDS[cmd]
        try:
            fn()
        except KeyboardInterrupt:
            print("\n  (interrupted, returning to menu)")
        except Exception as e:
            print(f"  ❌ Unexpected error: {e}")


if __name__ == "__main__":
    main()