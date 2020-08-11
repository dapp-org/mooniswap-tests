#!/usr/bin/env bash
set -e

declare -a contracts=(
  "./mooniswap/contracts/Mooniswap.sol"
  "./mooniswap/contracts/MooniFactory.sol"
)

declare -a libs=(
  "./mooniswap/contracts/libraries/UniERC20.sol"
  "./mooniswap/contracts/mocks/TokenMock.sol"
)

cp -r openzeppelin-contracts mooniswap/contracts/openzeppelin-contracts

for contract in ${contracts[@]}; do
  sed -i -e "s/@openzeppelin/\.\/openzeppelin-contracts/g" $contract
done

for lib in ${libs[@]}; do
  sed -i -e "s/@openzeppelin/\.\.\/openzeppelin-contracts/g" $lib
done

function clean() {
  rm -rf mooniswap/contracts/openzeppelin-contracts;

  for contract in ${contracts[@]}; do
    sed -i -e "s/\.\/openzeppelin-contracts/@openzeppelin/g" $contract
  done

  for lib in ${libs[@]}; do
    sed -i -e "s/\.\.\/openzeppelin-contracts/@openzeppelin/g" $lib
  done

}
trap clean EXIT

SOLC_FLAGS="--optimize --optimize-runs 999999" \
dapp --use solc:0.6.12 "$@"
