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
            --out-file queries/utxo-collateral.json

cardano-cli query utxo \
            --address "$(cat addresses/address-script.addr)" \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --out-file queries/utxo.json

cardano-cli query protocol-parameters \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --out-file queries/parameters.json

# cardano-cli transaction build-raw
TXIN_COLLATERAL=$(jq -r 'keys[0]' queries/utxo-collateral.json)
TXIN=$(jq -r 'keys[0]' queries/utxo.json)
LOVELACE=$(jq -r ".[\"$TXIN\"].value.lovelace" queries/utxo.json)

mkdir -p txs

cardano-cli transaction build \
            --alonzo-era \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --tx-in ${TXIN} \
            --tx-in-collateral ${TXIN_COLLATERAL} \
            --change-address $(cat addresses/address-script.addr) \
            --certificate-file certs/register-stake-address-script  \
            --certificate-file certs/delegate-script \
            --certificate-script-file ${SCRIPTPATH} \
            --certificate-redeemer-file ${REDEEMERPATH} \
            --protocol-params-file queries/parameters.json \
            --out-file txs/delegate.raw

cardano-cli transaction sign \
            --tx-body-file txs/delegate.raw \
            --signing-key-file addresses/payment-addr.skey \
            --testnet-magic ${TESTNET_MAGIC} \
            --out-file txs/delegate

cardano-cli transaction submit \
            --cardano-mode \
            --testnet-magic ${TESTNET_MAGIC} \
            --tx-file txs/delegate
