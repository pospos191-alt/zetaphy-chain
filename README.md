# ZETAPHY chain node setup

Published copy of the node setup script for the ZETAPHY testnet (Cosmos EVM
with post-quantum ML-DSA-44 accounts and vote signatures).

- `setup-node.sh`: the latest version
- `v/<sha256>.sh`: every published version, named by its SHA-256 and never
  changed; the Oracle Cloud `cloud-init.sh` downloads one of these and runs
  it only if the fingerprint matches

Testnet only. No keys or secrets are in this repository.
