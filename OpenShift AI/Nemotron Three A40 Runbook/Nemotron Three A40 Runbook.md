# Nemotron Three A40 Runbook

**New deployment in namespace `nemo` • updated October 20, 2026 • startup and short-response inference verified; long-context load testing pending**

This is a separate runbook for `RedHatAI/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16`. It leaves **Three A40 Runbook.md** unchanged. It assumes the same functioning OpenShift 4.22 / OpenShift AI 3.5 cluster, three A40 nodes, GPU/Network Operators, KServe, LeaderWorkerSet, Connectivity Link/GatewayClass, ODF, and internal registry services. All model-specific resources are created independently in `nemo`; Qwen does not need to be installed.

**Operating model:** run only one three-GPU model at a time. GPU availability is a shared hardware constraint, not a dependency on another model. If another workload owns the A40s, stop it using its own operating procedure and wait for its GPU pods to disappear. The commands here manage only Nemotron.

**Compatibility gate:** the standalone preflight passed on an A40 with the pinned upstream vLLM 0.27.1 image below. It verified CUDA BF16 matrix multiplication, loading the `nemotron_v3` reasoning parser, NemotronH registration and the pipeline-parallel interface. Subsequent captures show successful checkpoint loading and short-response inference. The October 20 leader log confirms PP=3, TP=1, BF16, a 65,536-token context, CUDA graph capture, and NCCL NET/IB using RoCE on net1 at 172.16.102.4. Full-length requests and concurrent long-context performance still require testing. This is an upstream runtime test within the existing OpenShift AI deployment, not a claim of Red Hat support for that image. Only Nemotron-owned manifests use it.

## Contents

1. Target layout and assumptions
2. Namespace and runtime preflight
3. Create the 172.16.102.0/24 attachment
4. Validate secondary-network connectivity
5. Import and store the new ModelCar
6. Create independent persistent pull credentials
7. Create the Nemotron-owned pipeline runtime
8. Create the namespace-local gateway
9. Create the Nemotron service, initially stopped
10. Check GPU availability and start Nemotron
11. Verify serving, network selection, and inference
12. Create the external model Route
13. Deploy a separate Open WebUI in nemo
14. Optional Gen AI Playground
15. Stop or restart Nemotron and troubleshoot
16. Validation record and sources

## 1. Target layout and assumptions

| Setting | New deployment |
|---|---|
| Namespace | `nemo` |
| Hugging Face source | `RedHatAI/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16` |
| LLMInferenceService / served model | `nemotron35-30b-bf16-pp3` |
| ImageStream / registry repository | `nemo/nemotron35-30b-bf16` |
| Initial image tag | `v1`; record/pin the imported digest afterward |
| Topology | One group, pipeline 3, tensor 1 |
| Nodes | `ocp113.localdomain`, `ocp114.localdomain`, `ocp115.localdomain` |
| Per leader/worker request and limit | 6 CPU, 48Gi RAM, 1 A40, 1 `rdma/rdma_shared_device_dx_bond` |
| Context / concurrent sequences | 65,536 tokens / 2 sequences; startup verified, full-length load testing pending |
| Secondary interface | `net1`, macvlan on existing `bond1`, MTU 9000 |
| MacvlanNetwork / generated NAD | `rdma-nemo` / `nemo/rdma-nemo` |
| Secondary subnet | `172.16.102.0/24`; addresses .0–.3 and .255 excluded |
| Gateway | `nemo-inference`, class `openshift-default`, ClusterIP backing Service |
| Model Route | `nemotron35-pp3` |
| Pull secret | `nemotron35-30b-bf16` |
| WebUI | `nemo/open-webui`, separate PVC and signing-key Secret |

The model card describes a 30B-total/3B-active BF16 Mamba-2/MoE/attention hybrid. The rough weight-only estimate is 30 billion × 2 bytes ≈ 60 GB (56 GiB), before runtime, recurrent state, KV cache, workspaces, and checkpoint-specific overhead. Three A40s provide 144GiB aggregate nominal VRAM, but memory is partitioned by pipeline stage, not pooled. A stage can run out of memory even when aggregate free memory appears sufficient. The 48Gi host-RAM limit per pod is a starting allowance for the larger BF16 checkpoint, not a measured minimum.

The source model recipe names `nemotron_v3` reasoning and `qwen3_coder` tool parsers, with temperature 1.0, top_p 0.95, and request-level `enable_thinking`. `qwen3_coder` is the parser name required by this model recipe; it does not require a Qwen deployment. No speculative decoder or draft-model download is configured here. [1]

Confirm 48Gi host RAM and 6 CPU per GPU pod can be scheduled alongside cluster services. The manifest specifies resources explicitly. An optional dashboard hardware profile is described in section 15.1.

The 172.16.102 addresses are **secondary pod addresses**. Kubernetes Service IPs, default Pod IPs, Routes, and Open WebUI do not move to this subnet. A namespace and a different IP subnet do not create an isolated VLAN. This design uses the existing shared Layer-2 bond network; it does not create `bond1.102` or change switch tagging. Verify that 172.16.102.0/24 is unused and not overlapping other routed, Pod, Service, DHCP, or IPAM ranges. If VLAN 102 is desired, stop here and design the host/switch VLAN path separately.

Run the commands from your existing Bash/oc workstation. Commands requiring Python or jq state so explicitly. Work in a new directory for the Nemotron manifests:

```bash
mkdir -p ~/nemo-deployment
cd ~/nemo-deployment
oc whoami
oc get nodes -L nvidia.com/gpu.product
oc get gatewayclass openshift-default
oc get storageclass ocs-storagecluster-ceph-rbd
```


### Resource ownership

| Shared cluster infrastructure | Nemotron-owned resources |
| --- | --- |
| GPU/Network Operators, device plugins, host bond1, physical A40 nodes | Runtime probe and three-rank inference workload in `nemo` |
| OpenShift AI/KServe/LWS controllers, inference SCC/ClusterRole, vendor routing/scheduler presets | Local pipeline runtime, inference service account and SCC RoleBinding |
| Registry service and authorized import workflow | Nemotron registration, OCI repository, puller account, RBAC and pull Secret |
| ODF storage class, GatewayClass and ingress controller | `rdma-nemo` network/NAD, `nemo-inference` gateway, model Route, WebUI, Secrets and PVC |

No Qwen pod, service, gateway, secret, model image, runtime object, or namespace is a prerequisite. The subnet remains `172.16.102.0/24`.

## 2. Namespace and runtime preflight

```bash
oc create namespace nemo --dry-run=client -o yaml | oc apply -f -
oc label namespace nemo opendatahub.io/dashboard=true --overwrite
```

Do not reinstall cluster-scoped GPU/Network Operators, alter their device-sharing settings, or apply a replacement DataScienceCluster. Existing shared resources serve both namespaces.

### 2.1 GPU-visible preflight: passed October 19, 2026 (EDT)

The successful log was captured October 20 at 01:56 UTC (October 19 at 21:56 EDT). It reports driver `580.126.20`, vLLM `0.27.1`, PyTorch `2.13.0+cu130`, CUDA `13.0`, and A40 compute capability `8.6`.

Two probe corrections matter: use `python3` (this image has no `python` command), and load `nemotron_v3` through `ReasoningParserManager` rather than searching CLI help. This parser was registered and loaded successfully despite being absent from help text. The earlier Red Hat 0.24.0+rhaiv.13 result tested help text only; it did not conclusively establish parser absence. The original CPU-only probe failed device initialization before compatibility checks ran.

Use the standalone `nemo` probe below. It does not exec into another model's pod or read another namespace's configuration. It needs one free A40; the full model later needs all three. Inspect GPU allocations with section 10's inventory before running the probe. If the A40s are occupied, stop the owning workload through its own procedure first. Keep Nemotron stopped until the probe has completed and been deleted.

Save this corrected version as `01-runtime-check.yaml`. It requests **one GPU**, selects A40 nodes, and runs a small BF16 computation plus feature inspection; no model weights are loaded:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nemotron-runtime-check
  namespace: nemo
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
      parser = ReasoningParserManager.get_reasoning_parser("nemotron_v3")
      print("PASS: nemotron_v3 loads:", parser, flush=True)

      missing = []
      for value in ["qwen3_coder", "--nnodes", "--node-rank", "--master-addr", "--pipeline-parallel-size"]:
          present = value in result.stdout
          print(f"{'PASS' if present else 'FAIL'}: {value}", flush=True)
          if not present:
              missing.append(value)

      from vllm.model_executor.models import ModelRegistry
      from vllm.model_executor.models.nemotron_h import NemotronHForCausalLM
      registered = "NemotronHForCausalLM" in ModelRegistry.get_supported_archs()
      classes = [c.__name__ for c in NemotronHForCausalLM.__mro__]
      print("Architecture registered:", registered, flush=True)
      print("Class hierarchy:", classes, flush=True)
      assert not missing, f"Missing runtime options/parsers: {missing}"
      assert registered, "NemotronH architecture not registered"
      assert "SupportsPP" in classes, "Pipeline interface missing"
      print("PREFLIGHT PASSED", flush=True)
      print("Checkpoint loading, Mamba kernels and three-node inference remain untested.")
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

A Pod's resource changes require recreation. Delete only the failed test Pod, then apply the corrected manifest:

```bash
oc delete pod nemotron-runtime-check -n nemo --ignore-not-found
oc apply -f 01-runtime-check.yaml
oc logs -f pod/nemotron-runtime-check -n nemo --pod-running-timeout=15m
oc get pod nemotron-runtime-check -n nemo \
  -o jsonpath='{.status.phase}{"\n"}'
```

Expected phase: `Succeeded`. If the log command races startup, rerun it. Inspect failure details with `oc logs pod/nemotron-runtime-check -n nemo` and `oc describe pod nemotron-runtime-check -n nemo`. A Pending Pod may be waiting for a free GPU. If CUDA detection still fails with a GPU assigned, investigate device injection and image/runtime initialization; do not bypass the check by forcing a CPU device type.

**Do not proceed on a missing model implementation, parser or launch flag.** Newer upstream NemotronH implements the pipeline-parallel interface [2], but that does not prove this packaged image supports the exact checkpoint. The passing preflight validates a small BF16 computation, not full-checkpoint loading, Mamba-specific kernels or distributed execution. If an updated runtime is required, resolve and test a model-scoped configuration separately; modify only the Nemotron-owned runtime and probe image together.

Clean up the test Pod:

```bash
oc delete pod nemotron-runtime-check -n nemo --ignore-not-found
```

Deleting the standalone probe releases the GPU before starting the three-rank model. Resume section 3; perform the GPU switchover only when all prerequisites are ready.

## 3. Create the 172.16.102.0/24 attachment

`MacvlanNetwork` is cluster-scoped in the captured installation. Its new name must therefore be unique across namespaces. `networkNamespace` tells the Network Operator where to generate the NAD.

Save as `02-rdma-nemo.yaml`:

```yaml
apiVersion: mellanox.com/v1alpha1
kind: MacvlanNetwork
metadata:
  name: rdma-nemo
spec:
  master: bond1
  mode: bridge
  mtu: 9000
  networkNamespace: nemo
  ipam: |-
    {
      "type": "whereabouts",
      "range": "172.16.102.0/24",
      "exclude": [
        "172.16.102.0/30",
        "172.16.102.255/32"
      ]
    }
```

```bash
oc apply -f 02-rdma-nemo.yaml
oc get macvlannetwork rdma-nemo -o yaml
oc get network-attachment-definitions.k8s.cni.cncf.io rdma-nemo -n nemo -o yaml
```

If the NAD is not present immediately, rerun the final command after operator reconciliation. Do not create a competing manual NAD. Verify its CNI JSON:

```bash
oc get network-attachment-definitions.k8s.cni.cncf.io rdma-nemo -n nemo \
  -o jsonpath='{.spec.config}' | jq .
```

Expected: master `bond1`, MTU 9000, Whereabouts range `172.16.102.0/24`. Existing physical interfaces and bond1 remain MTU 9100 on the shared host network. No host IP address in this subnet is required for pod-to-pod macvlan traffic.

## 4. Validate secondary-network connectivity

Create three temporary CPU-only pods, one per A40 node. They request a shared RDMA device but no GPU, so an existing GPU workload can remain running during this network check. The image is the pinned upstream runtime image, reused here for Python connectivity checks. Optional RDMA utilities may not be installed in this image.

```bash
for node in ocp113 ocp114 ocp115; do
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nemo-net-${node}
  namespace: nemo
  labels:
    app: nemo-netcheck
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"rdma-nemo","namespace":"nemo","interface":"net1"}]'
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

oc wait pod -n nemo -l app=nemo-netcheck \
  --for=condition=Ready --timeout=300s

oc get pods -n nemo -l app=nemo-netcheck -o json |
jq -r '.items[] | .metadata.name as $pod |
  (.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] | fromjson)[] |
  select(.interface == "net1") | [$pod, (.ips | join(","))] | @tsv'
```

Save the following as `check-nemo-network.py` on your workstation and run `python3 check-nemo-network.py`. It checks all six cross-node directions using the allocated 172.16.102 addresses, not default Pod addresses:

```python
import ipaddress
import json
import subprocess

pods = json.loads(subprocess.check_output([
    "oc", "get", "pods", "-n", "nemo", "-l", "app=nemo-netcheck", "-o", "json"
]))["items"]
addresses = {}
for pod in pods:
    networks = json.loads(pod["metadata"]["annotations"][
        "k8s.v1.cni.cncf.io/network-status"])
    address = next(n["ips"][0] for n in networks if n.get("interface") == "net1")
    assert ipaddress.ip_address(address) in ipaddress.ip_network("172.16.102.0/24")
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
        subprocess.run(["oc", "exec", "-n", "nemo", source, "--", "python3", "-c", code], check=True)
        print(source, "->", destination, address, "OK")
```

Inspect device exposure and network MTU where tools are available:

```bash
for node in ocp113 ocp114 ocp115; do
  oc exec -n nemo "nemo-net-${node}" -- bash -lc \
    'ls /dev/infiniband; cat /sys/class/net/net1/mtu; if command -v ibv_devinfo >/dev/null; then ibv_devinfo; fi; if command -v show_gids >/dev/null; then show_gids; fi'
done
```

TCP success is not proof of jumbo-frame forwarding or RoCE. Preserve the existing switch MTU configuration and verify NCCL's actual transport during model startup. In particular, the NIC must expose usable RoCE GIDs associated with the new subnet if the NCCL range restriction below is to succeed.

After the checks pass:

```bash
oc delete pod -n nemo -l app=nemo-netcheck
```

## 5. Import and store the new ModelCar

Use OpenShift AI **Register and store** to create a new registered model/version and use `nemo` as the destination project. Use a new registration and repository; do not copy IDs from another model.

| Field | Value |
|---|---|
| Model name | `Nemotron 3.5 Lightning BF16` |
| Model type | Generative AI model (Example, LLM) |
| Version name | `1` |
| Model transfer job name | **nemotron-35-lightning-bf16** |
| Project | **nemo** |
| URI | `hf://RedHatAI/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16` |
| Destination registry | `image-registry.openshift-image-registry.svc:5000` |
| Destination image URI | `image-registry.openshift-image-registry.svc:5000/nemo/nemotron35-30b-bf16:v1` |
| Username | `model-registry-uploader` |
| Password | The service-account token generated in section 5.2 |
| Serving URI | `oci://image-registry.openshift-image-registry.svc:5000/nemo/nemotron35-30b-bf16:v1` |

The destination UI URI includes the full registry hostname. Use `oci://` only in the model serving URI. Generate the upload credential below before submitting the import.

### 5.0 Optional: authenticate the Hugging Face download

The warning `You are sending unauthenticated requests to the HF Hub` concerns the **source download**, not the destination OpenShift registry login. Public downloads may continue without authentication; a valid HF token enables authenticated requests and the account's applicable rate limits. It does not guarantee a particular download speed. [7]

**Create the token on Hugging Face:** sign in at [Settings → Access Tokens](https://huggingface.co/settings/tokens), create a token named `openshift-nemo-import`, and select **Read** access for downloads. If your organization requires fine-grained tokens, grant read access appropriate to the target repository instead. No write permission is needed. For gated repositories, the HF account must also have accepted the model terms and received access. Copy the `hf_...` token. OpenShift stores this existing credential; it does not generate an HF token. [7]

**Store it in nemo:** run the following Bash block. Paste the HF token at the hidden prompt, then press Enter. This avoids putting the token in shell history or `oc` command-line arguments.

```bash
(
  set +x
  set -euo pipefail
  umask 077
  hf_secret_dir=$(mktemp -d)
  trap 'rm -rf "$hf_secret_dir"' EXIT

  read -r -s -p 'Paste Hugging Face read token: ' nemo_hf_token
  printf '\n'
  case "$nemo_hf_token" in
    hf_*) ;;
    *) printf '%s\n' 'Expected an hf_ token; no Secret was changed.' >&2; exit 1 ;;
  esac
  printf '%s' "$nemo_hf_token" > "$hf_secret_dir/HF_TOKEN"
  unset nemo_hf_token

  oc create secret generic huggingface-token -n nemo \
    --from-file=HF_TOKEN="$hf_secret_dir/HF_TOKEN" \
    --dry-run=client -o yaml | oc apply -f -
)

# Print the Secret name and key names only, never the token.
oc get secret huggingface-token -n nemo -o json |
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

The Secret and Job must be in the same namespace. This runbook uses `nemo`; if the actual transfer runs elsewhere, create its HF Secret in that namespace. `HF_TOKEN` is recognized by the Hugging Face client. Do not set `HF_HUB_DISABLE_IMPLICIT_TOKEN=1` when relying on implicit token use. [7]

For **Register and store**, use its **source** token/connection field if one is offered. If it accepts a token directly, paste the HF website token there; if it offers an existing source connection, configure that connection according to its required fields. A plain generic Secret is not necessarily listed as a dashboard Connection. The previously observed username/password fields for the **destination OCI registry** still use `model-registry-uploader` and its OpenShift token, never the HF token.

The upstream async-upload template also has a `SOURCE_CONNECTION` parameter that mounts source credentials. That mounted-credential mechanism is distinct from the `HF_TOKEN` environment reference above; its Secret key/file format must match the installed importer. Do not assume selecting an arbitrary Secret exports its keys as environment variables. The installed dashboard's source-token wiring has not yet been captured for this deployment. [8]

**Inspect the existing job without printing credential values:**

```bash
oc get jobs -n nemo

# Set this to the exact NAME shown above, including any generated suffix.
NEMO_IMPORT_JOB='nemotron-35-lightning-bf16'

oc get job "$NEMO_IMPORT_JOB" -n nemo -o json |
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

### 5.1 Create an upload identity in nemo

Run from `~/nemo-deployment` using an OpenShift login authorized to create service accounts, ImageStreams, and RoleBindings in `nemo`, and to grant `system:image-builder`. This role permits image pushes within this project. The account below is independent of the inference puller and does not receive cluster-wide push access. [6]

```bash
oc create serviceaccount model-registry-uploader -n nemo \
  --dry-run=client -o yaml | oc apply -f -

oc create rolebinding model-registry-uploader -n nemo \
  --clusterrole=system:image-builder \
  --serviceaccount=nemo:model-registry-uploader \
  --dry-run=client -o yaml | oc apply -f -

oc create imagestream nemotron35-30b-bf16 -n nemo \
  --dry-run=client -o yaml | oc apply -f -

oc auth can-i update imagestreams.image.openshift.io \
  --subresource=layers -n nemo \
  --as=system:serviceaccount:nemo:model-registry-uploader
```

Expected authorization result: `yes`. The `--as` check requires impersonation permission; if that is denied, have a cluster administrator run the check. It does not mean the uploader's permission is necessarily missing. Creating the ImageStream prepares the repository metadata; it does not upload the checkpoint.

### 5.2 Generate the destination registry credential file

Create a short-lived service-account token and package it as a Docker authentication JSON file for the UI. These commands require `oc` and `jq`. The token is passed through a pipe, not printed or embedded in command-line arguments. The requested lifetime is 24 hours; the API server can adjust it. Generate the credential shortly before import, and ensure its actual expiry covers the download and push.

```bash
(
  set -euo pipefail
  umask 077

  upload_auth_tmp=$(mktemp ./nemo-upload-auth.XXXXXX)
  trap 'rm -f "$upload_auth_tmp"' EXIT

  oc create token model-registry-uploader -n nemo --duration=24h |
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

  mv "$upload_auth_tmp" nemo-registry-upload-auth.json
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
config = json.loads(Path("nemo-registry-upload-auth.json").read_text())
entry = config["auths"]["image-registry.openshift-image-registry.svc:5000"]
payload = entry["password"].split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
print("Upload token expires:", datetime.fromtimestamp(claims["exp"], timezone.utc).isoformat())
PY
```

This decodes the expiry for inspection; it does not verify the token's signature. If the token expires before completion, rerun the generation block and supply the refreshed file when retrying the import. An already-created transfer job does not automatically receive the new local file.

### 5.3 Supply credentials in Register and store

1. Open the OpenShift AI model registration flow and choose **Register and store** for the Nemotron source above.
2. Set the destination image URI to `image-registry.openshift-image-registry.svc:5000/nemo/nemotron35-30b-bf16:v1`.
3. In the **destination OCI registry credentials** fields, enter Username `model-registry-uploader` and use the service-account token as Password, as described below. If another form offers credential-file upload instead, use `nemo-registry-upload-auth.json`. A Hugging Face source token is a separate credential.
4. Submit the import and monitor its transfer status. The import job runs inside the cluster and uses the internal registry hostname; your browser does not need direct access to that hostname.

The password is **not your OpenShift login password**. Retrieve it from the credential file generated in section 5.2:

```bash
jq -r '.auths["image-registry.openshift-image-registry.svc:5000"].password' \
  ~/nemo-deployment/nemo-registry-upload-auth.json
```

Copy the output into the UI’s **Password** field. This displays the credential locally; do not paste it into chat or include it in shared logs.

If you have not generated that file, after completing section 5.1 you can generate a token directly:

```bash
oc create token model-registry-uploader -n nemo --duration=24h
```

Use the output as the Password with Username `model-registry-uploader`. This command prints a fresh token; it does not create or update the JSON credential file. Keep the uploader RoleBinding in place until the transfer finishes.

If using credential-file upload and the browser runs on a different computer from `rhel9dummy2`, copy the file to that computer first using your SSH file-transfer client. For example, run this on the browser computer:

```bash
scp dave@rhel9dummy2:~/nemo-deployment/nemo-registry-upload-auth.json .
```

Treat this JSON as a password. It is a credential file for the UI, not a Kubernetes YAML manifest, and should not be committed to source control. The long-lived inference pull credential is created separately in section 6.

### 5.4 Verify completion and retire upload access


Record the exact Hugging Face revision selected for import and the resulting image digest. The full checkpoint, config, tokenizer, and chat-template assets must be present. Do not select a similarly named NVFP4 or draft checkpoint. Review available registry storage before importing another approximately 60GB-class artifact; the original 500Gi registry PVC is shared by both models and other images.

```bash
oc get pvc odf-image-registry-pvc -n openshift-image-registry
oc exec -n openshift-image-registry deployment/image-registry -- df -h /registry
oc get jobs,pods -n nemo
```

Wait for the UI transfer/import job to finish, then verify the ImageStream tag:

```bash
oc get istag nemotron35-30b-bf16:v1 -n nemo \
  -o jsonpath='{.image.dockerImageReference}{"\n"}'
```

If your transfer workflow does not create an ImageStreamTag, verify the destination through its completed import output and registry tooling instead; do not interpret absence of metadata as proof the blobs exist. Stop before starting inference if the import failed. The manifest below uses `:v1` as an initial import tag; replace it with the confirmed `@sha256:...` digest for an immutable rebuild.

After the transfer succeeds and the image/tag is verified, remove the upload permission and your local upload file. These commands preserve the imported image and do not affect section 6's puller:

```bash
oc delete rolebinding model-registry-uploader -n nemo --ignore-not-found
rm -f nemo-registry-upload-auth.json
```

Remove any copy on the browser computer too. Keep the service account for later imports; repeat sections 5.1–5.2 to restore its binding and issue a fresh token. Do not remove upload access while a transfer or retry is still active.

## 6. Create independent persistent pull credentials

Save as `03-nemo-puller.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: model-registry-puller
  namespace: nemo
---
apiVersion: v1
kind: Secret
metadata:
  name: model-registry-puller-token
  namespace: nemo
  annotations:
    kubernetes.io/service-account.name: model-registry-puller
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: model-registry-puller
  namespace: nemo
subjects:
  - kind: ServiceAccount
    name: model-registry-puller
    namespace: nemo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:image-puller
```

```bash
oc apply -f 03-nemo-puller.yaml

oc wait secret/model-registry-puller-token \
  -n nemo --for=jsonpath='{.data.token}' --timeout=60s
```

Generate the auth file and create/update the pull secret. No token is printed:

```bash
(
  set -euo pipefail
  umask 077

  oc get secret model-registry-puller-token -n nemo -o json |
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

  oc create secret generic nemotron35-30b-bf16 \
    -n nemo --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=internal-registry-auth-serviceaccount.json \
    --dry-run=client -o yaml |
  oc apply -f -
)
```

The Secret also serves as an OpenShift AI **OCI connection**, because section 9 references it through `opendatahub.io/connections`. A plain image-pull Secret is insufficient for that admission check. Add the protocol annotation and registry/project URL required by the connections API [9]. This patch preserves `.dockerconfigjson` and its credentials:

```bash
oc patch secret nemotron35-30b-bf16 -n nemo --type=merge -p '{
  "metadata": {
    "annotations": {
      "opendatahub.io/connection-type-protocol": "oci"
    }
  },
  "stringData": {
    "OCI_HOST": "https://image-registry.openshift-image-registry.svc:5000/nemo"
  }
}'

# Verify connection metadata without printing the registry token.
oc get secret nemotron35-30b-bf16 -n nemo -o json |
jq '{name: .metadata.name,
     type,
     protocol: .metadata.annotations["opendatahub.io/connection-type-protocol"],
     ociHost: (.data.OCI_HOST | @base64d),
     keys: (.data | keys)}'
```

Expected: type `kubernetes.io/dockerconfigjson`, protocol `oci`, and keys `.dockerconfigjson` and `OCI_HOST`. `OCI_HOST` identifies the registry/project; section 9's `spec.model.uri` still supplies the full image repository and tag or digest.

If section 9 was already rejected with `must have a ... connection-type-protocol annotation`, run this patch and then reapply `05-nemotron-three-a40.yaml`. The following `NotFound` is a consequence of admission rejecting creation, not a separate missing-model-image error. Do not recreate the Secret or repeat the model import for this metadata error.

Treat the generated JSON as a pull credential. It may be supplied to a UI field that asks for inference image-pull credentials, but it cannot authorize a model upload. Use section 5’s `nemo-registry-upload-auth.json` for destination push credentials. The application/API query credential is separate from registry credentials.

Verify authorization using the **subresource flag**:

```bash
oc auth can-i get imagestreams.image.openshift.io \
  --subresource=layers -n nemo \
  --as=system:serviceaccount:nemo:model-registry-puller
```

Expected: `yes`. The earlier command `oc auth can-i get imagestreams/layers` was wrong because the slash was interpreted as resource/name.

Section 7 creates a dedicated `nemotron-inference` service account for the serving pods. Their explicit `imagePullSecrets` references use credentials belonging to `model-registry-puller`; setting their `serviceAccountName` to that account is not required.


## 7. Create the Nemotron-owned pipeline runtime

Create a dedicated service account and namespace-local binding to the **operator-provided** inference SCC. This authorizes only that account in `nemo`; it does not reuse another project's grants or change the cluster SCC.

Save as `03-nemo-inference-account.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nemotron-inference
  namespace: nemo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nemotron-inference-scc
  namespace: nemo
subjects:
- kind: ServiceAccount
  name: nemotron-inference
  namespace: nemo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openshift-ai-llminferenceservice-scc
```

```bash
oc get clusterrole openshift-ai-llminferenceservice-scc
oc apply -f 03-nemo-inference-account.yaml
```

Save the complete standalone manifest below as `03-nemo-runtime.yaml`. No `oc get` or copy from an existing model is required. The release-prefixed name is intentional: KServe automatically selects a pipeline preset, searching the service namespace before its system namespace. This **separate object in `nemo`** supplies that preset locally, so removing another model or its custom system-namespace pipeline template does not remove Nemotron's template. Do not move this object into `redhat-ods-applications`. Explicit `baseRefs` below also names this local configuration. [5]

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: v3-5-1-kserve-config-llm-worker-pipeline-parallel
  namespace: nemo
  labels:
    app.kubernetes.io/part-of: nemotron
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
    serviceAccountName: nemotron-inference
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
    serviceAccountName: nemotron-inference
```

```bash
oc apply --dry-run=server -f 03-nemo-runtime.yaml
oc apply -f 03-nemo-runtime.yaml
oc get llminferenceserviceconfig \
  v3-5-1-kserve-config-llm-worker-pipeline-parallel -n nemo
```

The full leader/worker commands, probes, volumes, and runtime image are owned here. If changing the runtime image after a failed compatibility gate, change both containers and section 2's probe to the same tested digest. Keep the operator-provided scheduler and routing presets shared.

The leader and worker now use the same upstream digest that passed section 2. Re-save `03-nemo-runtime.yaml` from this revision before applying it; an older local file still contains the Red Hat image. Section 4's network pods and section 11's client command also use `python3`.

```bash
oc get llminferenceserviceconfig \
  v3-5-1-kserve-config-llm-worker-pipeline-parallel -n nemo -o json |
jq '{leader: .spec.template.containers[0].image,
     worker: .spec.worker.containers[0].image}'
```

After starting the service, check `status.appliedConfigs` in section 11: the pipeline entry must have namespace `nemo`. If it instead resolves to `redhat-ods-applications`, stop Nemotron and inspect the controller's selected config name/version; create the corresponding **local** preset before retrying. Do not treat a successful start using another project's custom preset as validation. Repeat this check after platform upgrades.

## 8. Create the namespace-local gateway

Save as `04-nemo-gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    networking.istio.io/service-type: ClusterIP
  labels:
    istio.io/rev: openshift-gateway
  name: nemo-inference
  namespace: nemo
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
oc apply -f 04-nemo-gateway.yaml
oc wait gateway.gateway.networking.k8s.io/nemo-inference \
  -n nemo --for=condition=Programmed --timeout=180s
oc get svc nemo-inference-openshift-default -n nemo
```

Keep `networking.istio.io/service-type: ClusterIP`; this keeps the gateway internal, with external access supplied by the Route. Leave the generated proxy Service and Deployment under the Gateway controller's ownership. Same-namespace routing is intentional.

## 9. Create the Nemotron service, initially stopped

Save as `05-nemotron-three-a40.yaml`. `serving.kserve.io/stop: "true"` is deliberate: preparation can finish while another model is running. Reapplying this file later will stop Nemotron again; update your working copy when you intentionally change desired state.

Use the pinned runtime’s default compilation and CUDA graph configuration. Keep prefix caching disabled, two concurrent sequences, and GPU memory utilization at 0.90. Apply the same arguments to the leader and workers. No speculative decoder is configured.

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: nemotron35-30b-bf16-pp3
  namespace: nemo
  labels:
    opendatahub.io/dashboard: 'true'
    opendatahub.io/genai-asset: 'true'
  annotations:
    openshift.io/display-name: Nemotron 3.5 Lightning BF16 - Three A40s
    opendatahub.io/model-type: generative
    opendatahub.io/connections: nemotron35-30b-bf16
    security.opendatahub.io/enable-auth: 'false'
    serving.kserve.io/stop: 'true'
spec:
  baseRefs:
  - name: v3-5-1-kserve-config-llm-worker-pipeline-parallel
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{"name":"rdma-nemo","namespace":"nemo","interface":"net1"}]'
  model:
    name: nemotron35-30b-bf16-pp3
    uri: oci://image-registry.openshift-image-registry.svc:5000/nemo/nemotron35-30b-bf16:v1
  parallelism:
    pipeline: 3
    tensor: 1
  replicas: 1
  router:
    gateway:
      refs:
      - name: nemo-inference
        namespace: nemo
    route: {}
    scheduler: {}
  template:
    containers:
    - env:
      - name: VLLM_ADDITIONAL_ARGS
        value: --dtype=bfloat16 --max-model-len=65536 --max-num-seqs=2 --gpu-memory-utilization=0.90
          --no-enable-prefix-caching --reasoning-parser=nemotron_v3 --enable-auto-tool-choice --tool-call-parser=qwen3_coder
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
        value: 172.16.102.0/24
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
    - name: nemotron35-30b-bf16
    nodeSelector:
      nvidia.com/gpu.product: NVIDIA-A40
  worker:
    containers:
    - env:
      - name: VLLM_ADDITIONAL_ARGS
        value: --dtype=bfloat16 --max-model-len=65536 --max-num-seqs=2 --gpu-memory-utilization=0.90
          --no-enable-prefix-caching --reasoning-parser=nemotron_v3 --enable-auto-tool-choice --tool-call-parser=qwen3_coder
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
        value: 172.16.102.0/24
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
    - name: nemotron35-30b-bf16
    nodeSelector:
      nvidia.com/gpu.product: NVIDIA-A40
```

```bash
oc apply --dry-run=server -f 05-nemotron-three-a40.yaml
oc apply -f 05-nemotron-three-a40.yaml
oc get llminferenceservice nemotron35-30b-bf16-pp3 -n nemo
```

Do not add `data`, `dataLocal`, or `dataRPCPort`, and do not put duplicate TP/PP launch options in `VLLM_ADDITIONAL_ARGS`. Keep both leader and worker resource/credential settings. The start annotation may prevent readiness while stopped; that is expected.

The NCCL settings explicitly select `net1` for socket interface selection and `172.16.102.0/24` for dynamic RoCE GID selection. `NCCL_IB_ADDR_RANGE` requires NCCL 2.21+ and an unset fixed GID index [3]. It does not create GIDs or guarantee RDMA. If no matching GID exists, fix the device/network exposure rather than silently claiming traffic used the new subnet. The LWS master address still uses Kubernetes discovery; not every control-plane connection moves to the secondary subnet.

## 10. Check GPU availability and start Nemotron

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

Start Nemotron:

```bash
oc annotate llminferenceservice nemotron35-30b-bf16-pp3 \
  -n nemo serving.kserve.io/stop=false --overwrite

oc get pods -n nemo -o wide
oc wait llminferenceservice/nemotron35-30b-bf16-pp3 \
  -n nemo --for=condition=Ready --timeout=1800s
```

If the wait fails, collect section 15 diagnostics. Do not automatically restart the workload repeatedly or change the shared GPU policy.

## 11. Verify serving, network selection, and inference

```bash
oc get llminferenceservice nemotron35-30b-bf16-pp3 -n nemo -o json |
jq '{generation: .metadata.generation,
     observedGeneration: .status.observedGeneration,
     appliedConfigs: .status.appliedConfigs,
     conditions: .status.conditions,
     url: .status.url}'

oc get pods -n nemo -o wide
```

Expect one leader plus two workers, each on an A40 node, one GPU per pod. Inspect the entire group:

```bash
oc get pods -n nemo -o json |
jq -r '.items[] |
  select(.metadata.name | startswith("nemotron35-30b-bf16-pp3-kserve-mn-")) |
  [.metadata.name,
   .spec.nodeName,
   .metadata.annotations["openshift.io/scc"],
   .metadata.annotations["k8s.v1.cni.cncf.io/network-status"]] | @tsv'

for pod in $(oc get pods -n nemo -o json |
  jq -r '.items[] | select(.metadata.name | startswith("nemotron35-30b-bf16-pp3-kserve-mn-")) | .metadata.name'); do
  oc logs -n nemo "$pod" -c main --tail=1000 > "${pod}.log"
  grep -Ei 'NCCL|NET/IB|NET/Socket|GID|172\.16\.102|error|traceback' "${pod}.log" || true
done
```

Every group pod needs `net1` in 172.16.102.0/24 and the expected RDMA allocation. `NET/IB` initialization/channel logs are needed to establish RoCE use; a successful API call or socket bootstrap line alone is not proof. For stronger proof, correlate the selected GID/interface with `show_gids` and NIC counters under a test request. If NCCL uses sockets for data transfer, document it as TCP fallback and investigate before calling RoCE validated.

Run an internal API test from the leader (no extra client image needed):

```bash
oc exec -i -n nemo nemotron35-30b-bf16-pp3-kserve-mn-0 -c main -- python3 - <<'PYTEST'
import json
import urllib.request
base = "http://nemo-inference-openshift-default.nemo.svc.cluster.local/nemo/nemotron35-30b-bf16-pp3/v1"
with urllib.request.urlopen(base + "/models", timeout=30) as response:
    print(json.dumps(json.load(response), indent=2))
payload = {
    "model": "nemotron35-30b-bf16-pp3",
    "messages": [{"role": "user", "content": "Explain RoCE in two sentences."}],
    "max_tokens": 256,
    "temperature": 1.0,
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

## 12. Create the external model Route

Save as `06-nemotron-route.yaml`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: nemotron35-pp3
  namespace: nemo
  annotations:
    haproxy.router.openshift.io/timeout: 300s
spec:
  path: /nemo/nemotron35-30b-bf16-pp3
  to:
    kind: Service
    name: nemo-inference-openshift-default
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
```

```bash
oc apply -f 06-nemotron-route.yaml
NEMO_HOST=$(oc get route nemotron35-pp3 -n nemo -o jsonpath='{.spec.host}')
printf 'https://%s/nemo/nemotron35-30b-bf16-pp3/v1
' "$NEMO_HOST"

curl --fail-with-body -k -N \
  "https://${NEMO_HOST}/nemo/nemotron35-30b-bf16-pp3/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"nemotron35-30b-bf16-pp3",
    "messages":[{"role":"user","content":"Say hello in one sentence."}],
    "max_tokens":128,
    "temperature":1.0,
    "top_p":0.95,
    "stream":true,
    "chat_template_kwargs":{"enable_thinking":false}
  }'
```

`-k` is only for the existing lab certificate; omit it when the router certificate is trusted. `security.opendatahub.io/enable-auth: false` means the model Route is unauthenticated. Open WebUI login does not protect direct calls to that model Route. Keep the exposure appropriate to your lab; adding model API authentication is a separate change.

## 13. Deploy a separate Open WebUI in nemo

This uses a WebUI image previously tested under `restricted-v2`, with independent namespace-local resources. No GPU is requested. The new WebUI is a fresh application with new accounts and history.

Create its signing key once:

```bash
(
  set -euo pipefail
  umask 077
  secret_dir=$(mktemp -d)
  trap 'rm -rf "$secret_dir"' EXIT
  openssl rand -hex 32 | tr -d '\n' > "$secret_dir/WEBUI_SECRET_KEY"
  oc create secret generic open-webui-secrets -n nemo \
    --from-file=WEBUI_SECRET_KEY="$secret_dir/WEBUI_SECRET_KEY"
)
```

If the Secret already exists, retain it. Save as `07-nemo-open-webui.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: open-webui
  namespace: nemo
automountServiceAccountToken: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: open-webui-data
  namespace: nemo
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
  namespace: nemo
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
          value: http://nemo-inference-openshift-default.nemo.svc.cluster.local/nemo/nemotron35-30b-bf16-pp3/v1
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
  namespace: nemo
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
oc apply -f 07-nemo-open-webui.yaml
oc rollout status deployment/open-webui -n nemo --timeout=900s

oc create route edge open-webui -n nemo \
  --service=open-webui --port=http --insecure-policy=Redirect \
  --dry-run=client -o yaml | oc apply -f -
oc annotate route open-webui -n nemo \
  haproxy.router.openshift.io/timeout=300s --overwrite
oc get route open-webui -n nemo -o jsonpath='https://{.spec.host}{"\n"}'
```

On the same cluster domain, the expected assigned hostname is `open-webui-nemo.apps.ocp4.localdomain`; use the printed value as authoritative. Register the administrator account first, select `nemotron35-30b-bf16-pp3`, and send a short prompt. Test a regular user account separately. A visible model-list alias is not another loaded model.

The WebUI deployment does not force thinking off; the API tests above do. If tuning UI latency, configure the model's request parameters in the WebUI and verify the actual generated request. Keep `nemotron_v3` as the reasoning parser.

Validate account/history persistence after a completed normal saved chat:

```bash
oc rollout restart deployment/open-webui -n nemo
oc rollout status deployment/open-webui -n nemo --timeout=300s
oc get pvc open-webui-data -n nemo
oc get pods -n nemo -l app=open-webui -o json |
jq '.items[] | {name: .metadata.name,
               serviceAccount: .spec.serviceAccountName,
               scc: .metadata.annotations["openshift.io/scc"]}'
```

Refresh the browser, verify history remains, and ask another question. Expected SCC is `restricted-v2`, based on the tested image; confirm rather than grant anyuid preemptively. Back up the data PVC and signing-key Secret. Keep replica/worker count at one for this SQLite deployment. RAG, SSO, tool execution and uploads are outside the initial validation scope.

## 14. Optional Gen AI Playground

The standalone WebUI above completes the requested browser interface; an OGX copy is not required to serve it. If you also want the OpenShift AI Playground in `nemo`, use the dashboard to provision its project-specific OGX resources after the model is Ready. Do not copy another project’s ConfigMap wholesale: its model, database host, Secrets and owner references are namespace-specific, and the captured OGX local stores are ephemeral.

Verify its vLLM provider uses exactly:

```text
http://nemo-inference-openshift-default.nemo.svc.cluster.local/nemo/nemotron35-30b-bf16-pp3/v1
```

The provider model ID must be `nemotron35-30b-bf16-pp3`. A UI-generated endpoint pointing at the old shared gateway can produce a 404. This optional Playground setup needs its own live configuration capture before it can be called validated.

## 15. Stop or restart Nemotron and troubleshoot

Stop Nemotron first:

```bash
oc annotate llminferenceservice nemotron35-30b-bf16-pp3 \
  -n nemo serving.kserve.io/stop=true --overwrite
oc wait pods -n nemo \
  -l leaderworkerset.sigs.k8s.io/name=nemotron35-30b-bf16-pp3-kserve-mn \
  --for=delete --timeout=600s
```

Repeat the all-namespace GPU-pod inventory from section 10 and confirm Nemotron's GPU pods have disappeared. The GPUs are then available for another workload, managed by its own instructions.

To restart Nemotron, confirm all three A40s are available and repeat section 10. Do not delete namespaces, PVCs, model images, or puller token Secrets to stop or start the model. An idle gateway/WebUI uses CPU/RAM, not GPU. Requests to a stopped backend fail until it starts again.

Diagnostic commands:

```bash
oc get llminferenceservice nemotron35-30b-bf16-pp3 -n nemo -o yaml
oc get pods -n nemo -o wide
oc get events -n nemo --sort-by=.metadata.creationTimestamp | tail -50
oc get gateway nemo-inference -n nemo -o yaml
oc get httproute,inferencepool -n nemo
oc logs -n nemo nemotron35-30b-bf16-pp3-kserve-mn-0 -c main --tail=300
```

| Symptom | Next action |
|---|---|
| Unsupported architecture/parser/argument | Stop; compare the preflight and packaged runtime with the checkpoint requirements. Resolve a compatible runtime by updating the nemo-owned preset and probe together |
| Mamba kernel unsupported / illegal instruction | Preserve complete stack trace, GPU architecture and runtime version; model registry recognition alone is insufficient |
| PP or hybrid cache assertion | Investigate model/runtime PP support. Do not assume TP=3 is a valid substitute; model dimensions must support the chosen topology |
| GPU pods Pending | Check competing model pods, 48Gi/6 CPU availability, A40 labels and admission events |
| ImagePullBackOff on ModelCar | Verify nemo import completed, full registry path, puller RBAC and nemo Secret; use the Secret created in nemo |
| Worker downloads fail / storage exhausted | Inspect node ephemeral storage and registry capacity; each ModelCar consumer needs local image layers |
| CUDA OOM | Inspect failing stage; lower context/concurrency, keep speculative decoding off, and confirm checkpoint precision |
| No matching GID / socket fallback | Check net1 addresses, GIDs and device visibility; 172.16.102 CIDR allocation alone does not establish RoCE |
| Gateway not ready | Confirm ClusterIP annotation and Gateway conditions |
| API 404 | Verify namespace/model path and served model ID; keep `/v1` on the client base URL |
| WebUI works but direct Route remains open | Expected: WebUI accounts and model API authentication are separate |
| Model answers but slowly | Measure time to first token and output tokens/second at representative prompt lengths and concurrency; inspect per-stage memory and kernel warnings before tuning |
| Prompt exceeds context | Keep input plus requested output within 65,536 tokens; reduce history or start a new chat |

### 15.1 Optional dashboard hardware profile

A hardware profile is a reusable dashboard resource preset; the explicit resource requests in this runbook already control scheduling. Creating a profile does not automatically associate it with the existing service or improve inference speed.

In the OpenShift AI dashboard, open **Settings → Environment setup → Hardware profiles → Create hardware profile**. Create a dedicated profile with these per-pod values:

| Field | Value |
|---|---|
| Name | Nemotron A40 |
| CPU default | 6 cores |
| Memory default | 48Gi |
| Accelerator resource | `nvidia.com/gpu` |
| Accelerator default | 1 |
| Node selector | `nvidia.com/gpu.product: NVIDIA-A40` |

If the form requires minimum/maximum values, choose ranges that include those defaults. The deployment uses three pods with one GPU each; do not request three GPUs per pod. Preserve the manifest’s RDMA resource request, network annotations and pipeline topology. Dashboard association with an existing custom LLMInferenceService is version-dependent and has not been verified here; keep the explicit manifest as the configuration source.

### 15.2 Context budget and applying runtime settings

The leader and worker arguments in section 9 use `--max-model-len=65536 --max-num-seqs=2 --gpu-memory-utilization=0.90`. Compilation and CUDA graphs use the pinned runtime defaults, and prefix caching remains disabled.

The 65,536-token limit covers the complete input and generated output together, including system instructions, conversation history and tool content. Reserving 4,096 output tokens leaves at most 61,440 input tokens. Open WebUI’s maximum-output setting does not increase the server’s context limit. Start a new chat or trim/summarize history when necessary; reasoning tokens also consume the output budget when thinking is enabled.

For an existing running deployment, edit both argument lists in `05-nemotron-three-a40.yaml` and set its `serving.kserve.io/stop` annotation to `"false"` before applying it. Schedule the rollout when interruption is acceptable:

```bash
oc apply --dry-run=server -f 05-nemotron-three-a40.yaml
oc apply -f 05-nemotron-three-a40.yaml
oc get llminferenceservice nemotron35-30b-bf16-pp3 -n nemo
oc get pods -n nemo -w
```

After the replacement pods start, use section 11’s readiness and API checks. Inspect the leader log:

```bash
oc logs -n nemo nemotron35-30b-bf16-pp3-kserve-mn-0 -c main |
  grep -E 'max_seq_len=|Graph capturing finished|Available KV cache memory|HTTP server started'
```

Confirm `max_seq_len=65536`, successful graph capture and HTTP startup. Then test a representative long prompt with room reserved for its answer, followed by two concurrent representative requests. Monitor all three stages for memory pressure and latency. Successful startup alone does not establish capacity for two maximum-length requests. If memory is exhausted, reduce context or concurrency in both argument lists and reapply.

### 15.3 Host RAM, checkpoint prefetch and TF32

Keep the current **48Gi RAM per pod** for now. The leader log reports a 61.31 GiB checkpoint, 44.67 GiB available host RAM, and XFS storage, so automatic prefetch is skipped. This is a checkpoint-loading optimization, not a serving error. The same log reports weight loading in **4.23 seconds**. There is no evidence here that more pod RAM would improve steady-state token generation.

The RAM threshold alone would require more than approximately 68.12 GiB available RAM (61.31 / 0.90), plus room for the process and other allocations. Raising a pod limit does not guarantee that much available memory, and the filesystem criterion also applies. Do not force prefetch or increase RAM solely to remove this message. Investigate node and container memory only if loading is slow or OOM events occur. Host RAM and GPU VRAM are separate budgets. [10]

The TF32 warning concerns eligible **float32 matrix multiplication**; the model is serving in BF16. It does not establish a material performance bottleneck. Keep the existing precision settings unless benchmarking shows a benefit with acceptable numerical behavior. Calling `torch.set_float32_matmul_precision('high')` in a separate `oc exec` Python process would not configure the running inference workers. Default A40 MoE/Mamba kernel warnings likewise warrant measured tuning, not an automatic precision change. [11]

## 16. Validation record and sources

Before labeling this deployment validated, record:

- Exact HF revision and imported OCI digest.
- Runtime image/version and successful full-checkpoint load on A40.
- Pipeline preset resolved from namespace `nemo`, three ranks on three nodes, expected BF16 dtype.
- All net1 addresses in 172.16.102.0/24, cross-node connectivity and selected RoCE GIDs/transport.
- Gateway Programmed and model Ready; correct HTTP 200 answer and completed stream.
- WebUI regular-user access, history after restart and actual SCC.
- Successful Nemotron stop/start and GPU release, with no competing model allocation.
- Effective runtime arguments, context/concurrency limits, graph capture, and measured request latency.

The standalone preflight and a short non-streaming API request passed (HTTP 200, complete answer, finish_reason=stop), and the user reports working WebUI interaction. The October 20 leader log confirms startup at 65,536 tokens with two sequences, BF16, PP=3/TP=1, FULL_AND_PIECEWISE CUDA graphs, successful capture using 0.05 GiB, and HTTP server startup. It reports NCCL NET/IB with RoCE on net1 at 172.16.102.4. This is leader-side evidence; retain all-rank network checks. Requests near the context limit, two simultaneous long requests, streaming, and sustained performance still require separate validation. The model card's listing under RedHatAI is not by itself a statement of Red Hat support for this exact runtime, three-A40 topology, or custom template.

[1] [Requested model card](https://huggingface.co/RedHatAI/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16) — model architecture, BF16, published vLLM recipe and parser/request conventions. Reviewed October 19, 2026.

[2] [vLLM 0.27.1 NemotronH implementation](https://docs.vllm.ai/en/v0.27.1/api/vllm/model_executor/models/nemotron_h/) — pipeline-parallel interface in this upstream version; not a validation of the installed Red Hat image.

[3] [NCCL environment variables](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html) — socket interface and dynamic RoCE GID selection; verify the installed NCCL version.

[4] [Open WebUI Kubernetes deployment](https://docs.openwebui.com/deployment/kubernetes/) and [configuration](https://docs.openwebui.com/reference/env-configuration/) — persistent single-replica application and OpenAI-compatible connections.

Local baseline: **Three A40 Runbook.md**, Qwen live captures and successful Open WebUI tests from October 19, 2026. That document is not modified by creating this one.

[5] [KServe configuration merge implementation](https://github.com/kserve/kserve/blob/master/pkg/controller/v1alpha2/llmisvc/config_merge.go) — namespace-local preset lookup precedes system-namespace fallback; verify the installed controller’s applied configuration record.

[6] [OpenShift 4.22: Accessing the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/registry/accessing-the-registry) — project-scoped image-builder permissions and token-based registry login.

[7] Hugging Face: [User access tokens](https://huggingface.co/docs/hub/security-tokens) and [HF_TOKEN environment variable](https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables).

[8] [Model Registry Operator async-upload template](https://github.com/opendatahub-io/model-registry-operator/blob/main/config/jobs-async-upload/README.md) — upstream source-connection mechanism; inspect the installed template before using its credential format.

[9] [OpenShift AI 3.5: Use connections](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_on_projects/using-connections_projects) — OCI connection protocol annotation, Docker authentication Secret, and OCI_HOST field.

[10] [vLLM 0.27.1 load configuration](https://docs.vllm.ai/en/v0.27.1/api/vllm/config/load/) — checkpoint loading and prefetch configuration.

[11] [PyTorch CUDA semantics](https://docs.pytorch.org/docs/stable/notes/cuda.html) — TF32 behavior for float32 operations.
