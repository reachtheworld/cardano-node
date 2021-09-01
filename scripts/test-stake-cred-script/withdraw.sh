#!/usr/bin/env bash

set -e
# Unoffiical bash strict mode.
# See: http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -u
set -o pipefail

source consts.sh
export CARDANO_NODE_SOCKET_PATH=${NODE_SOCK}

# query the UTxO
cardano-cli query utxo \
            --address "$(cat addresses/address.addr)" \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --out-file queries/utxo-collateral-claim.json

cardano-cli query utxo \
            --address "$(cat addresses/address-script.addr)" \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --out-file queries/utxo-claim.json

cardano-cli query protocol-parameters \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --out-file queries/parameters-claim.json

## FIXME: This currently uses a fixed stake address, we need to get this from the CLI
cardano-cli query stake-address-info \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --epoch-slots ${SLOTS_PER_EPOCH_BYRON} \
            --address ${STAKE_ADDRESS} \
            --out-file queries/stake-address-info.json


TXIN_COLLATERAL=$(jq -r 'keys[0]' queries/utxo-collateral-claim.json)
TXIN=$(jq -r 'keys[0]' queries/utxo-claim.json)
LOVELACE=$(jq -r ".[\"$TXIN\"].value.lovelace" queries/utxo-claim.json)

REWARDS_BALANCE=$(jq -r '.[0].rewardAccountBalance' queries/stake-address-info.json)

cardano-cli transaction build \
            --alonzo-era \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --tx-in ${TXIN} \
            --tx-in-collateral ${TXIN_COLLATERAL} \
            --change-address $(cat addresses/address-script.addr) \
            --withdrawal "${STAKE_ADDRESS}+${REWARDS_BALANCE}" \
            --withdrawal-script-file ${SCRIPTPATH} \
            --withdrawal-redeemer-file ${REDEEMERPATH} \
            --protocol-params-file queries/parameters.json \
            --out-file txs/withdraw.raw

cardano-cli transaction sign \
            --tx-body-file txs/withdraw.raw \
            --signing-key-file addresses/payment-addr.skey \
            --testnet-magic ${TESTNET_MAGIC} \
            --out-file txs/withdraw

cardano-cli transaction submit \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --tx-file txs/withdraw
