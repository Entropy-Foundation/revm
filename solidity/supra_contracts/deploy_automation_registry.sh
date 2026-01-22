#!/bin/bash
set -e

MODE=$1   # optional: "anvil" or empty

# --------------------------
# USER CONFIG (used when NOT anvil)
# --------------------------
RPC_URL="http://localhost:27002/rpc/v1/eth/wallet_integration"
DEPLOY_LOG="deploy.log"
ENV_FILE="deployed.env"
PRIVATE_KEY=""

START_ANVIL=false
ANVIL_PID=""

if [[ "$MODE" == "anvil" ]]; then
    RPC_URL="http://127.0.0.1:8545"
    START_ANVIL=true
    echo "Mode: ANVIL"
else
    echo "Mode: EXTERNAL RPC"
    echo "RPC: $RPC_URL"
fi

# Helper for cleaner + safer extraction
extract() {
    local result
    result=$(grep -m1 "$1" "$DEPLOY_LOG" | grep -o "0x[a-fA-F0-9]\{40\}")
    echo "${result:-NOT_FOUND}"
}

# ------------------------------------------------------------
# 1. START ANVIL (only if mode = anvil)
# ------------------------------------------------------------

if [[ "$START_ANVIL" == true ]]; then
    echo "=== Starting Anvil ==="
    anvil > anvil.log 2>&1 &
    ANVIL_PID=$!
    sleep 2
    echo "Anvil launched (PID $ANVIL_PID)"
fi

# ------------------------------------------------------------
# 2. RUN FOUNDRY DEPLOY SCRIPT
# ------------------------------------------------------------
echo ""
echo "=== Deploying contracts ==="

forge script script/DeployAutomationRegistry.s.sol:DeployAutomationRegistry \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --skip-simulation \
    -vvvv > "$DEPLOY_LOG" 2>&1

echo "Deployment logs saved to $DEPLOY_LOG"

# ------------------------------------------------------------
# 3. PARSE DEPLOYED CONTRACT ADDRESSES
# ------------------------------------------------------------
echo ""
echo "=== Extracting deployed addresses ==="

ERC20_SUPRA=$(extract "ERC20Supra deployed at:")
AUTOMATION_CORE_IMPL=$(extract "AutomationCore implementation deployed at:")
AUTOMATION_CORE_PROXY=$(extract "AutomationCore proxy deployed at:")
AUTOMATION_REGISTRY_IMPL=$(extract "AutomationRegistry implementation deployed at:")
AUTOMATION_REGISTRY_PROXY=$(extract "AutomationRegistry proxy deployed at:")
AUTOMATION_CONTROLLER_IMPL=$(extract "AutomationController implementation deployed at:")
AUTOMATION_CONTROLLER_PROXY=$(extract "AutomationController proxy deployed at:")

# ------------------------------------------------------------
# 4. WRITE TO .env
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

RPC_URL=$RPC_URL
EOF

cat "$ENV_FILE"

echo ""
echo "=== Deployment Complete ==="

# ------------------------------------------------------------
# 5. STOP ANVIL (only if started by this script)
# ------------------------------------------------------------

if [[ "$START_ANVIL" == true ]]; then
    echo "Stopping Anvil..."
    kill "$ANVIL_PID"
fi
