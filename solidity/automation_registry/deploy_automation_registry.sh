#!/bin/bash
set -e

# --------------------------
# CONFIGURATION
# --------------------------
RPC_URL="http://127.0.0.1:8545"
DEPLOY_LOG="deploy.log"
ENV_FILE="deployed.env"
PRIVATE_KEY=""

# Helper for cleaner + safer extraction
extract() {
    local result
    result=$(grep -m1 "$1" "$DEPLOY_LOG" | grep -o "0x[a-fA-F0-9]\{40\}")
    echo "${result:-NOT_FOUND}"
}

# ------------------------------------------------------------
# 1. START ANVIL
# ------------------------------------------------------------
echo "=== Starting Anvil with DEFAULT settings ==="

echo "Checking if port 8545 is in use..."
EXISTING_PID=$(lsof -ti:8545 || true)

if [ ! -z "$EXISTING_PID" ]; then
    echo "Port is busy. Killing $EXISTING_PID ..."
    kill -9 "$EXISTING_PID"
    sleep 1
fi

echo "Starting Anvil..."
anvil > anvil.log 2>&1 &
ANVIL_PID=$!
sleep 2

echo "Anvil launched (PID $ANVIL_PID)"
echo "RPC URL: $RPC_URL"

# ------------------------------------------------------------
# 2. RUN DEPLOY SCRIPT
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
# 3. PARSE DEPLOYED ADDRESSES
# ------------------------------------------------------------
echo ""
echo "=== Extracting deployed addresses ==="

ERC20_SUPRA=$(extract "ERC20Supra deployed at:")
AUTOMATION_REGISTRY_IMPL=$(extract "AutomationRegistry implementation deployed at:")
AUTOMATION_REGISTRY_PROXY=$(extract "AutomationRegistry proxy deployed at:")
BLOCKMETA_IMPL=$(extract "BlockMeta implementation deployed at:")
BLOCKMETA_PROXY=$(extract "BlockMeta proxy deployed at:")
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

AUTOMATION_REGISTRY_IMPL=$AUTOMATION_REGISTRY_IMPL
AUTOMATION_REGISTRY_PROXY=$AUTOMATION_REGISTRY_PROXY

BLOCKMETA_IMPL=$BLOCKMETA_IMPL
BLOCKMETA_PROXY=$BLOCKMETA_PROXY

AUTOMATION_CONTROLLER_IMPL=$AUTOMATION_CONTROLLER_IMPL
AUTOMATION_CONTROLLER_PROXY=$AUTOMATION_CONTROLLER_PROXY
EOF

cat "$ENV_FILE"

echo ""
echo "=== Deployment Complete ==="

# ------------------------------------------------------------
# 5. STOP ANVIL
# ------------------------------------------------------------
# echo "Stopping Anvil (PID $ANVIL_PID)"

# if kill -0 "$ANVIL_PID" 2>/dev/null; then
#     kill "$ANVIL_PID"
#     echo "Anvil stopped successfully."
# else
#     echo "Anvil already exited."
# fi
