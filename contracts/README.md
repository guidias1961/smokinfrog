# SmokinFrogHotbox — contracts

Open-edition ERC-721 for the HOTBOX HANGAR section of the site. 99 arts, each
starts at 0.01 ETH and ratchets +5% after every mint of the same art; proceeds
forward to `payout` on each mint; excess msg.value refunded in the same tx.
ERC-2981 5% royalty. Target chain: Robinhood Chain (4663).

- `src/SmokinFrogHotbox.sol` — the contract (solc 0.8.26, OZ v5.1.0)
- `test/SmokinFrogHotbox.t.sol` — forge suite (30 tests)
- `deploy.sh` — mainnet deploy + Blockscout verify (`DEPLOYER_KEY=0x... ./deploy.sh`)

Libs are not vendored: `forge install OpenZeppelin/openzeppelin-contracts@v5.1.0`
after cloning (forge-std comes with `forge init`).
