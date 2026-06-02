#!/usr/bin/env bash
set -euo pipefail

SRC_KUBECONFIG="${SRC_KUBECONFIG:-/tmp/migration-kubeconfig}"
SRC_CTX="${SRC_CTX:-migration-context}"
SRC_NS="${SRC_NS:-default}"

DST_CTX="${DST_CTX:-migration-vks:migration-vks}"
DST_NS="${DST_NS:-testing}"

SRC_PREFIX="${SRC_PREFIX:-data-genome-filler-ceph-}"
DST_PREFIX="${DST_PREFIX:-destination-pvc-}"

START="${START:-0}"
END="${END:-19}"

SECRET_NAME="${SECRET_NAME:-volsync-shared-psk}"
RUN_ID="${RUN_ID:-run-$(date +%s)}"

echo "VolSync run ID: $RUN_ID"
echo "Source PVCs: ${SRC_PREFIX}${START}..${SRC_PREFIX}${END}"
echo "Destination PVCs: ${DST_PREFIX}${START}..${DST_PREFIX}${END}"

k_src() {
  oc --kubeconfig="$SRC_KUBECONFIG" --context="$SRC_CTX" -n "$SRC_NS" "$@"
}

k_dst() {
  kubectl --context="$DST_CTX" -n "$DST_NS" "$@"
}

echo
echo "1. Annotating namespaces for privileged VolSync movers..."
oc --kubeconfig="$SRC_KUBECONFIG" --context="$SRC_CTX" \
  annotate namespace "$SRC_NS" volsync.backube/privileged-movers=true --overwrite

kubectl --context="$DST_CTX" \
  annotate namespace "$DST_NS" volsync.backube/privileged-movers=true --overwrite

echo
echo "2. Cleaning existing VolSync mover jobs..."

for j in $(k_src get job -o name | grep '^job.batch/volsync-' || true); do
  echo "Deleting source job $j"
  k_src delete "$j" --ignore-not-found
done

for j in $(k_dst get job -o name | grep '^job.batch/volsync-' || true); do
  echo "Deleting destination job $j"
  k_dst delete "$j" --ignore-not-found
done

echo
echo "3. Cleaning old VolSync test CRs for genome-${START}..genome-${END}..."

for i in $(seq "$START" "$END"); do
  k_src delete replicationsource "genome-${i}" --ignore-not-found
  k_src delete replicationsource "genome-${i}-clean" --ignore-not-found

  k_dst delete replicationdestination "genome-${i}" --ignore-not-found
  k_dst delete replicationdestination "genome-${i}-clean" --ignore-not-found
done

echo
echo "4. Verifying source and destination PVCs exist..."

missing=0

for i in $(seq "$START" "$END"); do
  if ! k_src get pvc "${SRC_PREFIX}${i}" >/dev/null 2>&1; then
    echo "Missing source PVC: ${SRC_PREFIX}${i}"
    missing=1
  fi

  if ! k_dst get pvc "${DST_PREFIX}${i}" >/dev/null 2>&1; then
    echo "Missing destination PVC: ${DST_PREFIX}${i}"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  echo "One or more PVCs are missing. Exiting."
  exit 1
fi

echo "PVC check passed."

echo
echo "5. Recreating shared rsyncTLS PSK secret..."

PSK="1:$(openssl rand -hex 32)"

k_src create secret generic "$SECRET_NAME" \
  --from-literal=psk.txt="$PSK" \
  --dry-run=client -o yaml | k_src apply -f -

k_dst create secret generic "$SECRET_NAME" \
  --from-literal=psk.txt="$PSK" \
  --dry-run=client -o yaml | k_dst apply -f -

echo
echo "6. Creating ReplicationDestination objects on destination..."

for i in $(seq "$START" "$END"); do
  k_dst apply -f - <<EOF2
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: genome-${i}
spec:
  rsyncTLS:
    copyMethod: Direct
    destinationPVC: ${DST_PREFIX}${i}
    keySecret: ${SECRET_NAME}
    serviceType: LoadBalancer
    moverSecurityContext:
      runAsUser: 0
      runAsGroup: 0
      fsGroup: 0
EOF2
done

echo
echo "7. Waiting for destination LoadBalancer addresses..."
echo "If the LB pool is too small, this is where it will stall."

for i in $(seq "$START" "$END"); do
  echo -n "genome-${i}: "

  for attempt in $(seq 1 300); do
    ADDR="$(k_dst get replicationdestination "genome-${i}" \
      -o jsonpath='{.status.rsyncTLS.address}' 2>/dev/null || true)"

    if [ -n "$ADDR" ]; then
      echo "$ADDR"
      break
    fi

    if [ "$attempt" -eq 300 ]; then
      echo "TIMEOUT waiting for address"
      exit 1
    fi

    sleep 2
  done
done

echo
echo "8. Creating ReplicationSource objects and triggering sync..."

for i in $(seq "$START" "$END"); do
  ADDR="$(k_dst get replicationdestination "genome-${i}" \
    -o jsonpath='{.status.rsyncTLS.address}')"

  k_src apply -f - <<EOF2
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: genome-${i}
spec:
  sourcePVC: ${SRC_PREFIX}${i}
  trigger:
    manual: ${RUN_ID}
  rsyncTLS:
    address: ${ADDR}
    keySecret: ${SECRET_NAME}
    copyMethod: Direct
    moverSecurityContext:
      runAsUser: 0
      runAsGroup: 0
      fsGroup: 0
EOF2
done

echo
echo "Triggered all syncs with manual token: $RUN_ID"
echo
echo "Watch with:"
echo "  /tmp/volsync-watch-20.sh $RUN_ID"
