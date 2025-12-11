#!/bin/bash
set -e

# 1. Deploy everything
./deploy_automation_registry.sh

echo ""
echo "=== Loading deployed contract addresses ==="
source deployed.env

echo ""
echo "Contracts Loaded:"
echo "ERC20_SUPRA:              $ERC20_SUPRA"
echo "AUTOMATION_REGISTRY:      $AUTOMATION_REGISTRY_PROXY"

echo ""
echo "=== Starting Automation CLI ==="

# -------------------------------
# Load deployed contract addresses
# -------------------------------
if [ ! -f "deployed.env" ]; then
    echo "ERROR: deployed.env not found. Run ./run.sh first."
    exit 1
fi

source deployed.env

REGISTRY="$AUTOMATION_REGISTRY_PROXY"
TOKEN="$ERC20_SUPRA"
RPC_URL="http://127.0.0.1:8545"

# -------------------------------
# Ask user for private key
# -------------------------------
echo -n "Enter PRIVATE_KEY (0x...): "
read -r PRIVATE_KEY

ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo ""
echo "Using RPC: $RPC_URL"
echo "Wallet: $ADDRESS"
echo "Registry proxy: $REGISTRY"
echo "ERC20 token: $TOKEN"
echo ""

# -------------------------------
# Helper - safe send
# -------------------------------
send_tx() {
    cast send \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        "$@"
}

# -------------------------------
# Balance + allowance helpers
# -------------------------------
get_eth_balance() {
    RAW=$(cast balance "$ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null)
    RAW=${RAW:-0}
    ETH=$(cast --from-wei "$RAW")
    echo "ETH Balance: $ETH ETH"
}

get_token_balance() {
    RAW=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null)
    DEC_WEI=$(echo "$RAW" | awk '{print $1}')
    DEC_WEI=${DEC_WEI:-0}
    SUPRA=$(cast --from-wei "$DEC_WEI")
    echo "ERC20Supra Balance: $SUPRA SUPRA"
}

get_allowance() {
    RAW=$(cast call "$TOKEN" "allowance(address,address)(uint256)" "$ADDRESS" "$REGISTRY" --rpc-url "$RPC_URL" 2>/dev/null)
    DEC_WEI=$(echo "$RAW" | awk '{print $1}')
    DEC_WEI=${DEC_WEI:-0}
    SUPRA=$(cast --from-wei "$DEC_WEI")
    echo "Allowance to Registry: $SUPRA SUPRA"
}

# -------------------------------
# Registry view functions
# -------------------------------

view_task_details() {
    echo -n "Task index: "
    read -r index
    echo ""
    echo "=== Task Details ==="
    node getTaskDetails.js "$REGISTRY" "$index" "$RPC_URL"
    echo ""
}

view_registry_locked_balance() {
    RAW=$(cast call "$REGISTRY" "getTotalLockedBalance()(uint256)" --rpc-url "$RPC_URL")
    DEC=$(echo "$RAW" | awk '{print $1}')
    SUPRA=$(cast --from-wei "$DEC")
    echo "Registry Locked SUPRA: $SUPRA SUPRA"
}

view_registry_token_balance() {
    RAW=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$REGISTRY" --rpc-url "$RPC_URL")

    DEC=$(echo "$RAW" | awk '{print $1}')
    SUPRA=$(cast --from-wei "$DEC")

    echo "Registry ERC20Supra Balance: $SUPRA SUPRA"
}

view_task_list() {
    RAW=$(cast call "$REGISTRY" "getTaskIdList()(uint256[])" --rpc-url "$RPC_URL")
    echo ""
    echo "=== Task IDs ==="
    echo "$RAW"
    echo ""
}

view_total_tasks() {
    RAW=$(cast call "$REGISTRY" "totalTasks()(uint256)" --rpc-url "$RPC_URL")
    echo "Total Task Count: $RAW"
}

# -------------------------------
# Main menu
# -------------------------------
while true; do
    echo ""
    echo "Automation CLI - extended"
    echo ""
    echo "Commands:"
    echo "  eth-balance             Show ETH balance"
    echo "  supra-balance           Show ERC20Supra balance"
    echo "  allowance               Check ERC20 approval to registry"
    echo "  deposit                 Deposit ETH → mint ERC20Supra"
    echo "  approve                 Approve ERC20 token for fees"
    echo "  register                Register a user task"
    echo "  register-system         Register a system task"
    echo "  cancel                  Cancel a user task"
    echo "  cancel-system           Cancel a system task"
    echo "  stop                    Stop user tasks"
    echo "  stop-system             Stop system tasks"
    echo "  task-details            View details of a task"
    echo "  registry-locked-balance View registry's locked balance"
    echo "  registry-balance        View ERC20Supra balance of registry contract"
    echo "  task-list               View all task IDs"
    echo "  total-tasks             View number of tasks"
    echo "  exit                    Quit"
    echo -n "Command> "
    read -r CMD
    echo ""

    case "$CMD" in
        eth-balance) get_eth_balance ;;
        supra-balance) get_token_balance ;;
        allowance) get_allowance ;;

        deposit)
            echo -n "Amount to deposit (ETH): "
            read -r ethAmount
            weiAmount=$(cast --to-wei "$ethAmount")
            echo "Depositing $ethAmount ETH..."
            send_tx "$TOKEN" "deposit()" --value "$weiAmount"
        ;;

        approve)
            echo -n "Amount to approve (ETH): "
            read -r ethAmount
            weiAmount=$(cast --to-wei "$ethAmount")
            echo "Approving $ethAmount SUPRA..."
            send_tx "$TOKEN" "approve(address,uint256)" "$REGISTRY" "$weiAmount"
        ;;

        register)
            echo "Register task (user task)"
            echo -n "payloadTx (0x...): "
            read -r payloadTx

            echo -n "Duration (seconds): "
            read -r duration
            now=$(cast block latest --rpc-url "$RPC_URL" | grep "timestamp" | awk '{print $2}')
            expiryTime=$(("$now" + "$duration"))
            echo "Computed expiryTime = $expiryTime"

            echo -n "txHash (0x...): "
            read -r txHash

            echo -n "maxGasAmount: "
            read -r maxGas
            
            echo -n "Gas price cap (GWEI): "
            read -r gasPriceCap
            gasPriceCapWei=$(cast --to-wei "$gasPriceCap" gwei)   # convert GWEI to wei


            echo -n "Automation fee cap for cycle (ETH): "
            read -r feeCap
            feeCapWei=$(cast --to-wei "$feeCap")   # convert ETH to wei


            echo -n "auxData count: "
            read -r auxCount

            auxArray=()
            for ((i=0; i<auxCount; i++)); do
                echo -n "auxData[$i] (0x...): "
                read -r item
                auxArray+=("$item")
            done

            aux_json=$(printf '%s,' "${auxArray[@]}")
            aux_json="[${aux_json%,}]"

            send_tx "$REGISTRY" \
                "register(bytes,uint64,bytes32,uint128,uint128,uint128,bytes[])" \
                "$payloadTx" "$expiryTime" "$txHash" "$maxGas" "$gasPriceCapWei" "$feeCapWei" "$aux_json"
        ;;

        register-system)
            echo "Register system task"
            echo -n "payloadTx (0x...): "
            read -r payloadTx

            echo -n "Duration (seconds): "
            read -r duration
            now=$(cast block latest --rpc-url "$RPC_URL" | grep "timestamp" | awk '{print $2}')
            expiryTime=$(("$now" + "$duration"))
            echo "Computed expiryTime = $expiryTime"

            echo -n "txHash (0x...): "
            read -r txHash

            echo -n "maxGasAmount: "
            read -r maxGas

            echo -n "auxData count: "
            read -r auxCount

            auxArray=()
            for ((i=0; i<auxCount; i++)); do
                echo -n "auxData[$i] (0x...): "
                read -r item
                auxArray+=("$item")
            done

            send_tx "$REGISTRY" \
                "registerSystemTask(bytes,uint64,bytes32,uint128,bytes[])" \
                "$payloadTx" "$expiryTime" "$txHash" "$maxGas" "${auxArray[@]}"
        ;;

        cancel)
            echo -n "Task index: "
            read -r index
            send_tx "$REGISTRY" "cancelTask(uint64)" "$index"
        ;;

        cancel-system)
            echo -n "System task index: "
            read -r index
            send_tx "$REGISTRY" "cancelSystemTask(uint64)" "$index"
        ;;

        stop)
            echo -n "Enter task indexes (space-separated): "
            read -r -a indexes
            send_tx "$REGISTRY" "stopTasks(uint64[])" "${indexes[@]}"
        ;;

        stop-system)
            echo -n "System task indexes: "
            read -r -a indexes
            send_tx "$REGISTRY" "stopSystemTasks(uint64[])" "${indexes[@]}"
        ;;

        task-details) view_task_details ;;
        registry-locked-balance) view_registry_locked_balance ;;
        registry-balance) view_registry_token_balance ;;
        task-list) view_task_list ;;
        total-tasks) view_total_tasks ;;

        exit)
            echo "Exiting."
            exit 0
        ;;

        *)
            echo "Unknown command."
        ;;
    esac
done
