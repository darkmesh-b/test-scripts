#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIG
# ============================================================

PVC_START=0
PVC_END=19

# Number of PVCs mounted per source/destination batch.
# Start conservative; raise once attach/mount behaviour is proven.
BATCH_SIZE="${BATCH_SIZE:-8}"

# Number of simultaneous rsync streams inside each batch.
IN_BATCH_PARALLEL="${IN_BATCH_PARALLEL:-4}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-900s}"

# Source cluster: OpenShift / ODF side
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/tmp/migration-kubeconfig}"
SOURCE_CTX="${SOURCE_CTX:-migration-context}"
SOURCE_NS="${SOURCE_NS:-default}"

# Destination cluster: VKS side
DEST_KUBECONFIG="${DEST_KUBECONFIG:-$HOME/.kube/config}"
DEST_CTX="${DEST_CTX:-migration-vks:migration-vks}"
DEST_NS="${DEST_NS:-testing}"

# PVC naming
SOURCE_PREFIX="${SOURCE_PREFIX:-data-genome-filler-ceph-}"
DEST_PREFIX="${DEST_PREFIX:-destination-pvc-}"

# One LB Service exposes BASE_PORT, BASE_PORT+1, ...
BASE_PORT="${BASE_PORT:-31000}"

# Source service account. Needs privileged SCC on OpenShift source.
SOURCE_SA="${SOURCE_SA:-poc-rsync-source}"

# Keep resources after run for debugging:
#   KEEP_RESOURCES=1 /tmp/one-lb-envoy-rsync-poc.sh
KEEP_RESOURCES="${KEEP_RESOURCES:-0}"

# Runtime images
SOURCE_IMAGE="${SOURCE_IMAGE:-alpine:3.20}"
DEST_IMAGE="${DEST_IMAGE:-alpine:3.20}"
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.31-latest}"

RUN_ID="${RUN_ID:-rsync-poc-$(date +%s)}"

# ============================================================
# KUBECTL WRAPPERS
# ============================================================

k_src() {
  kubectl --kubeconfig="$SOURCE_KUBECONFIG" --context="$SOURCE_CTX" -n "$SOURCE_NS" "$@"
}

k_dest() {
  kubectl --kubeconfig="$DEST_KUBECONFIG" --context="$DEST_CTX" -n "$DEST_NS" "$@"
}

oc_src_cluster() {
  oc --kubeconfig="$SOURCE_KUBECONFIG" --context="$SOURCE_CTX" "$@"
}

# ============================================================
# CLEANUP
# ============================================================

cleanup_batch() {
  local batch="$1"

  if [ "$KEEP_RESOURCES" = "1" ]; then
    echo "KEEP_RESOURCES=1 set; leaving resources for batch $batch"
    return 0
  fi

  echo "Cleaning up batch $batch resources..."

  k_src delete pod,secret \
    -l "app=one-lb-envoy-rsync-poc,migration-run=${batch}" \
    --ignore-not-found=true >/dev/null 2>&1 || true

  k_dest delete pod,svc,configmap \
    -l "app=one-lb-envoy-rsync-poc,migration-run=${batch}" \
    --ignore-not-found=true >/dev/null 2>&1 || true
}

cleanup_all_on_exit() {
  if [ "$KEEP_RESOURCES" = "1" ]; then
    return 0
  fi

  # Only clean resources created by this run.
  k_src delete pod,secret \
    -l "app=one-lb-envoy-rsync-poc,run-id=${RUN_ID}" \
    --ignore-not-found=true >/dev/null 2>&1 || true

  k_dest delete pod,svc,configmap \
    -l "app=one-lb-envoy-rsync-poc,run-id=${RUN_ID}" \
    --ignore-not-found=true >/dev/null 2>&1 || true
}

trap cleanup_all_on_exit EXIT

# ============================================================
# HELPERS
# ============================================================

wait_for_lb() {
  local svc="$1"
  local target=""

  echo "Waiting for LoadBalancer address on service/$svc..." >&2

  for _ in $(seq 1 300); do
    target="$(k_dest get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

    if [ -z "$target" ]; then
      target="$(k_dest get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    fi

    if [ -n "$target" ]; then
      echo "$target"
      return 0
    fi

    sleep 2
  done

  echo "Timed out waiting for LoadBalancer address for service/$svc" >&2
  return 1
}

apply_configmap_from_file_dest() {
  local name="$1"
  local key="$2"
  local file="$3"
  local batch="$4"

  k_dest create configmap "$name" \
    --from-file="${key}=${file}" \
    --dry-run=client -o yaml \
    | k_dest apply -f - >/dev/null

  k_dest label configmap "$name" \
    app=one-lb-envoy-rsync-poc \
    role=config \
    "run-id=${RUN_ID}" \
    "migration-run=${batch}" \
    --overwrite >/dev/null
}

apply_configmap_from_file_src() {
  local name="$1"
  local key="$2"
  local file="$3"
  local batch="$4"

  k_src create configmap "$name" \
    --from-file="${key}=${file}" \
    --dry-run=client -o yaml \
    | k_src apply -f - >/dev/null

  k_src label configmap "$name" \
    app=one-lb-envoy-rsync-poc \
    role=config \
    "run-id=${RUN_ID}" \
    "migration-run=${batch}" \
    --overwrite >/dev/null
}

# ============================================================
# PRE-FLIGHT
# ============================================================

echo "Run ID: $RUN_ID"
echo "BATCH_SIZE=$BATCH_SIZE"
echo "IN_BATCH_PARALLEL=$IN_BATCH_PARALLEL"
echo "BASE_PORT=$BASE_PORT"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"; cleanup_all_on_exit' EXIT

echo "Creating source service account if needed..."
k_src create sa "$SOURCE_SA" --dry-run=client -o yaml | k_src apply -f - >/dev/null

echo "Trying to grant privileged SCC to source service account..."
if ! oc_src_cluster adm policy add-scc-to-user privileged -z "$SOURCE_SA" -n "$SOURCE_NS" >/dev/null 2>&1; then
  echo "WARNING: could not grant privileged SCC automatically."
  echo "If source pod is rejected, run:"
  echo "  oc --kubeconfig=\"$SOURCE_KUBECONFIG\" --context=\"$SOURCE_CTX\" adm policy add-scc-to-user privileged -z \"$SOURCE_SA\" -n \"$SOURCE_NS\""
fi

echo "Generating ephemeral SSH key..."
ssh-keygen -t ed25519 -f "$TMPDIR/id_ed25519" -N "" -q
cp "$TMPDIR/id_ed25519.pub" "$TMPDIR/authorized_keys"
PRIV_KEY_B64="$(base64 < "$TMPDIR/id_ed25519" | tr -d '\n')"

PVC_INDEXES=()
for i in $(seq "$PVC_START" "$PVC_END"); do
  PVC_INDEXES+=("$i")
done

# ============================================================
# BATCH LOOP
# ============================================================

batch_num=0

for ((offset=0; offset<${#PVC_INDEXES[@]}; offset+=BATCH_SIZE)); do
  batch_num=$((batch_num + 1))
  CHUNK=("${PVC_INDEXES[@]:offset:BATCH_SIZE}")

  BATCH="${RUN_ID}-b${batch_num}"
  SRC_POD="${BATCH}-source"
  GW_POD="${BATCH}-envoy"
  GW_SVC="${BATCH}-envoy"
  ENVOY_CM="${BATCH}-envoy-config"
  AUTH_CM="${BATCH}-auth"
  SSH_SECRET="${BATCH}-ssh-key"

  echo
  echo "============================================================"
  echo "Processing batch $batch_num: indexes ${CHUNK[*]}"
  echo "Batch name: $BATCH"
  echo "============================================================"

  trap 'cleanup_batch "'"$BATCH"'"' ERR

  # ------------------------------------------------------------
  # Generate Envoy config
  # ------------------------------------------------------------

  ENVOY_CFG="$TMPDIR/envoy-${BATCH}.yaml"

  cat > "$ENVOY_CFG" <<EOF_ENVOY
admin:
  address:
    socket_address:
      address: 0.0.0.0
      port_value: 9901

static_resources:
  listeners:
EOF_ENVOY

  local_slot=0
  for idx in "${CHUNK[@]}"; do
    port=$((BASE_PORT + local_slot))

    cat >> "$ENVOY_CFG" <<EOF_ENVOY
  - name: listener_${idx}
    address:
      socket_address:
        address: 0.0.0.0
        port_value: ${port}
    filter_chains:
    - filters:
      - name: envoy.filters.network.tcp_proxy
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
          stat_prefix: rsync_${idx}
          cluster: dest_${idx}
EOF_ENVOY

    local_slot=$((local_slot + 1))
  done

  cat >> "$ENVOY_CFG" <<EOF_ENVOY

  clusters:
EOF_ENVOY

  for idx in "${CHUNK[@]}"; do
    cat >> "$ENVOY_CFG" <<EOF_ENVOY
  - name: dest_${idx}
    connect_timeout: 10s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: dest_${idx}
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: ${BATCH}-dest-${idx}.${DEST_NS}.svc.cluster.local
                port_value: 22
EOF_ENVOY
  done

  echo "Applying destination ConfigMaps..."
  apply_configmap_from_file_dest "$ENVOY_CM" envoy.yaml "$ENVOY_CFG" "$BATCH"
  apply_configmap_from_file_dest "$AUTH_CM" authorized_keys "$TMPDIR/authorized_keys" "$BATCH"

  # ------------------------------------------------------------
  # Destination resources:
  #   - Envoy gateway pod
  #   - one LB service exposing many ports
  #   - one sshd worker pod/service per destination PVC
  # ------------------------------------------------------------

  DEST_YAML="$TMPDIR/dest-${BATCH}.yaml"

  cat > "$DEST_YAML" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${GW_POD}
  namespace: ${DEST_NS}
  labels:
    app: one-lb-envoy-rsync-poc
    role: gateway
    run-id: ${RUN_ID}
    migration-run: ${BATCH}
spec:
  containers:
  - name: envoy
    image: ${ENVOY_IMAGE}
    args:
    - "-c"
    - "/etc/envoy/envoy.yaml"
    - "--log-level"
    - "info"
    ports:
YAML

  local_slot=0
  for idx in "${CHUNK[@]}"; do
    port=$((BASE_PORT + local_slot))
    cat >> "$DEST_YAML" <<YAML
    - name: p${port}
      containerPort: ${port}
      protocol: TCP
YAML
    local_slot=$((local_slot + 1))
  done

  cat >> "$DEST_YAML" <<YAML
    - name: admin
      containerPort: 9901
      protocol: TCP
    readinessProbe:
      httpGet:
        path: /ready
        port: 9901
      initialDelaySeconds: 2
      periodSeconds: 3
    volumeMounts:
    - name: envoy-config
      mountPath: /etc/envoy
      readOnly: true
  volumes:
  - name: envoy-config
    configMap:
      name: ${ENVOY_CM}
---
apiVersion: v1
kind: Service
metadata:
  name: ${GW_SVC}
  namespace: ${DEST_NS}
  labels:
    app: one-lb-envoy-rsync-poc
    role: gateway
    run-id: ${RUN_ID}
    migration-run: ${BATCH}
spec:
  type: LoadBalancer
  selector:
    app: one-lb-envoy-rsync-poc
    role: gateway
    migration-run: ${BATCH}
  ports:
YAML

  local_slot=0
  for idx in "${CHUNK[@]}"; do
    port=$((BASE_PORT + local_slot))
    cat >> "$DEST_YAML" <<YAML
  - name: p${port}
    port: ${port}
    targetPort: ${port}
    protocol: TCP
YAML
    local_slot=$((local_slot + 1))
  done

  for idx in "${CHUNK[@]}"; do
    dest_pvc="${DEST_PREFIX}${idx}"

    cat >> "$DEST_YAML" <<YAML
---
apiVersion: v1
kind: Service
metadata:
  name: ${BATCH}-dest-${idx}
  namespace: ${DEST_NS}
  labels:
    app: one-lb-envoy-rsync-poc
    role: dest-worker
    run-id: ${RUN_ID}
    migration-run: ${BATCH}
    pvc-index: "${idx}"
spec:
  type: ClusterIP
  selector:
    app: one-lb-envoy-rsync-poc
    role: dest-worker
    migration-run: ${BATCH}
    pvc-index: "${idx}"
  ports:
  - name: ssh
    port: 22
    targetPort: 22
    protocol: TCP
---
apiVersion: v1
kind: Pod
metadata:
  name: ${BATCH}-dest-${idx}
  namespace: ${DEST_NS}
  labels:
    app: one-lb-envoy-rsync-poc
    role: dest-worker
    run-id: ${RUN_ID}
    migration-run: ${BATCH}
    pvc-index: "${idx}"
spec:
  securityContext:
    runAsUser: 0
  containers:
  - name: sshd
    image: ${DEST_IMAGE}
    command:
    - /bin/sh
    - -c
    - |
      set -eu

      apk add --no-cache openssh rsync
      ssh-keygen -A

      mkdir -p /root/.ssh
      cp /auth/authorized_keys /root/.ssh/authorized_keys
      chmod 700 /root/.ssh
      chmod 600 /root/.ssh/authorized_keys

      cat > /etc/ssh/sshd_config <<'SSHD'
      Port 22
      PermitRootLogin prohibit-password
      PasswordAuthentication no
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      PermitTunnel no
      AllowTcpForwarding no
      X11Forwarding no
      MaxStartups 100:30:200
      MaxSessions 100
      Subsystem sftp internal-sftp
      SSHD

      touch /tmp/ready
      exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
    readinessProbe:
      exec:
        command:
        - /bin/sh
        - -c
        - test -f /tmp/ready
      initialDelaySeconds: 2
      periodSeconds: 3
    volumeMounts:
    - name: auth
      mountPath: /auth
      readOnly: true
    - name: data
      mountPath: /data
  volumes:
  - name: auth
    configMap:
      name: ${AUTH_CM}
  - name: data
    persistentVolumeClaim:
      claimName: ${dest_pvc}
YAML
  done

  echo "Applying destination pods/services..."
  if ! k_dest apply -f "$DEST_YAML"; then
    echo
    echo "Destination manifest failed. Generated YAML:"
    nl -ba "$DEST_YAML" | sed -n '1,260p'
    exit 1
  fi

  # ------------------------------------------------------------
  # Source resources:
  #   - SSH private key secret
  #   - one privileged source pod mounting all source PVCs read-only
  # ------------------------------------------------------------

  SOURCE_YAML="$TMPDIR/source-${BATCH}.yaml"

  cat > "$SOURCE_YAML" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${SSH_SECRET}
  namespace: ${SOURCE_NS}
  labels:
    app: one-lb-envoy-rsync-poc
    role: source
    run-id: ${RUN_ID}
    migration-run: ${BATCH}
type: Opaque
data:
  id_ed25519: ${PRIV_KEY_B64}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${SRC_POD}
  namespace: ${SOURCE_NS}
  labels:
    app: one-lb-envoy-rsync-poc
    role: source
    run-id: ${RUN_ID}
    migration-run: ${BATCH}
spec:
  serviceAccountName: ${SOURCE_SA}
  securityContext:
    runAsUser: 0
  containers:
  - name: rsync-client
    image: ${SOURCE_IMAGE}
    securityContext:
      privileged: true
    command:
    - /bin/sh
    - -c
    - |
      set -eu

      apk add --no-cache openssh-client rsync

      mkdir -p /root/.ssh
      cp /ssh/id_ed25519 /root/.ssh/id_ed25519
      chmod 600 /root/.ssh/id_ed25519

      cat > /root/.ssh/config <<'SSHCFG'
      Host *
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
      SSHCFG

      touch /tmp/ready
      sleep infinity
    readinessProbe:
      exec:
        command:
        - /bin/sh
        - -c
        - test -f /tmp/ready
      initialDelaySeconds: 2
      periodSeconds: 3
    volumeMounts:
    - name: ssh-key
      mountPath: /ssh
      readOnly: true
YAML

  for idx in "${CHUNK[@]}"; do
    src_pvc="${SOURCE_PREFIX}${idx}"
    cat >> "$SOURCE_YAML" <<YAML
    - name: src-${idx}
      mountPath: /mnt/src/${src_pvc}
      readOnly: true
YAML
  done

  cat >> "$SOURCE_YAML" <<YAML
  volumes:
  - name: ssh-key
    secret:
      secretName: ${SSH_SECRET}
      defaultMode: 0400
YAML

  for idx in "${CHUNK[@]}"; do
    src_pvc="${SOURCE_PREFIX}${idx}"
    cat >> "$SOURCE_YAML" <<YAML
  - name: src-${idx}
    persistentVolumeClaim:
      claimName: ${src_pvc}
      readOnly: true
YAML
  done

  echo "Applying source pod..."
  if ! k_src apply -f "$SOURCE_YAML"; then
    echo
    echo "Source manifest failed. Generated YAML:"
    nl -ba "$SOURCE_YAML" | sed -n '1,240p'
    exit 1
  fi

  # ------------------------------------------------------------
  # Wait for readiness
  # ------------------------------------------------------------

  echo "Waiting for destination worker pods..."
  k_dest wait \
    --for=condition=Ready pod \
    -l "app=one-lb-envoy-rsync-poc,role=dest-worker,migration-run=${BATCH}" \
    --timeout="$WAIT_TIMEOUT"

  echo "Waiting for Envoy gateway pod..."
  k_dest wait \
    --for=condition=Ready pod/"$GW_POD" \
    --timeout="$WAIT_TIMEOUT"

  echo "Waiting for source pod..."
  k_src wait \
    --for=condition=Ready pod/"$SRC_POD" \
    --timeout="$WAIT_TIMEOUT"

  TARGET_IP="$(wait_for_lb "$GW_SVC")"
  echo "Gateway address: $TARGET_IP"

  echo
  echo "Destination services:"
  k_dest get svc -l "app=one-lb-envoy-rsync-poc,migration-run=${BATCH}" -o wide

  # ------------------------------------------------------------
  # Build rsync map
  # ------------------------------------------------------------

  MAP_FILE="$TMPDIR/rsync-map-${BATCH}.txt"
  : > "$MAP_FILE"

  local_slot=0
  for idx in "${CHUNK[@]}"; do
    src_pvc="${SOURCE_PREFIX}${idx}"
    port=$((BASE_PORT + local_slot))
    echo "${src_pvc} ${port}" >> "$MAP_FILE"
    local_slot=$((local_slot + 1))
  done

  echo "Copying rsync map into source pod..."
  k_src exec -i "$SRC_POD" -c rsync-client -- sh -c 'cat > /tmp/rsync-map.txt' < "$MAP_FILE"

  echo "Installing rsync runner into source pod..."
  k_src exec -i "$SRC_POD" -c rsync-client -- sh -c 'cat > /tmp/run-rsyncs.sh && chmod +x /tmp/run-rsyncs.sh' <<'RUNNER'
#!/bin/sh
set -eu

echo "Target LB: ${TARGET_IP}"
echo "Parallel rsync streams: ${IN_BATCH_PARALLEL}"
echo
echo "Rsync map:"
cat /tmp/rsync-map.txt
echo

cat /tmp/rsync-map.txt | xargs -n 2 -P "${IN_BATCH_PARALLEL}" sh -c '
  set -eu

  SRC="$1"
  PORT="$2"

  echo
  echo "===== START ${SRC} via ${TARGET_IP}:${PORT} ====="

  rsync \
    -aH \
    --whole-file \
    --numeric-ids \
    --delete \
    --info=progress2 \
    -e "ssh -i /root/.ssh/id_ed25519 -p ${PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    "/mnt/src/${SRC}/" \
    "root@${TARGET_IP}:/data/"

  echo "===== DONE ${SRC} ====="
' _
RUNNER

  # ------------------------------------------------------------
  # Run batch transfer
  # ------------------------------------------------------------

  echo
  echo "Starting batch $batch_num transfer..."
  start_ts="$(date +%s)"

  k_src exec "$SRC_POD" -c rsync-client -- env \
    TARGET_IP="$TARGET_IP" \
    IN_BATCH_PARALLEL="$IN_BATCH_PARALLEL" \
    sh /tmp/run-rsyncs.sh

  end_ts="$(date +%s)"
  elapsed=$((end_ts - start_ts))

  echo
  echo "Batch $batch_num completed in ${elapsed}s"

  cleanup_batch "$BATCH"
  trap - ERR
done

echo
echo "All batches complete."
echo "Run ID was: $RUN_ID"