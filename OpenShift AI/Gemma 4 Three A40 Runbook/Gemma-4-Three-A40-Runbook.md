# Gemma 4 26B A4B FP8 — Three A40 Runbook

**OpenShift 4.22 / OpenShift AI 3.5.x • prepared October 22, 2026 • deployment candidate, not cluster-validated**

Deploy `RedHatAI/gemma-4-26B-A4B-it-FP8-dynamic` as an independent `LLMInferenceService` in namespace `gemma`, using three A40 GPUs, one per node, pipeline parallelism 3 and tensor parallelism 1. Includes ModelCar import, namespace-owned runtime, RoCE attachment, gateway, optional external model Route, and separate persistent Open WebUI.

Adapted from the linked Nemotron runbook [B]. Its successful Nemotron results are **not** Gemma test results. The pinned upstream vLLM image below comes from that baseline; its source has Gemma multimodal and pipeline interfaces, but this exact checkpoint, FP8 fallback, image processing and three-node execution must pass the checks here. No commands have been executed against your cluster in preparing this document.

**Run only one three-GPU model at a time.** Prepare CPU-only resources first. Stop the currently active model through its own procedure before the GPU probe, and release the probe GPU before starting Gemma. Nothing here modifies Qwen or Nemotron resources.

## Contents

1. Target layout and compatibility decisions
2. Namespace and runtime preflight
3. Create the secondary-network attachment
4. Validate secondary-network connectivity
5. Import and store the ModelCar
6. Create independent persistent pull credentials
7. Create the Gemma-owned pipeline runtime and chat template
8. Create the namespace-local gateway
9. Create the Gemma service, initially stopped
10. Check GPU availability and start Gemma
11. Verify serving, RoCE, text, images and tools
12. Optional external model Route
13. Deploy separate Open WebUI
14. Optional Gen AI Playground
15. Stop/start, troubleshooting, tuning and upgrade checks
16. Validation record and sources

## 1. Target layout and compatibility decisions

| Setting | Value |
|---|---|
| Namespace | `gemma` |
| HF source | `RedHatAI/gemma-4-26B-A4B-it-FP8-dynamic` |
| Service / served model name | `gemma4-26b-a4b-fp8-pp3` |
| ImageStream | `gemma/gemma4-26b-a4b-fp8` |
| Initial model image tag | `v1`; pin the imported digest before validation |
| Topology | One replica group, PP=3, TP=1, three processes on three nodes |
| Decoder partition | `VLLM_PP_LAYER_PARTITION=10,10,10`, all ranks |
| Nodes | `ocp113.localdomain`, `ocp114.localdomain`, `ocp115.localdomain` |
| Resources per rank | 6 CPU, 48Gi host RAM, 1 A40, 1 `rdma/rdma_shared_device_dx_bond` |
| Initial context / concurrency | 32,768 tokens / 2 active sequences |
| Nonquantized compute / KV cache | BF16 / `auto` (no FP8 KV cache requested) |
| Images | One image per request initially; text output only |
| Runtime | Upstream vLLM 0.27.1 candidate digest from baseline, identical on all ranks |
| Local runtime config | `gemma4-pipeline-v1` |
| Network / NAD | `rdma-gemma` / `gemma/rdma-gemma` |
| Secondary subnet | Proposed `172.16.103.0/24`; confirm unused before applying |
| Interface | `net1`, macvlan on existing `bond1`, MTU 9000 |
| Gateway | `gemma-inference`, class `openshift-default` |
| Model Route | `gemma4-pp3` (optional and unauthenticated) |
| WebUI | `gemma/open-webui`, independent 10Gi PVC and signing key |

### What changes from Nemotron

The requested checkpoint accepts text and images and returns text. It does not generate images. Use the Gemma reasoning/tool parsers and its matching multimodal chat template; remove Nemotron-specific parser assumptions and do not pass `--language-model-only`. [M]

The recipe [R] supplies model-serving conventions, but the retrieved page does **not** publish an A40 PP=3 deployment. Its GPU examples and FP8 recommendations cannot be treated as validation of this topology. The three-node launch here is adapted from your baseline [B] and checked against the pinned vLLM source [P].

### PP=3: explicit, model-specific split

The inspected checkpoint configuration has 30 text decoder layers, with 16 attention heads, 8 local KV heads, 2 global KV heads and no shared-KV tail layers. Use PP=3/TP=1; do not replace it with TP=3, which does not divide those head counts. The explicit 10/10/10 split covers decoder indices 0–9, 10–19 and 20–29. The vision encoder has its own layers and is not part of that total. Equal decoder counts do not guarantee equal VRAM usage or processing time. [C, P]

`VLLM_PP_LAYER_PARTITION` is provided to **all three ranks**. KServe's `pipeline: 3` drives `--pipeline-parallel-size=3` and `--nnodes=3`; LWS assigns rank 0/1/2. No expert parallelism, Ray cluster, speculative decoder or additional replica is configured.

### A40 FP8 compatibility gate

A40 is Ampere SM86 and has no native FP8 Tensor Core arithmetic. vLLM documents FP8 weight-only execution with 16-bit activations through Marlin on Ampere [Q]. The v0.27.1 compressed-tensors source includes a W8A16 fallback for linear layers; the MoE selector also includes Marlin. That establishes a candidate path, **not a guarantee that this Gemma checkpoint and all its operators work**. Full checkpoint startup and both text/image requests are mandatory. [K]

Let vLLM read `quant_method: compressed-tensors` from the checkpoint. Do not force `--quantization=fp8`, edit its quantization metadata, or claim native W8A8 acceleration on A40. `--dtype=bfloat16` controls nonquantized computation; it does not undo the stored weight quantization. Retain automatic kernel selection initially and capture the selected kernels in logs.

No CPU weight offload or external KV-cache connector is enabled initially. Establish a functional baseline before adding offload. Three A40s offer substantial aggregate memory but PP does not pool it into one address space; one stage can still run out of VRAM. The 48Gi RAM allowance per pod is inherited conservatively, not a measured Gemma minimum.

### Infrastructure assumptions

Reuse the functioning GPU/Network Operators, KServe/LWS, Connectivity Link/GatewayClass, ODF, registry and inference SCC. Confirm three physical A40s are available without changing the sharing policy. The new subnet is only a secondary pod network on the existing Layer-2 bond; it is not VLAN 103, does not create `bond1.103`, and does not isolate traffic by itself. Check for overlap with node, DHCP, routed, Pod, Service and IPAM networks first.

```bash
mkdir -p ~/gemma-deployment
cd ~/gemma-deployment
oc whoami
oc get nodes -L nvidia.com/gpu.product
oc get gatewayclass openshift-default
oc get storageclass ocs-storagecluster-ceph-rbd
oc get subscriptions -n redhat-ods-operator
```

Keep manifests under your own version control, excluding tokens and credential JSON. This runbook uses namespace-owned objects and a stable explicit runtime reference, but shared controller/preset changes still require regression testing after OpenShift AI upgrades.

## 2. Namespace and runtime preflight

```bash
oc create namespace gemma --dry-run=client -o yaml | oc apply -f -
oc label namespace gemma opendatahub.io/dashboard=true --overwrite
```

Do not reinstall cluster-scoped GPU/Network Operators, alter their device-sharing settings, or apply a replacement DataScienceCluster. Existing shared resources serve both namespaces.

### 2.1 GPU-visible feature probe (must be run)

This checks A40 CUDA/BF16, Gemma model classes, both parsers, and multi-node launch flags. It deliberately does not download weights and cannot prove FP8/MoE or vision kernels work. Use one free GPU and save as `01-runtime-check.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gemma-runtime-check
  namespace: gemma
spec:
  restartPolicy: Never
  containers:
  - name: check
    image: docker.io/vllm/vllm-openai@sha256:c2f3b1b964e47809b722b5e75b61b1e7b39a50f70388cf2bf2418f16a9f31da2
    command:
    - /bin/bash
    - -c
    args:
    - |
      set -euo pipefail
      nvidia-smi
      python3 -u - <<'PY'
      from importlib.metadata import version
      import subprocess
      import torch

      print("vLLM:", version("vllm"), flush=True)
      print("PyTorch:", torch.__version__, flush=True)
      print("PyTorch CUDA:", torch.version.cuda, flush=True)
      assert torch.cuda.is_available(), "CUDA unavailable"
      print("GPU:", torch.cuda.get_device_name(0), flush=True)
      print("Compute capability:", torch.cuda.get_device_capability(0), flush=True)
      x = torch.ones((128, 128), device="cuda", dtype=torch.bfloat16)
      y = x @ x
      torch.cuda.synchronize()
      assert torch.all(y == 128).item(), "Unexpected BF16 result"
      print("PASS: CUDA BF16 matrix multiplication", flush=True)

      result = subprocess.run(
          ["vllm", "serve", "--help=all"],
          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
      )
      if result.returncode:
          print(result.stdout, flush=True)
          raise SystemExit(result.returncode)

      from vllm.reasoning import ReasoningParserManager
      print("Registered reasoning parsers:", ReasoningParserManager.list_registered(), flush=True)
      parser = ReasoningParserManager.get_reasoning_parser("gemma4")
      print("PASS: gemma4 loads:", parser, flush=True)

      from vllm.tool_parsers import ToolParserManager
      print("Tool parser:", ToolParserManager.get_tool_parser("gemma4"), flush=True)

      missing = []
      for value in ["--nnodes", "--node-rank", "--master-addr", "--pipeline-parallel-size", "--no-async-scheduling"]:
          present = value in result.stdout
          print(f"{'PASS' if present else 'FAIL'}: {value}", flush=True)
          if not present:
              missing.append(value)

      from vllm.model_executor.models import ModelRegistry
      from vllm.model_executor.models.gemma4_mm import Gemma4ForConditionalGeneration
      from vllm.model_executor.models.gemma4 import Gemma4ForCausalLM
      registered = "Gemma4ForConditionalGeneration" in ModelRegistry.get_supported_archs()
      classes = [c.__name__ for c in Gemma4ForConditionalGeneration.__mro__]
      print("Architecture registered:", registered, flush=True)
      print("Class hierarchy:", classes, flush=True)
      assert not missing, f"Missing runtime options/parsers: {missing}"
      assert registered, "Gemma4 architecture not registered"
      assert "SupportsPP" in classes, "Pipeline interface missing"
      assert "SupportsPP" in [c.__name__ for c in Gemma4ForCausalLM.__mro__]
      print("FEATURE PROBE PASSED", flush=True)
      print("Checkpoint loading, FP8/MoE kernels, images and three-node inference remain untested.")
      PY
    env:
    - name: HOME
      value: /tmp
    - name: XDG_CACHE_HOME
      value: /tmp/.cache
    - name: HF_HOME
      value: /tmp/huggingface
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
        nvidia.com/gpu: '1'
      limits:
        cpu: '2'
        memory: 8Gi
        nvidia.com/gpu: '1'
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault
    workingDir: /tmp
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-A40
    kubernetes.io/arch: amd64
  automountServiceAccountToken: false
```

A Pod's resource changes require recreation. Delete only the failed test Pod, then apply the manifest:

```bash
oc delete pod gemma-runtime-check -n gemma --ignore-not-found
oc apply -f 01-runtime-check.yaml
oc logs -f pod/gemma-runtime-check -n gemma --pod-running-timeout=15m
oc get pod gemma-runtime-check -n gemma \
  -o jsonpath='{.status.phase}{"\n"}'
```

Expected phase: `Succeeded`. If the log command races startup, rerun it. Inspect failure details with `oc logs pod/gemma-runtime-check -n gemma` and `oc describe pod gemma-runtime-check -n gemma`. A Pending Pod may be waiting for a free GPU. If CUDA detection still fails with a GPU assigned, investigate device injection and image/runtime initialization; do not bypass the check by forcing a CPU device type.

**Do not proceed if the feature probe fails.** A pass establishes only basic runtime readiness. Keep this image pinned for the full model test, and change the probe and both runtime containers together if a replacement is needed. Do not install packages into running serving pods.

```bash
oc delete pod gemma-runtime-check -n gemma --ignore-not-found
```

The completed probe must be removed before requesting all three GPUs.

## 3. Create the 172.16.103.0/24 attachment

`MacvlanNetwork` is cluster-scoped in the captured installation. Its new name must therefore be unique across namespaces. `networkNamespace` tells the Network Operator where to generate the NAD.

Save as `02-rdma-gemma.yaml`:

```yaml
apiVersion: mellanox.com/v1alpha1
kind: MacvlanNetwork
metadata:
  name: rdma-gemma
spec:
  master: bond1
  mode: bridge
  mtu: 9000
  networkNamespace: gemma
  ipam: |-
    {
      "type": "whereabouts",
      "range": "172.16.103.0/24",
      "exclude": [
        "172.16.103.0/30",
        "172.16.103.255/32"
      ]
    }
```

```bash
oc apply -f 02-rdma-gemma.yaml
oc get macvlannetwork rdma-gemma -o yaml
oc get network-attachment-definitions.k8s.cni.cncf.io rdma-gemma -n gemma -o yaml
```

If the NAD is not present immediately, rerun the final command after operator reconciliation. Do not create a competing manual NAD. Verify its CNI JSON:

```bash
oc get network-attachment-definitions.k8s.cni.cncf.io rdma-gemma -n gemma \
  -o jsonpath='{.spec.config}' | jq .
```

Expected: master `bond1`, MTU 9000, Whereabouts range `172.16.103.0/24`. Existing physical interfaces and bond1 remain MTU 9100 on the shared host network. No host IP address in this subnet is required for pod-to-pod macvlan traffic.

## 4. Validate secondary-network connectivity

Create three temporary CPU-only pods, one per A40 node. They request a shared RDMA device but no GPU, so an existing GPU workload can remain running during this network check. The image is the pinned upstream runtime image, reused here for Python connectivity checks. Optional RDMA utilities may not be installed in this image.

```bash
for node in ocp113 ocp114 ocp115; do
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gemma-net-${node}
  namespace: gemma
  labels:
    app: gemma-netcheck
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"rdma-gemma","namespace":"gemma","interface":"net1"}]'
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${node}.localdomain
  containers:
  - name: check
    image: docker.io/vllm/vllm-openai@sha256:c2f3b1b964e47809b722b5e75b61b1e7b39a50f70388cf2bf2418f16a9f31da2
    command: ["python3", "-m", "http.server", "18080", "--bind", "0.0.0.0", "--directory", "/tmp"]
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
        rdma/rdma_shared_device_dx_bond: '1'
      limits:
        cpu: '1'
        memory: 1Gi
        rdma/rdma_shared_device_dx_bond: '1'
    securityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
      seccompProfile:
        type: RuntimeDefault
EOF
done

oc wait pod -n gemma -l app=gemma-netcheck \
  --for=condition=Ready --timeout=300s

oc get pods -n gemma -l app=gemma-netcheck -o json |
jq -r '.items[] | .metadata.name as $pod |
  (.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] | fromjson)[] |
  select(.interface == "net1") | [$pod, (.ips | join(","))] | @tsv'
```

Save the following as `check-gemma-network.py` on your workstation and run `python3 check-gemma-network.py`. It checks all six cross-node directions using the allocated 172.16.103 addresses, not default Pod addresses:

```python
import ipaddress
import json
import subprocess

pods = json.loads(subprocess.check_output([
    "oc", "get", "pods", "-n", "gemma", "-l", "app=gemma-netcheck", "-o", "json"
]))["items"]
addresses = {}
for pod in pods:
    networks = json.loads(pod["metadata"]["annotations"][
        "k8s.v1.cni.cncf.io/network-status"])
    address = next(n["ips"][0] for n in networks if n.get("interface") == "net1")
    assert ipaddress.ip_address(address) in ipaddress.ip_network("172.16.103.0/24")
    addresses[pod["metadata"]["name"]] = address
assert len(addresses) == 3, addresses
for source in addresses:
    for destination, address in addresses.items():
        if source == destination:
            continue
        code = (
            "import urllib.request; "
            "opener=urllib.request.build_opener(urllib.request.ProxyHandler({})); "
            f"print(opener.open('http://{address}:18080', timeout=10).status)"
        )
        subprocess.run(["oc", "exec", "-n", "gemma", source, "--", "python3", "-c", code], check=True)
        print(source, "->", destination, address, "OK")
```

Inspect device exposure and network MTU where tools are available:

```bash
for node in ocp113 ocp114 ocp115; do
  oc exec -n gemma "gemma-net-${node}" -- bash -lc \
    'ls /dev/infiniband; cat /sys/class/net/net1/mtu; if command -v ibv_devinfo >/dev/null; then ibv_devinfo; fi; if command -v show_gids >/dev/null; then show_gids; fi'
done
```

TCP success is not proof of jumbo-frame forwarding or RoCE. Preserve the existing switch MTU configuration and verify NCCL's actual transport during model startup. In particular, the NIC must expose usable RoCE GIDs associated with the new subnet if the NCCL range restriction below is to succeed.

After the checks pass:

```bash
oc delete pod -n gemma -l app=gemma-netcheck
```

## 5. Import and store the new ModelCar

Use OpenShift AI **Register and store** to create a new registered model/version and use `gemma` as the destination project. Use a new registration and repository; do not copy IDs from another model.

| Field | Value |
|---|---|
| Model name | `Gemma 4 26B A4B FP8` |
| Model type | Generative AI model (Example, LLM) |
| Version name | `1` |
| Model transfer job name | **gemma4-26b-a4b-fp8-import** |
| Project | **gemma** |
| URI | `hf://RedHatAI/gemma-4-26B-A4B-it-FP8-dynamic` |
| Destination registry | `image-registry.openshift-image-registry.svc:5000` |
| Destination image URI | `image-registry.openshift-image-registry.svc:5000/gemma/gemma4-26b-a4b-fp8:v1` |
| Username | `model-registry-uploader` |
| Password | The service-account token generated in section 5.2 |
| Serving URI | `oci://image-registry.openshift-image-registry.svc:5000/gemma/gemma4-26b-a4b-fp8:v1` |

The destination UI URI includes the full registry hostname. Use `oci://` only in the model serving URI. Generate the upload credential below before submitting the import.

### 5.0 Optional: authenticate the Hugging Face download

The warning `You are sending unauthenticated requests to the HF Hub` concerns the **source download**, not the destination OpenShift registry login. Public downloads may continue without authentication; a valid HF token enables authenticated requests and the account's applicable rate limits. It does not guarantee a particular download speed. [7]

**Create the token on Hugging Face:** sign in at [Settings → Access Tokens](https://huggingface.co/settings/tokens), create a token named `openshift-gemma-import`, and select **Read** access for downloads. If your organization requires fine-grained tokens, grant read access appropriate to the target repository instead. No write permission is needed. For gated repositories, the HF account must also have accepted the model terms and received access. Copy the `hf_...` token. OpenShift stores this existing credential; it does not generate an HF token. [7]

**Store it in gemma:** run the following Bash block. Paste the HF token at the hidden prompt, then press Enter. This avoids putting the token in shell history or `oc` command-line arguments.

```bash
(
  set +x
  set -euo pipefail
  umask 077
  hf_secret_dir=$(mktemp -d)
  trap 'rm -rf "$hf_secret_dir"' EXIT

  read -r -s -p 'Paste Hugging Face read token: ' gemma_hf_token
  printf '\n'
  case "$gemma_hf_token" in
    hf_*) ;;
    *) printf '%s\n' 'Expected an hf_ token; no Secret was changed.' >&2; exit 1 ;;
  esac
  printf '%s' "$gemma_hf_token" > "$hf_secret_dir/HF_TOKEN"
  unset gemma_hf_token

  oc create secret generic huggingface-token -n gemma \
    --from-file=HF_TOKEN="$hf_secret_dir/HF_TOKEN" \
    --dry-run=client -o yaml | oc apply -f -
)

# Print the Secret name and key names only, never the token.
oc get secret huggingface-token -n gemma -o json |
jq '{name: .metadata.name, keys: (.data | keys)}'
```

Expected key: `HF_TOKEN`. Rerunning the block replaces the stored token. Keep this Secret separate from the destination registry upload credential in section 5.2 and the image-pull credential in section 6.

**Connect the token to the downloader:** a Secret is not automatically injected into pods. The transfer job's downloading container must receive `HF_TOKEN` before its process starts. For an import Job manifest you manage, include this entry under that container's `env` list, preserving its other environment settings:

```yaml
# Fragment for spec.template.spec.containers[the downloading container].env
- name: HF_TOKEN
  valueFrom:
    secretKeyRef:
      name: huggingface-token
      key: HF_TOKEN
```

The Secret and Job must be in the same namespace. This runbook uses `gemma`; if the actual transfer runs elsewhere, create its HF Secret in that namespace. `HF_TOKEN` is recognized by the Hugging Face client. Do not set `HF_HUB_DISABLE_IMPLICIT_TOKEN=1` when relying on implicit token use. [7]

For **Register and store**, use its **source** token/connection field if one is offered. If it accepts a token directly, paste the HF website token there; if it offers an existing source connection, configure that connection according to its required fields. A plain generic Secret is not necessarily listed as a dashboard Connection. The previously observed username/password fields for the **destination OCI registry** still use `model-registry-uploader` and its OpenShift token, never the HF token.

The upstream async-upload template also has a `SOURCE_CONNECTION` parameter that mounts source credentials. That mounted-credential mechanism is distinct from the `HF_TOKEN` environment reference above; its Secret key/file format must match the installed importer. Do not assume selecting an arbitrary Secret exports its keys as environment variables. The installed dashboard's source-token wiring has not yet been captured for this deployment. [8]

**Inspect the existing job without printing credential values:**

```bash
oc get jobs -n gemma

# Set this to the exact NAME shown above, including any generated suffix.
GEMMA_IMPORT_JOB='gemma4-26b-a4b-fp8-import'

oc get job "$GEMMA_IMPORT_JOB" -n gemma -o json |
jq '{
  name: .metadata.name,
  namespace: .metadata.namespace,
  containers: [
    ((.spec.template.spec.initContainers // []) +
     (.spec.template.spec.containers // []))[] |
    {
      name,
      env: [(.env // [])[] | {name, valueFrom}],
      envFrom,
      volumeMounts
    }
  ],
  secretVolumes: [(.spec.template.spec.volumes // [])[] |
    select(.secret != null) | {name, secret}]
}'
```

Look for an `HF_TOKEN` reference to `huggingface-token`/`HF_TOKEN`, or the importer's configured source-credential mount. The command intentionally omits literal environment values. A reference proves configuration, not token validity; confirm the next transfer authenticates successfully in its logs without printing the token.

Do not delete an active transfer merely to remove this warning. Creating the Secret now will not change the environment of an already-running process. A Job's pod template is normally immutable; attach credentials when preparing a new transfer or using the dashboard's retry flow. If the UI has no source-authentication option, capture the redacted job details above before deciding how to wire a retry, rather than cloning a job with stale model-registration metadata.

For rotation, issue a replacement on HF, rerun the Secret creation block, and ensure the next transfer uses it. Revoke the old token on the HF website after active users have finished. Deleting an OpenShift Secret does not revoke the token at Hugging Face. An inference workload serving the completed OCI ModelCar does not need this source-download token just to pull that image.

### 5.1 Create an upload identity in gemma

Run from `~/gemma-deployment` using an OpenShift login authorized to create service accounts, ImageStreams, and RoleBindings in `gemma`, and to grant `system:image-builder`. This role permits image pushes within this project. The account below is independent of the inference puller and does not receive cluster-wide push access. [6]

```bash
oc create serviceaccount model-registry-uploader -n gemma \
  --dry-run=client -o yaml | oc apply -f -

oc create rolebinding model-registry-uploader -n gemma \
  --clusterrole=system:image-builder \
  --serviceaccount=gemma:model-registry-uploader \
  --dry-run=client -o yaml | oc apply -f -

oc create imagestream gemma4-26b-a4b-fp8 -n gemma \
  --dry-run=client -o yaml | oc apply -f -

oc auth can-i update imagestreams.image.openshift.io \
  --subresource=layers -n gemma \
  --as=system:serviceaccount:gemma:model-registry-uploader
```

Expected authorization result: `yes`. The `--as` check requires impersonation permission; if that is denied, have a cluster administrator run the check. It does not mean the uploader's permission is necessarily missing. Creating the ImageStream prepares the repository metadata; it does not upload the checkpoint.

### 5.2 Generate the destination registry credential file

Create a short-lived service-account token and package it as a Docker authentication JSON file for the UI. These commands require `oc` and `jq`. The token is passed through a pipe, not printed or embedded in command-line arguments. The requested lifetime is 24 hours; the API server can adjust it. Generate the credential shortly before import, and ensure its actual expiry covers the download and push.

```bash
(
  set -euo pipefail
  umask 077

  upload_auth_tmp=$(mktemp ./gemma-upload-auth.XXXXXX)
  trap 'rm -f "$upload_auth_tmp"' EXIT

  oc create token model-registry-uploader -n gemma --duration=24h |
  jq -Rse \
    --arg registry 'image-registry.openshift-image-registry.svc:5000' \
    --arg username 'model-registry-uploader' '
      gsub("[\\r\\n]"; "") as $password |
      if ($password | length) == 0 then error("Empty upload token")
      else {
        auths: {
          ($registry): {
            username: $username,
            password: $password,
            auth: (($username + ":" + $password) | @base64)
          }
        }
      } end
    ' > "$upload_auth_tmp"

  mv "$upload_auth_tmp" gemma-registry-upload-auth.json
)
```

The registry login username deliberately has no colons; the service-account token determines the authenticated identity. Do not use the colon-containing Kubernetes service-account identity as the registry Basic-auth username. [6]

Optionally display only the token's expiry (not the credential):

```bash
python3 - <<'PY'
import base64
import json
from datetime import datetime, timezone
from pathlib import Path
config = json.loads(Path("gemma-registry-upload-auth.json").read_text())
entry = config["auths"]["image-registry.openshift-image-registry.svc:5000"]
payload = entry["password"].split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
print("Upload token expires:", datetime.fromtimestamp(claims["exp"], timezone.utc).isoformat())
PY
```

This decodes the expiry for inspection; it does not verify the token's signature. If the token expires before completion, rerun the generation block and supply the refreshed file when retrying the import. An already-created transfer job does not automatically receive the new local file.

### 5.3 Supply credentials in Register and store

1. Open the OpenShift AI model registration flow and choose **Register and store** for the Gemma source above.
2. Set the destination image URI to `image-registry.openshift-image-registry.svc:5000/gemma/gemma4-26b-a4b-fp8:v1`.
3. In the **destination OCI registry credentials** fields, enter Username `model-registry-uploader` and use the service-account token as Password, as described below. If another form offers credential-file upload instead, use `gemma-registry-upload-auth.json`. A Hugging Face source token is a separate credential.
4. Submit the import and monitor its transfer status. The import job runs inside the cluster and uses the internal registry hostname; your browser does not need direct access to that hostname.

The password is **not your OpenShift login password**. Retrieve it from the credential file generated in section 5.2:

```bash
jq -r '.auths["image-registry.openshift-image-registry.svc:5000"].password' \
  ~/gemma-deployment/gemma-registry-upload-auth.json
```

Copy the output into the UI’s **Password** field. This displays the credential locally; do not paste it into chat or include it in shared logs.

If you have not generated that file, after completing section 5.1 you can generate a token directly:

```bash
oc create token model-registry-uploader -n gemma --duration=24h
```

Use the output as the Password with Username `model-registry-uploader`. This command prints a fresh token; it does not create or update the JSON credential file. Keep the uploader RoleBinding in place until the transfer finishes.

If using credential-file upload and the browser runs on a different computer from `rhel9dummy2`, copy the file to that computer first using your SSH file-transfer client. For example, run this on the browser computer:

```bash
scp dave@rhel9dummy2:~/gemma-deployment/gemma-registry-upload-auth.json .
```

Treat this JSON as a password. It is a credential file for the UI, not a Kubernetes YAML manifest, and should not be committed to source control. The long-lived inference pull credential is created separately in section 6.

### 5.4 Verify completion and retire upload access


Record the exact Hugging Face revision selected for import and the resulting image digest. The full checkpoint, config, tokenizer, chat-template and vision processor assets must be present; retain preprocessor/processor configuration files from the snapshot. Do not select a similarly named NVFP4 or draft checkpoint. Review available registry storage before importing another new multimodal checkpoint (measure its actual imported size); the original 500Gi registry PVC is shared by both models and other images.

```bash
oc get pvc odf-image-registry-pvc -n openshift-image-registry
oc exec -n openshift-image-registry deployment/image-registry -- df -h /registry
oc get jobs,pods -n gemma
```

Wait for the UI transfer/import job to finish, then verify the ImageStream tag:

```bash
oc get istag gemma4-26b-a4b-fp8:v1 -n gemma \
  -o jsonpath='{.image.dockerImageReference}{"\n"}'
```

If your transfer workflow does not create an ImageStreamTag, verify the destination through its completed import output and registry tooling instead; do not interpret absence of metadata as proof the blobs exist. Stop before starting inference if the import failed. The manifest below uses `:v1` as an initial import tag; replace it with the confirmed `@sha256:...` digest for an immutable rebuild.

After the transfer succeeds and the image/tag is verified, remove the upload permission and your local upload file. These commands preserve the imported image and do not affect section 6's puller:

```bash
oc delete rolebinding model-registry-uploader -n gemma --ignore-not-found
rm -f gemma-registry-upload-auth.json
```

Remove any copy on the browser computer too. Keep the service account for later imports; repeat sections 5.1–5.2 to restore its binding and issue a fresh token. Do not remove upload access while a transfer or retry is still active.

## 6. Create independent persistent pull credentials

Save as `03-gemma-puller.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: model-registry-puller
  namespace: gemma
---
apiVersion: v1
kind: Secret
metadata:
  name: model-registry-puller-token
  namespace: gemma
  annotations:
    kubernetes.io/service-account.name: model-registry-puller
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: model-registry-puller
  namespace: gemma
subjects:
  - kind: ServiceAccount
    name: model-registry-puller
    namespace: gemma
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:image-puller
```

```bash
oc apply -f 03-gemma-puller.yaml

oc wait secret/model-registry-puller-token \
  -n gemma --for=jsonpath='{.data.token}' --timeout=60s
```

Generate the auth file and create/update the pull secret. No token is printed:

```bash
(
  set -euo pipefail
  umask 077

  oc get secret model-registry-puller-token -n gemma -o json |
  jq -e \
    --arg registry "image-registry.openshift-image-registry.svc:5000" \
    --arg username "model-registry-puller" '
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

  oc create secret generic gemma4-26b-a4b-fp8 \
    -n gemma --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=internal-registry-auth-serviceaccount.json \
    --dry-run=client -o yaml |
  oc apply -f -
)
```

The Secret also serves as an OpenShift AI **OCI connection**, because section 9 references it through `opendatahub.io/connections`. A plain image-pull Secret is insufficient for that admission check. Add the protocol annotation and registry/project URL required by the connections API [9]. This patch preserves `.dockerconfigjson` and its credentials:

```bash
oc patch secret gemma4-26b-a4b-fp8 -n gemma --type=merge -p '{
  "metadata": {
    "annotations": {
      "opendatahub.io/connection-type-protocol": "oci"
    }
  },
  "stringData": {
    "OCI_HOST": "https://image-registry.openshift-image-registry.svc:5000/gemma"
  }
}'

# Verify connection metadata without printing the registry token.
oc get secret gemma4-26b-a4b-fp8 -n gemma -o json |
jq '{name: .metadata.name,
     type,
     protocol: .metadata.annotations["opendatahub.io/connection-type-protocol"],
     ociHost: (.data.OCI_HOST | @base64d),
     keys: (.data | keys)}'
```

Expected: type `kubernetes.io/dockerconfigjson`, protocol `oci`, and keys `.dockerconfigjson` and `OCI_HOST`. `OCI_HOST` identifies the registry/project; section 9's `spec.model.uri` still supplies the full image repository and tag or digest.

If section 9 was already rejected with `must have a ... connection-type-protocol annotation`, run this patch and then reapply `05-gemma-three-a40.yaml`. The following `NotFound` is a consequence of admission rejecting creation, not a separate missing-model-image error. Do not recreate the Secret or repeat the model import for this metadata error.

Treat the generated JSON as a pull credential. It may be supplied to a UI field that asks for inference image-pull credentials, but it cannot authorize a model upload. Use section 5’s `gemma-registry-upload-auth.json` for destination push credentials. The application/API query credential is separate from registry credentials.

Verify authorization using the **subresource flag**:

```bash
oc auth can-i get imagestreams.image.openshift.io \
  --subresource=layers -n gemma \
  --as=system:serviceaccount:gemma:model-registry-puller
```

Expected: `yes`. The earlier command `oc auth can-i get imagestreams/layers` was wrong because the slash was interpreted as resource/name.

Section 7 creates a dedicated `gemma-inference` service account for the serving pods. Their explicit `imagePullSecrets` references use credentials belonging to `model-registry-puller`; setting their `serviceAccountName` to that account is not required.


## 7. Create the Gemma-owned pipeline runtime

Create a dedicated service account and namespace-local binding to the **operator-provided** inference SCC. This authorizes only that account in `gemma`; it does not reuse another project's grants or change the cluster SCC.

Save as `03-gemma-inference-account.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gemma-inference
  namespace: gemma
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gemma-inference-scc
  namespace: gemma
subjects:
- kind: ServiceAccount
  name: gemma-inference
  namespace: gemma
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openshift-ai-llminferenceservice-scc
```

```bash
oc get clusterrole openshift-ai-llminferenceservice-scc
oc apply -f 03-gemma-inference-account.yaml
```

Save as `03-gemma-runtime.yaml`. This is an explicit, namespace-local `LLMInferenceServiceConfig` named `gemma4-pipeline-v1`, referenced by the service's `baseRefs`. It does not overwrite an operator-owned release-prefixed preset. Shared defaults may still be merged by KServe; after reconciliation, inspect the applied configs **and actual pod commands/images** before considering the deployment correct. [5]

First obtain a version-matched Gemma template on the workstation, verify its checksum, and create a ConfigMap. For offline operation, transfer this exact file from an Internet-connected workstation before running the `oc create` command. The template is mounted on every rank, so the deployment does not rely on an image-relative `examples/` path.

```bash
curl --fail --location \
  https://raw.githubusercontent.com/vllm-project/vllm/v0.27.1/examples/tool_chat_template_gemma4.jinja \
  -o tool_chat_template_gemma4.jinja
printf '%s  %s\n' \
  afdbb2abe3667ccde95cc2f86919f05370339399bab5f750950a4390523b8927 \
  tool_chat_template_gemma4.jinja | sha256sum --check
oc create configmap gemma4-chat-template -n gemma \
  --from-file=tool_chat_template_gemma4.jinja \
  --dry-run=client -o yaml | oc apply -f -
```

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: gemma4-pipeline-v1
  namespace: gemma
  labels:
    app.kubernetes.io/part-of: gemma
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
      image: docker.io/vllm/vllm-openai@sha256:c2f3b1b964e47809b722b5e75b61b1e7b39a50f70388cf2bf2418f16a9f31da2
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
        failureThreshold: 180
        httpGet:
          path: /health
          port: 8000
          scheme: '{{ if .GlobalConfig.EnableTLS }}HTTPS{{else}}HTTP{{- end }}'
        periodSeconds: 10
      terminationMessagePath: /dev/termination-log
      terminationMessagePolicy: FallbackToLogsOnError
      volumeMounts:
      - mountPath: /etc/gemma
        name: gemma-chat-template
        readOnly: true
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
    - name: gemma-chat-template
      configMap:
        name: gemma4-chat-template
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
    serviceAccountName: gemma-inference
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
      image: docker.io/vllm/vllm-openai@sha256:c2f3b1b964e47809b722b5e75b61b1e7b39a50f70388cf2bf2418f16a9f31da2
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
      - mountPath: /etc/gemma
        name: gemma-chat-template
        readOnly: true
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
    - name: gemma-chat-template
      configMap:
        name: gemma4-chat-template
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
    serviceAccountName: gemma-inference
```

```bash
oc apply --dry-run=server -f 03-gemma-runtime.yaml
oc apply -f 03-gemma-runtime.yaml
oc get llminferenceserviceconfig \
  gemma4-pipeline-v1 -n gemma
```

The full leader/worker commands, probes, volumes, and runtime image are owned here. If changing the runtime image after a failed compatibility gate, change both containers and section 2's probe to the same tested digest. Keep the operator-provided scheduler and routing presets shared.

The leader and worker use the same **candidate** upstream digest as the feature probe. A successful Nemotron launch with this image is not Gemma validation.

```bash
oc get llminferenceserviceconfig \
  gemma4-pipeline-v1 -n gemma -o json |
jq '{leader: .spec.template.containers[0].image,
     worker: .spec.worker.containers[0].image}'
```

After startup, `status.appliedConfigs` must include `gemma4-pipeline-v1` from `gemma`. Also verify actual main-container images, launch commands, arguments, template mounts and service accounts on all three pods. Stop if any differs from the intended configuration; inspect merge behavior and the installed controller before adjusting only Gemma-owned manifests. Repeat after upgrades.

## 8. Create the namespace-local gateway

Save as `04-gemma-gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    networking.istio.io/service-type: ClusterIP
  labels:
    istio.io/rev: openshift-gateway
  name: gemma-inference
  namespace: gemma
spec:
  gatewayClassName: openshift-default
  listeners:
  - allowedRoutes:
      namespaces:
        from: Same
    name: http
    port: 80
    protocol: HTTP
```

```bash
oc apply -f 04-gemma-gateway.yaml
oc wait gateway.gateway.networking.k8s.io/gemma-inference \
  -n gemma --for=condition=Programmed --timeout=180s
oc get svc gemma-inference-openshift-default -n gemma
```

Keep `networking.istio.io/service-type: ClusterIP`; this keeps the gateway internal, with external access supplied by the Route. Leave the generated proxy Service and Deployment under the Gateway controller's ownership. Same-namespace routing is intentional.

## 9. Create the Gemma service, initially stopped

Save as `05-gemma-three-a40.yaml`. `serving.kserve.io/stop: "true"` is deliberate: preparation can finish while another model is running. Reapplying this file later will stop Gemma again; update your working copy when you intentionally change desired state.

Start with eager execution and synchronous scheduling to reduce startup variables. Prefix caching is disabled for the first functional test; it can be benchmarked later. Keep the same settings on leader and workers. The explicit decoder partition and one-image cap apply to all ranks. No speculative decoder or external cache connector is configured.

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: gemma4-26b-a4b-fp8-pp3
  namespace: gemma
  labels:
    opendatahub.io/dashboard: 'true'
    opendatahub.io/genai-asset: 'true'
  annotations:
    openshift.io/display-name: Gemma 4 26B A4B FP8 - Three A40s
    opendatahub.io/model-type: generative
    opendatahub.io/connections: gemma4-26b-a4b-fp8
    security.opendatahub.io/enable-auth: 'false'
    serving.kserve.io/stop: 'true'
spec:
  baseRefs:
  - name: gemma4-pipeline-v1
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"rdma-gemma","namespace":"gemma","interface":"net1"}]'
  model:
    name: gemma4-26b-a4b-fp8-pp3
    uri: oci://image-registry.openshift-image-registry.svc:5000/gemma/gemma4-26b-a4b-fp8:v1
  parallelism:
    pipeline: 3
    tensor: 1
  replicas: 1
  router:
    gateway:
      refs:
      - name: gemma-inference
        namespace: gemma
    route: {}
    scheduler: {}
  template:
    containers:
    - env:
      - name: VLLM_ADDITIONAL_ARGS
        value: >-
          --dtype=bfloat16 --max-model-len=32768 --max-num-seqs=2
          --gpu-memory-utilization=0.90 --kv-cache-dtype=auto
          --enforce-eager --no-async-scheduling --no-enable-prefix-caching
          --reasoning-parser=gemma4 --enable-auto-tool-choice --tool-call-parser=gemma4
          --chat-template=/etc/gemma/tool_chat_template_gemma4.jinja
          --limit-mm-per-prompt.image=1 --limit-mm-per-prompt.audio=0
          --limit-mm-per-prompt.video=0
      - name: VLLM_PP_LAYER_PARTITION
        value: '10,10,10'
      - name: OMP_NUM_THREADS
        value: '6'
      - name: NCCL_DEBUG
        value: INFO
      - name: NCCL_DEBUG_SUBSYS
        value: INIT,NET
      - name: NCCL_IB_DISABLE
        value: '0'
      - name: NCCL_SOCKET_IFNAME
        value: =net1
      - name: NCCL_IB_ADDR_FAMILY
        value: AF_INET
      - name: NCCL_IB_ADDR_RANGE
        value: 172.16.103.0/24
      name: main
      resources:
        limits:
          cpu: '6'
          memory: 48Gi
          nvidia.com/gpu: '1'
          rdma/rdma_shared_device_dx_bond: '1'
        requests:
          cpu: '6'
          memory: 48Gi
          nvidia.com/gpu: '1'
          rdma/rdma_shared_device_dx_bond: '1'
    imagePullSecrets:
    - name: gemma4-26b-a4b-fp8
    nodeSelector:
      nvidia.com/gpu.product: NVIDIA-A40
  worker:
    containers:
    - env:
      - name: VLLM_ADDITIONAL_ARGS
        value: >-
          --dtype=bfloat16 --max-model-len=32768 --max-num-seqs=2
          --gpu-memory-utilization=0.90 --kv-cache-dtype=auto
          --enforce-eager --no-async-scheduling --no-enable-prefix-caching
          --reasoning-parser=gemma4 --enable-auto-tool-choice --tool-call-parser=gemma4
          --chat-template=/etc/gemma/tool_chat_template_gemma4.jinja
          --limit-mm-per-prompt.image=1 --limit-mm-per-prompt.audio=0
          --limit-mm-per-prompt.video=0
      - name: VLLM_PP_LAYER_PARTITION
        value: '10,10,10'
      - name: OMP_NUM_THREADS
        value: '6'
      - name: NCCL_DEBUG
        value: INFO
      - name: NCCL_DEBUG_SUBSYS
        value: INIT,NET
      - name: NCCL_IB_DISABLE
        value: '0'
      - name: NCCL_SOCKET_IFNAME
        value: =net1
      - name: NCCL_IB_ADDR_FAMILY
        value: AF_INET
      - name: NCCL_IB_ADDR_RANGE
        value: 172.16.103.0/24
      name: main
      resources:
        limits:
          cpu: '6'
          memory: 48Gi
          nvidia.com/gpu: '1'
          rdma/rdma_shared_device_dx_bond: '1'
        requests:
          cpu: '6'
          memory: 48Gi
          nvidia.com/gpu: '1'
          rdma/rdma_shared_device_dx_bond: '1'
    imagePullSecrets:
    - name: gemma4-26b-a4b-fp8
    nodeSelector:
      nvidia.com/gpu.product: NVIDIA-A40
```

```bash
oc apply --dry-run=server -f 05-gemma-three-a40.yaml
oc apply -f 05-gemma-three-a40.yaml
oc get llminferenceservice gemma4-26b-a4b-fp8-pp3 -n gemma
```

Do not add `data`, `dataLocal`, or `dataRPCPort`, and do not put duplicate TP/PP launch options in `VLLM_ADDITIONAL_ARGS`. Keep both leader and worker resource/credential settings. The start annotation may prevent readiness while stopped; that is expected.

The NCCL settings explicitly select `net1` for socket interface selection and `172.16.103.0/24` for dynamic RoCE GID selection. `NCCL_IB_ADDR_RANGE` requires NCCL 2.21+ and an unset fixed GID index [3]. It does not create GIDs or guarantee RDMA. If no matching GID exists, fix the device/network exposure rather than silently claiming traffic used the new subnet. The LWS master address still uses Kubernetes discovery; not every control-plane connection moves to the secondary subnet.

## 10. Check GPU availability and start Gemma

Run after import, preflight, and network preparation succeed. All three A40s must be available. If another workload owns them, stop that workload using its own runbook; no particular other model or namespace needs to exist. Delete the completed preflight pod before proceeding.

Independently inspect GPU-consuming pods across namespaces. This avoids relying only on a label selector that might differ between controller versions:

```bash
oc get pods -A -o json |
jq -r '.items[] |
  select(.status.phase != "Succeeded" and .status.phase != "Failed") |
  select(any(.spec.containers[]?;
    ((.resources.limits["nvidia.com/gpu"] // "0") | tonumber) > 0)) |
  [.metadata.namespace, .metadata.name, .status.phase, (.spec.nodeName // "")] | @tsv'
```

If GPU pods from another workload remain on the three A40 nodes (including Terminating pods), wait. Review Pending GPU pods too, since they may compete when capacity becomes available. Node allocatable GPU capacity does not decrease when GPUs are allocated; do not use that field as a free-GPU counter. Resolve other GPU consumers before proceeding.

Start Gemma:

```bash
oc annotate llminferenceservice gemma4-26b-a4b-fp8-pp3 \
  -n gemma serving.kserve.io/stop=false --overwrite

oc get pods -n gemma -o wide
oc wait llminferenceservice/gemma4-26b-a4b-fp8-pp3 \
  -n gemma --for=condition=Ready --timeout=1800s
```

If the wait fails, collect section 15 diagnostics. Do not automatically restart the workload repeatedly or change the shared GPU policy.

## 11. Verify serving, network selection, and inference

```bash
oc get llminferenceservice gemma4-26b-a4b-fp8-pp3 -n gemma -o json |
jq '{generation: .metadata.generation,
     observedGeneration: .status.observedGeneration,
     appliedConfigs: .status.appliedConfigs,
     conditions: .status.conditions,
     url: .status.url}'

oc get pods -n gemma -o wide
```

Expect one leader plus two workers, each on an A40 node, one GPU per pod. Inspect the entire group:

```bash
oc get pods -n gemma -o json |
jq -r '.items[] |
  select(.metadata.name | startswith("gemma4-26b-a4b-fp8-pp3-kserve-mn-")) |
  [.metadata.name,
   .spec.nodeName,
   .metadata.annotations["openshift.io/scc"],
   .metadata.annotations["k8s.v1.cni.cncf.io/network-status"]] | @tsv'

for pod in $(oc get pods -n gemma -o json |
  jq -r '.items[] | select(.metadata.name | startswith("gemma4-26b-a4b-fp8-pp3-kserve-mn-")) | .metadata.name'); do
  oc logs -n gemma "$pod" -c main --tail=1000 > "${pod}.log"
  grep -Ei 'NCCL|NET/IB|NET/Socket|GID|172\.16\.103|error|traceback' "${pod}.log" || true
done
```

Every group pod needs `net1` in 172.16.103.0/24 and the expected RDMA allocation. `NET/IB` initialization/channel logs are needed to establish RoCE use; a successful API call or socket bootstrap line alone is not proof. For stronger proof, correlate the selected GID/interface with `show_gids` and NIC counters under a test request. If NCCL uses sockets for data transfer, document it as TCP fallback and investigate before calling RoCE validated.

Run an internal API test from the leader (no extra client image needed):

```bash
oc exec -i -n gemma gemma4-26b-a4b-fp8-pp3-kserve-mn-0 -c main -- python3 - <<'PYTEST'
import json
import urllib.request
base = "http://gemma-inference-openshift-default.gemma.svc.cluster.local/gemma/gemma4-26b-a4b-fp8-pp3/v1"
with urllib.request.urlopen(base + "/models", timeout=30) as response:
    print(json.dumps(json.load(response), indent=2))
payload = {
    "model": "gemma4-26b-a4b-fp8-pp3",
    "messages": [{"role": "user", "content": "Explain RoCE in two sentences."}],
    "max_tokens": 256,
    "temperature": 0.7,
    "top_p": 0.95,
    "stream": False,
    "chat_template_kwargs": {"enable_thinking": False},
}
request = urllib.request.Request(base + "/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json", "Authorization": "Bearer fake"})
with urllib.request.urlopen(request, timeout=180) as response:
    print(json.dumps(json.load(response), indent=2))
PYTEST
```

If generated pod names differ, substitute the leader name shown by `oc get pods`. Success requires a real complete answer, not only readiness. Add multi-turn, concurrent, and longer-context tests after the short request works. This runbook does not claim a throughput rate or a validated maximum context length.

### 11.1 Verify effective settings and checkpoint metadata

Check the generated workload rather than relying only on the desired CR:

```bash
oc get pods -n gemma -o json |
jq '.items[] | select(.metadata.name | startswith("gemma4-26b-a4b-fp8-pp3-kserve-mn-")) |
  {name: .metadata.name, node: .spec.nodeName,
   account: .spec.serviceAccountName,
   main: [.spec.containers[] | select(.name == "main") |
     {image, command, args, env, resources, volumeMounts}]}'

oc exec -i -n gemma gemma4-26b-a4b-fp8-pp3-kserve-mn-0 -c main -- python3 - <<'PY'
import json
from pathlib import Path
c = json.loads(Path('/mnt/models/config.json').read_text())
t = c['text_config']
print('Architecture:', c['architectures'])
print('Decoder layers:', t['num_hidden_layers'])
print('Quantization:', c['quantization_config']['quant_method'])
print('Template mounted:', Path('/etc/gemma/tool_chat_template_gemma4.jinja').is_file())
assert t['num_hidden_layers'] == 30, 'Recalculate the PP split for this revision'
assert c['quantization_config']['quant_method'] == 'compressed-tensors'
PY
```

Inspect all-rank logs for PP=3, TP=1, successful checkpoint loading, selected quantization/attention backends, and successful KV-cache allocation. Confirm the partition environment exists on all ranks. An import or feature probe alone is not this test. Record whether Marlin or another supported fallback was actually selected. Do not label the run native FP8 merely because the checkpoint is named FP8.

### 11.2 Image test without Internet access

This creates a small PNG with red on the left and blue on the right using Python's standard library, sends it as a data URL, and asks for the colors. It avoids image-server/network dependencies and confirms a genuine image request through the same gateway used by WebUI.

```bash
oc exec -i -n gemma gemma4-26b-a4b-fp8-pp3-kserve-mn-0 -c main -- python3 - <<'PY'
import base64, json, struct, urllib.request, zlib
def chunk(kind, data):
    return (struct.pack('!I', len(data)) + kind + data +
            struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff))
w = h = 256
row = b'\x00' + b'\xff\x00\x00' * (w // 2) + b'\x00\x00\xff' * (w // 2)
png = (b'\x89PNG\r\n\x1a\n' +
       chunk(b'IHDR', struct.pack('!2I5B', w, h, 8, 2, 0, 0, 0)) +
       chunk(b'IDAT', zlib.compress(row * h)) + chunk(b'IEND', b''))
uri = 'data:image/png;base64,' + base64.b64encode(png).decode()
payload = {
    'model': 'gemma4-26b-a4b-fp8-pp3',
    'messages': [{'role': 'user', 'content': [
        {'type': 'text', 'text': 'Name the color on the left and the color on the right.'},
        {'type': 'image_url', 'image_url': {'url': uri}},
    ]}],
    'max_tokens': 128, 'temperature': 0,
    'chat_template_kwargs': {'enable_thinking': False},
}
url = 'http://gemma-inference-openshift-default.gemma.svc.cluster.local/gemma/gemma4-26b-a4b-fp8-pp3/v1/chat/completions'
req = urllib.request.Request(url, data=json.dumps(payload).encode(),
    headers={'Content-Type': 'application/json'})
with urllib.request.urlopen(req, timeout=300) as r:
    response = json.load(r)
print(json.dumps(response, indent=2))
PY
```

Expected semantic result: **left red, right blue**. Then use a real photograph, screenshot or diagram representative of your workload. Correct answers, no kernel errors and acceptable memory usage are required before calling vision validated. This API produces text, not a generated image.

### 11.3 Tool-call parsing test (does not execute a tool)

```bash
oc exec -i -n gemma gemma4-26b-a4b-fp8-pp3-kserve-mn-0 -c main -- python3 - <<'PY'
import json, urllib.request
payload = {
    'model': 'gemma4-26b-a4b-fp8-pp3',
    'messages': [{'role': 'user', 'content':
        'Use the get_temperature tool to get the temperature in Boston, MA.'}],
    'tools': [{'type': 'function', 'function': {
        'name': 'get_temperature', 'description': 'Get the current temperature for a city.',
        'parameters': {'type': 'object', 'properties': {
            'city': {'type': 'string'}}, 'required': ['city']}}}],
    'tool_choice': 'auto', 'max_tokens': 512, 'temperature': 0,
    'chat_template_kwargs': {'enable_thinking': False},
}
url = 'http://gemma-inference-openshift-default.gemma.svc.cluster.local/gemma/gemma4-26b-a4b-fp8-pp3/v1/chat/completions'
req = urllib.request.Request(url, data=json.dumps(payload).encode(),
    headers={'Content-Type': 'application/json'})
with urllib.request.urlopen(req, timeout=300) as r:
    response = json.load(r)
print(json.dumps(response, indent=2))
calls = response['choices'][0]['message'].get('tool_calls') or []
assert calls, 'No structured tool call returned: inspect template/parser/model response'
assert calls[0]['function']['name'] == 'get_temperature'
print('Arguments:', json.loads(calls[0]['function']['arguments']))
PY
```

Check for a structured call with a Boston city argument, not raw special tokens in ordinary content. A tool-capable client must execute a real tool and submit its result as a subsequent message; this test only validates parsing. Test `enable_thinking: true` separately with a larger output budget and inspect the reasoning field supplied by this runtime.

### 11.4 Streaming and concurrent requests

If you skip the external Route, forward the gateway locally in another terminal:

```bash
oc port-forward -n gemma service/gemma-inference-openshift-default 18080:80
```

Then run:

```bash
curl --fail-with-body --no-buffer \
  http://127.0.0.1:18080/gemma/gemma4-26b-a4b-fp8-pp3/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4-26b-a4b-fp8-pp3","messages":[{"role":"user","content":"Count from one to five."}],"max_tokens":128,"stream":true,"chat_template_kwargs":{"enable_thinking":false}}'
```

Expect completed SSE output, including the stream terminator. Run two independent short prompts simultaneously from separate terminals or WebUI chats, using different facts in each conversation. Confirm each answer follows its own submitted history. Repeat with representative long inputs and one-image prompts while monitoring all ranks; two successful short requests do not validate two 32K requests.

## 12. Optional external model Route

Skip this section if Open WebUI and internal clients are sufficient. The WebUI connects internally and does not require this model Route.

Save as `06-gemma-route.yaml`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: gemma4-pp3
  namespace: gemma
  annotations:
    haproxy.router.openshift.io/timeout: 300s
spec:
  path: /gemma/gemma4-26b-a4b-fp8-pp3
  to:
    kind: Service
    name: gemma-inference-openshift-default
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
```

```bash
oc apply -f 06-gemma-route.yaml
GEMMA_HOST=$(oc get route gemma4-pp3 -n gemma -o jsonpath='{.spec.host}')
printf 'https://%s/gemma/gemma4-26b-a4b-fp8-pp3/v1
' "$GEMMA_HOST"

curl --fail-with-body -k -N \
  "https://${GEMMA_HOST}/gemma/gemma4-26b-a4b-fp8-pp3/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"gemma4-26b-a4b-fp8-pp3",
    "messages":[{"role":"user","content":"Say hello in one sentence."}],
    "max_tokens":128,
    "temperature":0.7,
    "top_p":0.95,
    "stream":true,
    "chat_template_kwargs":{"enable_thinking":false}
  }'
```

`-k` is only for the existing lab certificate; omit it when the router certificate is trusted. `security.opendatahub.io/enable-auth: false` means the model Route is unauthenticated. Open WebUI login does not protect direct calls to that model Route. Keep the exposure appropriate to your lab; adding model API authentication is a separate change.

## 13. Deploy a separate Open WebUI in gemma

This uses the WebUI digest reported as working under `restricted-v2` in the Nemotron baseline, with independent namespace-local resources. No GPU is requested. The new WebUI is a fresh application with new accounts and history.

Create its signing key once:

```bash
(
  set -euo pipefail
  umask 077
  secret_dir=$(mktemp -d)
  trap 'rm -rf "$secret_dir"' EXIT
  openssl rand -hex 32 | tr -d '\n' > "$secret_dir/WEBUI_SECRET_KEY"
  oc create secret generic open-webui-secrets -n gemma \
    --from-file=WEBUI_SECRET_KEY="$secret_dir/WEBUI_SECRET_KEY"
)
```

If the Secret already exists, retain it. Save as `07-gemma-open-webui.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: open-webui
  namespace: gemma
automountServiceAccountToken: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: open-webui-data
  namespace: gemma
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: ocs-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: gemma
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      serviceAccountName: open-webui
      automountServiceAccountToken: false
      nodeSelector:
        kubernetes.io/arch: amd64
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: open-webui
        image: ghcr.io/open-webui/open-webui@sha256:ef11a68f38457d831e23168486858c25b9d9c4399094c9e72c0d4d8767ac09de
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 8080
        env:
        - name: PORT
          value: '8080'
        - name: HOME
          value: /tmp
        - name: DATA_DIR
          value: /app/backend/data
        - name: WEBUI_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: open-webui-secrets
              key: WEBUI_SECRET_KEY
        - name: WEBUI_AUTH
          value: 'true'
        - name: DEFAULT_USER_ROLE
          value: pending
        - name: ENABLE_OLLAMA_API
          value: 'false'
        - name: ENABLE_OPENAI_API
          value: 'true'
        - name: OPENAI_API_BASE_URL
          value: http://gemma-inference-openshift-default.gemma.svc.cluster.local/gemma/gemma4-26b-a4b-fp8-pp3/v1
        - name: OPENAI_API_KEY
          value: fake
        - name: UVICORN_WORKERS
          value: '1'
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: '2'
            memory: 4Gi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: [ALL]
        startupProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 90
        readinessProbe:
          httpGet:
            path: /health/db
            port: http
          periodSeconds: 10
          timeoutSeconds: 5
        livenessProbe:
          httpGet:
            path: /health
            port: http
          periodSeconds: 30
          timeoutSeconds: 5
          failureThreshold: 3
        volumeMounts:
        - name: data
          mountPath: /app/backend/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: open-webui-data
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: gemma
spec:
  selector:
    app: open-webui
  ports:
  - name: http
    port: 8080
    targetPort: http
  type: ClusterIP
```

```bash
oc apply -f 07-gemma-open-webui.yaml
oc rollout status deployment/open-webui -n gemma --timeout=900s

oc create route edge open-webui -n gemma \
  --service=open-webui --port=http --insecure-policy=Redirect \
  --dry-run=client -o yaml | oc apply -f -
oc annotate route open-webui -n gemma \
  haproxy.router.openshift.io/timeout=300s --overwrite
oc get route open-webui -n gemma -o jsonpath='https://{.spec.host}{"\n"}'
```

On the same cluster domain, the expected assigned hostname is `open-webui-gemma.apps.ocp4.localdomain`; use the printed value as authoritative. Register the administrator account first, select `gemma4-26b-a4b-fp8-pp3`, and send a short prompt. Test a regular user account separately. A visible model-list alias is not another loaded model.

Enable **Vision** for this model in the WebUI model settings if the image attachment option is unavailable; custom served-model IDs may not be auto-detected. Upload one known image and confirm the answer uses its contents. If the direct image API test passes but WebUI fails, inspect the WebUI connection URL, model capabilities and request payload before changing vLLM.

The WebUI deployment does not force thinking off; the API tests above do. If tuning UI latency, configure the model's request parameters in the WebUI and verify the actual generated request. Keep `gemma4` as the reasoning parser.

Validate account/history persistence after a completed normal saved chat:

```bash
oc rollout restart deployment/open-webui -n gemma
oc rollout status deployment/open-webui -n gemma --timeout=300s
oc get pvc open-webui-data -n gemma
oc get pods -n gemma -l app=open-webui -o json |
jq '.items[] | {name: .metadata.name,
               serviceAccount: .spec.serviceAccountName,
               scc: .metadata.annotations["openshift.io/scc"]}'
```

Refresh the browser, verify history remains, and ask another question. Expected SCC is `restricted-v2`, based on the tested image; confirm rather than grant anyuid preemptively. Back up the data PVC and signing-key Secret. Keep replica/worker count at one for this SQLite deployment. RAG, SSO and actual tool execution are outside the initial scope. Image attachment is tested below; parsing a tool call does not execute it.

## 14. Optional Gen AI Playground

The standalone WebUI above completes the requested browser interface; an OGX copy is not required to serve it. If you also want the OpenShift AI Playground in `gemma`, use the dashboard to provision its project-specific OGX resources after the model is Ready. Do not copy another project’s ConfigMap wholesale: its model, database host, Secrets and owner references are namespace-specific, and the captured OGX local stores are ephemeral.

Verify its vLLM provider uses exactly:

```text
http://gemma-inference-openshift-default.gemma.svc.cluster.local/gemma/gemma4-26b-a4b-fp8-pp3/v1
```

The provider model ID must be `gemma4-26b-a4b-fp8-pp3`. A UI-generated endpoint pointing at the old shared gateway can produce a 404. This optional Playground setup needs its own live configuration capture before it can be called validated.

## 15. Stop or restart Gemma and troubleshoot

Stop Gemma first:

```bash
oc annotate llminferenceservice gemma4-26b-a4b-fp8-pp3 \
  -n gemma serving.kserve.io/stop=true --overwrite
oc wait pods -n gemma \
  -l leaderworkerset.sigs.k8s.io/name=gemma4-26b-a4b-fp8-pp3-kserve-mn \
  --for=delete --timeout=600s
```

Repeat the all-namespace GPU-pod inventory from section 10 and confirm Gemma's GPU pods have disappeared. The GPUs are then available for another workload, managed by its own instructions.

To restart Gemma, confirm all three A40s are available and repeat section 10. Do not delete namespaces, PVCs, model images, or puller token Secrets to stop or start the model. An idle gateway/WebUI uses CPU/RAM, not GPU. Requests to a stopped backend fail until it starts again.

Diagnostic commands:

```bash
oc get llminferenceservice gemma4-26b-a4b-fp8-pp3 -n gemma -o yaml
oc get pods -n gemma -o wide
oc get events -n gemma --sort-by=.metadata.creationTimestamp | tail -50
oc get gateway gemma-inference -n gemma -o yaml
oc get httproute,inferencepool -n gemma
oc logs -n gemma gemma4-26b-a4b-fp8-pp3-kserve-mn-0 -c main --tail=300
```

| Symptom | Next action |
|---|---|
| Unsupported architecture/parser/argument | Stop; compare the preflight and packaged runtime with the checkpoint requirements. Resolve a compatible runtime by updating the gemma-owned preset and probe together |
| FP8/MoE/vision kernel unsupported / illegal instruction | Preserve complete stack trace, GPU architecture and runtime version; model registry recognition alone is insufficient |
| PP or mixed-attention cache assertion | Investigate model/runtime PP support. Do not assume TP=3 is a valid substitute; model dimensions must support the chosen topology |
| GPU pods Pending | Check competing model pods, 48Gi/6 CPU availability, A40 labels and admission events |
| ImagePullBackOff on ModelCar | Verify gemma import completed, full registry path, puller RBAC and gemma Secret; use the Secret created in gemma |
| Worker downloads fail / storage exhausted | Inspect node ephemeral storage and registry capacity; each ModelCar consumer needs local image layers |
| CUDA OOM | Inspect failing stage; lower context/concurrency, keep speculative decoding off, and confirm checkpoint precision |
| No matching GID / socket fallback | Check net1 addresses, GIDs and device visibility; 172.16.103 CIDR allocation alone does not establish RoCE |
| Gateway not ready | Confirm ClusterIP annotation and Gateway conditions |
| API 404 | Verify namespace/model path and served model ID; keep `/v1` on the client base URL |
| WebUI works but direct Route remains open | Expected: WebUI accounts and model API authentication are separate |
| Model answers but slowly | Measure time to first token and output tokens/second at representative prompt lengths and concurrency; inspect per-stage memory and kernel warnings before tuning |
| Prompt exceeds context | Keep input plus requested output within 32,768 tokens; reduce history or start a new chat |

### 15.1 Optional dashboard hardware profile

A hardware profile is a reusable dashboard resource preset; the explicit resource requests in this runbook already control scheduling. Creating a profile does not automatically associate it with the existing service or improve inference speed.

In the OpenShift AI dashboard, open **Settings → Environment setup → Hardware profiles → Create hardware profile**. Create a dedicated profile with these per-pod values:

| Field | Value |
|---|---|
| Name | Gemma A40 |
| CPU default | 6 cores |
| Memory default | 48Gi |
| Accelerator resource | `nvidia.com/gpu` |
| Accelerator default | 1 |
| Node selector | `nvidia.com/gpu.product: NVIDIA-A40` |

If the form requires minimum/maximum values, choose ranges that include those defaults. The deployment uses three pods with one GPU each; do not request three GPUs per pod. Preserve the manifest’s RDMA resource request, network annotations and pipeline topology. Dashboard association with an existing custom LLMInferenceService is version-dependent and has not been verified here; keep the explicit manifest as the configuration source.

### 15.2 Context, concurrency and memory tuning

32,768 tokens covers system instructions, history, image tokens, tools, reasoning and the final answer together. Reserving 4,096 output tokens leaves at most 28,672 input tokens. Two sequences means up to two active requests; histories remain request-specific. It does not guarantee two maximum-length requests fit, and Open WebUI must send the appropriate conversation history for each request.

Change both `VLLM_ADDITIONAL_ARGS` lists in `05-gemma-three-a40.yaml`. If reapplying to a running service, set its stop annotation to `"false"` intentionally; the original file has `"true"`. Use server-side dry-run, then apply and repeat the API/image tests. Do not edit generated LWS or pod resources.

Tune one variable at a time:

1. Establish text plus one-image success at the initial limits.
2. If VRAM is tight, lower context to 16,384 and sequences to 1; inspect the failing stage and image profiling memory.
3. If stable, test prefix caching or remove `--enforce-eager` separately; record memory and latency changes. Re-test image and tool requests after each change.
4. Raise the image cap to 2 or 4 only after profiling representative images. Avoid copying Hopper-oriented async/FP8-KV settings without checking the pinned runtime and A40 backend.
5. Raise context to 65,536 only with measured memory headroom and long-request tests. The recipe advertises 128K while the inspected config permits 262,144 positions; neither is evidence that your deployment can serve those lengths. The explicit 32K limit is intentional.

### 15.3 Offloading is optional, not part of the initial deployment

The requested FP8 checkpoint is already weight-compressed. Start without weight offload. If a stage runs out of VRAM **because of model weights**, a later experiment can add `--cpu-offload-gb=4` to both argument lists after confirming that option in the pinned runtime's help. This is a per-GPU CPU-memory allowance, not a storage cache, unified GPU memory pool or promise that every Gemma MoE tensor can be offloaded. Budget additional host RAM and expect CPU/GPU transfer costs. Test compatibility and speed before retaining it.

External KV caching/offload requires a separately compatible connector and configuration. Do not copy a Nemotron/Mamba cache setup into this mixed local/global-attention model. Cache reuse does not automatically free all active-request KV memory; a PVC or fast NVMe device alone does not make vLLM use it. Retain the no-offload baseline for rollback.

### 15.4 Upgrade resilience and rollback

The local config, explicit reference, pinned runtime digest and pinned model digest improve reproducibility. They do **not** freeze KServe's schema, scheduler, routing defaults or merge behavior. Automatic OpenShift AI upgrades can still affect this service.

Before an upgrade, save the Gemma service, local runtime config, gateway and template ConfigMap (excluding credential Secrets) and record the actual running image IDs:

```bash
mkdir -p upgrade-capture
oc get llminferenceservice gemma4-26b-a4b-fp8-pp3 -n gemma -o yaml \
  > upgrade-capture/service.yaml
oc get llminferenceserviceconfig gemma4-pipeline-v1 -n gemma -o yaml \
  > upgrade-capture/runtime.yaml
oc get gateway gemma-inference -n gemma -o yaml > upgrade-capture/gateway.yaml
oc get configmap gemma4-chat-template -n gemma -o yaml > upgrade-capture/template.yaml
oc get pods -n gemma -o json > upgrade-capture/pods.json
oc get subscriptions -A -o wide > upgrade-capture/subscriptions.txt
```

After an upgrade, run a server dry-run of the desired manifests, inspect applied configs and actual pod settings, then repeat text, image, tools, streaming and stop/start checks. Confirm that GPUs are released on stop. Keep manual approval of the OpenShift AI Subscription as an optional maintenance-policy decision; do not change the cluster's subscription automatically in this runbook. Restoring a model manifest is not an operator downgrade. Use clean desired-state manifests rather than blindly reapplying status-bearing captures.

## 16. Validation record and sources

This document was statically checked; the cluster deployment remains untested. Fill this record as you execute it:

| Check | Result to record |
|---|---|
| Source checkpoint | Exact HF commit and imported OCI digest |
| Runtime | Image digest, vLLM, PyTorch, CUDA, NVIDIA driver |
| Feature probe | Succeeded on A40; both parsers load |
| Full model load | Actual quantization kernels, no unsupported operator errors |
| Topology | Three ranks on distinct A40 nodes, PP3/TP1, 10/10/10 |
| Memory | Per-stage weight/cache usage, host RSS and image profiling peak |
| Network | Every net1 address, bidirectional checks, all-rank NCCL transport |
| Serving | Ready plus correct text, image and tool responses |
| Stream | Completed SSE response and finish reason |
| Concurrency | Two independent requests; then representative long histories |
| WebUI | Vision enabled, image answer, separate accounts/history, PVC persistence |
| Lifecycle | Stop/start succeeds and releases all three GPUs |
| Upgrade | Applied config and generated workload remain correct after reconciliation |

Source links were reviewed October 22, 2026. Upstream source inspection is evidence of implementation, not a support certification or live performance result.

[B] [Original Nemotron Three A40 Runbook](https://github.com/singlecheeze/ocp-cheat-sheet/blob/main/OpenShift%20AI/Nemotron%20Three%20A40%20Runbook/Nemotron%20Three%20A40%20Runbook.md) — user-supplied cluster layout and operational baseline.

[M] [Requested RedHatAI model card](https://huggingface.co/RedHatAI/gemma-4-26B-A4B-it-FP8-dynamic) — model identity and quantization.

[R] [Requested vLLM recipe](https://recipes.vllm.ai/Google/gemma-4-26B-A4B-it) — parser, template and multimodal conventions; no published A40 PP3 validation in retrieved page.

[C] [Checkpoint configuration](https://huggingface.co/RedHatAI/gemma-4-26B-A4B-it-FP8-dynamic/blob/main/config.json) — inspect again at the exact imported revision.

[P] vLLM v0.27.1 [text implementation](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/model_executor/models/gemma4.py) and [multimodal implementation](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/model_executor/models/gemma4_mm.py).

[Q] [vLLM FP8 documentation](https://docs.vllm.ai/en/v0.27.1/features/quantization/fp8/) — Ampere uses weight-only fallback rather than native W8A8.

[K] vLLM v0.27.1 [compressed-tensors selection](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/model_executor/layers/quantization/compressed_tensors/compressed_tensors.py) and [FP8 MoE backend selection](https://github.com/vllm-project/vllm/blob/v0.27.1/vllm/model_executor/layers/fused_moe/oracle/fp8.py).

[T] [Version-matched Gemma chat template](https://github.com/vllm-project/vllm/blob/v0.27.1/examples/tool_chat_template_gemma4.jinja).

[3] [NCCL environment variables](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html) — socket interface and dynamic RoCE GID selection; verify the installed NCCL version.

[4] [Open WebUI Kubernetes deployment](https://docs.openwebui.com/deployment/kubernetes/) and [configuration](https://docs.openwebui.com/reference/env-configuration/) — persistent single-replica application and OpenAI-compatible connections.

[5] [KServe configuration merge implementation](https://github.com/kserve/kserve/blob/master/pkg/controller/v1alpha2/llmisvc/config_merge.go) — namespace-local preset lookup precedes system-namespace fallback; verify the installed controller’s applied configuration record.

[6] [OpenShift 4.22: Accessing the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/registry/accessing-the-registry) — project-scoped image-builder permissions and token-based registry login.

[7] Hugging Face: [User access tokens](https://huggingface.co/docs/hub/security-tokens) and [HF_TOKEN environment variable](https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables).

[8] [Model Registry Operator async-upload template](https://github.com/opendatahub-io/model-registry-operator/blob/main/config/jobs-async-upload/README.md) — upstream source-connection mechanism; inspect the installed template before using its credential format.

[9] [OpenShift AI 3.5: Use connections](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_on_projects/using-connections_projects) — OCI connection protocol annotation, Docker authentication Secret, and OCI_HOST field.

