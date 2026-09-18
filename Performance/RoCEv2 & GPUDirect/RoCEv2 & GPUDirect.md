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
<img width="618" height="560" alt="image" src="https://gist.github.com/user-attachments/assets/171d4734-0e81-49cd-94d5-ac96187e1fee" />

$${\color{deeppink}\textbf{\textsf{Validation Test Script:}}}$$ `gpudirect-test.sh`
<blockquote>
<details><summary>Show Script</summary>

[Source: `Sources/gpudirect-test.sh`](Sources/gpudirect-test.sh)
<!-- embed-code: ./Sources/gpudirect-test.sh -->
```bash
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
Discover current net1 / 172.16.100.x addresses
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
  Server IP:       172.16.100.5
  Client node:     ocp115.localdomain
  Client pod:      doca-gpudirect-client-bd9c4994f-zt69n
  Client IP:       172.16.100.4
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

==> host-memory-rocev2: starting client on doca-gpudirect-client-bd9c4994f-zt69n -> 172.16.100.5
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

==> cuda-dmabuf-gpudirect-rocev2: starting client on doca-gpudirect-client-bd9c4994f-zt69n -> 172.16.100.5
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
Server:        doca-gpudirect-server-b8f5d47f-wxjb2 (ocp113.localdomain) 172.16.100.5
Client:        doca-gpudirect-client-bd9c4994f-zt69n (ocp115.localdomain) 172.16.100.4
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