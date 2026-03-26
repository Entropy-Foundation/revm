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
#     - with value of the CLI_PROFILE_PASSWORD of the local nodes, which is currently "Blue!Tiger99@Moon.PROFILE"
#
#   - run this script
#

password=""
if [ -n ${PASSWORD} ]; then
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

result=$(forge script ${script_path}/script/GovActions.s.sol:InitializeCycleMonitoring --keystore ${foundation_owners[0]} --sender ${foundation_owners_addresses[0]} --broadcast ${password})
export GOV_TXN_INDEX=$(echo ${result} | grep -o "TxnIndex: [0-9]* "| cut -d ":" -f2 | tr -d " ")

echo "Voting for: ${GOV_TXN_INDEX}"
length=${#foundation_owners[@]}
for ((  i = 1;  i < length;  i++ )); do
    keystore=${foundation_owners[$i]}
    address=${foundation_owners_addresses[$i]}
    echo ${keystore} ${address}
    forge script ${script_path}/script/GovActions.s.sol:VoteForTxn --keystore ${keystore} --sender ${address} --broadcast ${password}
done

echo "Executing Txn with index: ${GOV_TXN_INDEX}"
forge script ${script_path}/script/GovActions.s.sol:ExecuteTxn --keystore ${foundation_owners[0]} --sender ${foundation_owners_addresses[0]} --broadcast ${password}
