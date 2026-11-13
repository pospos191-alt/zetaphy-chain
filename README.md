# ZETAPHY chain node setup

Published copy of the node setup script for the ZETAPHY testnet (Cosmos EVM
with post-quantum ML-DSA-44 accounts and vote signatures).

- `setup-node.sh`: the latest version
- `v/<sha256>.sh`: every published version, named by its SHA-256 and never
  changed; the Oracle Cloud `cloud-init.sh` downloads one of these and runs
  it only if the fingerprint matches

## Mainnet `zetaphy_3659-1`

`mainnet/zetaphy_3659-1/` holds a copy of the published mainnet genesis (EVM chain id 3659, coin ZTPHY, genesis time
2026-11-13 14:00 UTC). Its sha256 is `ca0efb15f6ca80f57e157b32837e012a15f3dc3597531b18747629c8f0a94667`; check it
with `sha256sum -c genesis.sha256`. The source of truth and the full checks are in
https://github.com/pospos191-alt/zetaphy/tree/main/zetaphy-chain/mainnet/zetaphy_3659-1. Read the risk notice
first: https://github.com/pospos191-alt/zetaphy/blob/main/docs/ZETAPHY-MAINNET-NOTICE.md

No keys or secrets are in this repository: addresses and public keys only.
