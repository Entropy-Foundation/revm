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

forge script script/DeployAutomationRegistry.s.sol:DeployAutomationRegistry \
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

AUTOMATION_CORE_IMPL=$(extract "AutomationCore implementation deployed at:")
AUTOMATION_CORE_PROXY=$(extract "AutomationCore proxy deployed at:")
AUTOMATION_REGISTRY_IMPL=$(extract "AutomationRegistry implementation deployed at:")
AUTOMATION_REGISTRY_PROXY=$(extract "AutomationRegistry proxy deployed at:")
AUTOMATION_CONTROLLER_IMPL=$(extract "AutomationController implementation deployed at:")
AUTOMATION_CONTROLLER_PROXY=$(extract "AutomationController proxy deployed at:")

# ------------------------------------------------------------
# WRITE TO .env
# ------------------------------------------------------------
echo ""
echo "=== Saving contract addresses to $ENV_FILE ==="
echo ""

cat <<EOF > "$ENV_FILE"
# Auto-generated deployment output

ERC20_SUPRA=$ERC20_SUPRA

AUTOMATION_CORE_IMPL=$AUTOMATION_CORE_IMPL
AUTOMATION_CORE_PROXY=$AUTOMATION_CORE_PROXY

AUTOMATION_REGISTRY_IMPL=$AUTOMATION_REGISTRY_IMPL
AUTOMATION_REGISTRY_PROXY=$AUTOMATION_REGISTRY_PROXY

AUTOMATION_CONTROLLER_IMPL=$AUTOMATION_CONTROLLER_IMPL
AUTOMATION_CONTROLLER_PROXY=$AUTOMATION_CONTROLLER_PROXY
EOF

cat "$ENV_FILE"

echo ""
echo "=== Deployment Complete ==="