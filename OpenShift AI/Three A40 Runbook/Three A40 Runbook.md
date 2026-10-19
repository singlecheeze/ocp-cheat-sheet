# Three A40 GPUs Serving One Qwen Model on OpenShift AI 3.5

**Recreation runbook • consolidated October 16, 2026**

This document records the configuration that worked in this environment: one Qwen model split across three servers, with one NVIDIA A40 per server, llm-d routing, RoCE communication, an external HTTPS Route, and the OpenShift AI Gen AI Playground.

The manifests below are a clean reconstruction from the uploaded configuration and the successful changes in this conversation. Generated status, UIDs, resource versions, and credentials are excluded. They have not been reapplied to the live cluster as part of writing this document.

> **Scope:** This starts with a functioning OpenShift AI cluster and the GPU, network, storage, Gateway API, and llm-d operators already installed. The complete original GPU/Network Operator policies, host network policies, switch configuration, SCC assignments, and Playground database configuration were not supplied. Export them from the working cluster using the capture section before rebuilding an entire cluster.

## Contents

1. [Working architecture and settings](#1-working-architecture-and-settings)
2. [Prerequisites and installation checks](#2-prerequisites-and-installation-checks)
3. [Namespace and RoCE network](#3-namespace-and-roce-network)
4. [Internal registry and ModelCar](#4-internal-registry-and-modelcar)
5. [Persistent registry pull credentials](#5-persistent-registry-pull-credentials)
6. [Custom pipeline-parallel runtime template](#6-custom-pipeline-parallel-runtime-template)
7. [Namespace-local Gateway](#7-namespace-local-gateway)
8. [Three-node model service](#8-three-node-model-service)
9. [External HTTPS Route](#9-external-https-route)
10. [Gen AI Playground and OGX](#10-gen-ai-playground-and-ogx)
11. [Validation and performance](#11-validation-and-performance)
12. [Operations and troubleshooting](#12-operations-and-troubleshooting)
13. [Capture the live configuration](#13-capture-the-live-configuration)
14. [Python CLI](#14-python-cli)
15. [References](#15-references)

## 1. Working architecture and settings

| Setting | Working value |
|---|---|
| Platform | OpenShift Container Platform 4.22; operator output showed 4.22.16 |
| AI platform | Red Hat OpenShift AI 3.5 |
| Runtime | vLLM `0.24.0+rhaiv.13` |
| Namespace | `ai-test` |
| Model | `RedHatAI/Qwen3.6-35B-A3B-FP8` |
| Serving resource | `qwen36-35b-a3b-fp8-pp3` |
| Display name | Qwen3.6-35B-A3B-FP8 - Three A40s |
| Servers | `ocp113.localdomain`, `ocp114.localdomain`, `ocp115.localdomain` |
| GPUs | One NVIDIA A40 per server; three GPUs total |
| Parallelism | Tensor `1`; pipeline `3`; one model replica group |
| Layer split seen in logs | `[13,14,13]` |
| Per serving pod | 6 CPU; 32Gi host RAM; one GPU; one shared RDMA resource allocation |
| Network attachment | `ai-test/rdma-bond`; macvlan on `bond1`; MTU 9000 |
| Secondary IPv4 network | `172.16.101.0/24`, allocated by Whereabouts |
| HCA seen in logs | `mlx5_bond_0`, port 1, RoCE |
| Pull secret | `qwen36-35b-a3b-fp8` |
| Gateway | `ai-test/ai-test-inference`, class `openshift-default` |
| External Route | `ai-test/qwen36-pp3` |
| Model API authentication | Disabled in the working lab configuration |
| Playground backend | OGXServer `ai-test/lsd-genai-playground` |

The three GPUs hold different pipeline stages of the same model. They are not three independent full-model replicas. Increasing the replica count would create additional distributed groups and require more GPUs. Pipeline parallelism increases available model capacity and can improve throughput under concurrent load; it does not imply a threefold improvement for a single chat.

The request path is:

```mermaid
flowchart TD
    Client["curl or Python CLI"] --> Route["HTTPS Route: qwen36-pp3"]
    Route --> Gateway["Gateway: ai-test-inference"]
    Playground["Gen AI Playground / OGX"] --> Gateway
    Gateway --> Routing["HTTPRoute / InferencePool / scheduler"]
    Routing --> Leader["Pipeline rank 0: one A40"]
    Leader <--> Worker1["Pipeline rank 1: one A40"]
    Worker1 <--> Worker2["Pipeline rank 2: one A40"]
```

Stage placement is scheduled dynamically. The observed leader ran on `ocp114`, rank 1 on `ocp115`, and rank 2 on `ocp113`; that ordering is not required. Each node advertises only one full GPU, so one-GPU requests distribute the three serving pods across the three available nodes.

## 2. Prerequisites and installation checks

Required infrastructure:

- OpenShift AI with KServe LLMInferenceService and llm-d dependencies configured.
- NVIDIA GPU Operator with full-GPU allocation enabled; three allocatable A40 GPUs.
- NVIDIA Network Operator / RDMA shared device plugin exposing `rdma/rdma_shared_device_dx_bond`.
- Multus, macvlan, and Whereabouts, with working `bond1` connectivity on all three servers.
- Leader Worker Set Operator; the observed version was `1.0.1`.
- A working GatewayClass named `openshift-default` with inference routing support.
- Working internal image registry storage and the ModelCar image described below.
- The versioned KServe base configurations, including router/scheduler templates used by the custom runtime.
- For the Playground: Gen AI Studio and OGX enabled, with a working OGXServer and its persistent stores.
- For the commands: `oc`, `jq`, Bash, and cluster-admin access for cluster-scoped setup.

```bash
oc get nodes -L nvidia.com/gpu.product

oc get nodes -o json | jq -r '
  .items[] |
  [.metadata.name,
   .status.allocatable["nvidia.com/gpu"],
   .status.allocatable["rdma/rdma_shared_device_dx_bond"]] | @tsv
'

oc get crd llminferenceservices.serving.kserve.io
oc get crd leaderworkersets.leaderworkerset.x-k8s.io
oc get gatewayclass
oc get llminferenceserviceconfigs -n redhat-ods-applications
```

All three nodes reported `nvidia.com/gpu: 1` and shared RDMA capacity `1k` (1,000 allocation units, not 1,000 physical NICs). An RDMA allocation of `1` exposes shared device access; it is not a bandwidth reservation.

The custom template includes `IPC_LOCK`, `SYS_RAWIO`, and `NET_RAW`. The cluster admission/SCC configuration must permit the template on a fresh installation. Preserve the working service-account/SCC assignments; do not solve admission failures by granting broad privileged access to the namespace.

## 3. Namespace and RoCE network

```bash
oc create namespace ai-test --dry-run=client -o yaml | oc apply -f -
```

Save the following as `01-rdma-bond.yaml` if the NAD is not already managed by the Network Operator:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-bond
  namespace: ai-test
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "rdma-bond",
      "type": "macvlan",
      "master": "bond1",
      "mode": "bridge",
      "mtu": 9000,
      "ipam": {
        "type": "whereabouts",
        "range": "172.16.101.0/24",
        "exclude": ["172.16.101.0/30", "172.16.101.255/32"]
      }
    }
```

```bash
oc apply -f 01-rdma-bond.yaml
```

**Ownership:** In the working cluster this NAD is generated by a `MacvlanNetwork` named `rdma-bond` in `ai-test`. Preserve and recreate that parent resource when using Network Operator management. The NAD above captures the observed CNI configuration; do not simultaneously maintain a conflicting manual NAD and operator-owned source.

`bond1` must exist and be up on every serving node, with the same L2 connectivity and end-to-end jumbo-frame support. This NAD uses `bond1` directly, not `bond1.100`; do not substitute the VLAN interface without matching the actual network design.

The earlier network tests proved jumbo-ping connectivity and active RDMA ports between `ocp113` and `ocp115`. Later serving logs showed all three ranks communicating using RoCE. IP addresses are dynamic; do not hard-code the observed `.4`, `.5`, and `.6` addresses.

## 4. Internal registry and ModelCar

The metadata model registry and the OpenShift image registry have different jobs. The model registry catalogs model/version information. The internal image registry stores the ModelCar artifact that serving pods pull. A metadata registry alone does not cache weights in GPU memory or accelerate token generation.

### 4.1 Storage used in this environment

| Resource | Value |
|---|---|
| Registry namespace | `openshift-image-registry` |
| Registry PVC | `odf-image-registry-pvc` |
| StorageClass | `ocs-storagecluster-cephfs` |
| Access mode | `ReadWriteMany` |
| Final capacity | `500Gi` |
| Registry service | `image-registry.openshift-image-registry.svc:5000` |

For a fresh registry PVC, save as `02-registry-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odf-image-registry-pvc
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ocs-storagecluster-cephfs
  resources:
    requests:
      storage: 500Gi
```

Use this only when that claim needs creating. For an existing smaller claim, the actual expansion command was:

```bash
oc get storageclass ocs-storagecluster-cephfs \
  -o jsonpath='{.allowVolumeExpansion}{"\n"}'

oc patch pvc odf-image-registry-pvc \
  -n openshift-image-registry --type=merge \
  -p '{"spec":{"resources":{"requests":{"storage":"500Gi"}}}}'
```

To use this PVC as registry storage, merge only the relevant fields into the existing operator configuration:

```bash
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type=merge -p '{
    "spec": {
      "managementState": "Managed",
      "defaultRoute": true,
      "storage": {
        "managementState": "Unmanaged",
        "pvc": {"claim": "odf-image-registry-pvc"}
      }
    }
  }'
```

Do not apply this storage change over an existing registry using another storage backend without a storage migration plan. Expanding an existing PVC is different from replacing registry storage. `defaultRoute: true` was part of the recorded registry configuration but is not needed for in-cluster pulls.

```bash
oc get co image-registry
oc get pvc odf-image-registry-pvc -n openshift-image-registry
oc exec -n openshift-image-registry deployment/image-registry -- df -h /registry
```

The registry previously filled its smaller claim. Model blobs, failed-upload leftovers, and unrelated images share this storage. `500Gi` is the chosen capacity, not a claim that this model alone needs 500Gi.

### 4.2 Populate the ModelCar artifact

Use OpenShift AI **Register and store** to import the Hugging Face model, or restore the existing ModelCar image from a registry backup. The image must exist before deploying serving pods. Creating metadata in the model registry does not create its weight blobs.

| UI field | Value |
|---|---|
| Source | `RedHatAI/Qwen3.6-35B-A3B-FP8` on Hugging Face |
| Destination registry | `image-registry.openshift-image-registry.svc:5000` |
| Destination URI | `image-registry.openshift-image-registry.svc:5000/ai-test/qwen36-35b-a3b-fp8:v1` |
| Initial push credentials | An authorized image-push identity and its token |
| Serving storage URI | `oci://image-registry.openshift-image-registry.svc:5000/ai-test/qwen36-35b-a3b-fp8:v1` |

The destination URI in this UI required the **full registry hostname**. A relative URI previously sent the transfer toward Docker Hub. Keep the `oci://` prefix for the serving URI; do not add it to the UI destination Registry field.

The persistent service account in the next section has **pull-only** permissions. It is not a replacement for upload/push credentials.

For strict repeatability, record the source revision used in the import and the resulting OCI digest. `:v1` is a mutable tag. The model download in this conversation referenced revision `ea247061a1c961ddc12da…`; the complete revision and final OCI digest were not captured, so do not treat that abbreviated revision as a pin.

## 5. Persistent registry pull credentials

The final setup replaces a personal `oc whoami -t` token with a manually created persistent service-account token. It has no built-in expiry, but remains revocable and is invalidated if its backing Secret or ServiceAccount is deleted. Do not substitute `oc create token` here: TokenRequest credentials have expiration limits.

Save as `03-registry-puller.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: model-registry-puller
  namespace: ai-test
---
apiVersion: v1
kind: Secret
metadata:
  name: model-registry-puller-token
  namespace: ai-test
  annotations:
    kubernetes.io/service-account.name: model-registry-puller
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: model-registry-puller
  namespace: ai-test
subjects:
  - kind: ServiceAccount
    name: model-registry-puller
    namespace: ai-test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:image-puller
```

```bash
oc apply -f 03-registry-puller.yaml

oc wait secret/model-registry-puller-token \
  -n ai-test --for=jsonpath='{.data.token}' --timeout=60s
```

Generate the auth file and create/update the pull secret. No token is printed:

```bash
(
  set -euo pipefail
  umask 077

  oc get secret model-registry-puller-token -n ai-test -o json |
  jq -e \
    --arg registry "image-registry.openshift-image-registry.svc:5000" \
    --arg username "system:serviceaccount:ai-test:model-registry-puller" '
      (.data.token | @base64d) as $password |
      {
        auths: {
          ($registry): {
            username: $username,
            password: $password,
            auth: (($username + ":" + $password) | @base64)
          }
        }
      }
    ' > internal-registry-auth-serviceaccount.json

  oc create secret generic qwen36-35b-a3b-fp8 \
    -n ai-test --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=internal-registry-auth-serviceaccount.json \
    --dry-run=client -o yaml |
  oc apply -f -
)
```

Treat the generated JSON as a credential. For UI uploads, use this file instead of generating a new personal token. The application/API query credential is separate from the registry credential.

Verify authorization using the **subresource flag**:

```bash
oc auth can-i get imagestreams.image.openshift.io \
  --subresource=layers -n ai-test \
  --as=system:serviceaccount:ai-test:model-registry-puller
```

Expected: `yes`. The earlier command `oc auth can-i get imagestreams/layers` was wrong because the slash was interpreted as resource/name.

The serving pods can keep their existing service account. Their explicit `imagePullSecrets` references use credentials belonging to `model-registry-puller`; setting their `serviceAccountName` to that account is not required.

## 6. Custom pipeline-parallel runtime template

**This custom resource is essential.** Selecting the llm-d radio button or passing a pipeline flag to one pod does not launch a multi-node worker group.

Save the complete template below as `04-pipeline-runtime.yaml`. It is the custom template supplied by the working cluster, cleaned of generated metadata. It uses the installed version prefix `v3-5-1-`; other OpenShift AI versions may require a different template name or launch interface.

The template pins the observed runtime digest:

```text
registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:c056e61672b6aea489ad5dde0bd2f8497230f5333e87f7cf6c494eba3bfdc808
```

The versioned router, scheduler, TLS, model-loading, and controller dependencies must also be present. Keep this template separate from vendor-managed default templates.

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: v3-5-1-kserve-config-llm-worker-pipeline-parallel
  namespace: redhat-ods-applications
  annotations:
    serving.kserve.io/well-known-config: 'true'
  labels:
    platform.opendatahub.io/part-of: kserve
spec:
  annotations:
    serving.kserve.io/model-based-routing-enabled: 'true'
  model:
    uri: ''
  template:
    containers:
    - command:
      - /bin/bash
      - -c
      - |-
        if [ -f /etc/profile.d/ibm-aiu-setup.sh ]; then
          source /etc/profile.d/ibm-aiu-setup.sh
        fi

        MASTER_ADDR=$(getent ahostsv4 "${LWS_LEADER_ADDRESS}" | awk 'NR==1 {print $1}')
        if [ -z "${MASTER_ADDR}" ]; then
          MASTER_ADDR="${LWS_LEADER_ADDRESS}"
        fi

        echo "LWS_LEADER_ADDRESS=${LWS_LEADER_ADDRESS}"
        echo "MASTER_ADDR=${MASTER_ADDR}"
        echo "PP_SIZE={{ or .Spec.Parallelism.Pipeline 1 }}"
        echo "TP_SIZE={{ or .Spec.Parallelism.Tensor 1 }}"
        echo "NODE_RANK=0"

        ACCESS_LOG_ARGS="--disable-uvicorn-access-log"
        VLLM_VERSION=$(vllm --version 2>/dev/null | tail -1 | awk '{print $NF}')

        if [[ "${VLLM_VERSION}" =~ ^[0-9]+\.[0-9]+ ]] &&
           [ "$(printf '%s\n%s\n' "0.16.0" "${VLLM_VERSION}" | sort -V | head -1)" = "0.16.0" ]; then
          ACCESS_LOG_ARGS="--disable-access-log-for-endpoints /health,/metrics,/ping"
        fi

        eval "exec vllm serve \
          /mnt/models \
          --served-model-name \"{{ .Spec.Model.Name }}\" \"publishers/{{ .ObjectMeta.Namespace }}/models/{{ .Spec.Model.Name }}\" \
          --port 8000 \
          --api-server-count ${VLLM_API_SERVER_COUNT:-1} \
          --tensor-parallel-size {{ or .Spec.Parallelism.Tensor 1 }} \
          --pipeline-parallel-size {{ or .Spec.Parallelism.Pipeline 1 }} \
          --distributed-executor-backend mp \
          --nnodes {{ or .Spec.Parallelism.Pipeline 1 }} \
          --node-rank 0 \
          --master-addr ${MASTER_ADDR} \
          --master-port ${VLLM_MASTER_PORT:-29501} \
          ${ACCESS_LOG_ARGS} \
          {{ if .GlobalConfig.EnableTLS }}--enable-ssl-refresh{{- end }} \
          {{ if .GlobalConfig.EnableTLS }}--ssl-certfile /var/run/kserve/tls/tls.crt{{- end }} \
          {{ if .GlobalConfig.EnableTLS }}--ssl-keyfile /var/run/kserve/tls/tls.key{{- end }} \
          ${VLLM_ADDITIONAL_ARGS:-} \
          $@"
      - --
      env:
      - name: HOME
        value: /home
      - name: VLLM_LOGGING_LEVEL
        value: INFO
      - name: HF_HUB_CACHE
        value: /models
      image: registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:c056e61672b6aea489ad5dde0bd2f8497230f5333e87f7cf6c494eba3bfdc808
      imagePullPolicy: IfNotPresent
      lifecycle:
        preStop:
          exec:
            command:
            - /bin/sleep
            - '15'
      livenessProbe:
        failureThreshold: 10
        httpGet:
          path: /health
          port: 8000
          scheme: '{{ if .GlobalConfig.EnableTLS }}HTTPS{{else}}HTTP{{- end }}'
        periodSeconds: 10
        timeoutSeconds: 1
      name: main
      ports:
      - containerPort: 8000
        protocol: TCP
      readinessProbe:
        failureThreshold: 2
        httpGet:
          path: /health
          port: 8000
          scheme: '{{ if .GlobalConfig.EnableTLS }}HTTPS{{else}}HTTP{{- end }}'
        periodSeconds: 1
        timeoutSeconds: 1
      resources: {}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          add:
          - IPC_LOCK
          - SYS_RAWIO
          - NET_RAW
          drop:
          - ALL
        readOnlyRootFilesystem: false
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      startupProbe:
        failureThreshold: 60
        httpGet:
          path: /health
          port: 8000
          scheme: '{{ if .GlobalConfig.EnableTLS }}HTTPS{{else}}HTTP{{- end }}'
        periodSeconds: 10
      terminationMessagePath: /dev/termination-log
      terminationMessagePolicy: FallbackToLogsOnError
      volumeMounts:
      - mountPath: /home
        name: home
      - mountPath: /tmp
        name: tmp-dir
      - mountPath: /dev/shm
        name: dshm
      - mountPath: /models
        name: model-cache
      - mountPath: /var/run/kserve/tls
        name: tls-certs
        readOnly: true
    terminationGracePeriodSeconds: 60
    volumes:
    - emptyDir: {}
      name: home
    - emptyDir: {}
      name: tmp-dir
    - emptyDir:
        medium: Memory
        sizeLimit: 8Gi
      name: dshm
    - emptyDir: {}
      name: model-cache
    - name: tls-certs
      secret:
        secretName: '{{ ChildName .ObjectMeta.Name `-kserve-self-signed-certs` }}'
  worker:
    containers:
    - command:
      - /bin/bash
      - -c
      - |-
        if [ -f /etc/profile.d/ibm-aiu-setup.sh ]; then
          source /etc/profile.d/ibm-aiu-setup.sh
        fi

        MASTER_ADDR=$(getent ahostsv4 "${LWS_LEADER_ADDRESS}" | awk 'NR==1 {print $1}')
        if [ -z "${MASTER_ADDR}" ]; then
          MASTER_ADDR="${LWS_LEADER_ADDRESS}"
        fi

        NODE_RANK=${LWS_WORKER_INDEX:-1}

        echo "LWS_LEADER_ADDRESS=${LWS_LEADER_ADDRESS}"
        echo "MASTER_ADDR=${MASTER_ADDR}"
        echo "PP_SIZE={{ or .Spec.Parallelism.Pipeline 1 }}"
        echo "TP_SIZE={{ or .Spec.Parallelism.Tensor 1 }}"
        echo "NODE_RANK=${NODE_RANK}"

        ACCESS_LOG_ARGS="--disable-uvicorn-access-log"
        VLLM_VERSION=$(vllm --version 2>/dev/null | tail -1 | awk '{print $NF}')

        if [[ "${VLLM_VERSION}" =~ ^[0-9]+\.[0-9]+ ]] &&
           [ "$(printf '%s\n%s\n' "0.16.0" "${VLLM_VERSION}" | sort -V | head -1)" = "0.16.0" ]; then
          ACCESS_LOG_ARGS="--disable-access-log-for-endpoints /health,/metrics,/ping"
        fi

        eval "exec vllm serve \
          /mnt/models \
          --served-model-name \"{{ .Spec.Model.Name }}\" \"publishers/{{ .ObjectMeta.Namespace }}/models/{{ .Spec.Model.Name }}\" \
          --port 8000 \
          --tensor-parallel-size {{ or .Spec.Parallelism.Tensor 1 }} \
          --pipeline-parallel-size {{ or .Spec.Parallelism.Pipeline 1 }} \
          --distributed-executor-backend mp \
          --nnodes {{ or .Spec.Parallelism.Pipeline 1 }} \
          --node-rank ${NODE_RANK} \
          --master-addr ${MASTER_ADDR} \
          --master-port ${VLLM_MASTER_PORT:-29501} \
          --headless \
          ${ACCESS_LOG_ARGS} \
          {{ if .GlobalConfig.EnableTLS }}--enable-ssl-refresh{{- end }} \
          {{ if .GlobalConfig.EnableTLS }}--ssl-certfile /var/run/kserve/tls/tls.crt{{- end }} \
          {{ if .GlobalConfig.EnableTLS }}--ssl-keyfile /var/run/kserve/tls/tls.key{{- end }} \
          ${VLLM_ADDITIONAL_ARGS:-} \
          $@"
      - --
      env:
      - name: HOME
        value: /home
      - name: VLLM_LOGGING_LEVEL
        value: INFO
      - name: HF_HUB_CACHE
        value: /models
      image: registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:c056e61672b6aea489ad5dde0bd2f8497230f5333e87f7cf6c494eba3bfdc808
      imagePullPolicy: IfNotPresent
      lifecycle:
        preStop:
          exec:
            command:
            - /bin/sleep
            - '15'
      name: main
      ports:
      - containerPort: 8000
        protocol: TCP
      resources: {}
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          add:
          - IPC_LOCK
          - SYS_RAWIO
          - NET_RAW
          drop:
          - ALL
        readOnlyRootFilesystem: false
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      terminationMessagePath: /dev/termination-log
      terminationMessagePolicy: FallbackToLogsOnError
      volumeMounts:
      - mountPath: /home
        name: home
      - mountPath: /tmp
        name: tmp-dir
      - mountPath: /dev/shm
        name: dshm
      - mountPath: /models
        name: model-cache
      - mountPath: /var/run/kserve/tls
        name: tls-certs
        readOnly: true
    terminationGracePeriodSeconds: 60
    volumes:
    - emptyDir: {}
      name: home
    - emptyDir: {}
      name: tmp-dir
    - emptyDir:
        medium: Memory
        sizeLimit: 8Gi
      name: dshm
    - emptyDir: {}
      name: model-cache
    - name: tls-certs
      secret:
        secretName: '{{ ChildName .ObjectMeta.Name `-kserve-self-signed-certs` }}'

```

```bash
oc apply -f 04-pipeline-runtime.yaml

oc get llminferenceserviceconfig \
  v3-5-1-kserve-config-llm-worker-pipeline-parallel \
  -n redhat-ods-applications
```

The launch contract is:

| Parameter | Leader | Workers |
|---|---|---|
| Model path | `/mnt/models` | `/mnt/models` |
| Tensor size | `.spec.parallelism.tensor` | Same |
| Pipeline size / node count | `.spec.parallelism.pipeline` | Same |
| Executor | `mp` | `mp` |
| Node rank | `0` | `LWS_WORKER_INDEX` |
| Master address | Resolve `LWS_LEADER_ADDRESS` | Same |
| Master port | `29501` unless overridden | Same |
| API server | Enabled, port 8000 | `--headless` |

LWS supplies discovery and rank environment variables. Do not launch three independent `vllm serve` processes without this coordination.

This pipeline template does **not** contain the RoCE autodetection script present in the data-parallel template. Setting `KSERVE_INFER_ROCE=true` alone would not add that missing script. The working deployment used NCCL automatic HCA selection and verified the transport in logs.

## 7. Namespace-local Gateway

Save as `05-ai-test-gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ai-test-inference
  namespace: ai-test
  annotations:
    networking.istio.io/service-type: ClusterIP
  labels:
    istio.io/rev: openshift-gateway
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```

```bash
oc apply -f 05-ai-test-gateway.yaml
oc get svc ai-test-inference-openshift-default -n ai-test

oc wait gateway.gateway.networking.k8s.io/ai-test-inference \
  -n ai-test --for=condition=Programmed --timeout=120s
```

**Keep the ClusterIP annotation.** Without it, the gateway originally created a LoadBalancer Service with a pending external address. The external Route worked, but the gateway remained `Programmed=False`, causing OpenShift AI to report the model as starting/inactive. After changing to ClusterIP, both gateway and LLMInferenceService became ready.

The Service and proxy Deployment are generated by the gateway controller. Configure the Gateway rather than patching generated status or maintaining a competing Service manifest.

## 8. Three-node model service

Save as `06-qwen-three-a40.yaml`:

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: qwen36-35b-a3b-fp8-pp3
  namespace: ai-test
  labels:
    opendatahub.io/dashboard: 'true'
    opendatahub.io/genai-asset: 'true'
  annotations:
    openshift.io/display-name: Qwen3.6-35B-A3B-FP8 - Three A40s
    opendatahub.io/model-type: generative
    security.opendatahub.io/enable-auth: 'false'
spec:
  model:
    name: qwen36-35b-a3b-fp8-pp3
    uri: oci://image-registry.openshift-image-registry.svc:5000/ai-test/qwen36-35b-a3b-fp8:v1
  replicas: 1
  parallelism:
    tensor: 1
    pipeline: 3
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"rdma-bond","namespace":"ai-test"}]'
  router:
    gateway:
      refs:
      - name: ai-test-inference
        namespace: ai-test
    route: {}
    scheduler: {}
  template:
    nodeSelector:
      nvidia.com/gpu.product: NVIDIA-A40
    imagePullSecrets:
    - name: qwen36-35b-a3b-fp8
    containers:
    - name: main
      env:
      - name: VLLM_ADDITIONAL_ARGS
        value: --max-model-len=32768 --max-num-seqs=4 --gpu-memory-utilization=0.90 --reasoning-parser=qwen3
          --enable-auto-tool-choice --tool-call-parser=qwen3_coder --language-model-only
      - name: NCCL_DEBUG
        value: INFO
      - name: NCCL_IB_DISABLE
        value: '0'
      resources:
        requests:
          cpu: '6'
          memory: 32Gi
          nvidia.com/gpu: '1'
          rdma/rdma_shared_device_dx_bond: '1'
        limits:
          cpu: '6'
          memory: 32Gi
          nvidia.com/gpu: '1'
          rdma/rdma_shared_device_dx_bond: '1'
  worker:
    nodeSelector:
      nvidia.com/gpu.product: NVIDIA-A40
    imagePullSecrets:
    - name: qwen36-35b-a3b-fp8
    containers:
    - name: main
      env:
      - name: VLLM_ADDITIONAL_ARGS
        value: --max-model-len=32768 --max-num-seqs=4 --gpu-memory-utilization=0.90 --reasoning-parser=qwen3
          --enable-auto-tool-choice --tool-call-parser=qwen3_coder --language-model-only
      - name: NCCL_DEBUG
        value: INFO
      - name: NCCL_IB_DISABLE
        value: '0'
      resources:
        requests:
          cpu: '6'
          memory: 32Gi
          nvidia.com/gpu: '1'
          rdma/rdma_shared_device_dx_bond: '1'
        limits:
          cpu: '6'
          memory: 32Gi
          nvidia.com/gpu: '1'
          rdma/rdma_shared_device_dx_bond: '1'

```

```bash
oc apply -f 06-qwen-three-a40.yaml
```

This is a clean deployment manifest rather than a patch to the original one-GPU service. The original resource was named `qwen36-35b-a3b-fp8-1`; the final three-stage service is `qwen36-35b-a3b-fp8-pp3`.

Important implementation details:

- **Set pipeline size at creation.** Total parallelism is immutable in this installed CRD. Changing an existing single-stage service to three stages was rejected, even when stopped. Create a new service for a topology change.
- **Omit `data`, `dataLocal`, and `dataRPCPort`.** Setting `data: 1` or `dataLocal: 1` together with pipeline parallelism was rejected by admission validation. Do not copy those fields from a data-parallel example.
- **Use one replica group.** The controller generates one leader plus two workers. Do not create the generated LeaderWorkerSet manually.
- **Declare both `template` and `worker`.** The leader and every worker need the GPU, memory, RDMA allocation, model artifact access, and pull secret.
- **Do not duplicate TP/PP launch flags in `VLLM_ADDITIONAL_ARGS`.** The custom runtime supplies them from the CR.
- **The final configuration omits `--enforce-eager`.** It was a temporary startup diagnostic. Removing it enabled compilation/CUDA-graph optimizations and materially improved the user's observed performance.
- **Text-only mode is intentional.** `--language-model-only` was used in the working configuration. Remove it and revalidate memory/performance if image or video inputs are needed.
- **Registry IDs are installation-specific.** The original UI-created service carried model registry ID labels. Add matching `modelregistry.opendatahub.io/*` labels only after resolving actual IDs in the destination registry. Numeric IDs from another cluster must not be copied.
- The hardware profile previously used was `nvidia-1-gpu` in `redhat-ods-applications`. The manifest declares resources explicitly, so it does not copy that profile's resource-version annotation. Recreate/select the profile separately if editing through the dashboard.

### Final vLLM tuning

| Argument | Value / reason |
|---|---|
| `--max-model-len` | `32768`; tested context limit |
| `--max-num-seqs` | `4`; conservative simultaneous-sequence limit |
| `--gpu-memory-utilization` | `0.90` |
| `--reasoning-parser` | `qwen3` |
| `--enable-auto-tool-choice` | Enabled |
| `--tool-call-parser` | `qwen3_coder` |
| `--language-model-only` | Enabled for text-only operation |
| `--enforce-eager` | **Absent** in the final configuration |
| Speculative decoding | Not enabled in the final configuration |
| `NCCL_DEBUG` | `INFO` for verification |
| `NCCL_IB_DISABLE` | `0`; permit RDMA transport |
| `OMP_NUM_THREADS` | Not overridden |

The A40 runtime selected Marlin FP8 weight-only kernels; the A40 does not provide native FP8 arithmetic. No Hopper-specific DeepGEMM backend was forced. The model-card eight-GPU example was not copied as the cluster topology.

The default reasoning behavior is a **request** setting, separate from the reasoning parser. Send `chat_template_kwargs: {enable_thinking: false}` for the low-latency non-thinking tests. Do not assume every client or the Playground automatically applies this.

## 9. External HTTPS Route

An OpenShift Route targets a Service in the same namespace. With the dedicated gateway Service now in `ai-test`, the external Route can also live there.

```bash
GATEWAY_HTTP_PORT="$(
  oc get svc ai-test-inference-openshift-default -n ai-test -o json |
  jq -er '
    [.spec.ports[] | select(.port == 80)] |
    first | .name // (.port | tostring)
  '
)" &&
oc create route edge qwen36-pp3 \
  -n ai-test \
  --service=ai-test-inference-openshift-default \
  --port="$GATEWAY_HTTP_PORT" \
  --path=/ai-test/qwen36-35b-a3b-fp8-pp3 \
  --insecure-policy=Redirect

oc annotate route qwen36-pp3 -n ai-test \
  haproxy.router.openshift.io/timeout=300s --overwrite
```

For a declarative copy, the structure is below. Substitute the actual Service port **name** returned above for `SERVICE_HTTP_PORT_NAME` and adjust the host for the destination cluster:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: qwen36-pp3
  namespace: ai-test
  annotations:
    haproxy.router.openshift.io/timeout: 300s
spec:
  host: qwen36-pp3-ai-test.apps.ocp4.localdomain
  path: /ai-test/qwen36-35b-a3b-fp8-pp3
  to:
    kind: Service
    name: ai-test-inference-openshift-default
    weight: 100
  port:
    targetPort: SERVICE_HTTP_PORT_NAME
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

Do not set targetPort to `80` blindly when the Service has a named port with a different numeric targetPort. The command above resolves the actual Service port name.

| Endpoint | URL |
|---|---|
| External base | `https://qwen36-pp3-ai-test.apps.ocp4.localdomain/ai-test/qwen36-35b-a3b-fp8-pp3` |
| Internal base | `http://ai-test-inference-openshift-default.ai-test.svc.cluster.local/ai-test/qwen36-35b-a3b-fp8-pp3` |
| OGX OpenAI provider base | Internal base plus `/v1` |
| Chat completion | Base plus `/v1/chat/completions` |

Preserve the model path prefix; the generated HTTPRoute rewrites it for the backend. Internal `.svc.cluster.local` names normally resolve only inside the cluster. Curl from the RHEL client should use the external Route.

The lab used the router's default certificate with a CA not trusted by the client. `curl -k` / the Python `--insecure` option skips verification for that lab. A trusted ingress certificate or `--cacert` is the verified-TLS alternative. The recorded service has authentication disabled; the Route does not itself add model authentication.

### External test

```bash
ROUTE_HOST="$(oc get route qwen36-pp3 -n ai-test -o jsonpath='{.spec.host}')"
MODEL_ENDPOINT="https://${ROUTE_HOST}/ai-test/qwen36-35b-a3b-fp8-pp3"

curl -skS "${MODEL_ENDPOINT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen36-35b-a3b-fp8-pp3",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "max_tokens": 64,
    "temperature": 0.7,
    "top_p": 0.8,
    "chat_template_kwargs": {"enable_thinking": false}
  }' | jq .
```

## 10. Gen AI Playground and OGX

### 10.1 Provision the Playground components

For a fresh namespace, use the OpenShift AI UI to enable/provision the Playground and its stores. The observed resources were:

| Resource | Working name |
|---|---|
| OGXServer | `lsd-genai-playground` |
| Backend Deployment | `lsd-genai-playground` |
| ConfigMap | `llama-stack-config`, key `config.yaml` |
| OGX port | `8321` |
| OGX distribution | `rh-dev` |
| Loaded OGX version | `1.2.4+rhaiv.0` |
| Inference provider | `vllm-inference-1`, type `remote::vllm` |
| Vector store host | `genai-pgvector.ai-test.svc.cluster.local:5432` |
| Vector database/user | `vectordb` / `vectoruser` |
| Database Secret | `genai-pgvector-credentials`, key `password` |

The resource type in this installation is **`ogxservers.ogx.io`**, not the older `llamastackdistributions` name. `ConfigGenerated=False / ConfigGenerationInactive` was expected while using `overrideConfig`; it did not mean the running server was unhealthy.

The observed OGXServer configuration is below. Apply it only after the UI or your backup restore supplies the complete `llama-stack-config`, pgvector, database credentials, and required persistence. This manifest alone does not create those dependencies.

```yaml
apiVersion: ogx.io/v1beta1
kind: OGXServer
metadata:
  name: lsd-genai-playground
  namespace: ai-test
  annotations:
    openshift.io/display-name: lsd-genai-playground
  labels:
    opendatahub.io/dashboard: 'true'
spec:
  distribution:
    name: rh-dev
  network:
    port: 8321
  overrideConfig:
    key: config.yaml
    name: llama-stack-config
  workload:
    overrides:
      command:
        - /bin/sh
        - -c
        - ogx run /etc/ogx/config.yaml --insecure
      env:
        - name: VLLM_TLS_VERIFY
          value: 'false'
        - name: FAISS_STORE_DIR
          value: ~/.llama/faiss
        - name: SENTENCE_TRANSFORMERS_HOME
          value: /opt/app-root/.cache/huggingface/hub
        - name: HF_HUB_OFFLINE
          value: '1'
        - name: TRANSFORMERS_OFFLINE
          value: '1'
        - name: HF_DATASETS_OFFLINE
          value: '1'
        - name: VLLM_MAX_TOKENS_1
          value: '4096'
        - name: VLLM_API_TOKEN_1
          value: fake
        - name: PGVECTOR_HOST
          value: genai-pgvector.ai-test.svc.cluster.local
        - name: PGVECTOR_PORT
          value: '5432'
        - name: PGVECTOR_DB
          value: vectordb
        - name: PGVECTOR_USER
          value: vectoruser
        - name: PGVECTOR_PASSWORD
          valueFrom:
            secretKeyRef:
              key: password
              name: genai-pgvector-credentials
        - name: OGX_CONFIG_DIR
          value: /opt/app-root/src/.ogx/distributions/rh/
    replicas: 1
    resources:
      limits:
        cpu: '2'
        memory: 12Gi
      requests:
        cpu: 250m
        memory: 500Mi
```

`fake` was a non-secret placeholder accepted for the unauthenticated model endpoint. It is not a registry password. The offline flags were already present in the working Playground; they are appropriate only when its required local model assets are available.

### 10.2 Correct the provider endpoint

The key failure after moving gateways was that OGX retained the old gateway address. The model was ready and external curl worked, but Playground generation returned an upstream 404.

In the **existing full** `config.yaml`, the vLLM inference provider must resolve to:

```yaml
# Provider fragment only; merge into the existing configuration.
providers:
  inference:
    - provider_id: vllm-inference-1
      provider_type: remote::vllm
      config:
        base_url: http://ai-test-inference-openshift-default.ai-test.svc.cluster.local/ai-test/qwen36-35b-a3b-fp8-pp3/v1
```

Retain its existing token, maximum-token, TLS, model-registration, persistence, vector-store, file, and tool settings. Do not replace the entire ConfigMap with this fragment. The full ConfigMap was not supplied in the conversation, so exporting it from the working cluster is required for a complete standalone Playground rebuild.

When migrating from the old shared gateway, the successful repair was:

```bash
oc get configmap llama-stack-config -n ai-test -o json \
  > llama-stack-config-before.json

jq '
  {
    data: {
      "config.yaml": (
        .data["config.yaml"] |
        gsub(
          "openshift-ai-inference-openshift-default\\.openshift-ingress\\.svc\\.cluster\\.local";
          "ai-test-inference-openshift-default.ai-test.svc.cluster.local"
        )
      )
    }
  }
' llama-stack-config-before.json > llama-stack-endpoint-patch.json

oc patch configmap llama-stack-config -n ai-test --type=merge \
  --patch-file=llama-stack-endpoint-patch.json

oc rollout restart deployment/lsd-genai-playground -n ai-test
oc rollout status deployment/lsd-genai-playground \
  -n ai-test --timeout=180s
```

Verify the loaded runtime configuration:

```bash
oc get ogxserver lsd-genai-playground -n ai-test -o json |
jq -r '
  .status.distributionConfig.providers[] |
  select(.provider_id == "vllm-inference-1") |
  .config.base_url
'
```

It must show the **new `ai-test` gateway** and end in `/v1`. The registered provider's backend model name must be `qwen36-35b-a3b-fp8-pp3` (or its served publisher alias), not an obsolete one-GPU model identifier. The Playground may display the provider-qualified name `vllm-inference-1/...`.

Refresh/reopen the Playground after changing configuration. Recheck the provider URL when adding or reconfiguring models through the UI, because the Playground ConfigMap can be managed by dashboard workflows.

## 11. Validation and performance

### 11.1 Control-plane readiness

```bash
oc get llminferenceservice qwen36-35b-a3b-fp8-pp3 -n ai-test

oc wait llminferenceservice/qwen36-35b-a3b-fp8-pp3 \
  -n ai-test --for=condition=Ready --timeout=600s

oc get llminferenceservice qwen36-35b-a3b-fp8-pp3 -n ai-test \
  -o jsonpath='{.spec.parallelism}{"\n"}{range .status.appliedConfigs[*]}{.name}{"\n"}{end}'

oc get leaderworkersets -n ai-test
oc get pods -n ai-test -o wide
```

Expect the pipeline runtime in `appliedConfigs`, one LWS group of size three, and three GPU-serving pods on different nodes. Router/scheduler pods are additional and do not need GPUs.

Generated pod names observed in this deployment were:

```text
qwen36-35b-a3b-fp8-pp3-kserve-mn-0
qwen36-35b-a3b-fp8-pp3-kserve-mn-0-1
qwen36-35b-a3b-fp8-pp3-kserve-mn-0-2
```

Use the actual listing if naming differs in another release.

### 11.2 Network attachment and NCCL transport

```bash
oc get pods -n ai-test -o json | jq -r '
  .items[] |
  select(.metadata.name | startswith("qwen36-35b-a3b-fp8-pp3-kserve-mn-")) |
  .metadata.name as $pod |
  .spec.nodeName as $node |
  ((.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]")
    | fromjson)[] |
  [$pod, $node, .name, (.interface // ""), ((.ips // []) | join(","))] | @tsv
'
```

Each serving pod should show `ai-test/rdma-bond`, normally interface `net1`, with a `172.16.101.x` address.

```bash
oc get pods -n ai-test -o json |
jq -r '
  .items[] |
  select(.metadata.name | startswith("qwen36-35b-a3b-fp8-pp3-kserve-mn-")) |
  .metadata.name
' |
while IFS= read -r pod; do
  printf '\nPod: %s\n' "$pod"
  oc logs -n ai-test "$pod" -c main --tail=-1 |
    grep -Ei 'PP_SIZE|TP_SIZE|NODE_RANK|world_size|NET/IB|NET/Socket|Bootstrap|Init COMPLETE'
done
```

Observed evidence:

```text
PP_SIZE=3
TP_SIZE=1
world_size=3
NET/IB : Using [0]mlx5_bond_0:1/RoCE
Channel ... [send] via NET/IB/0
Channel ... [receive] via NET/IB/0
```

`Bootstrap: Using eth0:10.x...` describes setup communication; it does not mean payload traffic falls back to TCP. The channel lines establish the selected data transport. Missing optional NCCL plugin messages did not prevent the built-in IB transport from working.

To inspect valid GID mappings without printing errors for empty slots:

```bash
for pod in \
  qwen36-35b-a3b-fp8-pp3-kserve-mn-0 \
  qwen36-35b-a3b-fp8-pp3-kserve-mn-0-1 \
  qwen36-35b-a3b-fp8-pp3-kserve-mn-0-2
do
  printf '\nPod: %s\n' "$pod"
  oc exec -n ai-test "$pod" -c main -- sh -c '
    port=/sys/class/infiniband/mlx5_bond_0/ports/1
    for path in "$port"/gid_attrs/ndevs/*; do
      interface=$(cat "$path" 2>/dev/null) || continue
      [ "$interface" = net1 ] || continue
      index=${path##*/}
      type=$(cat "$port/gid_attrs/types/$index" 2>/dev/null) || continue
      gid=$(cat "$port/gids/$index" 2>/dev/null) || continue
      printf "index=%s interface=%s type=%s gid=%s\n" \
        "$index" "$interface" "$type" "$gid"
    done
  '
done
```

The leader had IPv4 RoCE v2 GID index `5`, encoding `172.16.101.4`. This establishes an available mapping, not proof of the exact GID selected by NCCL. Indexes can differ between nodes and restarts; none was hard-coded. `NCCL_SOCKET_IFNAME` and `NCCL_IB_HCA` were also not forced.

RoCE operation was observed. GPUDirect RDMA was **not conclusively established**: the logs reported DMA-BUF availability, but a later communicator also logged `GDR 0`. Do not equate `NET/IB` with proof of direct GPU-to-NIC transfers.

### 11.3 Performance checks

After compilation/warm-up, test the same short prompt with thinking disabled, then test realistic prompts and concurrent requests. Separate time to first visible answer, total request duration, token throughput, and concurrency.

Observed post-tuning CLI examples were about 0.14–0.15 seconds to first answer text, with total request times of 0.16–0.23 seconds for very short responses. These are single-request examples, not a capacity benchmark. A 3-token answer's tokens-per-second ratio is dominated by fixed request overhead.

The earlier eager-mode log showed roughly 24 generated tokens/s during a longer single request, initial Triton JIT compilation, and a long wait before visible text. Thinking was enabled in that initial test. These measurements are not directly comparable because execution settings, output length, and reasoning behavior changed.

The warning that Torch reduced CPU parallelism from 64 threads to 1 is not a GPU-thread limit. No `OMP_NUM_THREADS` increase was needed for the successful setup. First-request JIT warnings can cause latency spikes; judge steady-state performance after warm-up.

## 12. Operations and troubleshooting

### Stop and start the distributed model

```bash
# Stop the group.
oc annotate llminferenceservice qwen36-35b-a3b-fp8-pp3 \
  -n ai-test serving.kserve.io/stop=true --overwrite

# Start the group.
oc annotate llminferenceservice qwen36-35b-a3b-fp8-pp3 \
  -n ai-test serving.kserve.io/stop-
```

Wait for readiness after starting. The persistent registry credential avoids dependence on an expiring personal token when images must be pulled again.

| Symptom | Cause / resolution established here |
|---|---|
| Cannot combine pipeline and data parallelism | Omit `data`, `dataLocal`, and `dataRPCPort`; even values of `1` were rejected |
| Total parallelism immutable | Create a new LLMInferenceService with the desired topology at creation |
| One GPU pod despite llm-d selection | Worker section/custom pipeline template missing or not selected |
| Model serves externally but UI says starting/inactive | Check gateway `Programmed`; use ClusterIP behind the external Route |
| Playground `[server_error] 404`, external curl succeeds | OGX provider still pointed to old shared gateway; update ConfigMap and restart OGX |
| `.svc.cluster.local` DNS error on RHEL client | Use external Route, or issue the request inside the cluster |
| Curl certificate-chain error | Trust ingress CA / use `--cacert`; lab testing used `-k` |
| Pull authentication fails after a day | Replace personal token with the persistent service-account credentials |
| Pull permission check says `no` with `imagestreams/layers` | Use `--subresource=layers` rather than resource/name syntax |
| Slow first request | Compilation, communicator setup, or thinking; compare warmed, consistent requests |
| Low single-chat speed across three GPUs | Pipeline execution is sequential across stages; measure concurrent throughput separately |
| Registry upload runs out of space | Check registry PVC filesystem and expand as appropriate; model blobs share registry capacity |

Inspect failing readiness conditions:

```bash
oc get llminferenceservice qwen36-35b-a3b-fp8-pp3 -n ai-test -o json |
jq '[.status.conditions[]? | select(.status != "True")]'

oc get gateway ai-test-inference -n ai-test -o json |
jq '.status.conditions'

oc logs -n ai-test deployment/lsd-genai-playground \
  --all-containers --since=10m --tail=200
```

Do not manually set `status.Ready`, `Programmed`, or other controller-owned status fields. Fix the underlying configuration.

## 13. Capture the live configuration

These commands capture installation-specific details that are not fully represented in the conversation. Run them on the working cluster to retain the exact final configuration. Generated exports contain status and metadata; clean them before applying to a different cluster.

```bash
mkdir -p three-a40-backup

oc get llminferenceservice qwen36-35b-a3b-fp8-pp3 -n ai-test -o yaml \
  > three-a40-backup/llminferenceservice.yaml
oc get llminferenceserviceconfig \
  v3-5-1-kserve-config-llm-worker-pipeline-parallel \
  -n redhat-ods-applications -o yaml \
  > three-a40-backup/pipeline-runtime.yaml
oc get llminferenceserviceconfigs -n redhat-ods-applications -o yaml \
  > three-a40-backup/serving-configs.yaml
oc get gateway ai-test-inference -n ai-test -o yaml \
  > three-a40-backup/gateway.yaml
oc get gatewayclass openshift-default -o yaml \
  > three-a40-backup/gatewayclass.yaml
oc get route qwen36-pp3 -n ai-test -o yaml \
  > three-a40-backup/route.yaml
oc get httproute,inferencepool -n ai-test -o yaml \
  > three-a40-backup/generated-routing-reference.yaml
oc get network-attachment-definition rdma-bond -n ai-test -o yaml \
  > three-a40-backup/rdma-nad.yaml
oc get macvlannetwork rdma-bond -n ai-test -o yaml \
  > three-a40-backup/macvlan-parent.yaml
oc get nicclusterpolicies -o yaml \
  > three-a40-backup/network-operator-policy.yaml
oc get clusterpolicies.nvidia.com -o yaml \
  > three-a40-backup/gpu-operator-policy.yaml
oc get nodenetworkconfigurationpolicies -o yaml \
  > three-a40-backup/host-network-policies.yaml
oc get ogxserver lsd-genai-playground -n ai-test -o yaml \
  > three-a40-backup/ogxserver.yaml
oc get configmap llama-stack-config -n ai-test -o yaml \
  > three-a40-backup/playground-config.yaml
oc get deployment genai-pgvector -n ai-test -o yaml \
  > three-a40-backup/pgvector-deployment.yaml
oc get pvc -n ai-test -o yaml \
  > three-a40-backup/project-pvcs.yaml
oc get configs.imageregistry.operator.openshift.io cluster -o yaml \
  > three-a40-backup/registry-config.yaml
oc get pvc odf-image-registry-pvc -n openshift-image-registry -o yaml \
  > three-a40-backup/registry-pvc.yaml
```

Back up backing data separately: registry blobs, OGX stores/database, and any model metadata registry database. A YAML manifest for a PVC does not back up its data. Some full operator/config exports can contain credentials (for example, registry `httpSecret` or inline provider settings); protect and review the backup before sharing it. Reissue token Secrets on another cluster rather than copying service-account tokens across clusters.

The created LWS, HTTPRoute, InferencePool, proxy Services, and serving pods are controller-managed outputs. Retain their exports as diagnostic references; rebuild them by applying their parent Gateway and LLMInferenceService resources.

## 14. Python CLI

The companion `qwen.py` uses only Python standard-library modules. Save the source in the appendix as `~/qwen.py`, or use the previously delivered script. The default endpoint is the external Route in `ai-test`.

```bash
python3 ~/qwen.py --insecure --stream --stats "Explain RDMA."

# Persist the shortcut (add once).
echo "alias qwen='python3 ~/qwen.py --insecure --stream'" >> ~/.bashrc
source ~/.bashrc

qwen --stats "Say hello in one sentence."
```

Options include `--thinking`, `--max-tokens`, `--json`, `--endpoint`, and `--cacert`. `QWEN_TOKEN`, if set, is a serving API bearer token, not an image-pull credential.

Statistics include server-supplied prompt/completion/total token counts, reasoning/cache details when supplied, client wall time, streaming first-text times, finish reason, and completion tokens divided by total request time. This ratio is not GPU-only decode speed. Stats go to stderr; the answer goes to stdout.

<details>
<summary>Complete Python CLI source</summary>

```python
#!/usr/bin/env python3
"""Query the Qwen model on OpenShift AI. Python 3.9+, no pip packages needed.

Examples:
    python3 qwen.py --insecure "Explain pipeline parallelism."
    python3 qwen.py --insecure --stream "Write a short poem."
    python3 qwen.py --insecure --stream --stats "Explain RDMA."
    echo "Explain RDMA." | python3 qwen.py --insecure

Environment: QWEN_ENDPOINT, QWEN_MODEL, QWEN_TOKEN, QWEN_INSECURE=1.
The token is a model endpoint token, not a registry pull credential.
"""

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

DEFAULT_ENDPOINT = (
    "https://qwen36-pp3-ai-test.apps.ocp4.localdomain"
    "/ai-test/qwen36-35b-a3b-fp8-pp3"
)


def print_stats(usage, elapsed, first_generated, first_answer, finish_reason):
    """Server token counts; client timings include network and queueing."""
    print("\nStatistics (client wall time includes network and queueing):", file=sys.stderr)
    print("  Request time: {:.2f} s".format(elapsed), file=sys.stderr)
    for label, value in (("First generated text chunk", first_generated),
                         ("First answer text chunk", first_answer)):
        if value is not None:
            print("  {}: {:.2f} s".format(label, value), file=sys.stderr)
    if usage:
        for label, key in (("Prompt tokens", "prompt_tokens"),
                           ("Completion tokens", "completion_tokens"),
                           ("Total tokens", "total_tokens")):
            if usage.get(key) is not None:
                print("  {}: {}".format(label, usage[key]), file=sys.stderr)
        for label, details, key in (
            ("Reasoning tokens", "completion_tokens_details", "reasoning_tokens"),
            ("Cached prompt tokens", "prompt_tokens_details", "cached_tokens"),
        ):
            value = (usage.get(details) or {}).get(key)
            if value is not None:
                print("  {}: {}".format(label, value), file=sys.stderr)
        completion_tokens = usage.get("completion_tokens")
        if isinstance(completion_tokens, (int, float)) and elapsed > 0:
            print("  Completion tokens / total request time: {:.2f} tokens/s".format(
                completion_tokens / elapsed), file=sys.stderr)
    else:
        print("  Token usage: not supplied by server", file=sys.stderr)
    if finish_reason is not None:
        print("  Finish reason: {}".format(finish_reason), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("prompt", nargs="*", help="Prompt text; reads stdin if omitted")
    parser.add_argument("--endpoint", default=os.getenv("QWEN_ENDPOINT", DEFAULT_ENDPOINT))
    parser.add_argument("--model", default=os.getenv("QWEN_MODEL", "qwen36-35b-a3b-fp8-pp3"))
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--thinking", action="store_true", help="Enable model reasoning")
    parser.add_argument("--stream", action="store_true", help="Print answer as tokens arrive")
    parser.add_argument("--json", action="store_true", help="Print full response JSON")
    parser.add_argument("--stats", action="store_true", help="Print token counts and client timings to stderr")
    parser.add_argument("--timeout", type=float, default=300, help="Socket timeout in seconds")
    parser.add_argument("--cacert", help="PEM CA certificate file")
    parser.add_argument("--insecure", action="store_true",
                        default=os.getenv("QWEN_INSECURE", "").lower() in ("1", "true", "yes"),
                        help="Skip TLS verification for the lab certificate")
    args = parser.parse_args()
    if args.stream and args.json:
        parser.error("Choose --stream or --json, not both")
    if args.max_tokens < 1 or args.timeout <= 0:
        parser.error("--max-tokens and --timeout must be positive")
    if not args.prompt and sys.stdin.isatty():
        parser.error("Provide a prompt or pipe text into stdin")
    prompt = " ".join(args.prompt) if args.prompt else sys.stdin.read()
    if not prompt.strip():
        parser.error("Prompt is empty")
    endpoint = args.endpoint.rstrip("/")
    if not endpoint.startswith(("http://", "https://")):
        parser.error("--endpoint must start with http:// or https://")
    url = endpoint + ("/chat/completions" if endpoint.endswith("/v1")
                      else "/v1/chat/completions")
    payload = {
        "model": args.model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "top_p": 0.8,
        "stream": args.stream,
        "chat_template_kwargs": {"enable_thinking": args.thinking},
    }
    if args.stream and args.stats:
        payload["stream_options"] = {"include_usage": True}
    headers = {"Content-Type": "application/json"}
    if os.getenv("QWEN_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["QWEN_TOKEN"]
    try:
        context = ssl.create_default_context(cafile=args.cacert)
        if args.insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
        usage = None
        first_generated = None
        first_answer = None
        finish_reason = None
        started = time.perf_counter()
        with urllib.request.urlopen(request, context=context, timeout=args.timeout) as response:
            if args.stream:
                for line in response:
                    line = line.decode("utf-8").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    event = json.loads(data)
                    if "error" in event:
                        raise ValueError(str(event["error"]))
                    if event.get("usage") is not None:
                        usage = event["usage"]
                    for choice in event.get("choices", []):
                        delta = choice.get("delta") or {}
                        content = delta.get("content") or ""
                        reasoning = delta.get("reasoning") or delta.get("reasoning_content") or ""
                        if first_generated is None and (content or reasoning):
                            first_generated = time.perf_counter() - started
                        if first_answer is None and content:
                            first_answer = time.perf_counter() - started
                        if choice.get("finish_reason") is not None:
                            finish_reason = choice["finish_reason"]
                        print(content, end="", flush=True)
                print()
            else:
                result = json.load(response)
                usage = result.get("usage")
                finish_reason = result["choices"][0].get("finish_reason")
                if args.json:
                    print(json.dumps(result, indent=2, ensure_ascii=False))
                else:
                    print(result["choices"][0]["message"].get("content") or "")
        if args.stats:
            print_stats(usage, time.perf_counter() - started,
                        first_generated, first_answer, finish_reason)
        return 0
    except urllib.error.HTTPError as exc:
        print("HTTP {}: {}".format(exc.code, exc.read().decode("utf-8", errors="replace")),
              file=sys.stderr)
    except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError) as exc:
        print("Request failed: {}".format(exc), file=sys.stderr)
        print("For the lab certificate, use --insecure; otherwise use --cacert.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(file=sys.stderr)
        sys.exit(130)

```

</details>

## 15. References

- [RedHatAI/Qwen3.6-35B-A3B-FP8 model card](https://huggingface.co/RedHatAI/Qwen3.6-35B-A3B-FP8): model-specific parser flags and request-level non-thinking mode. The topology and conservative limits in this runbook are environment-specific adjustments.
- [OpenShift AI 3.5: Distributed Inference with llm-d](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/index)
- [OpenShift AI 3.5: Gateway configuration and references](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/deploy_models_using_distributed_inference_with_llm-d/gateway-discovery-for-llmd_gateway-discovery)
- [OpenShift AI 3.5: RoCE networking](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_distributed_workloads/configuring-roce-networking-for-distributed-llm-deployments_distributed-llm-roce): this feature is documented as Technology Preview in 3.5.
- [Istio: Gateway service-type annotation](https://istio.io/latest/docs/setup/getting-started/)
- [NCCL environment variables](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html)
- [vLLM parallelism and scaling](https://docs.vllm.ai/en/latest/serving/parallelism_scaling/)
- [vLLM CUDA graphs](https://docs.vllm.ai/en/latest/design/cuda_graphs/)
- [vLLM FP8 kernels and hardware behavior](https://docs.vllm.ai/en/latest/features/quantization/llm_compressor/fp8/)
- [Kubernetes: manually created persistent service-account tokens](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [OpenShift 4.22: image access permissions](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/images/managing-images)

**Completion check:** three serving ranks, NCCL RoCE channels, gateway `Programmed=True`, model `Ready=True`, successful external chat request, and successful Playground generation using the new gateway address.
