#!/bin/bash
set -e

source .env
: "${RPC_URL:?Missing RPC_URL in .env}"
: "${PRIVATE_KEY:?Missing PRIVATE_KEY in .env}"

DEPLOY_LOG="deploy.log"
ENV_FILE="deployed.env"

# Helper for cleaner + safer extraction
extract() {
    local result
    result=$(grep -m1 "$1" "$DEPLOY_LOG" | grep -o "0x[a-fA-F0-9]\{40\}")
    echo "${result:-NOT_FOUND}"
}

# ------------------------------------------------------------
# RUN FOUNDRY DEPLOY SCRIPT
# ------------------------------------------------------------
echo ""
echo "=== Deploying contracts ==="

ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
export OWNER=$ADDRESS

forge script script/DeployERC20Supra.s.sol:DeployERC20Supra \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --skip-simulation \
    -vvvv > "$DEPLOY_LOG" 2>&1

ERC20_SUPRA=$(extract "ERC20Supra deployed at: ")
if [[ "$ERC20_SUPRA" == "NOT_FOUND" ]]; then
    echo "ERROR: ERC20Supra address not found"
    exit 1
fi

export ERC20_SUPRA

forge script script/DeployDiamond.s.sol:DeployDiamond \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --skip-simulation \
    -vvvv >> "$DEPLOY_LOG" 2>&1

echo "Deployment logs saved to $DEPLOY_LOG"

# ------------------------------------------------------------
# PARSE DEPLOYED CONTRACT ADDRESSES
# ------------------------------------------------------------
echo ""
echo "=== Extracting deployed addresses ==="

DIAMOND_OWNER=$(extract "Diamond owner:")
DIAMOND=$(extract "Diamond deployed at:")
DIAMOND_CUT_FACET=$(extract "DiamondCutFacet deployed at:")
DIAMOND_LOUPE_FACET=$(extract "DiamondLoupeFacet deployed at:")
OWNERSHIP_FACET=$(extract "OwnershipFacet deployed at:")
CONFIG_FACET=$(extract "ConfigFacet deployed at:")
REGISTRY_FACET=$(extract "RegistryFacet deployed at:")
CORE_FACET=$(extract "CoreFacet deployed at:")
DIAMOND_INIT=$(extract "DiamondInit deployed at:")

# ------------------------------------------------------------
# WRITE TO .env
# ------------------------------------------------------------
echo ""
echo "=== Saving contract addresses to $ENV_FILE ==="
echo ""

cat <<EOF > "$ENV_FILE"
# Auto-generated deployment output

ERC20_SUPRA=$ERC20_SUPRA

DIAMOND_OWNER=$DIAMOND_OWNER
DIAMOND=$DIAMOND
DIAMOND_CUT_FACET=$DIAMOND_CUT_FACET
DIAMOND_LOUPE_FACET=$DIAMOND_LOUPE_FACET
OWNERSHIP_FACET=$OWNERSHIP_FACET
CONFIG_FACET=$CONFIG_FACET
REGISTRY_FACET=$REGISTRY_FACET
CORE_FACET=$CORE_FACET
DIAMOND_INIT=$DIAMOND_INIT
EOF

cat "$ENV_FILE"

echo ""
echo "=== Deployment Complete ==="