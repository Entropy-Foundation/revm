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

FACETS=(DiamondCutFacet DiamondLoupeFacet OwnershipFacet ConfigFacet RegistryFacet CoreFacet)

echo "Running CheckFacetSelectors.s.sol to collect each facet's self-reported getSelectors()..."
SCRIPT_OUTPUT="$(forge script script/CheckFacetSelectors.s.sol 2>&1)"

if ! grep -q "^  SELECTOR " <<<"$SCRIPT_OUTPUT"; then
    echo "FAIL: CheckFacetSelectors.s.sol produced no SELECTOR lines. Full output:"
    echo "$SCRIPT_OUTPUT"
    exit 1
fi

overall_status=0

for facet in "${FACETS[@]}"; do
    # Ground truth: every external/public function's selector, per solc's own ABI.
    # getSelectors() itself is excluded — it is deliberately not meant to be routed.
    inspected_selectors="$(
        forge inspect "$facet" methods --json \
            | jq -r 'to_entries[] | select(.key != "getSelectors()") | .value' \
            | tr '[:upper:]' '[:lower:]' \
            | sort -u
    )"

    # What the facet's own getSelectors() (or, for DiamondCutFacet, Diamond's constructor's
    # hardcoded IDiamondCut.diamondCut.selector) actually reports.
    reported_selectors="$(
        grep "^  SELECTOR $facet " <<<"$SCRIPT_OUTPUT" \
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
