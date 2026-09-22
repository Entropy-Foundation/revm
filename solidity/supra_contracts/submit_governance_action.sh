#!/bin/bash -x

# Script targeting localnet to initialize cycle monitoring for each block
# by registering AutomationController::monitor_cycle_end entry in block-metadata contract
# Steps:
#   - For localnet run:
#     - Start a supra localnet chain
#     - cp Logs/owners/evm* into env_setup directory created next to this script
#
#   - prepare .env file next to script with the following content
#
#      MULTISIG_WALLET_ADDRESS=0x0a3fa0df1f4e8777ea4a752a5a06681af6acba49
#      BLOCK_METADATA_ADDRESS=0x2cd6f3c0f0ca46ea1616adf9e396ee99c24559df
#      AUTOMATION_CONTROLLER=0x31fb454ab230303b7095064d385cae8d4da4651b
#      TIMEOUT=360
#
#   - export PASSWORD variable, otherwise password will be requested during run
#     - with value of the CLI_PROFILE_PASSWORD of the local nodes
#
#   - run this script
#
# GOV_TXN_INDEX is the index the submit step's own broadcast receipt records for its
# SubmitTransaction event (via read_submitted_tx_index.sh). GOV_TXN_CONTENT_HASH, scraped from
# the submit step's own "TxnContentHash:" log line, is the digest of the action this run
# submitted; confirmTransaction and executeTransaction reject any index whose stored content
# does not match it.

set -euo pipefail

# Import environment variables from .env file. This script expects the following variables to be set in the .env file:
source .env

if [ -z "${1:-}" ]; then
    echo "Usage: $0 GOV_ACTION_SCRIPT_NAME"
    exit 1
fi

action=$1

password=""
if [ -n "${PASSWORD:-}" ]; then
  password="--password ${PASSWORD}"
fi

script_path=$(dirname $(realpath ${0}))
foundation_owners=( $(ls ${script_path}/env_setup/evm*) )
foundation_owners_addresses=()
for owner in ${foundation_owners[*]}
do
  foundation_owners_addresses+=( $(basename ${owner} | cut -d "_" -f2) )
done

echo ${foundation_owners[*]} ${foundation_owners_addresses[*]}

result=$(forge script ${script_path}/script/GovActions.s.sol:${action} --keystore ${foundation_owners[0]} --sender ${foundation_owners_addresses[0]} --broadcast ${password})
echo "${result}"

export GOV_TXN_CONTENT_HASH=$(echo "${result}" | grep -o "TxnContentHash: 0x[0-9a-fA-F]*" | head -1 | cut -d " " -f2)
if [ -z "${GOV_TXN_CONTENT_HASH}" ]; then
    echo "Could not read the submitted transaction's content hash from the script output." >&2
    exit 1
fi

# forge writes this run's receipt to broadcast/GovActions.s.sol/<chainId>/run-latest.json; the
# submit step above is the most recently written one regardless of which chain this is run
# against.
run_latest_json=$(ls -t ${script_path}/broadcast/GovActions.s.sol/*/run-latest.json | head -1)
export GOV_TXN_INDEX=$(${script_path}/read_submitted_tx_index.sh "${run_latest_json}" "${MULTISIG_WALLET_ADDRESS}")
if [ -z "${GOV_TXN_INDEX}" ]; then
    echo "Could not read the submitted transaction's index from the script output." >&2
    exit 2
fi

echo "Voting for: ${GOV_TXN_INDEX} (content hash ${GOV_TXN_CONTENT_HASH})"
length=${#foundation_owners[@]}
for ((  i = 1;  i < length;  i++ )); do
    keystore=${foundation_owners[$i]}
    address=${foundation_owners_addresses[$i]}
    echo ${keystore} ${address}
    forge script ${script_path}/script/GovActions.s.sol:VoteForTxn --keystore ${keystore} --sender ${address} --broadcast ${password}
done

echo "Executing Txn with index: ${GOV_TXN_INDEX}"
forge script ${script_path}/script/GovActions.s.sol:ExecuteTxn --keystore ${foundation_owners[0]} --sender ${foundation_owners_addresses[0]} --broadcast ${password}
