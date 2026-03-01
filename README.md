# eth-meshseed

Small script to find good Ethereum peers from public sources and add them to your node via JSON-RPC.

## What it does
- Fetches candidate enodes from web discovery data
- Prioritizes peers close to your location (same country first)
- Filters low-quality/stale peers
- Skips self + already-connected peers
- Adds peers with `admin_addPeer` using `curl`

## Requirements
- `bash`
- `curl`
- `jq`
- `rg` (ripgrep)
- Node JSON-RPC with `admin_*` enabled (Geth/Nethermind/Reth-compatible admin endpoint)

## Usage
```bash
# Dry run (preview only)
DRY_RUN=1 RPC_URL=http://127.0.0.1:8545 ./scripts/eth-meshseed.sh

# Live add (default target is 25)
RPC_URL=http://127.0.0.1:8545 ./scripts/eth-meshseed.sh
```

## Useful options
```bash
TARGET_NEW_PEERS=40
COUNTRY_CODE=NO
MIN_SEEN_COUNT=5
MAX_LAST_SEEN_HOURS=72
MAX_PAGES=8
```

## Notes
- Uses official mainnet geth bootnodes as fallback source
- Prints before/after peer count and add summary
- Safe to run repeatedly (dedupes current peers)

## License
*MIT* License
