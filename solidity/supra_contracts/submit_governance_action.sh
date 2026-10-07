#!/bin/bash
# Set here rather than on the shebang line: options on a `#!` line apply only when the kernel
# execs this file, and `bash submit_governance_action.sh` would ignore them. A failing step has
# to stop the run either way.
set -euo pipefail

# Runs one governance action on the genesis-deployed EVM system contracts through the foundation
# MultiSignatureWallet that owns them.
#
# The wallet requires a quorum, so a single action is three phases, each a separate forge script
# from script/GovActions.s.sol signed with an owner's keystore:
#   1. owner 0 submits the action (the submission counts as owner 0's confirmation);
#   2. owners 1 .. required-1 confirm it with VoteForTxn, where `required` is the wallet's
#      numConfirmationsRequired;
#   3. owner 0 executes it with ExecuteTxn.
#
# Usage: submit_governance_action.sh <InitializeCycleMonitoring|AuthorizeAccount|EnableDisableAutomation>
#
# Environment, either exported or written to a `.env` file next to this script:
#
#   EVM_RPC_URL           EVM JSON-RPC endpoint of the target chain, e.g.
#                         https://rpc-devnet.supra.com/rpc/v1/eth or
#                         http://localhost:27000/rpc/v1/eth
#   EVM_FOUNDATION_OWNERS keystore paths (Web3 Secret Storage JSON) of the owners who sign,
#                         space separated, at least numConfirmationsRequired of them; the first
#                         one submits and executes
#   CLI_PROFILE_PASSWORD  password of those keystores
#   FoundationWallet      address of the foundation MultiSignatureWallet
#   Timeout               seconds the submitted action stays executable
#
#   Per action:
#   InitializeCycleMonitoring  BlockMetadata, AutomationRegistry, SelectorGasLimit
#   AuthorizeAccount           AutomationRegistry, AccountToAuthorize
#   EnableDisableAutomation    AutomationRegistry, EnableAutomation (true or false)
#
# FoundationWallet, BlockMetadata and AutomationRegistry are named after the keys of the on-chain
# `0x1::evm_config::EvmContractsDetails` resource, which holds the addresses genesis deployed.
#
# Every signing owner needs an EVM balance to pay for its transaction. Genesis credits none, so
# fund the owners first (see README.md, "Post-genesis governance actions").

THIS_DIR=$(dirname "$(realpath "${0}")")
GOV_ACTIONS="${THIS_DIR}/script/GovActions.s.sol"

function usage() {
    echo "Usage: $0 <InitializeCycleMonitoring|AuthorizeAccount|EnableDisableAutomation>" >&2
    exit 1
}

action=${1:-}
# Only the actions that submit are accepted: VoteForTxn and ExecuteTxn are phases of every
# action, run below, and are not actions of their own.
case "${action}" in
    InitializeCycleMonitoring|AuthorizeAccount|EnableDisableAutomation) ;;
    *) usage ;;
esac

if [ -f "${THIS_DIR}/.env" ]; then
    # Exported so the forge scripts, which are separate processes, see the values.
    set -a
    # shellcheck disable=SC1091
    source "${THIS_DIR}/.env"
    set +a
fi

: "${EVM_RPC_URL:?EVM_RPC_URL is required: foundry.toml names no RPC endpoint}"
: "${EVM_FOUNDATION_OWNERS:?EVM_FOUNDATION_OWNERS is required: keystore paths of the signing owners}"
: "${CLI_PROFILE_PASSWORD:?CLI_PROFILE_PASSWORD is required: password of the keystores}"
: "${FoundationWallet:?FoundationWallet is required: the foundation multisig wallet address}"
: "${Timeout:?Timeout is required: seconds the submitted action stays executable}"
export FoundationWallet Timeout

# The keystore password reaches cast and forge as the path of a file holding it, rather than on
# argv: an argv password is readable by any local user for as long as the process runs
# (/proc/<pid>/cmdline, ps). The file is private and removed when this script exits, by whichever
# path. It is passed with --password-file to the commands that unlock a keystore, not exported as
# ETH_PASSWORD: with ETH_PASSWORD set, cast treats every call as a signing one and refuses a
# read-only `cast call` that names no keystore.
password_file=$(mktemp)
trap 'rm -f "${password_file}"' EXIT
chmod 600 "${password_file}"
printf '%s' "${CLI_PROFILE_PASSWORD}" > "${password_file}"
unset ETH_PASSWORD

rpc_arg=(--rpc-url "${EVM_RPC_URL}")
# Arguments every signing forge script below shares. --root makes forge resolve this project's
# foundry.toml and remappings, and write its broadcast receipts under ${THIS_DIR}/broadcast, from
# whatever directory the script is run in; the keystore paths stay relative to the caller's.
sign_args=(--root "${THIS_DIR}" --password-file "${password_file}" --broadcast "${rpc_arg[@]}")

wallet_owners=$(cast call "${FoundationWallet}" "getOwners()(address[])" "${rpc_arg[@]}" | tr '[:upper:]' '[:lower:]')
required=$(cast call "${FoundationWallet}" "numConfirmationsRequired()(uint256)" "${rpc_arg[@]}")
# cast renders a uint256 with a trailing annotation on some versions; keep the digits.
required=${required%% *}
echo "FoundationWallet ${FoundationWallet}: ${required} confirmation(s) required"

owner_keystores=()
owner_addresses=()
# EVM_FOUNDATION_OWNERS is a space separated list, split deliberately.
# shellcheck disable=SC2086
for keystore in ${EVM_FOUNDATION_OWNERS}; do
    if ! [ -f "${keystore}" ]; then
        echo "Keystore not found: ${keystore}" >&2
        exit 1
    fi
    address=$(cast wallet address --keystore "${keystore}" --password-file "${password_file}")
    # A keystore that does not belong to an owner would only fail at its confirmation, after
    # owner 0 has already paid for the submission.
    if ! grep -qi "${address}" <<< "${wallet_owners}"; then
        echo "${address} (${keystore}) is not an owner of FoundationWallet ${FoundationWallet}" >&2
        exit 1
    fi
    # The same owner listed twice would be asked to confirm a transaction it already confirmed.
    if [[ " ${owner_addresses[*]:-} " == *" ${address} "* ]]; then
        echo "${address} is listed more than once in EVM_FOUNDATION_OWNERS" >&2
        exit 1
    fi
    owner_keystores+=( "${keystore}" )
    owner_addresses+=( "${address}" )
done

if [ "${#owner_keystores[@]}" -lt "${required}" ]; then
    echo "${required} owners must sign, but EVM_FOUNDATION_OWNERS lists ${#owner_keystores[@]}" >&2
    exit 1
fi
echo "Signing owners: ${owner_addresses[*]:0:${required}}"

result=$(forge script "${GOV_ACTIONS}:${action}" --keystore "${owner_keystores[0]}" \
    --sender "${owner_addresses[0]}" "${sign_args[@]}")
echo "${result}"

# The digest of the action this run itself submitted, computed by the script from its own inputs
# before broadcasting, so scraping it from stdout cannot pick up someone else's submission. The
# first match is taken in case the output repeats the line.
GOV_TXN_CONTENT_HASH=$(grep -o "TxnContentHash: 0x[0-9a-fA-F]*" <<< "${result}" | head -1 | cut -d " " -f2 || true)
if [ -z "${GOV_TXN_CONTENT_HASH}" ]; then
    echo "Could not read the submitted action's content hash from the script output;" >&2
    echo "refusing to confirm an unknown transaction." >&2
    exit 1
fi
export GOV_TXN_CONTENT_HASH

# The index this submission was actually assigned, read from the SubmitTransaction event in its
# own broadcast receipt rather than predicted beforehand: a prediction can be pre-empted by
# another submission landing first. forge writes the receipt to
# broadcast/GovActions.s.sol/<chainId>/run-latest.json, and the submit step above is the most
# recently written one whichever chain this runs against.
run_latest_json=$(ls -t "${THIS_DIR}"/broadcast/GovActions.s.sol/*/run-latest.json | head -1)
GOV_TXN_INDEX=$("${THIS_DIR}/read_submitted_tx_index.sh" "${run_latest_json}" "${FoundationWallet}")
if [ -z "${GOV_TXN_INDEX}" ]; then
    echo "No transaction index available; refusing to confirm an unknown transaction." >&2
    exit 2
fi
export GOV_TXN_INDEX

echo "Confirming transaction ${GOV_TXN_INDEX} (content hash ${GOV_TXN_CONTENT_HASH})"
for (( i = 1; i < required; i++ )); do
    echo "Confirmation by ${owner_addresses[$i]}"
    forge script "${GOV_ACTIONS}:VoteForTxn" --keystore "${owner_keystores[$i]}" \
        --sender "${owner_addresses[$i]}" "${sign_args[@]}"
done

echo "Executing transaction ${GOV_TXN_INDEX}"
forge script "${GOV_ACTIONS}:ExecuteTxn" --keystore "${owner_keystores[0]}" \
    --sender "${owner_addresses[0]}" "${sign_args[@]}"
