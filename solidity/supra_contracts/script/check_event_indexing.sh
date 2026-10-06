#!/usr/bin/env bash
# Fails if an event declared in src/ indexes a parameter whose value a log reader cannot recover
# from its topic: a struct (tuple), an array, `string` or `bytes`.
#
# A topic is one 32-byte word. An indexed value type (an integer, address, bool, enum or bytesN)
# is stored in it as is, so a reader both filters on it and reads it back. An indexed struct,
# array, string or bytes value is stored as the keccak256 of its ABI encoding, so the topic carries
# none of its fields and the value appears nowhere else in the log
# (Entropy-Foundation/smr-moonshot#4285). Such a parameter belongs in the log data, where it is
# ABI-encoded and a reader decodes it with the event's ABI.
#
# The same convention keeps fee, refund and balance amounts out of the topics: a reader does not
# filter on an amount, and a topic spent on one is not available for a task index, owner or
# cycle index. That half is not mechanically checkable, since an amount and an index share
# integer types, so this script enforces only the hash rule.
#
# Indexing is not part of the event signature: adding or removing `indexed` keeps topic0 and
# changes the log's topic count and data layout, so a decoder built from the previous ABI
# misreads the log instead of failing to match it. Announce any such change with the tag that
# ships it.
#
# The check reads the ABIs of the compiled artifacts, so it sees every event a contract or
# interface in src/ declares or inherits, however the declaration is formatted. Artifacts of
# lib/, test/ and script/ sources are skipped.
#
# Usage: ./script/check_event_indexing.sh [OUT_DIR]   (run after `forge build`; OUT_DIR defaults to
#        the project's out/; the script cd's to supra_contracts/ first)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

OUT_DIR="${1:-out}"

if [[ ! -d "$OUT_DIR" ]]; then
    echo "FAIL: artifact directory '$OUT_DIR' does not exist; run 'forge build' first."
    exit 1
fi

# Every artifact whose compilation target is a source under src/. compilationTarget maps the
# source path to the contract name; an artifact without metadata is not a compiled contract.
src_artifacts=()
while IFS= read -r -d '' artifact; do
    if jq -e '(.metadata.settings.compilationTarget // {}) | keys | any(startswith("src/"))' \
        "$artifact" >/dev/null 2>&1; then
        src_artifacts+=("$artifact")
    fi
done < <(find "$OUT_DIR" -name '*.json' -print0)

# An empty set means the build did not produce what this script expects (a different out/
# layout, or no build at all); passing would hide that, so it fails.
if [[ ${#src_artifacts[@]} -eq 0 ]]; then
    echo "FAIL: no artifacts compiled from src/ found under '$OUT_DIR'."
    exit 1
fi

# One line per violation: "<source>:<contract> <event>(<param> <type>)". The same event is
# reported once per declaring or inheriting contract and then de-duplicated.
#
# A type is hashed when indexed if it is a tuple (struct), any array (it contains '['), or
# exactly "string" or "bytes"; "bytes32" and the other bytesN types are value types.
violations="$(
    for artifact in "${src_artifacts[@]}"; do
        jq -r '
            ((.metadata.settings.compilationTarget | to_entries[0]) | "\(.key):\(.value)") as $where
            | .abi[]
            | select(.type == "event")
            | .name as $event
            | .inputs[]
            | select(.indexed == true)
            | select((.type | startswith("tuple")) or (.type | contains("["))
                     or .type == "string" or .type == "bytes")
            | "\($where) \($event)(\(.name) \(.internalType // .type))"
        ' "$artifact"
    done | sort -u
)"

if [[ -n "$violations" ]]; then
    echo "FAIL: indexed event parameters that are logged only as a keccak256 hash."
    echo "Move each into the log data by dropping 'indexed' (see this script's header):"
    while IFS= read -r line; do
        echo "  $line"
    done <<<"$violations"
    exit 1
fi

echo "PASS: no event in src/ indexes a struct, array, string or bytes parameter (${#src_artifacts[@]} artifacts checked)."
