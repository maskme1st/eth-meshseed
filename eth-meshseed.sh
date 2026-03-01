#!/usr/bin/env bash
# MIT License <-> Copyright © 2026 John Hauger Mitander

set -euo pipefail

RPC_URL="${RPC_URL:-${1:-http://127.0.0.1:8545}}"
DISCOVERY_API="${DISCOVERY_API:-https://nodeexplorer.ethnova.net/api}"
BOOTNODES_URL="${BOOTNODES_URL:-https://raw.githubusercontent.com/ethereum/go-ethereum/master/params/bootnodes.go}"

TARGET_NEW_PEERS="${TARGET_NEW_PEERS:-50}"
PAGE_SIZE="${PAGE_SIZE:-400}"
MAX_PAGES="${MAX_PAGES:-10}"
MIN_SEEN_COUNT="${MIN_SEEN_COUNT:-3}"
MAX_LAST_SEEN_HOURS="${MAX_LAST_SEEN_HOURS:-48}"
HTTP_TIMEOUT_SECS="${HTTP_TIMEOUT_SECS:-10}"

COUNTRY_CODE="${COUNTRY_CODE:-}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-1}"
OUTPUT_JSON="${OUTPUT_JSON:-peers_list.json}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

log() {
  if [[ "$VERBOSE" == "1" ]]; then
    echo "[$(date -u +%H:%M:%S)] $*"
  fi
}

rpc_call() {
  local method="$1"
  local params_json="$2"
  curl -fsS --max-time "$HTTP_TIMEOUT_SECS" \
    -H "Content-Type: application/json" \
    --data "$(jq -cn --arg m "$method" --argjson p "$params_json" '{jsonrpc:"2.0",id:1,method:$m,params:$p}')" \
    "$RPC_URL"
}

hex_to_dec() {
  local hex="${1:-0x0}"
  hex="${hex#0x}"
  if [[ -z "$hex" ]]; then
    echo 0
    return
  fi
  printf "%d\n" "0x$hex"
}

detect_country_code() {
  if [[ -n "$COUNTRY_CODE" ]]; then
    echo "$COUNTRY_CODE" | tr '[:lower:]' '[:upper:]'
    return
  fi

  local cc=""
  cc="$(curl -fsS --max-time "$HTTP_TIMEOUT_SECS" "https://ipapi.co/country/" 2>/dev/null || true)"
  cc="$(echo "$cc" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

  if [[ "$cc" =~ ^[A-Z]{2}$ ]]; then
    echo "$cc"
    return
  fi
  echo ""
}

fetch_nodes_page() {
  local status="$1"
  local page="$2"
  local country="${3:-}"

  local args=(
    --get
    --data-urlencode "status=$status"
    --data-urlencode "page=$page"
    --data-urlencode "pageSize=$PAGE_SIZE"
    --data-urlencode "sort=seen_count"
    --data-urlencode "dir=desc"
    --data-urlencode "hideIp=true"
  )
  if [[ -n "$country" ]]; then
    args+=(--data-urlencode "country=$country")
  fi

  curl -fsS --max-time "$HTTP_TIMEOUT_SECS" "${args[@]}" "$DISCOVERY_API/nodes"
}

collect_candidates() {
  local status="$1"
  local country="${2:-}"

  local now_ms max_age_ms page
  now_ms="$(( $(date +%s) * 1000 ))"
  max_age_ms="$(( MAX_LAST_SEEN_HOURS * 60 * 60 * 1000 ))"

  for page in $(seq 1 "$MAX_PAGES"); do
    local body
    if ! body="$(fetch_nodes_page "$status" "$page" "$country" 2>/dev/null)"; then
      break
    fi

    echo "$body" | jq -r \
      --argjson now "$now_ms" \
      --argjson max_age "$max_age_ms" \
      --argjson min_seen "$MIN_SEEN_COUNT" '
        .items[]? |
        select((.enode // "") | test("^enode://[0-9a-fA-F]{128}@")) |
        select((.caps // []) | any(startswith("eth/"))) |
        select((.seen_count // 0) >= $min_seen) |
        select((.last_seen // 0) >= ($now - $max_age)) |
        select((((.client_name // "") | ascii_downcase) | test("bor/|pulse"; "i")) | not) |
        [
          .enode,
          (.country_code // ""),
          (.seen_count // 0),
          (.last_seen // 0),
          (.online // false),
          (.client_name // "")
        ] | @tsv
      '

    local total pages_available
    total="$(echo "$body" | jq -r '.total // 0')"
    pages_available=$(( (total + PAGE_SIZE - 1) / PAGE_SIZE ))
    if (( page >= pages_available )); then
      break
    fi
  done
}

collect_bootnodes() {
  curl -fsS --max-time "$HTTP_TIMEOUT_SECS" "$BOOTNODES_URL" 2>/dev/null \
    | awk '
        /var MainnetBootnodes = \[]string\{/ {in_mainnet=1; next}
        in_mainnet && /^\}/ {in_mainnet=0}
        in_mainnet {print}
      ' \
    | rg -o 'enode://[^"]+' \
    | head -n 32 \
    | awk '{print $0 "\tBOOT\t1\t0\tfalse\tgo-ethereum-mainnet-bootnode"}'
}

read_current_peers() {
  rpc_call "admin_peers" "[]" \
    | jq -r '.result[]?.enode // empty'
}

read_self_enode() {
  rpc_call "admin_nodeInfo" "[]" \
    | jq -r '.result.enode // empty'
}

add_peer() {
  local enode="$1"
  local payload resp result

  # Cross-client compatibility:
  # - Geth/Reth: admin_addPeer([enode])
  # - Nethermind accepts addToStaticNodes as second arg.
  for payload in \
    "$(jq -cn --arg e "$enode" '[$e]')" \
    "$(jq -cn --arg e "$enode" '[$e,true]')" \
    "$(jq -cn --arg e "$enode" '[$e,false]')"
  do
    if ! resp="$(rpc_call "admin_addTrustedPeer" "$payload" 2>/dev/null)"; then
      continue
    fi
    result="$(echo "$resp" | jq -r '.result // empty')"
    if [[ "$result" == "true" ]]; then
      return 0
    fi
    if echo "$resp" | jq -e '.error == null' >/dev/null 2>&1; then
      # Some clients return false for duplicate/unreachable peers.
      return 1
    fi
  done

  return 1
}

main() {
  need_cmd curl
  need_cmd jq
  need_cmd rg
  need_cmd awk

  log "RPC: $RPC_URL"
  log "Discovery API: $DISCOVERY_API"

  local client_version
  if ! client_version="$(rpc_call "web3_clientVersion" "[]" | jq -r '.result // empty')"; then
    echo "failed to contact RPC at $RPC_URL" >&2
    exit 1
  fi
  if [[ -z "$client_version" ]]; then
    echo "RPC reachable but web3_clientVersion returned no result" >&2
    exit 1
  fi
  log "Client: $client_version"

  local peer_before_hex peer_before
  peer_before_hex="$(rpc_call "net_peerCount" "[]" | jq -r '.result // "0x0"')"
  peer_before="$(hex_to_dec "$peer_before_hex")"
  log "Current peer count: $peer_before"

  local cc
  cc="$(detect_country_code)"
  if [[ -n "$cc" ]]; then
    log "Location country code: $cc (same-country peers prioritized)"
  else
    log "Could not auto-detect country; using global peer discovery"
  fi

  local tmp_all tmp_existing tmp_filtered tmp_unique tmp_results
  tmp_all="$(mktemp)"
  tmp_existing="$(mktemp)"
  tmp_filtered="$(mktemp)"
  tmp_unique="$(mktemp)"
  tmp_results="$(mktemp)"
  trap 'rm -f "${tmp_all:-}" "${tmp_existing:-}" "${tmp_filtered:-}" "${tmp_unique:-}" "${tmp_results:-}"' EXIT

  if [[ -n "$cc" ]]; then
    collect_candidates "online" "$cc" >>"$tmp_all" || true
    collect_candidates "all" "$cc" >>"$tmp_all" || true
  fi
  collect_candidates "online" "" >>"$tmp_all" || true
  collect_candidates "all" "" >>"$tmp_all" || true
  collect_bootnodes >>"$tmp_all" || true

  if [[ ! -s "$tmp_all" ]]; then
    echo "no candidates discovered from web sources" >&2
    exit 1
  fi

  read_current_peers >"$tmp_existing" || true
  read_self_enode >>"$tmp_existing" || true
  sort -u "$tmp_existing" -o "$tmp_existing"

  # Keep input order preference while removing malformed/duplicate entries.
  awk -F'\t' '!seen[$1]++ { print }' "$tmp_all" >"$tmp_unique"

  # Filter out self/already connected and rank by:
  #   online desc, country match desc, seen_count desc, last_seen desc
  local country_rank
  country_rank="$cc"
  awk -F'\t' 'NF>=1 { print }' "$tmp_unique" \
    | jq -Rrs \
      --arg cc "$country_rank" \
      --rawfile existing "$tmp_existing" '
        def existing_set:
          ($existing
            | split("\n")
            | map(select(length>0))
            | map({(.): true})
            | add // {});

        (split("\n")
         | map(select(length>0))
         | map(split("\t"))
         | map({
             enode: .[0],
             country: (.[1] // ""),
             seen_count: ((.[2] // "0") | tonumber),
             last_seen: ((.[3] // "0") | tonumber),
             online: ((.[4] // "false") == "true"),
             client: (.[5] // "")
           })
         | map(select((existing_set[.enode] // false) | not))
         | map(. + {
             country_match: (.country == $cc),
             score: (
               (if .online then 1000000000 else 0 end) +
               (if .country == $cc and ($cc|length)==2 then 100000000 else 0 end) +
               (.seen_count * 1000) +
               .last_seen
             )
           })
         | sort_by(.score)
         | reverse
         | .[]
         | [.enode, .country, (.seen_count|tostring), (.last_seen|tostring), (.online|tostring), .client]
         | @tsv
        )
      ' >"$tmp_filtered"

  local candidate_count
  candidate_count="$(wc -l <"$tmp_filtered" | tr -d ' ')"
  if [[ "$candidate_count" == "0" ]]; then
    log "No new candidate peers after filtering existing/self peers."
    exit 0
  fi

  log "New candidate peers after filtering: $candidate_count"
  log "Target additions: $TARGET_NEW_PEERS"

  local added=0 attempted=0
  while IFS=$'\t' read -r enode country seen last_seen online client; do
    [[ -z "$enode" ]] && continue
    if (( attempted >= TARGET_NEW_PEERS )); then
      break
    fi
    attempted=$((attempted + 1))

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY_RUN addPeer $enode  # country=$country online=$online seen_count=$seen client=$client"
      added=$((added + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$enode" "$country" "$seen" "$last_seen" "$online" "$client" "dry_run" >>"$tmp_results"
      continue
    fi

    if add_peer "$enode"; then
      echo "added peer: $enode  # country=$country online=$online seen_count=$seen client=$client"
      added=$((added + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$enode" "$country" "$seen" "$last_seen" "$online" "$client" "added" >>"$tmp_results"
    else
      echo "failed peer: $enode  # country=$country online=$online seen_count=$seen client=$client" >&2
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$enode" "$country" "$seen" "$last_seen" "$online" "$client" "failed" >>"$tmp_results"
    fi
  done <"$tmp_filtered"

  local peer_after_hex peer_after
  peer_after_hex="$(rpc_call "net_peerCount" "[]" | jq -r '.result // "0x0"')"
  peer_after="$(hex_to_dec "$peer_after_hex")"

  mkdir -p "$(dirname "$OUTPUT_JSON")"
  jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg rpc_url "$RPC_URL" \
    --arg client_version "$client_version" \
    --arg country "${cc:-}" \
    --arg dry_run "$DRY_RUN" \
    --argjson target_new_peers "$TARGET_NEW_PEERS" \
    --argjson attempted_count "$attempted" \
    --argjson successful_add_calls "$added" \
    --argjson peer_count_before "$peer_before" \
    --argjson peer_count_after "$peer_after" \
    --rawfile ranked_tsv "$tmp_filtered" \
    --rawfile attempted_tsv "$tmp_results" '
      def parse_ranked($s):
        ($s
         | split("\n")
         | map(select(length>0))
         | map(split("\t"))
         | map({
             enode: .[0],
             country_code: (.[1] // ""),
             seen_count: ((.[2] // "0") | tonumber),
             last_seen_ms: ((.[3] // "0") | tonumber),
             online: ((.[4] // "false") == "true"),
             client: (.[5] // "")
           }));
      def parse_attempted($s):
        ($s
         | split("\n")
         | map(select(length>0))
         | map(split("\t"))
         | map({
             enode: .[0],
             country_code: (.[1] // ""),
             seen_count: ((.[2] // "0") | tonumber),
             last_seen_ms: ((.[3] // "0") | tonumber),
             online: ((.[4] // "false") == "true"),
             client: (.[5] // ""),
             status: (.[6] // "unknown")
           }));
      {
        generated_at_utc: $generated_at,
        rpc_url: $rpc_url,
        client_version: $client_version,
        country_code: (if $country == "" then null else $country end),
        dry_run: ($dry_run == "1"),
        target_new_peers: $target_new_peers,
        summary: {
          attempted: $attempted_count,
          successful_add_calls: $successful_add_calls,
          peer_count_before: $peer_count_before,
          peer_count_after: $peer_count_after
        },
        attempted_peers: parse_attempted($attempted_tsv),
        ranked_candidates: parse_ranked($ranked_tsv)
      }
    ' >"$OUTPUT_JSON"

  echo
  echo "summary:"
  echo "  client_version: $client_version"
  echo "  country_code: ${cc:-unknown}"
  echo "  attempted: $attempted"
  echo "  successful_add_calls: $added"
  echo "  peer_count_before: $peer_before"
  echo "  peer_count_after:  $peer_after"
  echo "  peers_list_json:  $OUTPUT_JSON"
}

main "$@"
