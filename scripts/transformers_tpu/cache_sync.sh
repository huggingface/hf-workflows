#!/usr/bin/env bash
# Usage: cache_sync.sh <source> <destination>
#
# Copies the compilation cache entries missing from the destination. `hf sync` moves about 500 files/min and the cache
# holds about a million entries, so it runs in 16 shards (by the first hex digit of the entry name), retrying the shards
# that fail.
set -u

src=$1
dst=$2
hf=${HF_CLI:-hf}
logs=$(mktemp -d)
pending="0 1 2 3 4 5 6 7 8 9 a b c d e f"
start=$SECONDS

for attempt in 1 2 3; do
  for shard in $pending; do
    ( "$hf" sync "$src" "$dst" --include "*/${shard}*.bin" --no-delete --ignore-existing \
        > "$logs/$shard.log" 2>&1 || touch "$logs/$shard.failed" ) &
  done
  wait
  pending=""
  for failed in "$logs"/*.failed; do
    [ -e "$failed" ] && pending+="$(basename "$failed" .failed) " && rm "$failed"
  done
  [ -z "$pending" ] && break
  echo "Attempt $attempt: shards ${pending}failed"
  sleep 60
done

for log in "$logs"/*.log; do
  echo "== shard $(basename "$log" .log)"
  tail -n 5 "$log"
done
summary="Sync from \`$src\` to \`$dst\`: $((SECONDS - start)) s${pending:+, failed shards: $pending}"
echo "$summary"
echo "- $summary" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
[ -z "$pending" ]
