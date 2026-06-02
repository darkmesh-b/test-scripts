#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${1:-}"

SRC_KUBECONFIG="${SRC_KUBECONFIG:-/tmp/migration-kubeconfig}"
SRC_CTX="${SRC_CTX:-migration-context}"
SRC_NS="${SRC_NS:-default}"

k_src() {
  oc --kubeconfig="$SRC_KUBECONFIG" --context="$SRC_CTX" -n "$SRC_NS" "$@"
}

while true; do
  clear
  echo "VolSync 20-PVC status"
  [ -n "$RUN_ID" ] && echo "Expected manual trigger: $RUN_ID"
  echo

  printf "%-10s %-16s %-18s %-12s %-18s\n" "PVC" "ManualSync" "Duration" "Result" "Reason"
  printf "%-10s %-16s %-18s %-12s %-18s\n" "---" "----------" "--------" "------" "------"

  complete=0
  failed=0
  total=0

  for i in $(seq 0 19); do
    name="genome-${i}"

    manual="$(k_src get replicationsource "$name" -o jsonpath='{.status.lastManualSync}' 2>/dev/null || true)"
    duration="$(k_src get replicationsource "$name" -o jsonpath='{.status.lastSyncDuration}' 2>/dev/null || true)"
    result="$(k_src get replicationsource "$name" -o jsonpath='{.status.latestMoverStatus.result}' 2>/dev/null || true)"
    reason="$(k_src get replicationsource "$name" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)"

    printf "%-10s %-16s %-18s %-12s %-18s\n" "$name" "${manual:-"-"}" "${duration:-"-"}" "${result:-"-"}" "${reason:-"-"}"

    total=$((total + 1))

    if [ "$result" = "Failed" ]; then
      failed=$((failed + 1))
    fi

    if [ -n "$RUN_ID" ] && [ "$manual" = "$RUN_ID" ] && [ "$result" = "Successful" ]; then
      complete=$((complete + 1))
    elif [ -z "$RUN_ID" ] && [ "$result" = "Successful" ]; then
      complete=$((complete + 1))
    fi
  done

  echo
  echo "Complete: $complete/$total   Failed: $failed/$total"

  if [ "$complete" -eq "$total" ]; then
    echo
    echo "All complete."
    exit 0
  fi

  if [ "$failed" -gt 0 ]; then
    echo
    echo "One or more syncs failed. Inspect with:"
    echo "  oc --kubeconfig=$SRC_KUBECONFIG --context=$SRC_CTX -n $SRC_NS describe replicationsource genome-N"
  fi

  sleep 5
done
