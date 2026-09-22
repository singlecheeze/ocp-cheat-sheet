### RoCEv2 & GPUDirect Validation Test:  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ How is the `cuda_data_direct` mode different than `cuda_dmabuf` in `doca_perftest`?
- They are both GPUDirect RDMA GPU-memory modes, but they solve the GPU↔NIC mapping differently.
- `cuda_dmabuf` uses the Linux DMA-BUF framework to export GPU memory and let the NIC DMA directly into/out of that memory. It is the modern, broadly applicable GPUDirect RDMA path and requires compatible CUDA/kernel/driver support.
- `cuda_data_direct` is a newer, more specialized path. NVIDIA describes it as using direct PCIe mappings and ranks it ahead of DMA-BUF for performance; DOCA's automatic CUDA mode tries `cuda_data_direct` first, then `cuda_dmabuf`, then legacy `cuda_peermem`.
- NVIDIA's actual Data Direct architecture is associated with newer ConnectX hardware, particularly `ConnectX-8`, where the NIC exposes an additional PCIe Data Direct side-DMA function. That extra function can give the NIC a more direct PCIe path to GPU memory, avoiding less-efficient PCIe paths through the CPU/root-complex topology.
  
Continuing from the `Nvidia Network Operator` section, this section of the cheat sheet has as prerequisites:  
- `NicClusterPolicy`
- `MacvlanNetwork`, and auto created `NetworkAttachmentDefinition` in the `rdma-test` namespace
- Your switch (See `Mikrotik RoCEv2 Settings` section) needs to be configured for:
  - DCBX = Tells neighbors what the QoS/PFC/ETS policy is
  - ECT  = Says a packet is ECN-capable
  - ECN  = Marks congestion and tells the sender to reduce rate
  - PFC  = Temporarily pauses the congested priority before buffers overflow 
 
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ Sign in to [Nvidia NGC](https://org.ngc.nvidia.com/account/api-keys):
- Generate a personal API key with NGC Catalog container pull access, and retain the key because NGC does not display it again.
- NVIDIA’s documented registry username is the literal value `$oauthtoken`; the API key is supplied as the password.  
- Use  https://org.ngc.nvidia.com/account/api-keys:  
<img alt="image" src="Images/649545569-171d4734-0e81-49cd-94d5-ac96187e1fee.png" />

$${\color{deeppink}\textbf{\textsf{Validation Test Script:}}}$$ `gpudirect-test.sh`
<blockquote>
<details><summary>Show Script</summary>

[Source: `Sources/gpudirect-test.sh`](Sources/gpudirect-test.sh)
<!-- embed-code: ./Sources/gpudirect-test.sh -->
```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# gpudirect-test.sh
#
# Single-file OpenShift + NVIDIA DOCA RoCEv2 & GPUDirect RDMA test harness.
#
# It combines the capabilities previously split across:
#   create-gpudirect-test.sh
#   gpudirect-env.sh / gpudirect-env-v3.sh
#   run-gpudirect-test-v6.sh
#
# The existing secondary network (NetworkAttachmentDefinition) is intentionally
# NOT created or modified. This script validates and consumes it.
#
# Common examples:
#   ./gpudirect-test.sh apply
#   ./gpudirect-test.sh status
#   ./gpudirect-test.sh host --streams 8 --processes 4 --bond-stats
#   ./gpudirect-test.sh cuda --streams 8 --processes 4 --duration 30 --traffic-class 106 --bond-stats
#   ./gpudirect-test.sh all  --streams 8 --processes 4 --duration 30 --traffic-class 106 --bond-stats
#   ./gpudirect-test.sh delete
#
# For host/cuda/all, the OpenShift test objects are reconciled automatically
# before the benchmark unless --skip-apply is supplied.
#
# NGC credentials:
#   - If the pull secret already exists, normal runs do not prompt for a key.
#   - If it is missing, set NGC_API_KEY or enter it at the secure prompt.
#   - Use --refresh-ngc-secret to deliberately recreate/update the secret.

# ---------------------------------------------------------------------------
# Defaults - exported environment variables may override these values.
# ---------------------------------------------------------------------------

NS="${NS:-rdma-test}"

NODE113="${NODE113:-ocp113.localdomain}"
NODE114="${NODE114:-ocp114.localdomain}"
NODE115="${NODE115:-ocp115.localdomain}"
SERVER_NODE="${SERVER_NODE:-$NODE113}"
CLIENT_NODE="${CLIENT_NODE:-$NODE115}"
ALL_NODES="${ALL_NODES:-$NODE113 $NODE114 $NODE115}"

NAD="${NAD:-rdma-bond}"
MACVLAN_IFACE="${MACVLAN_IFACE:-net1}"

RDMA_DEVICE="${RDMA_DEVICE:-mlx5_bond_1}"
RDMA_RESOURCE="${RDMA_RESOURCE:-rdma/rdma_shared_device_dx_bond}"
GPU_RESOURCE="${GPU_RESOURCE:-nvidia.com/gpu}"

DOCA_IMAGE="${DOCA_IMAGE:-nvcr.io/nvidia/doca/doca:full-rt-cuda13.0.0-3.5.0-runtime-host}"
NGC_REGISTRY="${NGC_REGISTRY:-nvcr.io}"
NGC_USERNAME="${NGC_USERNAME:-\$oauthtoken}"
NGC_PULL_SECRET="${NGC_PULL_SECRET:-ngc-pull}"

SA="${SA:-doca-gpudirect}"
SCC="${SCC:-doca-gpudirect-test}"
SCC_ROLE="${SCC_ROLE:-use-doca-gpudirect-scc}"
SCC_ROLEBINDING="${SCC_ROLEBINDING:-use-doca-gpudirect-scc}"

APP_LABEL="${APP_LABEL:-doca-gpudirect}"
SERVER_DEPLOYMENT="${SERVER_DEPLOYMENT:-doca-gpudirect-server}"
CLIENT_DEPLOYMENT="${CLIENT_DEPLOYMENT:-doca-gpudirect-client}"

MACHINE_CONFIG_NAME="${MACHINE_CONFIG_NAME:-99-enable-iommu-pass-through}"
MACHINE_CONFIG_POOL="${MACHINE_CONFIG_POOL:-master}"
IOMMU_KERNEL_ARGUMENT="${IOMMU_KERNEL_ARGUMENT:-iommu=pt}"

CUDA_DEVICE="${CUDA_DEVICE:-0}"
DOCA_RDMA_DRIVER="${DOCA_RDMA_DRIVER:-ibv}"
DOCA_CONNECTION="${DOCA_CONNECTION:-RC}"
DOCA_VERB="${DOCA_VERB:-write}"
DOCA_METRIC="${DOCA_METRIC:-bw}"
DOCA_MESSAGE_SIZE="${DOCA_MESSAGE_SIZE:-1048576}"
DOCA_DURATION="${DOCA_DURATION:-10}"
DOCA_STREAMS="${DOCA_STREAMS:-${DOCA_QPS:-1}}"
DOCA_TEST_PROCESSES="${DOCA_TEST_PROCESSES:-${DOCA_PROCESSES:-1}}"
DOCA_CONTROL_PORT="${DOCA_CONTROL_PORT:-18555}"
DOCA_TRAFFIC_CLASS="${DOCA_TRAFFIC_CLASS:-}"
DOCA_GID_INDEX="${DOCA_GID_INDEX:-}"
DOCA_SERVICE_LEVEL="${DOCA_SERVICE_LEVEL:-3}"
DOCA_USE_SERVICE_LEVEL="${DOCA_USE_SERVICE_LEVEL:-0}"
DOCA_QP_HISTOGRAM="${DOCA_QP_HISTOGRAM:-0}"

VERIFY_BOND_STATS="${VERIFY_BOND_STATS:-0}"
BOND_MEMBER_1="${BOND_MEMBER_1:-enp1s0f0np0}"
BOND_MEMBER_2="${BOND_MEMBER_2:-enp1s0f1np1}"
SKIP_PING="${SKIP_PING:-0}"
AUTO_APPLY="${AUTO_APPLY:-1}"
REFRESH_NGC_SECRET="${REFRESH_NGC_SECRET:-0}"

SERVER_START_DELAY="${SERVER_START_DELAY:-2}"

SCRIPT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd
)"
LOG_ROOT="${LOG_ROOT:-${SCRIPT_DIR}/gpudirect-results}"
LOG_DIR=""

ACTION="all"

# Runtime-discovered values.
SERVER_POD=""
CLIENT_POD=""
SERVER_IP=""
CLIENT_IP=""
SERVER_GID=""
CLIENT_GID=""

SERVER_SELECTOR=""
CLIENT_SELECTOR=""
NAD_FULL=""

SERVER_WRAPPER_PID=""

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

info() {
  printf '\n==> %s\n' "$*"
}

ok() {
  printf 'PASS: %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_oc_access() {
  require_cmd oc
  oc whoami >/dev/null 2>&1 || die "Not logged into an OpenShift cluster."
}

usage() {
  cat <<EOF_USAGE
Usage:
  $0 [action] [options]

Actions:
  all       Reconcile objects, then run host-memory baseline and CUDA DMA-BUF test. (default)
  host      Reconcile objects, then run host-memory RoCEv2 baseline only.
  cuda      Reconcile objects, then run CUDA DMA-BUF GPUDirect test only.
  apply     Create/reconcile the OpenShift test objects only.
  status    Show deployments, pods, Multus IPs, SCCs, and node resources.
  env       Discover runtime values and print the effective test environment.
  gids      Dump non-zero GID entries visible from the two test pods.
  delete    Delete objects created by this script. Keeps namespace and NAD.
  cleanup   Alias for delete.

Test options:
  --streams N          RC QPs per DOCA process (-q). Default: ${DOCA_STREAMS}
  --processes N        Synchronized DOCA processes (-N). Default: ${DOCA_TEST_PROCESSES}
  --duration SEC       Test duration. Default: ${DOCA_DURATION}
  --message-size N     Message size in bytes. Default: ${DOCA_MESSAGE_SIZE}
  --traffic-class N    QP IP traffic class / ToS byte (0-255).
                       Example: 104 = DSCP 26, ECN 00.
                       Example: 106 = DSCP 26, ECT(0).
  --service-level N    Set DOCA service level (-S) and enable it.
  --gid-index N        Force a verified GID index; default is automatic.
  --histogram          Request QP histogram (-H); CLI mode requires --processes 1.
  --bond-stats         Snapshot mlx5 physical-port hardware byte counters.
  --no-ping            Skip optional ICMP reachability preflight.
  --skip-apply         For host/cuda/all, do not reconcile objects before testing.

OpenShift/config options:
  --namespace NAME     Namespace. Default: ${NS}
  --server-node NAME   Server node. Default: ${SERVER_NODE}
  --client-node NAME   Client node. Default: ${CLIENT_NODE}
  --nad NAME           Existing NetworkAttachmentDefinition. Default: ${NAD}
  --rdma-device NAME   RDMA device. Default: ${RDMA_DEVICE}
  --image IMAGE        DOCA container image.
  --refresh-ngc-secret Recreate/update the NGC pull secret.

Environment overrides are also supported, including:
  NS SERVER_NODE CLIENT_NODE NAD MACVLAN_IFACE RDMA_DEVICE RDMA_RESOURCE
  GPU_RESOURCE DOCA_IMAGE CUDA_DEVICE BOND_MEMBER_1 BOND_MEMBER_2 NGC_API_KEY

Examples:
  # One command: ensure objects, run host baseline, then CUDA DMA-BUF.
  $0 all --streams 8 --processes 4 --duration 30 --traffic-class 106 --bond-stats

  # Repeated CUDA test without reapplying objects.
  $0 cuda --skip-apply --streams 8 --processes 4 --duration 30 --traffic-class 106 --bond-stats

  # DSCP 26 classification-only test (Not-ECT).
  $0 cuda --streams 8 --processes 4 --traffic-class 104 --bond-stats

  # Inspect objects and discovered pod IPs.
  $0 status
  $0 env
EOF_USAGE
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    all|host|cuda|apply|status|env|gids|delete|cleanup)
      ACTION="$1"
      shift
      ;;
    --streams)
      [[ $# -ge 2 ]] || die "--streams requires a value"
      DOCA_STREAMS="$2"
      shift 2
      ;;
    --processes)
      [[ $# -ge 2 ]] || die "--processes requires a value"
      DOCA_TEST_PROCESSES="$2"
      shift 2
      ;;
    --duration)
      [[ $# -ge 2 ]] || die "--duration requires a value"
      DOCA_DURATION="$2"
      shift 2
      ;;
    --message-size)
      [[ $# -ge 2 ]] || die "--message-size requires a value"
      DOCA_MESSAGE_SIZE="$2"
      shift 2
      ;;
    --traffic-class)
      [[ $# -ge 2 ]] || die "--traffic-class requires a value"
      DOCA_TRAFFIC_CLASS="$2"
      shift 2
      ;;
    --service-level)
      [[ $# -ge 2 ]] || die "--service-level requires a value"
      DOCA_SERVICE_LEVEL="$2"
      DOCA_USE_SERVICE_LEVEL=1
      shift 2
      ;;
    --gid-index)
      [[ $# -ge 2 ]] || die "--gid-index requires a value"
      DOCA_GID_INDEX="$2"
      shift 2
      ;;
    --histogram)
      DOCA_QP_HISTOGRAM=1
      shift
      ;;
    --bond-stats)
      VERIFY_BOND_STATS=1
      shift
      ;;
    --no-ping)
      SKIP_PING=1
      shift
      ;;
    --skip-apply)
      AUTO_APPLY=0
      shift
      ;;
    --refresh-ngc-secret)
      REFRESH_NGC_SECRET=1
      shift
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      NS="$2"
      shift 2
      ;;
    --server-node)
      [[ $# -ge 2 ]] || die "--server-node requires a value"
      SERVER_NODE="$2"
      shift 2
      ;;
    --client-node)
      [[ $# -ge 2 ]] || die "--client-node requires a value"
      CLIENT_NODE="$2"
      shift 2
      ;;
    --nad)
      [[ $# -ge 2 ]] || die "--nad requires a value"
      NAD="$2"
      shift 2
      ;;
    --rdma-device)
      [[ $# -ge 2 ]] || die "--rdma-device requires a value"
      RDMA_DEVICE="$2"
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || die "--image requires a value"
      DOCA_IMAGE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for numeric_name in DOCA_STREAMS DOCA_TEST_PROCESSES DOCA_DURATION DOCA_MESSAGE_SIZE; do
  numeric_value="${!numeric_name}"
  [[ "$numeric_value" =~ ^[1-9][0-9]*$ ]] ||
    die "$numeric_name must be a positive integer (got '$numeric_value')"
done

if [[ -n "$DOCA_TRAFFIC_CLASS" ]]; then
  [[ "$DOCA_TRAFFIC_CLASS" =~ ^[0-9]+$ ]] ||
    die "--traffic-class must be an integer from 0 to 255"
  (( DOCA_TRAFFIC_CLASS >= 0 && DOCA_TRAFFIC_CLASS <= 255 )) ||
    die "--traffic-class must be in range 0..255"
fi

if [[ -n "$DOCA_GID_INDEX" ]]; then
  [[ "$DOCA_GID_INDEX" =~ ^[0-9]+$ ]] ||
    die "--gid-index must be a non-negative integer"
fi

NAD_FULL="${NS}/${NAD}"
SERVER_SELECTOR="app.kubernetes.io/name=${APP_LABEL},app.kubernetes.io/component=server"
CLIENT_SELECTOR="app.kubernetes.io/name=${APP_LABEL},app.kubernetes.io/component=client"

SERVER_TIMEOUT="${SERVER_TIMEOUT:-$((DOCA_DURATION + 90))}"
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-$((DOCA_DURATION + 90))}"

# ---------------------------------------------------------------------------
# OpenShift object creation / reconciliation
# ---------------------------------------------------------------------------

ensure_namespace() {
  if oc get namespace "$NS" >/dev/null 2>&1; then
    echo "Namespace ${NS} already exists."
  else
    oc create namespace "$NS"
  fi
}

verify_existing_network() {
  if ! oc get network-attachment-definition.k8s.cni.cncf.io \
      -n "$NS" "$NAD" >/dev/null 2>&1; then
    die "NetworkAttachmentDefinition ${NS}/${NAD} does not exist. Create/verify the MacVLAN network first."
  fi

  echo "Using NetworkAttachmentDefinition: ${NS}/${NAD}"
}

node_resource_value() {
  local node="$1"
  local key="$2"

  oc get node "$node" -o json |
    jq -r --arg k "$key" '.status.allocatable[$k] // "0"'
}

verify_node_resources() {
  local node gpu rdma

  for node in "$SERVER_NODE" "$CLIENT_NODE"; do
    oc get node "$node" >/dev/null 2>&1 || die "Node not found: $node"

    gpu="$(node_resource_value "$node" "$GPU_RESOURCE")"
    rdma="$(node_resource_value "$node" "$RDMA_RESOURCE")"

    echo "$node: ${GPU_RESOURCE}=${gpu:-0}, ${RDMA_RESOURCE}=${rdma:-0}"

    [[ -n "${gpu:-}" && "${gpu:-0}" != "0" ]] ||
      die "$node does not advertise $GPU_RESOURCE"
    [[ -n "${rdma:-}" && "${rdma:-0}" != "0" ]] ||
      die "$node does not advertise $RDMA_RESOURCE"
  done
}

ensure_service_account() {
  oc create serviceaccount "$SA" \
    -n "$NS" \
    --dry-run=client \
    -o yaml |
  oc apply -f -
}

ensure_ngc_pull_secret() {
  if [[ "$REFRESH_NGC_SECRET" != "1" ]] && \
     oc get secret "$NGC_PULL_SECRET" -n "$NS" >/dev/null 2>&1; then
    echo "NGC pull secret ${NS}/${NGC_PULL_SECRET} already exists; leaving it unchanged."
    return
  fi

  local key="${NGC_API_KEY:-}"

  if [[ -z "$key" ]]; then
    read -r -s -p "NGC API key: " key
    echo
  fi

  [[ -n "$key" ]] || die "NGC API key is empty."

  oc create secret docker-registry "$NGC_PULL_SECRET" \
    -n "$NS" \
    --docker-server="$NGC_REGISTRY" \
    --docker-username="$NGC_USERNAME" \
    --docker-password="$key" \
    --docker-email=unused@example.com \
    --dry-run=client \
    -o yaml |
  oc apply -f -

  unset key
}

ensure_scc() {
  cat <<EOF_SCC | oc apply -f -
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: ${SCC}
priority: 10
allowPrivilegedContainer: false
allowPrivilegeEscalation: false
defaultAllowPrivilegeEscalation: false
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
readOnlyRootFilesystem: false
allowedCapabilities:
  - IPC_LOCK
  - NET_RAW
defaultAddCapabilities: []
requiredDropCapabilities:
  - ALL
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: MustRunAs
fsGroup:
  type: RunAsAny
supplementalGroups:
  type: RunAsAny
seccompProfiles:
  - runtime/default
volumes:
  - configMap
  - downwardAPI
  - emptyDir
  - projected
  - secret
EOF_SCC
}

ensure_scc_rbac() {
  oc create role "$SCC_ROLE" \
    -n "$NS" \
    --verb=use \
    --resource=securitycontextconstraints.security.openshift.io \
    --resource-name="$SCC" \
    --dry-run=client \
    -o yaml |
  oc apply -f -

  oc create rolebinding "$SCC_ROLEBINDING" \
    -n "$NS" \
    --role="$SCC_ROLE" \
    --serviceaccount="${NS}:${SA}" \
    --dry-run=client \
    -o yaml |
  oc apply -f -

  echo -n "SCC authorization: "
  oc auth can-i use "scc/${SCC}" \
    --as="system:serviceaccount:${NS}:${SA}" \
    -n "$NS"
}

ensure_deployments() {
  cat <<EOF_DEPLOY | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVER_DEPLOYMENT}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${APP_LABEL}
    app.kubernetes.io/component: server
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_LABEL}
      app.kubernetes.io/component: server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP_LABEL}
        app.kubernetes.io/component: server
      annotations:
        openshift.io/required-scc: ${SCC}
        k8s.v1.cni.cncf.io/networks: >-
          [{"name":"${NAD}","namespace":"${NS}","interface":"${MACVLAN_IFACE}"}]
    spec:
      serviceAccountName: ${SA}
      imagePullSecrets:
        - name: ${NGC_PULL_SECRET}
      nodeSelector:
        kubernetes.io/hostname: ${SERVER_NODE}
      terminationGracePeriodSeconds: 0
      containers:
        - name: doca-perftest
          image: ${DOCA_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/bash
            - -lc
          args:
            - exec sleep infinity
          env:
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: compute,utility
          securityContext:
            allowPrivilegeEscalation: false
            seccompProfile:
              type: RuntimeDefault
            capabilities:
              drop:
                - ALL
              add:
                - IPC_LOCK
                - NET_RAW
          resources:
            requests:
              ${GPU_RESOURCE}: 1
              ${RDMA_RESOURCE}: 1
            limits:
              ${GPU_RESOURCE}: 1
              ${RDMA_RESOURCE}: 1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CLIENT_DEPLOYMENT}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${APP_LABEL}
    app.kubernetes.io/component: client
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_LABEL}
      app.kubernetes.io/component: client
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP_LABEL}
        app.kubernetes.io/component: client
      annotations:
        openshift.io/required-scc: ${SCC}
        k8s.v1.cni.cncf.io/networks: >-
          [{"name":"${NAD}","namespace":"${NS}","interface":"${MACVLAN_IFACE}"}]
    spec:
      serviceAccountName: ${SA}
      imagePullSecrets:
        - name: ${NGC_PULL_SECRET}
      nodeSelector:
        kubernetes.io/hostname: ${CLIENT_NODE}
      terminationGracePeriodSeconds: 0
      containers:
        - name: doca-perftest
          image: ${DOCA_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/bash
            - -lc
          args:
            - exec sleep infinity
          env:
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: compute,utility
          securityContext:
            allowPrivilegeEscalation: false
            seccompProfile:
              type: RuntimeDefault
            capabilities:
              drop:
                - ALL
              add:
                - IPC_LOCK
                - NET_RAW
          resources:
            requests:
              ${GPU_RESOURCE}: 1
              ${RDMA_RESOURCE}: 1
            limits:
              ${GPU_RESOURCE}: 1
              ${RDMA_RESOURCE}: 1
EOF_DEPLOY
}

wait_for_deployments() {
  oc rollout status \
    -n "$NS" \
    "deployment/${SERVER_DEPLOYMENT}" \
    --timeout=10m

  oc rollout status \
    -n "$NS" \
    "deployment/${CLIENT_DEPLOYMENT}" \
    --timeout=10m
}

reconcile_test_objects() {
  check_oc_access
  require_cmd jq

  info "Reconciling GPUDirect OpenShift test objects"
  echo "Namespace:       $NS"
  echo "Server node:     $SERVER_NODE"
  echo "Client node:     $CLIENT_NODE"
  echo "MacVLAN NAD:     $NS/$NAD"
  echo "RDMA device:     $RDMA_DEVICE"
  echo "RDMA resource:   $RDMA_RESOURCE"
  echo "GPU resource:    $GPU_RESOURCE"
  echo "DOCA image:      $DOCA_IMAGE"

  ensure_namespace
  verify_existing_network
  verify_node_resources
  ensure_service_account
  ensure_ngc_pull_secret
  ensure_scc
  ensure_scc_rbac
  ensure_deployments
  wait_for_deployments
}

show_status() {
  check_oc_access
  require_cmd jq

  echo
  echo "===== Deployments ====="
  oc get deployment \
    -n "$NS" \
    "$SERVER_DEPLOYMENT" "$CLIENT_DEPLOYMENT" \
    -o wide 2>/dev/null || true

  echo
  echo "===== Pods ====="
  oc get pods \
    -n "$NS" \
    -l "app.kubernetes.io/name=${APP_LABEL}" \
    -o wide 2>/dev/null || true

  echo
  echo "===== SCC used by pods ====="
  oc get pods \
    -n "$NS" \
    -l "app.kubernetes.io/name=${APP_LABEL}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}' \
    2>/dev/null || true

  echo
  echo "===== Multus network status ====="
  oc get pods \
    -n "$NS" \
    -l "app.kubernetes.io/name=${APP_LABEL}" \
    -o json 2>/dev/null |
    jq -r --arg iface "$MACVLAN_IFACE" '
      .items[] |
      .metadata.name as $pod |
      (.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]") |
      fromjson |
      .[] |
      select(.interface == $iface) |
      "\($pod)\t\(.interface)\t\(.ips | join(","))"
    ' || true

  echo
  echo "===== Resource availability ====="
  verify_node_resources
}

post_apply_checks() {
  refresh_runtime

  echo
  echo "===== Runtime validation ====="

  local pod
  for pod in "$SERVER_POD" "$CLIENT_POD"; do
    echo
    echo "--- $pod ---"

    oc exec -n "$NS" "$pod" -- bash -lc "
      echo 'GPU:'
      nvidia-smi --query-gpu=name,driver_version,pci.bus_id --format=csv

      echo
      echo 'DOCA Perftest:'
      command -v doca_perftest
      doca_perftest -V 2>/dev/null || true

      echo
      echo 'RDMA device:'
      test -e /sys/class/infiniband/${RDMA_DEVICE} &&
        echo '${RDMA_DEVICE} present' ||
        echo '${RDMA_DEVICE} NOT FOUND'
    "
  done
}

delete_objects() {
  check_oc_access

  echo "Deleting GPUDirect test objects from namespace ${NS} ..."

  oc delete deployment \
    "$SERVER_DEPLOYMENT" \
    "$CLIENT_DEPLOYMENT" \
    -n "$NS" \
    --ignore-not-found

  oc delete rolebinding "$SCC_ROLEBINDING" \
    -n "$NS" \
    --ignore-not-found

  oc delete role "$SCC_ROLE" \
    -n "$NS" \
    --ignore-not-found

  oc delete serviceaccount "$SA" \
    -n "$NS" \
    --ignore-not-found

  oc delete secret "$NGC_PULL_SECRET" \
    -n "$NS" \
    --ignore-not-found

  oc delete scc "$SCC" --ignore-not-found

  echo
  echo "Namespace ${NS} and existing NAD ${NS}/${NAD} were NOT deleted."
}

# ---------------------------------------------------------------------------
# Runtime discovery - replaces the separate gpudirect-env.sh source step.
# ---------------------------------------------------------------------------

ready_pod() {
  local selector="$1"

  oc get pods \
    -n "$NS" \
    -l "$selector" \
    -o json 2>/dev/null |
    jq -r '
      [
        .items[]
        | select(.status.phase == "Running")
        | select(any(.status.conditions[]?;
            .type == "Ready" and .status == "True"))
      ]
      | sort_by(.metadata.creationTimestamp)
      | .[-1].metadata.name // empty
    '
}

macvlan_ipv4() {
  local pod="$1"

  oc get pod -n "$NS" "$pod" -o json 2>/dev/null |
    jq -r \
      --arg network "$NAD_FULL" \
      --arg nad "$NAD" \
      --arg iface "$MACVLAN_IFACE" '
        (.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]")
        | fromjson
        | .[]
        | select(
            .interface == $iface and
            (.name == $network or .name == $nad)
          )
        | .ips[]?
        | sub("/.*$"; "")
        | select(test("^[0-9]+(\\.[0-9]+){3}$"))
      ' |
    head -n 1
}

refresh_runtime() {
  require_cmd oc
  require_cmd jq

  SERVER_POD="$(ready_pod "$SERVER_SELECTOR")"
  CLIENT_POD="$(ready_pod "$CLIENT_SELECTOR")"

  [[ -n "$SERVER_POD" ]] || die "No Ready server pod found with selector: $SERVER_SELECTOR"
  [[ -n "$CLIENT_POD" ]] || die "No Ready client pod found with selector: $CLIENT_SELECTOR"

  SERVER_IP="$(macvlan_ipv4 "$SERVER_POD")"
  CLIENT_IP="$(macvlan_ipv4 "$CLIENT_POD")"

  [[ -n "$SERVER_IP" ]] || die "No IPv4 address found on $MACVLAN_IFACE for $SERVER_POD"
  [[ -n "$CLIENT_IP" ]] || die "No IPv4 address found on $MACVLAN_IFACE for $CLIENT_POD"
}

show_environment() {
  refresh_runtime

  cat <<EOF_ENV
GPUDirect environment
  Namespace:          $NS
  NAD:                $NAD_FULL
  MacVLAN interface:  $MACVLAN_IFACE
  Server node:        $SERVER_NODE
  Client node:        $CLIENT_NODE
  RDMA device:        $RDMA_DEVICE
  RDMA resource:      $RDMA_RESOURCE
  GPU resource:       $GPU_RESOURCE
  DOCA image:         $DOCA_IMAGE
  Server pod:         $SERVER_POD
  Client pod:         $CLIENT_POD
  Server net1 IP:     $SERVER_IP
  Client net1 IP:     $CLIENT_IP
  GID selection:      ${DOCA_GID_INDEX:-automatic via DOCA/RDMA-CM}
  QPs/process:        $DOCA_STREAMS
  Processes:          $DOCA_TEST_PROCESSES
  Traffic class:      ${DOCA_TRAFFIC_CLASS:-DOCA default (0)}
EOF_ENV
}

show_gids() {
  refresh_runtime

  local pod
  for pod in "$SERVER_POD" "$CLIENT_POD"; do
    echo "===== $pod : $RDMA_DEVICE ====="

    oc exec -n "$NS" "$pod" -- \
      bash -lc '
        device="$1"
        base="/sys/class/infiniband/${device}/ports/1"

        if [[ ! -d "$base" ]]; then
          echo "RDMA device path not found: $base" >&2
          exit 1
        fi

        found=0
        for gid_file in "$base"/gids/*; do
          [[ -e "$gid_file" ]] || continue

          index="${gid_file##*/}"
          gid="$(cat "$gid_file" 2>/dev/null || echo unknown)"
          type="$(cat "$base/gid_attrs/types/$index" 2>/dev/null || echo unknown)"
          netdev="$(cat "$base/gid_attrs/ndevs/$index" 2>/dev/null || echo unknown)"

          if [[ "$gid" != "0000:0000:0000:0000:0000:0000:0000:0000" ]]; then
            printf "index=%s gid=%s type=%s netdev=%s\n" \
              "$index" "$gid" "$type" "$netdev"
            found=1
          fi
        done

        if [[ "$found" == "0" ]]; then
          echo "No non-zero GIDs exposed in this pod namespace."
        fi
      ' _ "$RDMA_DEVICE"
  done
}

# ---------------------------------------------------------------------------
# Benchmark preflight
# ---------------------------------------------------------------------------

verify_pod_placement() {
  local server_actual client_actual

  server_actual="$(
    oc get pod -n "$NS" "$SERVER_POD" -o jsonpath='{.spec.nodeName}'
  )"

  client_actual="$(
    oc get pod -n "$NS" "$CLIENT_POD" -o jsonpath='{.spec.nodeName}'
  )"

  echo "Server pod: $SERVER_POD -> $server_actual"
  echo "Client pod: $CLIENT_POD -> $client_actual"

  [[ "$server_actual" == "$SERVER_NODE" ]] ||
    die "Server pod is on $server_actual, expected $SERVER_NODE"

  [[ "$client_actual" == "$CLIENT_NODE" ]] ||
    die "Client pod is on $client_actual, expected $CLIENT_NODE"

  ok "pod placement"
}

verify_scc() {
  local pod scc

  for pod in "$SERVER_POD" "$CLIENT_POD"; do
    scc="$(
      oc get pod -n "$NS" "$pod" \
        -o jsonpath='{.metadata.annotations.openshift\.io/scc}'
    )"

    echo "$pod SCC: ${scc:-<none>}"

    [[ "$scc" == "$SCC" ]] ||
      die "$pod is using SCC '${scc:-<none>}', expected '$SCC'"
  done

  ok "SCC admission"
}

verify_runtime_tools() {
  local pod

  for pod in "$SERVER_POD" "$CLIENT_POD"; do
    info "Runtime checks on $pod"

    oc exec -n "$NS" "$pod" -- bash -lc "
      set -e

      command -v doca_perftest >/dev/null
      command -v nvidia-smi >/dev/null
      test -d /sys/class/infiniband/${RDMA_DEVICE}

      echo 'GPU:'
      nvidia-smi \\
        --query-gpu=name,driver_version,pci.bus_id \\
        --format=csv,noheader

      echo
      echo 'RDMA device: ${RDMA_DEVICE}'

      echo
      echo 'Kernel command line:'
      cat /proc/cmdline

      echo
      echo 'NVIDIA module:'
      cat /proc/driver/nvidia/version
    "

    if ! oc exec -n "$NS" "$pod" -- \
      doca_perftest -h 2>&1 |
      grep -q 'cuda_dmabuf'; then
      die "doca_perftest in $pod does not advertise cuda_dmabuf support"
    fi

    if ! oc exec -n "$NS" "$pod" -- \
      grep -qw "$IOMMU_KERNEL_ARGUMENT" /proc/cmdline; then
      die "$pod host kernel was not booted with $IOMMU_KERNEL_ARGUMENT"
    fi
  done

  ok "DOCA, CUDA, RDMA device, and ${IOMMU_KERNEL_ARGUMENT} prerequisites"
}

verify_route_and_ping() {
  info "Checking MacVLAN reachability when networking tools are available"

  if oc exec -n "$NS" "$CLIENT_POD" -- \
      bash -lc 'command -v ip >/dev/null 2>&1'; then

    local route
    route="$(
      oc exec -n "$NS" "$CLIENT_POD" -- ip route get "$SERVER_IP"
    )"

    echo "$route"

    grep -q "dev ${MACVLAN_IFACE}" <<<"$route" ||
      die "Route to $SERVER_IP is not using $MACVLAN_IFACE"

    ok "route uses $MACVLAN_IFACE"
  else
    warn "'ip' is not installed in the DOCA runtime image; route check skipped"
  fi

  if [[ "$SKIP_PING" == "1" ]]; then
    warn "SKIP_PING=1: ICMP preflight skipped"
    return
  fi

  if oc exec -n "$NS" "$CLIENT_POD" -- \
      bash -lc 'command -v ping >/dev/null 2>&1'; then

    oc exec -n "$NS" "$CLIENT_POD" -- \
      ping -4 \
        -I "$MACVLAN_IFACE" \
        -c 3 \
        -W 2 \
        "$SERVER_IP"

    ok "MacVLAN ping"
  else
    warn "'ping' is not installed in the DOCA runtime image; ICMP check skipped"
  fi
}

preflight() {
  require_cmd oc
  require_cmd jq
  require_cmd timeout
  require_cmd tee
  require_cmd grep

  info "Preflight"
  oc whoami
  verify_pod_placement
  verify_scc
  verify_runtime_tools

  info "RoCE mode"
  echo "Using DOCA/RDMA-CM automatic addressing on ${RDMA_DEVICE}"

  verify_route_and_ping

  echo
  echo "Test environment:"
  echo "  Namespace:       $NS"
  echo "  Server node:     $SERVER_NODE"
  echo "  Server pod:      $SERVER_POD"
  echo "  Server IP:       $SERVER_IP"
  echo "  Client node:     $CLIENT_NODE"
  echo "  Client pod:      $CLIENT_POD"
  echo "  Client IP:       $CLIENT_IP"
  echo "  RDMA device:     $RDMA_DEVICE"
  echo "  Memory baseline: host"
  echo "  GPU test memory: cuda_dmabuf"
  echo "  CUDA device:     $CUDA_DEVICE"
  echo "  GID selection:   ${DOCA_GID_INDEX:-automatic}"
  echo "  QPs/streams:     $DOCA_STREAMS per process"
  echo "  Processes:       $DOCA_TEST_PROCESSES"
  echo "  Total RC QPs:    $((DOCA_STREAMS * DOCA_TEST_PROCESSES))"
  echo "  Bond members:    $BOND_MEMBER_1 + $BOND_MEMBER_2"

  if [[ "$DOCA_USE_SERVICE_LEVEL" == "1" ]]; then
    echo "  Service level:   $DOCA_SERVICE_LEVEL"
  else
    echo "  Service level:   DOCA default"
  fi

  echo "  Traffic class:   ${DOCA_TRAFFIC_CLASS:-DOCA default (0)}"
  echo "  Logs:            $LOG_DIR"
}

# ---------------------------------------------------------------------------
# DOCA command construction
# ---------------------------------------------------------------------------

build_common_args() {
  COMMON_ARGS=(
    -d "$RDMA_DEVICE"
    -N "$DOCA_TEST_PROCESSES"
    -c "$DOCA_CONNECTION"
    -v "$DOCA_VERB"
    -m "$DOCA_METRIC"
    -s "$DOCA_MESSAGE_SIZE"
    -D "$DOCA_DURATION"
    -q "$DOCA_STREAMS"
    -r "$DOCA_RDMA_DRIVER"
  )

  if [[ "$DOCA_USE_SERVICE_LEVEL" == "1" ]]; then
    COMMON_ARGS+=( -S "$DOCA_SERVICE_LEVEL" )
  fi

  if [[ -n "$DOCA_TRAFFIC_CLASS" ]]; then
    COMMON_ARGS+=( --traffic_class "$DOCA_TRAFFIC_CLASS" )
  fi

  if [[ -n "$DOCA_GID_INDEX" ]]; then
    COMMON_ARGS+=( -g "$DOCA_GID_INDEX" )
  fi

  if [[ "$DOCA_QP_HISTOGRAM" == "1" ]]; then
    if (( DOCA_TEST_PROCESSES > 1 )); then
      warn "QP histogram requires --processes 1 in CLI mode; disabling histogram for this run"
    elif oc exec -n "$NS" "$CLIENT_POD" -- \
        bash -lc 'doca_perftest -h 2>&1 | grep -Eq -- "(^|[[:space:]])-H([,[:space:]]|$)"'; then
      COMMON_ARGS+=( -H )
    else
      warn "This doca_perftest build does not advertise -H; QP histogram disabled"
    fi
  fi
}

memory_args() {
  local memory_type="$1"

  case "$memory_type" in
    host)
      MEMORY_ARGS=( -M host )
      ;;
    cuda_dmabuf)
      MEMORY_ARGS=( -M cuda_dmabuf -G "$CUDA_DEVICE" )
      ;;
    *)
      die "Unsupported memory type: $memory_type"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Physical bond-member counters
# ---------------------------------------------------------------------------

read_node_ethtool_counter() {
  local node="$1"
  local iface="$2"
  local counter="$3"

  oc debug "node/${node}" --quiet -- \
    chroot /host \
      ethtool -S "$iface" \
      2>/dev/null |
    awk -v c="$counter" '
      {
        key=$1
        sub(/:$/, "", key)
        if (key == c) {
          print $2
          exit
        }
      }
    '
}

snapshot_bond_stats() {
  local label="$1"
  local file="${LOG_DIR}/${label}.bond-stats"

  : > "$file"

  local node iface counter value
  for node in "$SERVER_NODE" "$CLIENT_NODE"; do
    for iface in "$BOND_MEMBER_1" "$BOND_MEMBER_2"; do
      for counter in rx_bytes_phy tx_bytes_phy; do
        value="$(
          read_node_ethtool_counter "$node" "$iface" "$counter" || true
        )"

        [[ "$value" =~ ^[0-9]+$ ]] || value=0

        printf '%s %s %s %s\n' \
          "$node" "$iface" "$counter" "$value" >> "$file"
      done
    done
  done

  echo "$file"
}

print_bond_delta() {
  local before="$1"
  local after="$2"

  echo
  echo "Physical mlx5 port byte deltas (ethtool *_bytes_phy):"
  printf '%-20s %-16s %18s %18s\n' \
    NODE INTERFACE RX_BYTES TX_BYTES

  local node iface b_rx a_rx b_tx a_tx d_rx d_tx

  for node in "$SERVER_NODE" "$CLIENT_NODE"; do
    for iface in "$BOND_MEMBER_1" "$BOND_MEMBER_2"; do
      b_rx="$(awk -v n="$node" -v i="$iface" '$1==n && $2==i && $3=="rx_bytes_phy" {print $4}' "$before")"
      a_rx="$(awk -v n="$node" -v i="$iface" '$1==n && $2==i && $3=="rx_bytes_phy" {print $4}' "$after")"
      b_tx="$(awk -v n="$node" -v i="$iface" '$1==n && $2==i && $3=="tx_bytes_phy" {print $4}' "$before")"
      a_tx="$(awk -v n="$node" -v i="$iface" '$1==n && $2==i && $3=="tx_bytes_phy" {print $4}' "$after")"

      d_rx=$(( ${a_rx:-0} - ${b_rx:-0} ))
      d_tx=$(( ${a_tx:-0} - ${b_tx:-0} ))

      printf '%-20s %-16s %18d %18d\n' \
        "$node" "$iface" "$d_rx" "$d_tx"
    done
  done

  echo
  echo "For unidirectional RDMA WRITE, compare client TX and server RX across both members."
}

# ---------------------------------------------------------------------------
# Benchmark execution
# ---------------------------------------------------------------------------

cleanup_remote_perftest() {
  [[ -n "$SERVER_POD" ]] && \
    oc exec -n "$NS" "$SERVER_POD" -- \
      bash -lc 'pkill -x doca_perftest >/dev/null 2>&1 || true' \
      >/dev/null 2>&1 || true

  [[ -n "$CLIENT_POD" ]] && \
    oc exec -n "$NS" "$CLIENT_POD" -- \
      bash -lc 'pkill -x doca_perftest >/dev/null 2>&1 || true' \
      >/dev/null 2>&1 || true
}

cleanup_on_exit() {
  if [[ -n "${SERVER_WRAPPER_PID:-}" ]]; then
    kill "$SERVER_WRAPPER_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup_on_exit EXIT INT TERM

run_doca_test() {
  local test_name="$1"
  local memory_type="$2"

  local server_log="${LOG_DIR}/${test_name}-server.log"
  local client_log="${LOG_DIR}/${test_name}-client.log"
  local server_rc=0
  local client_rc=0
  local bond_before=""
  local bond_after=""

  build_common_args
  memory_args "$memory_type"

  cleanup_remote_perftest

  if [[ "$VERIFY_BOND_STATS" == "1" ]]; then
    info "${test_name}: snapshotting bond-member counters"
    bond_before="$(snapshot_bond_stats "${test_name}-before")"
  fi

  info "${test_name}: starting server on ${SERVER_POD}"

  (
    set -o pipefail
    timeout "${SERVER_TIMEOUT}s" \
      oc exec -n "$NS" "$SERVER_POD" -- \
        doca_perftest \
          "${COMMON_ARGS[@]}" \
          "${MEMORY_ARGS[@]}" \
          2>&1 |
      tee "$server_log"
  ) &

  SERVER_WRAPPER_PID=$!

  sleep "$SERVER_START_DELAY"

  if ! kill -0 "$SERVER_WRAPPER_PID" >/dev/null 2>&1; then
    set +e
    wait "$SERVER_WRAPPER_PID"
    server_rc=$?
    set -e

    SERVER_WRAPPER_PID=""

    echo
    echo "Server exited before client startup."
    echo "Server log: $server_log"
    return "${server_rc:-1}"
  fi

  info "${test_name}: starting client on ${CLIENT_POD} -> ${SERVER_IP}"

  set +e
  set -o pipefail

  timeout "${CLIENT_TIMEOUT}s" \
    oc exec -n "$NS" "$CLIENT_POD" -- \
      doca_perftest \
        "${COMMON_ARGS[@]}" \
        "${MEMORY_ARGS[@]}" \
        -n "$SERVER_IP" \
        --launch_server disable \
        2>&1 |
    tee "$client_log"

  client_rc="${PIPESTATUS[0]}"

  set +o pipefail
  set -e

  if [[ "$client_rc" -ne 0 ]]; then
    warn "${test_name}: client failed with exit code $client_rc"

    cleanup_remote_perftest

    if [[ -n "$SERVER_WRAPPER_PID" ]]; then
      kill "$SERVER_WRAPPER_PID" >/dev/null 2>&1 || true
      wait "$SERVER_WRAPPER_PID" >/dev/null 2>&1 || true
      SERVER_WRAPPER_PID=""
    fi

    if [[ "$VERIFY_BOND_STATS" == "1" && -n "$bond_before" ]]; then
      bond_after="$(snapshot_bond_stats "${test_name}-after")"
      print_bond_delta "$bond_before" "$bond_after"
    fi

    echo "Client log: $client_log"
    echo "Server log: $server_log"
    return "$client_rc"
  fi

  set +e
  wait "$SERVER_WRAPPER_PID"
  server_rc=$?
  set -e

  SERVER_WRAPPER_PID=""

  if [[ "$server_rc" -ne 0 ]]; then
    warn "${test_name}: server failed with exit code $server_rc"

    if [[ "$VERIFY_BOND_STATS" == "1" && -n "$bond_before" ]]; then
      bond_after="$(snapshot_bond_stats "${test_name}-after")"
      print_bond_delta "$bond_before" "$bond_after"
    fi

    echo "Client log: $client_log"
    echo "Server log: $server_log"
    return "$server_rc"
  fi

  if [[ "$VERIFY_BOND_STATS" == "1" && -n "$bond_before" ]]; then
    bond_after="$(snapshot_bond_stats "${test_name}-after")"
    print_bond_delta "$bond_before" "$bond_after"
  fi

  ok "$test_name"
  echo "Client log: $client_log"
  echo "Server log: $server_log"
  return 0
}

collect_cuda_failure_diagnostics() {
  local since="$1"
  local diag="${LOG_DIR}/cuda-dmabuf-kernel-diagnostics.log"

  info "Collecting client-node kernel diagnostics since ${since}"

  set +e
  oc debug "node/${CLIENT_NODE}" -- \
    chroot /host \
      journalctl \
        -k \
        --since "$since" \
        --no-pager \
        2>&1 |
    tee "${LOG_DIR}/cuda-dmabuf-kernel-full.log" |
    grep -Ei \
      'IO_PAGE_FAULT|AMD-Vi.*Event|mlx5|NVRM|Xid|AER|PCIe|dma-buf|dmabuf|IOMMU|protection' |
    tee "$diag"
  set -e

  echo "Filtered diagnostics: $diag"
}

run_host_baseline() {
  info "TEST 1: Host-memory RoCEv2 baseline"

  if run_doca_test "host-memory-rocev2" "host"; then
    ok "Host-memory RoCEv2 baseline succeeded"
    return 0
  fi

  warn "Host-memory baseline failed. CUDA test will not be run in 'all' mode."
  return 2
}

run_cuda_dmabuf() {
  local test_start
  test_start="$(date --iso-8601=seconds)"

  info "TEST 2: CUDA DMA-BUF GPUDirect RoCEv2"
  echo "Test start: $test_start"

  if run_doca_test "cuda-dmabuf-gpudirect-rocev2" "cuda_dmabuf"; then
    ok "CUDA DMA-BUF GPUDirect RoCEv2 test succeeded"

    local success_diag="${LOG_DIR}/cuda-dmabuf-success-kernel-check.log"

    set +e
    oc debug "node/${CLIENT_NODE}" -- \
      chroot /host \
        journalctl \
          -k \
          --since "$test_start" \
          --no-pager \
          2>&1 |
      grep -Ei \
        'IO_PAGE_FAULT|AMD-Vi.*Event|NVRM.*Xid|AER.*error' |
      tee "$success_diag"
    set -e

    if [[ ! -s "$success_diag" ]]; then
      ok "No matching AMD-Vi IO_PAGE_FAULT, GPU Xid, or PCIe AER errors detected"
    else
      warn "The bandwidth test passed, but matching kernel messages were found: $success_diag"
    fi

    return 0
  fi

  collect_cuda_failure_diagnostics "$test_start"
  return 3
}

print_summary() {
  local host_status="$1"
  local cuda_status="$2"

  echo
  echo "============================================================"
  echo "GPUDirect / RoCEv2 test summary"
  echo "============================================================"
  echo "Server:        ${SERVER_POD} (${SERVER_NODE}) ${SERVER_IP}"
  echo "Client:        ${CLIENT_POD} (${CLIENT_NODE}) ${CLIENT_IP}"
  echo "RDMA device:   ${RDMA_DEVICE}"
  echo "GID selection: ${DOCA_GID_INDEX:-automatic via DOCA/RDMA-CM}"
  echo "QPs/streams:   ${DOCA_STREAMS} per process"
  echo "Processes:     ${DOCA_TEST_PROCESSES}"
  echo "Traffic class: ${DOCA_TRAFFIC_CLASS:-automatic/default}"
  echo "Total RC QPs:  $((DOCA_STREAMS * DOCA_TEST_PROCESSES))"
  echo "Logs:          ${LOG_DIR}"
  echo
  printf '%-30s %s\n' "Host-memory RoCEv2:" "$host_status"
  printf '%-30s %s\n' "CUDA DMA-BUF GPUDirect:" "$cuda_status"
  echo "============================================================"
}

prepare_test_run() {
  check_oc_access
  require_cmd jq

  if [[ "$AUTO_APPLY" == "1" ]]; then
    reconcile_test_objects
  fi

  refresh_runtime

  local timestamp
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  LOG_DIR="${LOG_ROOT}/${timestamp}"
  mkdir -p "$LOG_DIR"

  preflight
}

run_requested_tests() {
  local host_status="NOT RUN"
  local cuda_status="NOT RUN"

  prepare_test_run

  case "$ACTION" in
    host)
      if run_host_baseline; then
        host_status="PASS"
        print_summary "$host_status" "$cuda_status"
        return 0
      fi
      host_status="FAIL"
      print_summary "$host_status" "$cuda_status"
      return 2
      ;;

    cuda)
      if run_cuda_dmabuf; then
        cuda_status="PASS"
        print_summary "$host_status" "$cuda_status"
        return 0
      fi
      cuda_status="FAIL"
      print_summary "$host_status" "$cuda_status"
      return 3
      ;;

    all)
      if run_host_baseline; then
        host_status="PASS"
      else
        host_status="FAIL"
        print_summary "$host_status" "$cuda_status"
        return 2
      fi

      if run_cuda_dmabuf; then
        cuda_status="PASS"
        print_summary "$host_status" "$cuda_status"
        return 0
      fi

      cuda_status="FAIL"
      print_summary "$host_status" "$cuda_status"
      return 3
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------

case "$ACTION" in
  apply)
    reconcile_test_objects
    show_status
    post_apply_checks
    echo
    echo "GPUDirect test objects are ready."
    ;;

  status)
    show_status
    ;;

  env)
    check_oc_access
    show_environment
    ;;

  gids)
    check_oc_access
    show_gids
    ;;

  delete|cleanup)
    delete_objects
    ;;

  host|cuda|all)
    run_requested_tests
    ;;

  *)
    die "Unsupported action: $ACTION"
    ;;
esac
```
</details> 
</blockquote>

For an ECN-capable GPUDirect test, you can now do everything with one command:
```bash
chmod +x gpudirect-test.sh

./gpudirect-test.sh cuda \
  --streams 8 \
  --processes 4 \
  --duration 30 \
  --traffic-class 106 \
  --bond-stats
```
That single invocation will:
```text
Verify OpenShift login
        ↓
Create/reconcile namespace test objects
        ↓
Verify existing rdma-bond NAD
        ↓
Verify GPU + RDMA extended resources
        ↓
Create/update:
  ServiceAccount
  SCC
  Role/RoleBinding
  Deployments
        ↓
Wait for server/client pods
        ↓
Discover current pods
        ↓
Discover current net1 / 172.16.101.x addresses
        ↓
Validate:
  NVIDIA A40
  Open kernel module
  iommu=pt
  mlx5_bond_1
  cuda_dmabuf
        ↓
Run DOCA Perftest
        ↓
Collect physical bond-member counters
        ↓
Check AMD-Vi / Xid / AER errors
        ↓
Print summary + log location
```
A few other useful commands:
```bash
# Just create/reconcile the OpenShift objects
./gpudirect-test.sh apply

# Show current objects and network assignments
./gpudirect-test.sh status

# Show discovered pods/IPs/environment
./gpudirect-test.sh env

# Run host-memory baseline only
./gpudirect-test.sh host \
  --streams 8 \
  --processes 4 \
  --bond-stats

# Host-memory first, then CUDA DMA-BUF
./gpudirect-test.sh all \
  --streams 8 \
  --processes 4 \
  --duration 30 \
  --traffic-class 106 \
  --bond-stats

# Delete only the objects this script created
# Namespace and rdma-bond NAD are preserved
./gpudirect-test.sh delete
```
For repeated performance tests, you can avoid reapplying the OpenShift resources each time:
```bash
./gpudirect-test.sh cuda \
  --skip-apply \
  --streams 8 \
  --processes 4 \
  --duration 30 \
  --traffic-class 106 \
  --bond-stats
```
If `rdma-test/ngc-pull` already exists, it doesn't ask for the API key again. It will only prompt if the secret is missing.  
To deliberately replace it:
```bash
export NGC_API_KEY='...'

./gpudirect-test.sh apply --refresh-ngc-secret
```
You can switch between the two useful traffic-class values directly:
- `--traffic-class 104` = DSCP26→TC3
- `--traffic-class 106` = DSCP48→TC6
```bash
# DSCP 26, ECN=Not-ECT — useful for classification/PFC-specific testing
./gpudirect-test.sh cuda \
  --streams 8 \
  --processes 4 \
  --duration 30 \
  --traffic-class 104 \
  --bond-stats
```
And:
```bash
# DSCP 26 + ECT(0) — use for the ECN/DCQCN/CNP validation
./gpudirect-test.sh cuda \
  --streams 8 \
  --processes 4 \
  --duration 30 \
  --traffic-class 106 \
  --bond-stats
```
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ The existing `rdma-bond` NetworkAttachmentDefinition is intentionally not created, deleted, or modified by this script since that network is already working.

Validation Run Example:
```bash
[dave@rhel9dummy2 ocp]$ chmod +x gpudirect-test.sh
[dave@rhel9dummy2 ocp]$ ./gpudirect-test.sh all \
  --streams 8 \
  --processes 4 \
  --duration 30 \
  --traffic-class 106 \
  --bond-stats

==> Reconciling RoCEv2 & GPUDirect OpenShift test objects
Namespace:       rdma-test
Server node:     ocp113.localdomain
Client node:     ocp115.localdomain
MacVLAN NAD:     rdma-test/rdma-bond
RDMA device:     mlx5_bond_1
RDMA resource:   rdma/rdma_shared_device_dx_bond
GPU resource:    nvidia.com/gpu
DOCA image:      nvcr.io/nvidia/doca/doca:full-rt-cuda13.0.0-3.5.0-runtime-host
Namespace rdma-test already exists.
Using NetworkAttachmentDefinition: rdma-test/rdma-bond
ocp113.localdomain: nvidia.com/gpu=1, rdma/rdma_shared_device_dx_bond=1k
ocp115.localdomain: nvidia.com/gpu=1, rdma/rdma_shared_device_dx_bond=1k
serviceaccount/doca-gpudirect created
NGC API key:
secret/ngc-pull created
securitycontextconstraints.security.openshift.io/doca-gpudirect-test created
role.rbac.authorization.k8s.io/use-doca-gpudirect-scc created
rolebinding.rbac.authorization.k8s.io/use-doca-gpudirect-scc created
SCC authorization: Warning: resource 'securitycontextconstraints' is not namespace scoped in group 'security.openshift.io'

yes
deployment.apps/doca-gpudirect-server created
deployment.apps/doca-gpudirect-client created
Waiting for deployment "doca-gpudirect-server" rollout to finish: 0 of 1 updated replicas are available...
deployment "doca-gpudirect-server" successfully rolled out
deployment "doca-gpudirect-client" successfully rolled out

==> Preflight
dave
Server pod: doca-gpudirect-server-b8f5d47f-wxjb2 -> ocp113.localdomain
Client pod: doca-gpudirect-client-bd9c4994f-zt69n -> ocp115.localdomain
PASS: pod placement
doca-gpudirect-server-b8f5d47f-wxjb2 SCC: doca-gpudirect-test
doca-gpudirect-client-bd9c4994f-zt69n SCC: doca-gpudirect-test
PASS: SCC admission

==> Runtime checks on doca-gpudirect-server-b8f5d47f-wxjb2
GPU:
NVIDIA A40, 580.126.20, 00000000:81:00.0

RDMA device: mlx5_bond_1

Kernel command line:
BOOT_IMAGE=(hd2,gpt3)/boot/ostree/rhcos-55cd652db0d2da6000bd33732f3278dc44b8b17d96b8d37cf77e2b96a3289be5/vmlinuz-5.14.0-687.42.1.el9_8.x86_64 ignition.platform.id=metal ostree=/ostree/boot.0/rhcos/55cd652db0d2da6000bd33732f3278dc44b8b17d96b8d37cf77e2b96a3289be5/0 root=UUID=910678ff-f77e-4a7d-8d53-86f2ac47a823 rw rootflags=prjquota boot=UUID=43b68964-63c3-4cfa-b639-73cadbf73b7d systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all amd_pstate=active iommu=pt

NVIDIA module:
NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  580.126.20  Release Build  (dvs-builder@U22-I3-AF03-29-4)  Wed Feb 18 05:37:09 UTC 2026
GCC version:  gcc version 11.5.0 20240719 (Red Hat 11.5.0-14) (GCC)

==> Runtime checks on doca-gpudirect-client-bd9c4994f-zt69n
GPU:
NVIDIA A40, 580.126.20, 00000000:81:00.0

RDMA device: mlx5_bond_1

Kernel command line:
BOOT_IMAGE=(hd2,gpt3)/boot/ostree/rhcos-55cd652db0d2da6000bd33732f3278dc44b8b17d96b8d37cf77e2b96a3289be5/vmlinuz-5.14.0-687.42.1.el9_8.x86_64 ignition.platform.id=metal ostree=/ostree/boot.0/rhcos/55cd652db0d2da6000bd33732f3278dc44b8b17d96b8d37cf77e2b96a3289be5/0 root=UUID=910678ff-f77e-4a7d-8d53-86f2ac47a823 rw rootflags=prjquota boot=UUID=94900893-ca04-4778-b5ff-13280b34d122 systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all amd_pstate=active iommu=pt

NVIDIA module:
NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  580.126.20  Release Build  (dvs-builder@U22-I3-AF03-29-4)  Wed Feb 18 05:37:09 UTC 2026
GCC version:  gcc version 11.5.0 20240719 (Red Hat 11.5.0-14) (GCC)
PASS: DOCA, CUDA, RDMA device, and iommu=pt prerequisites

==> RoCE mode
Using DOCA/RDMA-CM automatic addressing on mlx5_bond_1

==> Checking MacVLAN reachability when networking tools are available
command terminated with exit code 1
WARN: 'ip' is not installed in the DOCA runtime image; route check skipped
command terminated with exit code 1
WARN: 'ping' is not installed in the DOCA runtime image; ICMP check skipped

Test environment:
  Namespace:       rdma-test
  Server node:     ocp113.localdomain
  Server pod:      doca-gpudirect-server-b8f5d47f-wxjb2
  Server IP:       172.16.101.5
  Client node:     ocp115.localdomain
  Client pod:      doca-gpudirect-client-bd9c4994f-zt69n
  Client IP:       172.16.101.4
  RDMA device:     mlx5_bond_1
  Memory baseline: host
  GPU test memory: cuda_dmabuf
  CUDA device:     0
  GID selection:   automatic
  QPs/streams:     8 per process
  Processes:       4
  Total RC QPs:    32
  Bond members:    enp1s0f0np0 + enp1s0f1np1
  Service level:   DOCA default
  Traffic class:   106
  Logs:            /home/dave/ocp/gpudirect-results/20260911-225356

==> TEST 1: Host-memory RoCEv2 baseline

==> host-memory-rocev2: snapshotting bond-member counters

==> host-memory-rocev2: starting server on doca-gpudirect-server-b8f5d47f-wxjb2
Running doca_perftest server...

==> host-memory-rocev2: starting client on doca-gpudirect-client-bd9c4994f-zt69n -> 172.16.101.5
Preparing RDMA resources | (0s)
Running traffic [======================================> ] 97% (33/34s, ~1s remaining)
BW:                                     165.06 [Gbit/sec]
Message Rate:                             0.02 [Mpps]
Duration:                                29.99 [sec]


Physical mlx5 port byte deltas (ethtool *_bytes_phy):
NODE                 INTERFACE                  RX_BYTES           TX_BYTES
ocp113.localdomain   enp1s0f0np0            423061510574          190681734
ocp113.localdomain   enp1s0f1np1            289540702220          262742021
ocp115.localdomain   enp1s0f0np0               316255919       290252871388
ocp115.localdomain   enp1s0f1np1               137244757       422350288665

For unidirectional RDMA WRITE, compare client TX and server RX across both members.
PASS: host-memory-rocev2
Client log: /home/dave/ocp/gpudirect-results/20260911-225356/host-memory-rocev2-client.log
Server log: /home/dave/ocp/gpudirect-results/20260911-225356/host-memory-rocev2-server.log
PASS: Host-memory RoCEv2 baseline succeeded

==> TEST 2: CUDA DMA-BUF RoCEv2 & GPUDirect RoCEv2
Test start: 2026-09-11T22:54:51-04:00

==> cuda-dmabuf-gpudirect-rocev2: snapshotting bond-member counters

==> cuda-dmabuf-gpudirect-rocev2: starting server on doca-gpudirect-server-b8f5d47f-wxjb2
Running doca_perftest server...

==> cuda-dmabuf-gpudirect-rocev2: starting client on doca-gpudirect-client-bd9c4994f-zt69n -> 172.16.101.5
Preparing RDMA resources | (0s)
Running traffic [========================================] 100% (34 seconds)
Finalizing | (0s)
BW:                                     184.15 [Gbit/sec]
Message Rate:                             0.02 [Mpps]
Duration:                                29.99 [sec]


Physical mlx5 port byte deltas (ethtool *_bytes_phy):
NODE                 INTERFACE                  RX_BYTES           TX_BYTES
ocp113.localdomain   enp1s0f0np0            219470229641          247663316
ocp113.localdomain   enp1s0f1np1            418777294129          172634029
ocp115.localdomain   enp1s0f0np0               115418506       378984408815
ocp115.localdomain   enp1s0f1np1               304903420       259263807516

For unidirectional RDMA WRITE, compare client TX and server RX across both members.
PASS: cuda-dmabuf-gpudirect-rocev2
Client log: /home/dave/ocp/gpudirect-results/20260911-225356/cuda-dmabuf-gpudirect-rocev2-client.log
Server log: /home/dave/ocp/gpudirect-results/20260911-225356/cuda-dmabuf-gpudirect-rocev2-server.log
PASS: CUDA DMA-BUF RoCEv2 & GPUDirect RoCEv2 test succeeded
PASS: No matching AMD-Vi IO_PAGE_FAULT, GPU Xid, or PCIe AER errors detected

============================================================
RoCEv2 & GPUDirect / RoCEv2 test summary
============================================================
Server:        doca-gpudirect-server-b8f5d47f-wxjb2 (ocp113.localdomain) 172.16.101.5
Client:        doca-gpudirect-client-bd9c4994f-zt69n (ocp115.localdomain) 172.16.101.4
RDMA device:   mlx5_bond_1
GID selection: automatic via DOCA/RDMA-CM
QPs/streams:   8 per process
Processes:     4
Traffic class: 106
Total RC QPs:  32
Logs:          /home/dave/ocp/gpudirect-results/20260911-225356

Host-memory RoCEv2:            PASS
CUDA DMA-BUF RoCEv2 & GPUDirect:        PASS
============================================================
```

Cleanup:
```bash
[dave@rhel9dummy2 ocp]$ ./gpudirect-test.sh delete
Deleting GPUDirect test objects from namespace rdma-test ...
deployment.apps "doca-gpudirect-server" deleted from rdma-test namespace
deployment.apps "doca-gpudirect-client" deleted from rdma-test namespace
rolebinding.rbac.authorization.k8s.io "use-doca-gpudirect-scc" deleted from rdma-test namespace
role.rbac.authorization.k8s.io "use-doca-gpudirect-scc" deleted from rdma-test namespace
serviceaccount "doca-gpudirect" deleted from rdma-test namespace
secret "ngc-pull" deleted from rdma-test namespace
securitycontextconstraints.security.openshift.io "doca-gpudirect-test" deleted

Namespace rdma-test and existing NAD rdma-test/rdma-bond were NOT deleted.
```