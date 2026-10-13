#### Model Caching Strategies:
```text
A) Native RHOAI Model Cache
   Hugging Face
        |
        +--> local copy on ocp113
        +--> local copy on ocp114
        +--> local copy on ocp115

B) RWX PVC
   Hugging Face
        |
        +--> one shared CephFS/RWX copy
                   |
             all three nodes
```

#### Check the disk available on each node:
```bash
for NODE in \
  ocp113.localdomain \
  ocp114.localdomain \
  ocp115.localdomain; do

  echo
  echo "=============== ${NODE} ==============="

  oc debug node/"${NODE}" --quiet -- \
    chroot /host bash -c '
      df -h /var/lib/kserve/models 2>/dev/null || df -h /var/lib/kserve || df -h /
    '
done
```
```bash
=============== ocp113.localdomain ===============
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p4  447G   66G  381G  15% /var

=============== ocp114.localdomain ===============
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p4  447G   78G  370G  18% /var

=============== ocp115.localdomain ===============
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p4  447G   81G  366G  19% /var
```
#### Patch the `DataScienceCluster`:
```bash
oc patch datasciencecluster default-dsc \
  --type=merge \
  -p '{
    "spec": {
      "components": {
        "kserve": {
          "managementState": "Managed",
          "modelCache": {
            "managementState": "Managed",
            "cacheSize": "150Gi",
            "nodeNames": [
              "ocp113.localdomain",
              "ocp114.localdomain",
              "ocp115.localdomain"
            ]
          }
        }
      }
    }
  }'
```
Then watch:
```bash
oc get localmodelnodegroup
NAME      AGE
workers   65m
```
And:
```bash
oc get pods \
  -n redhat-ods-applications \
  -l app.kubernetes.io/name=kserve-localmodelnode-agent \
  -o wide
NAME                                READY   STATUS    RESTARTS   AGE   IP             NODE                 NOMINATED NODE   READINESS GATES
kserve-localmodelnode-agent-55qt2   1/1     Running   0          34m   10.128.0.38    ocp113.localdomain   <none>           <none>
kserve-localmodelnode-agent-css6c   1/1     Running   0          34m   10.130.0.92    ocp114.localdomain   <none>           <none>
kserve-localmodelnode-agent-mp99t   1/1     Running   0          34m   10.129.0.122   ocp115.localdomain   <none>           <none>
```
RHOAI should create an agent on each selected node. The documented storage backing is local node storage, and the cache path is `/var/lib/kserve/models`  
  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ Check the HuggingFace (HF) Token section for inscreased download speed if you provide a Token!  
  
#### Create the native cache:  
Now create the namespace-scoped cache for ai-test (Omit `storage/key` if you don't have a HuggingFace Token):
```yaml
cat <<'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1alpha1
kind: LocalModelNamespaceCache
metadata:
  name: llama-3-3-70b-w8a8
  namespace: ai-test
spec:
  sourceModelUri: hf://RedHatAI/Llama-3.3-70B-Instruct-quantized.w8a8
  modelSize: 90Gi
  nodeGroups:
    - workers
  storage:
    key: hf-secret
EOF
localmodelnamespacecache.serving.kserve.io/llama-3-3-70b-w8a8 created
```
#### Watch what gets created
Immediately run:
```bash
oc get localmodelnamespacecache \
  llama-3-3-70b-w8a8 \
  -n ai-test \
  -o yaml
```
```bash
apiVersion: serving.kserve.io/v1alpha1
kind: LocalModelNamespaceCache
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"serving.kserve.io/v1alpha1","kind":"LocalModelNamespaceCache","metadata":{"annotations":{},"name":"llama-3-3-70b-w8a8","namespace":"ai-test"},"spec":{"modelSize":"90Gi","nodeGroups":["workers"],"sourceModelUri":"hf://RedHatAI/Llama-3.3-70B-Instruct-quantized.w8a8","storage":{"key":"hf-secret"}}}
  creationTimestamp: "2026-10-12T21:13:56Z"
  finalizers:
  - localmodelnamespacecache.kserve.io/finalizer
  generation: 1
  name: llama-3-3-70b-w8a8
  namespace: ai-test
  resourceVersion: "33116064"
  uid: 67addff4-2297-458d-ad06-89e7446d60d1
spec:
  modelSize: 90Gi
  nodeGroups:
  - workers
  sourceModelUri: hf://RedHatAI/Llama-3.3-70B-Instruct-quantized.w8a8
  storage:
    key: hf-secret
status:
  copies:
    total: 3
  nodeStatus:
    ocp113.localdomain: NodeDownloading
    ocp114.localdomain: NodeDownloading
    ocp115.localdomain: NodeDownloading
```
Then:
```bash
oc get localmodelnode -o wide
```
```bash
NAME                 AGE
ocp113.localdomain   85s
ocp114.localdomain   85s
ocp115.localdomain   85s
```
And most importantly, because your configured job namespace is redhat-ods-applications:
```bash
oc get jobs,pods \
  -n redhat-ods-applications \
  -o wide |
grep -Ei 'localmodel|llama|download'
```
We should now see the download jobs appear:
```bash
job.batch/llama-3-3-70b-w8a8-ocp113.localdomainr8gtf   Running   0/1           86s        86s   kserve-localmodel-download   registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:c2db37bfe06f62b4ead20a975afe9df1c00e0178492c4bcd75968b60b1fbee79   batch.kubernetes.io/controller-uid=0a4fdcc2-d0db-4844-ba61-d5304a0e2fcb
job.batch/llama-3-3-70b-w8a8-ocp114.localdomainb8h4n   Running   0/1           85s        85s   kserve-localmodel-download   registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:c2db37bfe06f62b4ead20a975afe9df1c00e0178492c4bcd75968b60b1fbee79   batch.kubernetes.io/controller-uid=34879510-3c70-4326-a74f-c0ec8545927d
job.batch/llama-3-3-70b-w8a8-ocp115.localdomain8kfb9   Running   0/1           85s        85s   kserve-localmodel-download   registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:c2db37bfe06f62b4ead20a975afe9df1c00e0178492c4bcd75968b60b1fbee79   batch.kubernetes.io/controller-uid=0cf687f6-a89a-45db-96be-ca042ff16653
pod/kserve-localmodel-controller-manager-86f7c7bfbf-4vczw             1/1     Running   0            67m     10.130.0.91    ocp114.localdomain   <none>           <none>
pod/kserve-localmodelnode-agent-55qt2                                 1/1     Running   0            67m     10.128.0.38    ocp113.localdomain   <none>           <none>
pod/kserve-localmodelnode-agent-css6c                                 1/1     Running   0            67m     10.130.0.92    ocp114.localdomain   <none>           <none>
pod/kserve-localmodelnode-agent-mp99t                                 1/1     Running   0            67m     10.129.0.122   ocp115.localdomain   <none>           <none>
pod/llama-3-3-70b-w8a8-ocp113.localdomainr8gtf-5trcw                  1/1     Running   0            86s     10.128.0.40    ocp113.localdomain   <none>           <none>
pod/llama-3-3-70b-w8a8-ocp114.localdomainb8h4n-jmdbx                  1/1     Running   0            85s     10.130.0.176   ocp114.localdomain   <none>           <none>
pod/llama-3-3-70b-w8a8-ocp115.localdomain8kfb9-bjtfp                  1/1     Running   0            85s     10.129.0.125   ocp115.localdomain   <none>           <none>
```
#### Verifying that the native Model Cache has finished on all three nodes:
```bash
oc get localmodelnamespacecache \
  llama-3-3-70b-w8a8 \
  -n ai-test \
  -o json | jq '.status'
{
  "copies": {
    "available": 1,
    "total": 3
  },
  "nodeStatus": {
    "ocp113.localdomain": "NodeDownloaded",
    "ocp114.localdomain": "NodeDownloading",
    "ocp115.localdomain": "NodeDownloading"
  }
}
```
Or:
```bash
 for NODE in \
  ocp113.localdomain \
  ocp114.localdomain \
  ocp115.localdomain; do

  echo
  echo "================ ${NODE} ================"

  oc get localmodelnode "${NODE}" \
    -o json | jq '.status.modelStatus'
done

================ ocp113.localdomain ================
{
  "ai-test/llama-3-3-70b-w8a8": "ModelDownloaded"
}

================ ocp114.localdomain ================
{
  "ai-test/llama-3-3-70b-w8a8": "ModelDownloading"
}

================ ocp115.localdomain ================
{
  "ai-test/llama-3-3-70b-w8a8": "ModelDownloading"
}
```
#### Check the correct host path
Run this:
```bash
for NODE in \
  ocp113.localdomain \
  ocp114.localdomain \
  ocp115.localdomain; do

  echo
  echo "================ ${NODE} ================"

  oc debug node/"${NODE}" --quiet -- \
    chroot /host bash -c '
      DIR=/var/lib/kserve/models/models/2baf2d73839a508c

      echo "Directory:"
      ls -ld "$DIR" 2>/dev/null || true

      echo
      echo "Size:"
      du -sh "$DIR" 2>/dev/null || true

      echo
      echo "Safetensor shards:"
      find "$DIR" \
        -maxdepth 1 \
        -name "*.safetensors" \
        -type f 2>/dev/null | wc -l
    '
done
```
```bash
================ ocp113.localdomain ================
Directory:
drwxr-xr-x. 3 core core 4096 Oct 12 21:21 /var/lib/kserve/models/models/2baf2d73839a508c

Size:
68G     /var/lib/kserve/models/models/2baf2d73839a508c

Safetensor shards:
15

================ ocp114.localdomain ================
Directory:
drwxr-xr-x. 3 core core 108 Oct 12 21:14 /var/lib/kserve/models/models/2baf2d73839a508c

Size:
12G     /var/lib/kserve/models/models/2baf2d73839a508c

Safetensor shards:
0

================ ocp115.localdomain ================
Directory:
drwxr-xr-x. 3 core core 108 Oct 12 21:14 /var/lib/kserve/models/models/2baf2d73839a508c

Size:
18G     /var/lib/kserve/models/models/2baf2d73839a508c

Safetensor shards:
0
```
`ocp113` to shows the full model now, while ocp114 and ocp115 should show directories that are still growing.
#### Inspect through each agent pod:
This avoids translating host/PVC/container paths at all:
```bash
for NODE in \
  ocp113.localdomain \
  ocp114.localdomain \
  ocp115.localdomain; do

  echo
  echo "================ ${NODE} ================"

  POD=$(
    oc get pods \
      -n redhat-ods-applications \
      -l app.kubernetes.io/name=kserve-localmodelnode-agent \
      --field-selector spec.nodeName="${NODE}" \
      -o jsonpath='{.items[0].metadata.name}'
  )

  echo "Agent: ${POD}"

  oc exec \
    -n redhat-ods-applications \
    "${POD}" -- \
    sh -c '
      DIR=/var/lib/kserve/models/2baf2d73839a508c

      du -sh "$DIR" 2>/dev/null || true

      printf "Safetensor shards: "
      find "$DIR" \
        -maxdepth 1 \
        -name "*.safetensors" \
        -type f 2>/dev/null | wc -l
    '
done
```
```bash
================ ocp113.localdomain ================
Agent: kserve-localmodelnode-agent-55qt2
68G     /var/lib/kserve/models/2baf2d73839a508c
Safetensor shards: 0

================ ocp114.localdomain ================
Agent: kserve-localmodelnode-agent-css6c
12G     /var/lib/kserve/models/2baf2d73839a508c
Safetensor shards: 0

================ ocp115.localdomain ================
Agent: kserve-localmodelnode-agent-mp99t
18G     /var/lib/kserve/models/2baf2d73839a508c
Safetensor shards: 0
```
#### Single PV/PVC is expected in this implementation:
The topology is effectively:
```text
kserve-localmodelnode-pv
    hostPath: /var/lib/kserve/models
                 |
                 +-- same path independently on ocp113
                 +-- same path independently on ocp114
                 +-- same path independently on ocp115

kserve-localmodelnode-pvc
                 |
        mounted into each agent
        as /var/lib/kserve
```
Because this is `hostPath`-backed node-local storage rather than Ceph, or some other shared storage, the same PV specification is resolving to the corresponding local filesystem path on each selected worker. The actual model data is therefore three separate physical copies, even though you're seeing one PV/PVC definition.  
  
That's exactly what we want for this:
- Each A40 node has the model locally, so when we launch the three-node distributed vLLM workload, none of the ranks needs to stream the model from ODF or Hugging Face during startup.