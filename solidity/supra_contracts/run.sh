#!/bin/bash
set -e

source .env

: "${RPC_URL:?Missing RPC_URL in .env}"
: "${PRIVATE_KEY:?Missing PRIVATE_KEY in .env}"
: "${ADMIN_PRIVATE_KEY:?Missing ADMIN_PRIVATE_KEY in .env}"

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
: "${ERC20_SUPRA:?Missing ERC20_SUPRA in deployed.env}"
: "${DIAMOND:?Missing DIAMOND in deployed.env}"

echo ""
echo "Contracts Loaded:"
echo "ERC20_SUPRA:              $ERC20_SUPRA"
echo "DIAMOND:                  $DIAMOND"

echo ""
echo "=== Starting Automation CLI ==="

ERC20_SUPRA="$ERC20_SUPRA"
DIAMOND="$DIAMOND"

ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
echo ""
echo "Using RPC: $RPC_URL"
echo "Wallet: $ADDRESS"
echo "ERC20 Supra: $ERC20_SUPRA"
echo "Diamond: $DIAMOND"
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
    RAW=$(cast erc20-token allowance "$ERC20_SUPRA" "$ADDRESS" "$DIAMOND" --rpc-url "$RPC_URL" 2>/dev/null)
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

    RAW=$(cast call "$DIAMOND" \
    "getTaskDetails(uint64)((uint128,uint128,uint128,uint128,bytes32,uint64,uint64,uint64,uint64,address,uint8,uint8,bytes,bytes[]))" \
    "$index" \
    --rpc-url "$RPC_URL" \
    --json 2>/dev/null || true)

    if [ -z "$RAW" ] || [ "$RAW" = "null" ]; then
        echo "❌ Task $index does not exist"
        echo ""
        return
    fi

    echo "$RAW" | jq '.[0] | {
        maxGasAmount: .[0],
        gasPriceCap: ((.[1] | tonumber) / 1e9 | tostring + " Gwei"),
        automationFeeCapForCycle: ((.[2] | tonumber) / 1e18 | tostring + " SUPRA"),
        depositFee: ((.[3] | tonumber) / 1e18 | tostring + " SUPRA"),
        txHash: .[4],
        taskIndex: .[5],
        registrationTime: .[6],
        expiryTime: .[7],
        priority: .[8],
        owner: .[9],
        taskType: (if .[10]==0 then "UST" elif .[10]==1 then "GST" else "UNKNOWN" end),
        taskState: (if .[11]==0 then "PENDING" elif .[11]==1 then "ACTIVE" elif .[11]==2 then "CANCELLED" else "UNKNOWN" end),
        payloadTx: .[12],
        auxData: .[13]
    }'

    echo ""
}

is_authorized_submitter() {
    echo -n "Enter address: "
    read -r address
    RAW=$(cast call "$DIAMOND" "isAuthorizedSubmitter(address)(bool)" $address --rpc-url "$RPC_URL")
    echo "Is submitter?: $RAW"
}

view_registry_locked_balance() {
    RAW=$(cast call "$DIAMOND" "getTotalLockedBalance()(uint256)" --rpc-url "$RPC_URL")
    DEC=$(echo "$RAW" | awk '{print $1}')
    SUPRA=$(cast --from-wei "$DEC")
    echo "Registry Locked SUPRA: $SUPRA SUPRA"
}

view_registry_erc20Supra_balance() {
    RAW=$(cast erc20-token balance "$ERC20_SUPRA" "$DIAMOND" --rpc-url "$RPC_URL")

    DEC=$(echo "$RAW" | awk '{print $1}')
    SUPRA=$(cast --from-wei "$DEC")

    echo "Automation Registry ERC20Supra Balance: $SUPRA SUPRA"
}

view_task_list() {
    RAW=$(cast call "$DIAMOND" "getTaskIdList()(uint256[])" --rpc-url "$RPC_URL")
    echo ""
    echo "=== Task IDs ==="
    echo "$RAW"
    echo ""
}

view_total_tasks() {
    RAW=$(cast call "$DIAMOND" "totalTasks()(uint256)" --rpc-url "$RPC_URL")
    echo "Total Task Count: $RAW"
}

view_user_tasks() {
    echo -n "Enter user address: "
    read -r user

    RAW=$(cast call "$DIAMOND" \
        "getUserTasks(address)(uint256[])" \
        "$user" \
        --rpc-url "$RPC_URL")

    echo ""
    echo "=== User Task IDs ==="
    echo "$RAW"
    echo ""
}

check_task_exists() {
    echo -n "Enter task index: "
    read -r index

    RAW=$(cast call "$DIAMOND" \
        "ifTaskExists(uint64)(bool)" \
        "$index" \
        --rpc-url "$RPC_URL")

    echo ""

    if [ "$RAW" = "true" ]; then
        echo "✅ Task $index EXISTS"
    else
        echo "❌ Task $index does NOT exist"
    fi

    echo ""
}

# -------------------------------
# Main menu
# -------------------------------
while true; do
    echo ""
    echo "Automation Registry CLI"
    echo ""
    echo "Commands:"
    echo "  native-balance                      Show native balance"
    echo "  erc20Supra-balance                  Show ERC20Supra balance"
    echo "  allowance                           Check ERC20 approval to registry"
    echo "  nativeToErc20Supra                  Deposit native → mint ERC20Supra"
    echo "  nativeToErc20SupraWithAllowance     Deposit native to mint ERC20Supra and grant allowance"
    echo "  approve                             Approve ERC20Supra for fees"
    echo "  register                            Register a user task"
    echo "  register-system                     Register a system task"
    echo "  cancel                              Cancel a user task"
    echo "  cancel-system                       Cancel a system task"
    echo "  stop                                Stop user tasks"
    echo "  stop-system                         Stop system tasks"
    echo "  grant-authorization                 Grant authorization to submit GST"
    echo "  revoke-authorization                Revoke authorization to submit GST"
    echo "  is-submitter                        Check if authorized submitter"
    echo "  task-details                        View details of a task"
    echo "  registry-locked-balance             View registry's locked balance"
    echo "  registry-balance                    View ERC20Supra balance of registry contract"
    echo "  task-list                           View all task IDs"
    echo "  total-tasks                         View number of tasks"
    echo "  user-tasks                          View tasks of a user"
    echo "  task-exists                         Check if a task exists"
    echo "  exit                                Quit"
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

        nativeToErc20SupraWithAllowance)
            echo "Enter: <depositAmount> <allowance>"
            read -r depositAmount allowance

            if [ -z "$depositAmount" ] || [ -z "$allowance" ]; then
                echo "Invalid input. Expected: <depositAmount>  <allowance>"
                exit 1
            fi

            depositWei=$(cast --to-wei "$depositAmount")
            allowanceWei=$(cast --to-wei "$allowance")

            echo "Depositing $depositAmount SUPRA, and approving $DIAMOND for $allowance ERC20Supra..."

            send_tx "$ERC20_SUPRA" \
                "nativeToErc20SupraWithAllowance(address,uint256)" \
                "$DIAMOND" "$allowanceWei" \
                --value "$depositWei"
        ;;

        approve)
            echo -n "Amount to approve (ETH): "
            read -r ethAmount
            weiAmount=$(cast --to-wei "$ethAmount")
            echo "Approving $ethAmount SUPRA..."
            cast erc20-token approve "$ERC20_SUPRA" "$DIAMOND" "$weiAmount" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
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

            aux_json="[]"

            send_tx "$DIAMOND" \
                "register(bytes,uint64,uint128,uint128,uint128,uint64,bytes[])" \
                "$payloadTx" "$expiryTime" "$maxGas" "$gasPriceCapWei" "$feeCapWei" "$priority" "$aux_json"
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

            echo -n "maxGasAmount: "
            read -r maxGas

            echo -n "Priority (uint64): "
            read -r priority

            aux_json="[]"

            send_tx "$DIAMOND" \
                "registerSystemTask(bytes,uint64,uint128,uint64,bytes[])" \
                "$payloadTx" "$expiryTime" "$maxGas" "$priority" "$aux_json"
        ;;

        cancel)
            echo -n "Task index: "
            read -r index
            send_tx "$DIAMOND" "cancelTask(uint64)" "$index"
        ;;

        cancel-system)
            echo -n "System task index: "
            read -r index
            send_tx "$DIAMOND" "cancelSystemTask(uint64)" "$index"
        ;;

        stop)
            echo -n "Enter task indexes array (e.g. [0,1,2,3]): "
            read -r indexes
            send_tx "$DIAMOND" "stopTasks(uint64[])" "$indexes"
        ;;

        stop-system)
            echo -n "System task indexes array (e.g. [0,1,2,3]): "
            read -r indexes
            send_tx "$DIAMOND" "stopSystemTasks(uint64[])" "$indexes"
        ;;

        grant-authorization)
            echo -n "Address to grant authorization to: "
            read -r -a address
            cast send "$DIAMOND" "grantAuthorization(address)" "$address" \
                --rpc-url "$RPC_URL" \
                --private-key "$ADMIN_PRIVATE_KEY" \
                --gas-limit 3000000
        ;;

        revoke-authorization)
            echo -n "Address to revoke authorization on: "
            read -r -a address
            cast send "$DIAMOND" "revokeAuthorization(address)" "$address" \
                --rpc-url "$RPC_URL" \
                --private-key "$ADMIN_PRIVATE_KEY" \
                --gas-limit 3000000
        ;;

        is-submitter) is_authorized_submitter ;;
        task-details) view_task_details ;;
        registry-locked-balance) view_registry_locked_balance ;;
        registry-balance) view_registry_erc20Supra_balance ;;
        task-list) view_task_list ;;
        total-tasks) view_total_tasks ;;
        user-tasks) view_user_tasks ;;
        task-exists) check_task_exists ;;

        exit)
            echo "Exiting."
            exit 0
        ;;

        *)
            echo "Unknown command."
        ;;
    esac
done
