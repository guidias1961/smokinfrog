#!/bin/bash
# Deploy SmokinFrogHotbox to Robinhood Chain mainnet (4663) and verify on Blockscout.
# Usage: DEPLOYER_KEY=0x... ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

FORGE=/home/peppa/.foundry/bin/forge
CAST=/home/peppa/.foundry/bin/cast
RPC=https://rpc.mainnet.chain.robinhood.com
BASE_URI="https://smokinfrog-production.up.railway.app/nft/meta/"
PAYOUT=0xAB07E08A351d2D3Db64422aFAe4E0503dD20D13f
ARTS=99

[ -n "${DEPLOYER_KEY:-}" ] || { echo "DEPLOYER_KEY not set"; exit 1; }

ADDR=$($CAST wallet address --private-key "$DEPLOYER_KEY")
BAL=$($CAST balance "$ADDR" --rpc-url $RPC)
echo "deployer: $ADDR  balance: $BAL wei"
[ "$BAL" != "0" ] || { echo "wallet has no gas ETH on chain 4663 — fund it first"; exit 1; }

OUT=$($FORGE create src/SmokinFrogHotbox.sol:SmokinFrogHotbox \
  --rpc-url $RPC --private-key "$DEPLOYER_KEY" --broadcast --json \
  --constructor-args $ARTS "$BASE_URI" $PAYOUT)
echo "$OUT"
CONTRACT=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')
echo "deployed: $CONTRACT"

echo "-- post-deploy sanity --"
$CAST call "$CONTRACT" 'priceOf(uint256)(uint256)' 1 --rpc-url $RPC
$CAST call "$CONTRACT" 'artCount()(uint256)' --rpc-url $RPC
$CAST call "$CONTRACT" 'payout()(address)' --rpc-url $RPC
$CAST call "$CONTRACT" 'tokenURI(uint256)(string)' 1 --rpc-url $RPC 2>/dev/null || echo "tokenURI(1) reverts pre-mint as expected"

echo "-- blockscout verify --"
$FORGE verify-contract "$CONTRACT" src/SmokinFrogHotbox.sol:SmokinFrogHotbox \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args "$($CAST abi-encode 'constructor(uint256,string,address)' $ARTS "$BASE_URI" $PAYOUT)" \
  || echo "verification failed — rerun later, deploy itself is done"

echo ""
echo "NEXT: set HANGAR.CONTRACT = '$CONTRACT' in index.html and redeploy the site."
