#!/bin/bash
# Deploy SmokinFrogHotbox (tiered, finite) to Robinhood Chain mainnet (4663)
# and verify on Blockscout. Usage: DEPLOYER_KEY=0x... ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

FORGE=/home/peppa/.foundry/bin/forge
CAST=/home/peppa/.foundry/bin/cast
RPC=https://rpc.mainnet.chain.robinhood.com
BASE_URI="https://smokinfrog-production.up.railway.app/nft/meta/"
PAYOUT=0xAB07E08A351d2D3Db64422aFAe4E0503dD20D13f
# 99 tier codes (0 Common..4 Legendary), seed 20080806, maxSupply 1495
TIERS=0x010101000100010000000004010100030002010100030103000202020003020201040100010000010200010201030101020001000101000000020100000001000100010000020000020402000001020100020003000001030002000001010300020002

[ -n "${DEPLOYER_KEY:-}" ] || { echo "DEPLOYER_KEY not set"; exit 1; }
ADDR=$($CAST wallet address --private-key "$DEPLOYER_KEY")
BAL=$($CAST balance "$ADDR" --rpc-url $RPC)
echo "deployer: $ADDR  balance: $BAL wei"
[ "$BAL" != "0" ] || { echo "wallet has no gas ETH on chain 4663"; exit 1; }

OUT=$($FORGE create src/SmokinFrogHotbox.sol:SmokinFrogHotbox \
  --rpc-url $RPC --private-key "$DEPLOYER_KEY" --broadcast --json \
  --constructor-args "$TIERS" "$BASE_URI" $PAYOUT)
echo "$OUT"
CONTRACT=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])')
echo "deployed: $CONTRACT"

echo "-- post-deploy sanity --"
echo "artCount:  $($CAST call "$CONTRACT" 'artCount()(uint256)' --rpc-url $RPC)"
echo "maxSupply: $($CAST call "$CONTRACT" 'maxSupply()(uint256)' --rpc-url $RPC)"
echo "payout:    $($CAST call "$CONTRACT" 'payout()(address)' --rpc-url $RPC)"
echo "tier(12):  $($CAST call "$CONTRACT" 'tierOf(uint256)(uint8)' 12 --rpc-url $RPC) (expect 4 legendary)"
echo "price(12): $($CAST call "$CONTRACT" 'priceOf(uint256)(uint256)' 12 --rpc-url $RPC) (expect 0.25e18)"
echo "price(1):  $($CAST call "$CONTRACT" 'priceOf(uint256)(uint256)' 1 --rpc-url $RPC)"

echo "-- blockscout verify --"
$FORGE verify-contract "$CONTRACT" src/SmokinFrogHotbox.sol:SmokinFrogHotbox \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api \
  --constructor-args "$($CAST abi-encode 'constructor(bytes,string,address)' "$TIERS" "$BASE_URI" $PAYOUT)" \
  || echo "verification failed — rerun later, deploy itself is done"

echo ""
echo "NEXT: set HANGAR.CONTRACT = '$CONTRACT' in index.html and redeploy the site."
