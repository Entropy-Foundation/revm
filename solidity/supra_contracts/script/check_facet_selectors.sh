#!/usr/bin/env bash
# Cross-checks each diamond facet's hand-maintained `getSelectors()` list against the
# facet's actual compiled ABI (`forge inspect <Facet> methods`).
#
# `getSelectors()` is trusted verbatim by Diamond's constructor when wiring the diamond's
# routing table (see Diamond.sol). Solidity has no way to enforce "this list contains every
# external function this contract defines" — an entry can be silently omitted by mistake,
# which yields a permanently unroutable function with no compiler error. This script makes
# that mechanical: any external/public function that solc's own ABI reports but that does
# not appear in the facet's `getSelectors()` output is flagged as a FAIL.
#
# There is no CI wiring for the Solidity contracts in this repo yet (checked
# .github/workflows/*.yml — none reference forge/foundry/supra_contracts), so this is a
# standalone script for now, run manually or wired into CI as a follow-up.
#
# Usage: ./script/check_facet_selectors.sh   (run from supra_contracts/, or anywhere — it cd's there)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"


echo "Running CheckFacetSelectors.s.sol to collect each facet's self-reported getSelectors()..."
SCRIPT_OUTPUT="$(forge script script/CheckFacetSelectors.s.sol 2>&1 || true)"

if ! grep -q "^  SELECTOR " <<<"$SCRIPT_OUTPUT"; then
    echo "FAIL: CheckFacetSelectors.s.sol produced no SELECTOR lines. Full output:"
    echo "$SCRIPT_OUTPUT"
    exit 1
fi

overall_status=0

# Ground-truth expected facet set: every contract under src/facets/ that implements
# IFacetSelectors, found directly in its .sol declaration -- not a hand-maintained list
# anywhere (not this script's, not CheckFacetSelectors.s.sol's deploy list, and not this
# run's SELECTOR output). That independence is what closes two different holes at once:
# a facet whose getSelectors() reports zero entries no longer vanishes from both sides of
# the comparison silently, AND a facet that implements IFacetSelectors but was never added
# to CheckFacetSelectors.s.sol's run() in the first place is caught too, instead of the
# checker only ever validating whatever that hand-maintained deploy list happens to include.
# DiamondCutFacet is added explicitly: it deliberately does not implement IFacetSelectors
# (Diamond's constructor wires its one selector directly) so it can never be found this way
# -- see CheckFacetSelectors.s.sol's own note on that.
expected_facets=( $(
    { grep -hoE 'contract [A-Za-z0-9_]+ is [^{]*\bIFacetSelectors\b' src/facets/*.sol \
        | awk '{print $2}'
      echo "DiamondCutFacet"
    } | sort -u
) )

reported_facets=( $(
    grep "^  SELECTOR" <<<"$SCRIPT_OUTPUT" \
        | awk '{print $2}' \
        | sort -u
            ) )

# Check membership in both directions: a facet that implements IFacetSelectors but never
# shows up in the run's output (missing from CheckFacetSelectors.s.sol's run(), or its
# getSelectors() reverts/reports zero entries) is a FAIL, not a silent skip; a facet that
# shows up in the output but doesn't implement IFacetSelectors in its own source (a typo'd
# name, or a stale entry for a removed facet) is flagged too, since the two have drifted apart.
for expected in "${expected_facets[@]}"; do
    if ! printf '%s\n' "${reported_facets[@]}" | grep -qx "$expected"; then
        overall_status=1
        echo "FAIL: $expected — implements IFacetSelectors but reported zero selectors (missing from CheckFacetSelectors.s.sol's run(), or getSelectors() is broken)"
    fi
done
for reported in "${reported_facets[@]}"; do
    if ! printf '%s\n' "${expected_facets[@]}" | grep -qx "$reported"; then
        overall_status=1
        echo "FAIL: $reported — reported selectors but does not implement IFacetSelectors in src/facets/ (stale or typo'd entry in CheckFacetSelectors.s.sol)"
    fi
done

for facet in "${reported_facets[@]}"; do
    # Ground truth: every external/public function's selector, per solc's own ABI.
    # getSelectors() itself is excluded — it is deliberately not meant to be routed.
    inspected_selectors="$(
        forge inspect "$facet" methods --json \
            | jq -r 'to_entries[] | select(.key != "getSelectors()") | .value' \
            | tr '[:upper:]' '[:lower:]' \
            | sort -u
    )"

    # What the facet's own getSelectors() (or, for DiamondCutFacet, Diamond's constructor's
    # hardcoded IDiamondCut.diamondCut.selector) actually reports. The `|| true` on the grep
    # itself (not the whole pipeline) matters: under `pipefail`, grep matching nothing would
    # otherwise abort the script before any FAIL is ever reported -- exactly the "this facet
    # reported zero selectors" case this checker exists to catch. Isolating it here keeps
    # reported_selectors a clean (possibly empty) list of hex selectors, so a genuine zero-
    # selector facet correctly shows every one of its real selectors as "missing" below,
    # instead of polluting the comparison with a human-readable fallback string.
    reported_selectors="$(
        { grep "^  SELECTOR $facet " <<<"$SCRIPT_OUTPUT" || true; } \
            | awk '{print $3}' \
            | sed 's/^0x//' \
            | tr '[:upper:]' '[:lower:]' \
            | sort -u
    )"

    missing="$(comm -23 <(echo "$inspected_selectors") <(echo "$reported_selectors") | sed '/^$/d')"
    extra="$(comm -13 <(echo "$inspected_selectors") <(echo "$reported_selectors") | sed '/^$/d')"

    if [[ -z "$missing" && -z "$extra" ]]; then
        echo "PASS: $facet — getSelectors() matches the compiled ABI exactly."
    else
        overall_status=1
        echo "FAIL: $facet"
        if [[ -n "$missing" ]]; then
            echo "  Selectors solc reports that getSelectors() is missing (permanently unroutable if added to the diamond):"
            while read -r sel; do
                name="$(jq -r --arg s "$sel" 'to_entries[] | select((.value | ascii_downcase) == $s) | .key' <(forge inspect "$facet" methods --json))"
                echo "    0x$sel  $name"
            done <<<"$missing"
        fi
        if [[ -n "$extra" ]]; then
            echo "  Selectors getSelectors() reports that solc's ABI does not have (should not happen — investigate):"
            while read -r sel; do
                echo "    0x$sel"
            done <<<"$extra"
        fi
    fi
done

exit $overall_status
