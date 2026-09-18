Ref: https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html#create-the-cluster-policy-using-the-web-console  
  
NVIDIA's current documentation says the preferred GPUDirect implementation is `DMA-BUF`, while `driver.rdma.enabled=true` is for the legacy `nvidia-peermem` route.  
To use the legacy `nvidia-peermem` kernel module instead of `DMA-BUF`, add set `driver.rdma.enabled=true`. Add `driver.kernelModuleType=open` if you are using a driver version from a branch earlier than R570:  
Ref: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-rdma.html#installing-the-gpu-operator-and-enabling-gpudirect-rdma  
```yaml
spec:
  driver:
    enabled: true
    rdma:
      enabled: true
```
ClusterPolicy (This is the default YAML that the operator creates for the operand):
```yaml
kind: ClusterPolicy
apiVersion: nvidia.com/v1
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    use_ocp_driver_toolkit: true
  cdi:
    enabled: true
    nriPluginEnabled: false
  sandboxWorkloads:
    enabled: false
    defaultWorkload: container
    mode: kubevirt
  driver:
    enabled: true
    useNvidiaDriverCRD: false
    kernelModuleType: auto
    upgradePolicy:
      autoUpgrade: true
      drain:
        deleteEmptyDir: false
        enable: false
        force: false
        timeoutSeconds: 300
      maxParallelUpgrades: 1
      maxUnavailable: 25%
      podDeletion:
        deleteEmptyDir: false
        force: false
        timeoutSeconds: 300
      waitForCompletion:
        timeoutSeconds: 0
    repoConfig:
      configMapName: ''
    certConfig:
      name: ''
    licensingConfig:
      nlsEnabled: true
      secretName: ''
    virtualTopology:
      config: ''
    kernelModuleConfig:
      name: ''
  dcgmExporter:
    enabled: true
    config:
      name: ''
    serviceMonitor:
      enabled: true
  dcgm:
    enabled: true
  daemonsets:
    updateStrategy: RollingUpdate
    rollingUpdate:
      maxUnavailable: '1'
  devicePlugin:
    enabled: true
    config:
      name: ''
      default: ''
    mps:
      root: /run/nvidia/mps
  gfd:
    enabled: true
  migManager:
    enabled: true
  nodeStatusExporter:
    enabled: true
  mig:
    strategy: single
  toolkit:
    enabled: true
  validator:
    plugin:
      env: []
  vgpuManager:
    enabled: false
  vgpuDeviceManager:
    enabled: true
  sandboxDevicePlugin:
    enabled: true
  kataSandboxDevicePlugin:
    enabled: true
  vfioManager:
    enabled: true
  ccManager:
    enabled: true
  gds:
    enabled: false
  gdrcopy:
    enabled: false
```

Validate Nvidia GPU Driver (There is now a validator pod that gets created in the Nvidia GPU Operator namespace that does this automatically):
New validation:
```bash
[root@ocp113 core]# oc get clusterpolicy gpu-cluster-policy -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" reason="}{.reason}{" message="}{.message}{"\n"}{end}'
Ready=True reason=Reconciled message=ClusterPolicy is ready as all resources have been successfully reconciled
Error=False reason=Ready message=

[root@ocp113 core]# oc get pods -n nvidia-gpu-operator \
  -o wide | grep -E 'validator|driver'
nvidia-cuda-validator-kr2gz                    0/1     Completed   0             19h   10.129.1.132   ocp115.localdomain   <none>           <none>
nvidia-cuda-validator-n6z7j                    0/1     Completed   0             19h   10.128.0.190   ocp113.localdomain   <none>           <none>
nvidia-cuda-validator-wmkwn                    0/1     Completed   0             19h   10.130.1.66    ocp114.localdomain   <none>           <none>
nvidia-driver-daemonset-9.8.20260819-1-5rlr5   2/2     Running     0             19h   10.128.0.172   ocp113.localdomain   <none>           <none>
nvidia-driver-daemonset-9.8.20260819-1-f9hbv   2/2     Running     0             19h   10.129.1.118   ocp115.localdomain   <none>           <none>
nvidia-driver-daemonset-9.8.20260819-1-n79p9   2/2     Running     0             19h   10.130.1.52    ocp114.localdomain   <none>           <none>
nvidia-operator-validator-8dtrk                1/1     Running     0             19h   10.129.1.131   ocp115.localdomain   <none>           <none>
nvidia-operator-validator-gghxc                1/1     Running     0             19h   10.130.1.61    ocp114.localdomain   <none>           <none>
nvidia-operator-validator-n9c2p                1/1     Running     0             19h   10.128.0.185   ocp113.localdomain   <none>           <none>
```
Old way:
 ```bash
[root@ocp113 core]# oc project nvidia-gpu-operator
Now using project "nvidia-gpu-operator" on server "https://localhost:6443".
```
```bash
[root@ocp113 core]# cat << EOF | oc create -f -

apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
spec:
  restartPolicy: OnFailure
  containers:
  - name: cuda-vectoradd
    image: "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0-ubi8"
    resources:
      limits:
        nvidia.com/gpu: 1
EOF


pod/cuda-vectoradd created
```
```bash    
[root@ocp113 core]# oc logs cuda-vectoradd
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```
```bash 
[root@ocp113 core]# oc project nvidia-gpu-operator
Now using project "nvidia-gpu-operator" on server "https://localhost:6443".
  
[root@ocp113 core]# oc get pod -owide -l openshift.driver-toolkit=true
NAME                                           READY   STATUS    RESTARTS   AGE   IP             NODE                   NOMINATED NODE   READINESS GATES
nvidia-driver-daemonset-9.8.20260727-0-4gfck   3/3     Running   0          23h   10.130.0.160   ocp115.localdomain   <none>           <none>
nvidia-driver-daemonset-9.8.20260727-0-845mc   3/3     Running   0          23h   10.129.1.211   ocp113.localdomain   <none>           <none>
nvidia-driver-daemonset-9.8.20260727-0-bhdmf   3/3     Running   0          22h   10.128.1.183   ocp114.localdomain   <none>           <none>
    
[root@ocp113 core]# oc exec -n nvidia-gpu-operator -it nvidia-driver-daemonset-9.8.20260727-0-4gfck -- nvidia-smi
Sat Aug  8 02:01:47 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 580.126.20             Driver Version: 580.126.20     CUDA Version: 13.0     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA A40                     On  |   00000000:81:00.0 Off |                  Off |
|  0%   32C    P8             34W /  300W |       1MiB /  49140MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|  No running processes found                                                             |
+-----------------------------------------------------------------------------------------+
 ```

Add Nvidia spec to containers:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: somename
spec:
 containers:
 - name: somename
   resources:
     limits:
       nvidia.com/gpu: 1
```
To configure Nvidia Multi Process Server (MPS):
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ One other important limitation: MPS configuration is node-level, not individual-GPU-level. NVIDIA states that MPS sharing applies to the full GPU resources on the node. If one physical OpenShift node contains both A40s and another model of NVIDIA GPU, you cannot use this mechanism to MPS-share only the A40 cards on that same node; those GPUs would need to be separated at the node level for this scheme.

Create a ConfigMap containing an ordinary non-sharing configuration plus a separate A40 MPS configuration:

$${\color{deeppink}\textbf{\textsf{Note:}}}$$ I prefer this over putting only a single MPS profile in the ConfigMap. NVIDIA's device-plugin config manager has fallback behavior where a single configuration can become the default in some deployment modes, so explicitly defining a normal baseline removes ambiguity.
[Source: `Sources/nvidia-device-plugin-config.yaml`](Sources/nvidia-device-plugin-config.yaml)  
<!-- embed-code: ./Sources/nvidia-device-plugin-config.yaml -->
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: nvidia-gpu-operator
data:
  full-gpu: |-
    version: v1

  a40-mps: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      mps:
        renameByDefault: true
        resources:
          - name: nvidia.com/gpu
            replicas: 2
```
`replicas: 2` is just an example:
- With MPS, NVIDIA divides both memory and compute capacity equally among the configured replicas. 
- So two replicas represent approximately half of the GPU's memory/compute allocation per client. 
- `renameByDefault: true` is particularly useful here because MPS resources become `nvidia.com/gpu.shared,` making them visibly different from an exclusive `nvidia.com/gpu`.

Patch the ClusterPolicy to Activate MPS:
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ Ensure that your `spec.mig.strategy` within that same file is set to `none` (if you are dedicating the entire node to MPS) to prevent provisioning conflicts
Locate the devicePlugin section under the configuration tree and update it to reference your config map and sharing strategy:
```yaml
spec:
  devicePlugin:
    config:
      name: nvidia-device-plugin-config
      default: full-gpu
```
Label only the A40 nodes:
- First determine the actual GPU product label. Don't assume its spelling!
 ```bash
[dave@rhel9dummy2 ~]$ oc get nodes -l nvidia.com/gpu.present=true \
  -L nvidia.com/gpu.product
NAME                 STATUS   ROLES                         AGE   VERSION   GPU.PRODUCT
ocp113.localdomain   Ready    control-plane,master,worker   8d    v1.35.6   NVIDIA-A40
ocp114.localdomain   Ready    control-plane,master,worker   8d    v1.35.6   Tesla-P4
ocp115.localdomain   Ready    control-plane,master,worker   8d    v1.35.6   NVIDIA-A40
```
If the actual label is NVIDIA-A40, then:
```bash
[dave@rhel9dummy2 ~]$ oc label nodes --overwrite -l 'nvidia.com/gpu.product=NVIDIA-A40' nvidia.com/device-plugin.config=a40-mps
node/ocp113.localdomain labeled
node/ocp115.localdomain labeled
```
Validate:
```bash
[dave@rhel9dummy2 ~]$ NS=nvidia-gpu-operator

oc get clusterpolicy gpu-cluster-policy \
  -o jsonpath='{.spec.devicePlugin.config}{"\n"}{.spec.mig.strategy}{"\n"}'

oc get nodes -l nvidia.com/gpu.present=true \
  -L nvidia.com/gpu.product,\
nvidia.com/device-plugin.config,\
nvidia.com/gpu.sharing-strategy,\
nvidia.com/mps.capable,\
nvidia.com/gpu.replicas
{"default":"full-gpu","name":"nvidia-device-plugin-config"}
none
NAME                 STATUS   ROLES                         AGE   VERSION   GPU.PRODUCT   DEVICE-PLUGIN.CONFIG   GPU.SHARING-STRATEGY   MPS.CAPABLE   GPU.REPLICAS
ocp113.localdomain   Ready    control-plane,master,worker   8d    v1.35.6   NVIDIA-A40    a40-mps                mps                    true          2
ocp114.localdomain   Ready    control-plane,master,worker   8d    v1.35.6   Tesla-P4                             none                   false         1
ocp115.localdomain   Ready    control-plane,master,worker   8d    v1.35.6   NVIDIA-A40    a40-mps                mps                    true          2
```
$${\color{deeppink}\textbf{\textsf{CRITICAL:}}}$$ Failure is in NVIDIA's k8s-device-plugin:v0.19.3 config-manager implementation:
- There is an upstream NVIDIA PR specifically for an issue. 
- NVIDIA describes the exact scenario I'm hitting: The sidecar changes configuration, attempts SIGHUP, cannot correctly identify the MPS process, and fails—particularly during the startup condition where the default configuration is applied before the node label arrives. 
- [This PR](https://github.com/NVIDIA/k8s-device-plugin/pull/1822) is still open.
  
As an immediate workaround, make the MPS DaemonSet itself use a40-mps as its startup default:
- You should see the MPS selector including: `nvidia.com/mps.capable:true`
```bash
[dave@rhel9dummy2 ~]$ NS=nvidia-gpu-operator
DS=nvidia-device-plugin-mps-control-daemon

oc -n "${NS}" get ds "${DS}" \
  -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}'
{"nvidia.com/gpu.deploy.device-plugin":"true","nvidia.com/mps.capable":"true"}
```
Then temporarily patch only the MPS DaemonSet's two config managers:
```bash
oc -n "${NS}" patch ds "${DS}" \
  --type=strategic \
  -p '{
    "spec": {
      "template": {
        "spec": {
          "initContainers": [
            {
              "name": "config-manager-init",
              "env": [
                {
                  "name": "DEFAULT_CONFIG",
                  "value": "a40-mps"
                }
              ]
            }
          ],
          "containers": [
            {
              "name": "config-manager",
              "env": [
                {
                  "name": "DEFAULT_CONFIG",
                  "value": "a40-mps"
                }
              ]
            }
          ]
        }
      }
    }
  }'
```
That does not change: ClusterPolicy default = full-gpu
It changes only: MPS control daemon startup default = a40-mps
The patch modifies the pod template, so the DaemonSet should roll automatically:
```bash
[dave@rhel9dummy2 ~]$ oc -n "${NS}" rollout status ds/"${DS}"
daemon set "nvidia-device-plugin-mps-control-daemon" successfully rolled out
```
Then:
```bash
[dave@rhel9dummy2 ~]$ oc -n "${NS}" get pods \
  -l app=nvidia-device-plugin-mps-control-daemon \
  -o wide
NAME                                            READY   STATUS    RESTARTS   AGE   IP             NODE                 NOMINATED NODE   READINESS GATES
nvidia-device-plugin-mps-control-daemon-b9nbj   2/2     Running   0          47m   10.128.1.239   ocp113.localdomain   <none>           <none>
nvidia-device-plugin-mps-control-daemon-h4g5h   2/2     Running   0          47m   10.129.0.244   ocp115.localdomain   <none>           <none>
```
You should have MPS pods only on:
- ocp113.localdomain
- ocp115.localdomain

$${\color{deeppink}\textbf{\textsf{CRITICAL:}}}$$ Important limitation of this workaround:
- This is a workaround, not the permanent upstream fix.
- The GPU Operator owns that DaemonSet, so it may eventually recreate the MPS daemon pods (node reboot, etc.) and require the patch again.

Check after the MPS daemon rollout:
```bash
[dave@rhel9dummy2 ~]$ oc -n "${NS}" get ds "${DS}" -o json | \
jq -r '
  (
    .spec.template.spec.initContainers[]?,
    .spec.template.spec.containers[]?
  )
  | select(
      .name=="config-manager-init" or
      .name=="config-manager"
    )
  | .name as $c
  | .env[]?
  | select(.name=="DEFAULT_CONFIG")
  | "\($c): \(.value)"
'
config-manager-init: a40-mps
config-manager: a40-mps
```
If the Operator changes it back to `full-gpu`, we'll need a different workaround (re-patch at least) at the Operator/operand level rather than modifying its generated DaemonSet.