#!/bin/bash
# Reads the transaction index a MultiSignatureWallet.submitTransaction call was assigned, from
# the Foundry broadcast receipt of that same call. Prints the decimal index on stdout and exits
# 0, or prints an error to stderr and exits non-zero.
#
# Usage: read_submitted_tx_index.sh <run-latest.json> <wallet-address>
#
# Requires `jq` and `cast` (from Foundry) on PATH.

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <run-latest.json> <wallet-address>" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 1
fi

receipt_file=$1
wallet_address=$2

if [ ! -f "${receipt_file}" ]; then
    echo "No such broadcast receipt: ${receipt_file}" >&2
    exit 1
fi

wallet_address_lower=$(echo "${wallet_address}" | tr '[:upper:]' '[:lower:]')

tx_function=$(jq -r '.transactions[0].function // ""' "${receipt_file}")
tx_to=$(jq -r '(.transactions[0].contractAddress // .transactions[0].transaction.to // "") | ascii_downcase' "${receipt_file}")
receipt_status=$(jq -r '.receipts[0].status // ""' "${receipt_file}")

if [[ "${tx_function}" != submitTransaction* ]]; then
    echo "Broadcast receipt's first transaction is not a submitTransaction call (got '${tx_function}')" >&2
    exit 1
fi

if [ "${tx_to}" != "${wallet_address_lower}" ]; then
    echo "Broadcast receipt's first transaction targets ${tx_to}, not the expected wallet ${wallet_address_lower}" >&2
    exit 1
fi

if [ "${receipt_status}" != "0x1" ]; then
    echo "Broadcast receipt's first transaction did not succeed (status=${receipt_status})" >&2
    exit 1
fi

submit_transaction_topic0=$(cast keccak "SubmitTransaction(address,uint256,address,uint256,bytes)")

matching_topics=$(jq -r --arg wallet "${wallet_address_lower}" --arg topic0 "${submit_transaction_topic0}" \
    '[.receipts[0].logs[] | select((.address | ascii_downcase) == $wallet and .topics[0] == $topic0) | .topics[2]]' \
    "${receipt_file}")

match_count=$(echo "${matching_topics}" | jq 'length')
if [ "${match_count}" -ne 1 ]; then
    echo "Expected exactly one SubmitTransaction log from the wallet in this receipt, found ${match_count}" >&2
    exit 1
fi

topic2=$(echo "${matching_topics}" | jq -r '.[0]')
cast to-dec "${topic2}"
