#!/bin/bash
set -e

# -------------------------------
# Load deployed contract addresses
# -------------------------------
echo "=== Loading deployed contract addresses ==="

if [ ! -f "deployed.env" ]; then
    echo "ERROR: deployed.env not found."
    exit 1
fi

source deployed.env

# -------------------------------
# Validate env variables
# -------------------------------
: "${RPC_URL:?Missing RPC_URL in deployed.env}"
: "${ERC20_SUPRA:?Missing ERC20_SUPRA in deployed.env}"
: "${AUTOMATION_CORE_PROXY:?Missing AUTOMATION_CORE_PROXY in deployed.env}"
: "${AUTOMATION_REGISTRY_PROXY:?Missing AUTOMATION_REGISTRY_PROXY in deployed.env}"

echo ""
echo "Contracts Loaded:"
echo "ERC20_SUPRA:              $ERC20_SUPRA"
echo "AUTOMATION_CORE:          $AUTOMATION_CORE_PROXY"
echo "AUTOMATION_REGISTRY:      $AUTOMATION_REGISTRY_PROXY"

echo ""
echo "=== Starting Automation CLI ==="

ERC20_SUPRA="$ERC20_SUPRA"
AUTOMATION_CORE="$AUTOMATION_CORE_PROXY"
REGISTRY="$AUTOMATION_REGISTRY_PROXY"

# -------------------------------
# Ask user for private key
# -------------------------------
echo -n "Enter PRIVATE_KEY (0x...): "
read -r PRIVATE_KEY

ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo ""
echo "Using RPC: $RPC_URL"
echo "Wallet: $ADDRESS"
echo "ERC20 Supra: $ERC20_SUPRA"
echo "Automation Core proxy: $AUTOMATION_CORE"
echo "Automation Registry proxy: $REGISTRY"
echo ""

# -------------------------------
# Helper - safe send
# -------------------------------
send_tx() {
    cast send \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --gas-limit 3000000 \
        "$@"
}

# -------------------------------
# Balance + allowance helpers
# -------------------------------
get_native_balance() {
    RAW=$(cast balance "$ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null)
    RAW=${RAW:-0}
    ETH=$(cast --from-wei "$RAW")
    echo "ETH Balance: $ETH ETH"
}

get_erc20Supra_balance() {
    RAW=$(cast erc20-token balance "$ERC20_SUPRA" "$ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null)
    DEC_WEI=$(echo "$RAW" | awk '{print $1}')
    DEC_WEI=${DEC_WEI:-0}
    SUPRA=$(cast --from-wei "$DEC_WEI")
    echo "ERC20Supra Balance: $SUPRA SUPRA"
}

get_allowance() {
    RAW=$(cast erc20-token allowance "$ERC20_SUPRA" "$ADDRESS" "$AUTOMATION_CORE" --rpc-url "$RPC_URL" 2>/dev/null)
    DEC_WEI=$(echo "$RAW" | awk '{print $1}')
    DEC_WEI=${DEC_WEI:-0}
    SUPRA=$(cast --from-wei "$DEC_WEI")
    echo "Allowance to Automation Registry: $SUPRA SUPRA"
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

is_authorized_submitter() {
    echo -n "Enter address: "
    read -r address
    RAW=$(cast call "$REGISTRY" "isAuthorizedSubmitter(address)(bool)" $address --rpc-url "$RPC_URL")
    echo "Is submitter?: $RAW"
}

view_registry_locked_balance() {
    RAW=$(cast call "$REGISTRY" "getTotalLockedBalance()(uint256)" --rpc-url "$RPC_URL")
    DEC=$(echo "$RAW" | awk '{print $1}')
    SUPRA=$(cast --from-wei "$DEC")
    echo "Registry Locked SUPRA: $SUPRA SUPRA"
}

view_registry_erc20Supra_balance() {
    RAW=$(cast erc20-token balance "$ERC20_SUPRA" "$AUTOMATION_CORE" --rpc-url "$RPC_URL")

    DEC=$(echo "$RAW" | awk '{print $1}')
    SUPRA=$(cast --from-wei "$DEC")

    echo "Automation Registry ERC20Supra Balance: $SUPRA SUPRA"
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
    echo "Automation Registry CLI"
    echo ""
    echo "Commands:"
    echo "  native-balance          Show native balance"
    echo "  erc20Supra-balance      Show ERC20Supra balance"
    echo "  allowance               Check ERC20 approval to registry"
    echo "  nativeToErc20Supra      Deposit native → mint ERC20Supra"
    echo "  approve                 Approve ERC20Supra for fees"
    echo "  register                Register a user task"
    echo "  register-system         Register a system task"
    echo "  cancel                  Cancel a user task"
    echo "  cancel-system           Cancel a system task"
    echo "  stop                    Stop user tasks"
    echo "  stop-system             Stop system tasks"
    echo "  grant-authorization     Grant authorization to submit GST"
    echo "  revoke-authorization    Revoke authorization to submit GST"
    echo "  is-submitter            Check if authorized submitter"
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
        native-balance) get_native_balance ;;
        erc20Supra-balance) get_erc20Supra_balance ;;
        allowance) get_allowance ;;

        nativeToErc20Supra)
            echo -n "Amount to deposit (ETH): "
            read -r ethAmount
            weiAmount=$(cast --to-wei "$ethAmount")
            echo "Depositing $ethAmount ETH..."
            send_tx "$ERC20_SUPRA" "nativeToErc20Supra()" --value "$weiAmount"
        ;;

        approve)
            echo -n "Amount to approve (ETH): "
            read -r ethAmount
            weiAmount=$(cast --to-wei "$ethAmount")
            echo "Approving $ethAmount SUPRA..."
            cast erc20-token approve "$ERC20_SUPRA" "$AUTOMATION_CORE" "$weiAmount" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
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

            echo -n "Priority (uint64): "
            read -r priority

            echo -n "Type (uint8): "
            read -r taskType

            aux_json="[]"

            send_tx "$REGISTRY" \
                "register(bytes,uint64,bytes32,uint128,uint128,uint128,uint64,uint8,bytes[])" \
                "$payloadTx" "$expiryTime" "$txHash" "$maxGas" "$gasPriceCapWei" "$feeCapWei" "$priority" "$taskType" "$aux_json"
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

            echo -n "Priority (uint64): "
            read -r priority

            echo -n "Type (uint8): "
            read -r taskType

            aux_json="[]"

            send_tx "$REGISTRY" \
                "registerSystemTask(bytes,uint64,bytes32,uint128,uint64,uint8,bytes[])" \
                "$payloadTx" "$expiryTime" "$txHash" "$maxGas" "$priority" "$taskType" "$aux_json"
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
            echo -n "Enter task indexes array (e.g. [0,1,2,3]): "
            read -r indexes
            send_tx "$REGISTRY" "stopTasks(uint64[])" "$indexes"
        ;;

        stop-system)
            echo -n "System task indexes array (e.g. [0,1,2,3]): "
            read -r indexes
            send_tx "$REGISTRY" "stopSystemTasks(uint64[])" "$indexes"
        ;;

        grant-authorization)
            echo -n "Enter Admin PRIVATE_KEY (0x...): "
            read -r PVT_KEY
            echo -n "Address to grant authorization: "
            read -r -a address
            cast send "$REGISTRY" "grantAuthorization(address)" "$address" \
                --rpc-url "$RPC_URL" \
                --private-key "$PVT_KEY" \
                --gas-limit 3000000
        ;;

        revoke-authorization)
            echo -n "Enter Admin PRIVATE_KEY (0x...): "
            read -r PVT_KEY
            echo -n "Address to revoke authorization on: "
            read -r -a address
            cast send "$REGISTRY" "revokeAuthorization(address)" "$address" \
                --rpc-url "$RPC_URL" \
                --private-key "$PVT_KEY" \
                --gas-limit 3000000
        ;;

        is-submitter) is_authorized_submitter ;;
        task-details) view_task_details ;;
        registry-locked-balance) view_registry_locked_balance ;;
        registry-balance) view_registry_erc20Supra_balance ;;
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
