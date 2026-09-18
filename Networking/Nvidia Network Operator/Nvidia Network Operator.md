Ref: https://docs.nvidia.com/networking/display/kubernetes2641/openshift/deployment-guide-openshift.html#network-operator-deployment-with-the-rdma-shared-device-plugin-ocp    
Ref: https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/install-gpu-ocp.html#create-the-cluster-policy-using-the-web-console  
Ref: https://docs.nvidia.com/networking/display/kubernetes2641/openshift/deployment-guide-openshift.html#sr-iov-network-operator  
  
If using Nvidia GPUs and Nvidia NICs in the same system, install `Node Feature Discovery` Operator first.  
  
`SR-IOV` Operator seems to only be needed for legacy mode (See link, more modern approach seems to use the `sriovDevicePlugin` CNI Plugin that does not require the SRIOV Operator from what I gather):  
https://docs.nvidia.com/networking/display/kubernetes2641/openshift/deployment-guide-openshift.html#network-operator-deployment-with-sr-iov-legacy-mode-ocp  
  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ If Nvidia driver is waiting on `Waiting for MOFED to be installed...` and the SRIOV Operator is deployed, then:
```bash
oc patch sriovoperatorconfig default \
  --type=merge -n openshift-sriov-network-operator \
  --patch '{ "spec": { "configDaemonNodeSelector": { "network.nvidia.com/operator.mofed.wait": "false", "node-role.kubernetes.io/worker": "", "feature.node.kubernetes.io/pci-15b3.sriov.capable": "true" } } }'
```

Nvidia Network Operator 26.7.0:  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ My cluster is using: 
- Bonded ConnectX-6 Lx 25 gbps NICs ("enp193s0f0np0", "enp193s0f1np1") in a LACP for node connectivity (etcd), and the cluster has inbox drivers in RHEL CoreOS (mlx5_core for ConnectX-6).  
- Bonded ConnectX-6 Dx 100 gbps NICs ("enp1s0f0np0", "enp1s0f1np1") in a LACP for AI RoCEv2 connectivity.
- I tried to use the bonded Dx NICs for all cluster traffic, but the only way to get RoCE to succeed a validation test was to build a VLAN off of the bond and associate the VLAN interface to the `rdmaSharedDevicePlugin`, which I don't want.
- With the two bonds, one for cluster traffic and normal ingress/egress, and one specific to AI GPUDirect/RoCEv2 between the nodes, this will keep traffic on the AI interfaces away from the cluster interfaces.
  - Shielding the Lx interfaces from being saturated and causing `etcd` latency issues. 
  - This is also best practices directly from Nvidia.
  
$${\color{red}\textbf{\textsf{WARNING:}}}$$ Deploy a `NodeFeatureDiscovery` operand first from the Node Feature Discovery Operator!  
  
$${\color{yellow}\textbf{\textsf{CRITICAL:}}}$$ Apply the below `machineconfig` as Red Hat specifically requires unlimited memlock on OpenShift GPU nodes for NIXL/RDMA because RDMA registration pins memory.
- You may want to `pause` you `MachineConfigPool` (MCP) if you have other configs to apply as this will cause a rolling reboot of your nodes.
- If you do `pause` your MCP, don't forget to resume it!
- Default setting on my cluster was `8192`
  
Generate the MachineConfig:
[Source: `Sources/99-master-rdma-memlock.bu`](Sources/99-master-rdma-memlock.bu)
<!-- embed-code: ./Sources/99-master-rdma-memlock.bu -->
```yaml
variant: openshift
version: 4.22.0

metadata:
  name: 99-master-rdma-memlock
  labels:
    machineconfiguration.openshift.io/role: master

storage:
  files:
    - path: /etc/crio/crio.conf.d/99-rdma-memlock
      mode: 0644
      overwrite: true
      contents:
        inline: |
          [crio.runtime]
          default_ulimits = [
            "memlock=-1:-1"
          ]
```
```bash
butane 99-master-rdma-memlock.bu -o 99-master-rdma-memlock.yaml
```
[Source: `Sources/99-master-rdma-memlock.yaml`](Sources/99-master-rdma-memlock.yaml)
<!-- embed-code: ./Sources/99-master-rdma-memlock.yaml -->
```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-master-rdma-memlock
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/crio/crio.conf.d/99-rdma-memlock
          mode: 420
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,W2NyaW8ucnVudGltZV0KZGVmYXVsdF91bGltaXRzID0gWwogICJtZW1sb2NrPS0xOi0xIgpdCg==
```
How to check the Check CRI-O's configuration:
```bash
for NODE in ocp113.localdomain ocp115.localdomain; do
  echo
  echo "=== ${NODE} ==="

  oc debug node/"${NODE}" --quiet -- \
    chroot /host bash -c \
    'crio config 2>/dev/null | grep -A4 -B2 default_ulimits'
done
```
For example:
```text
=== ocp113.localdomain ===
# "nofile=1024:2048"
# If nothing is set here, settings will be inherited from the CRI-O daemon
default_ulimits = [
        "memlock=-1:-1",
]

# If true, the runtime will not use pivot_root, but instead use MS_MOVE.

=== ocp115.localdomain ===
# "nofile=1024:2048"
# If nothing is set here, settings will be inherited from the CRI-O daemon
default_ulimits = [
        "memlock=-1:-1",
]

# If true, the runtime will not use pivot_root, but instead use MS_MOVE.
```
This can be used too:
```bash
for NODE in ocp113.localdomain ocp115.localdomain; do
  echo
  echo "==============================="
  echo "${NODE}"
  echo "==============================="

  oc debug node/"${NODE}" --quiet -- \
    chroot /host bash -c '
      echo "--- RDMA memlock drop-in ---"
      ls -l /etc/crio/crio.conf.d/99-rdma-memlock 2>/dev/null || true
      cat /etc/crio/crio.conf.d/99-rdma-memlock 2>/dev/null || true

      echo
      echo "--- All default_ulimits definitions ---"
      grep -Rns "default_ulimits" \
        /etc/crio/crio.conf \
        /etc/crio/crio.conf.d 2>/dev/null || true

      echo
      echo "--- Effective CRI-O configuration ---"
      crio status config 2>/dev/null | grep -A4 -B2 default_ulimits
    '
done
```
For example:
```text
===============================
ocp113.localdomain
===============================
--- RDMA memlock drop-in ---
-rw-r--r--. 1 root root 55 Sep 18 20:17 /etc/crio/crio.conf.d/99-rdma-memlock
[crio.runtime]
default_ulimits = [
  "memlock=-1:-1"
]

--- All default_ulimits definitions ---
/etc/crio/crio.conf:128:# default_ulimits = [
/etc/crio/crio.conf.d/99-rdma-memlock:2:default_ulimits = [

--- Effective CRI-O configuration ---
    min_injected_gomaxprocs = 0
    default_sysctls = ["net.ipv4.ping_group_range=0 2147483647"]
    default_ulimits = ["memlock=-1:-1"]
    allowed_devices = ["/dev/fuse", "/dev/net/tun"]
    cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
    device_ownership_from_security_context = false
    default_runtime = "crun"

===============================
ocp115.localdomain
===============================
--- RDMA memlock drop-in ---
-rw-r--r--. 1 root root 55 Sep 18 20:26 /etc/crio/crio.conf.d/99-rdma-memlock
[crio.runtime]
default_ulimits = [
  "memlock=-1:-1"
]

--- All default_ulimits definitions ---
/etc/crio/crio.conf:128:# default_ulimits = [
/etc/crio/crio.conf.d/99-rdma-memlock:2:default_ulimits = [

--- Effective CRI-O configuration ---
    min_injected_gomaxprocs = 0
    default_sysctls = ["net.ipv4.ping_group_range=0 2147483647"]
    default_ulimits = ["memlock=-1:-1"]
    allowed_devices = ["/dev/fuse", "/dev/net/tun"]
    cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
    device_ownership_from_security_context = false
    default_runtime = "crun"
```
Finally, test a newly created container:
```bash
for NODE in ocp113.localdomain ocp114.localdomain ocp115.localdomain; do
  printf "%-22s " "${NODE}"

  oc debug node/"${NODE}" --quiet -- \
    chroot /host bash -c 'ulimit -l'
done
```
Expected:
```text
ocp113.localdomain     unlimited
ocp114.localdomain     unlimited
ocp115.localdomain     unlimited
```
Then, create a `NodeNetworkConfigurationPolicy` for the Dx NICs:  
[Source: `Sources/100gb-bond-nnc.yaml`](Sources/100gb-bond-nnc.yaml)  
<!-- embed-code: ./Sources/100gb-bond-nnc.yaml -->
```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: 100gb-bond-nnc
spec:
  nodeSelector:
    node-role.kubernetes.io/master: ""
  desiredState:
    interfaces:
      - name: enp1s0f0np0
        type: ethernet
        state: up
        mtu: 9100
        ipv4:
          enabled: false
        ipv6:
          enabled: false
      - name: enp1s0f1np1
        type: ethernet
        state: up
        mtu: 9100
        ipv4:
          enabled: false
        ipv6:
          enabled: false
      - name: bond1
        type: bond
        state: up
        mtu: 9100
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        link-aggregation:
          mode: 802.3ad
          options:
            miimon: "100"
            lacp_rate: fast
            xmit_hash_policy: layer3+4
          port:
            - enp1s0f0np0
            - enp1s0f1np1
```
Verify MTU after `Enactments` succeed:  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ My interfaces are down as they are admin downed at the switch still.  
```bash
[root@ocp113 core]# !2
export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig

[root@ocp113 core]# oc debug node/ocp113.localdomain -- chroot /host bash -c '
for IFACE in enp1s0f0np0 enp1s0f1np1 bond1; do
    echo "===== ${IFACE} ====="
    ip -d link show "${IFACE}" |
      sed -n "1,2p"
done
'
Starting pod/ocp113localdomain-debug-bvzc6 ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
===== enp1s0f0np0 =====
4: enp1s0f0np0: <NO-CARRIER,BROADCAST,MULTICAST,SLAVE,UP> mtu 9100 qdisc mq master bond1 state DOWN mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:5c:58:30 brd ff:ff:ff:ff:ff:ff promiscuity 1 allmulti 0 minmtu 68 maxmtu 9978
===== enp1s0f1np1 =====
5: enp1s0f1np1: <NO-CARRIER,BROADCAST,MULTICAST,SLAVE,UP> mtu 9100 qdisc mq master bond1 state DOWN mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:5c:58:30 brd ff:ff:ff:ff:ff:ff permaddr 3c:ec:ef:5c:58:31 promiscuity 1 allmulti 0 minmtu 68 maxmtu 9978
===== bond1 =====
1528: bond1: <NO-CARRIER,BROADCAST,MULTICAST,MASTER,UP> mtu 9100 qdisc noqueue master ovs-system state DOWN mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:5c:58:30 brd ff:ff:ff:ff:ff:ff promiscuity 1 allmulti 0 minmtu 68 maxmtu 65535
Removing debug pod ...
```
Then create an Nvidia Network Operator `NicClusterPolicy`:  
$${\color{red}\textbf{\textsf{WARNING:}}}$$ Both of the env vars below will cause a network blip and outage to the cluster for a short duration while the drivers deploy!  
[Source: `Sources/nic-cluster-policy.yaml`](Sources/nic-cluster-policy.yaml)
<!-- embed-code: ./Sources/nic-cluster-policy.yaml -->
```yaml
kind: NicClusterPolicy
apiVersion: mellanox.com/v1alpha1
metadata:
  name: nic-cluster-policy
spec:
  ofedDriver:
    image: doca-driver
    livenessProbe:
      initialDelaySeconds: 30
      periodSeconds: 30
    env:
      - name: UNLOAD_STORAGE_MODULES   # This will unload the active kernel modules of the inbox driver
        value: 'true'
      - name: DISABLE_SAFE_DRIVER_LOADING   # This will cause the drivers to step on the inbox drivers aggressively to load them
        value: 'true'
    readinessProbe:
      initialDelaySeconds: 10
      periodSeconds: 30
    repository: nvcr.io/nvidia/mellanox
    startupProbe:
      initialDelaySeconds: 10
      periodSeconds: 20
    terminationGracePeriodSeconds: 300
    upgradePolicy:
      autoUpgrade: true
      drain:
        deleteEmptyDir: true
        enable: true
        force: true
        podSelector: ''
        timeoutSeconds: 300
      maxParallelUpgrades: 1
    version: doca3.5.0-26.07-0.7.7.0-0
  rdmaSharedDevicePlugin:
    config: |
      {
        "configList": [
          {
            "resourceName": "rdma_shared_device_dx_bond",
            "rdmaHcaMax": 1000,
            "selectors": {
              "ifNames": [
              "enp1s0f0np0",
              "enp1s0f1np1"
            ]
            }
          }
        ]
      }
    image: k8s-rdma-shared-dev-plugin
    repository: nvcr.io/nvidia/mellanox
    version: 'sha256:2d28133fdee8c263e19b4d0656bf58d30513c9d13e47ef84bd68c5499b3c18ce'
```
If you hit an error like this in one of the Nvidia Network Operator DaemonSet pods, then see/add the environment variable(s) above (`DISABLE_SAFE_DRIVER_LOADING` may be superseded by `upgradePolicy: safeLoad: false` which looks to be appended to the `NicClusterPolicy` after creation, regardless of env vars):
```text
2026-09-09T15:56:46.385Z INFO cmd/main.go:78 entrypoint {"version": "(clean), commit:, date:2026-08-25T10:47:47+00:00"}
2026-09-09T15:56:46.385Z INFO cmd/main.go:80 Container full version: 26.07-0.7.7.0-0
2026-09-09T15:56:46.385Z INFO cmd/main.go:92 start manager {"mode": "sources"}
2026-09-09T15:56:46.386Z INFO entrypoint/entrypoint.go:101 NVIDIA driver container exec preStart
2026-09-09T15:56:46.386Z INFO ready/ready.go:76 remove driver ready indicator
2026-09-09T15:56:46.386Z INFO ready/ready.go:85 driver ready indicator cleared {"path": "/run/mellanox/drivers/.driver-ready"}
2026-09-09T15:56:46.386Z INFO udev/udev.go:75 remove udev rules
2026-09-09T15:56:46.386Z INFO udev/udev.go:83 udev rules file was not previously created, skipping {"path": "/host/etc/udev/rules.d/77-mlnx-net-names.rules"}
2026-09-09T15:56:46.387Z INFO driver/driver.go:2281 Updating system CA certificates (RHEL/OpenShift)...
2026-09-09T15:56:48.064Z INFO driver/driver.go:123 Executing driver sources container
2026-09-09T15:56:48.064Z INFO entrypoint/entrypoint.go:279 Verifying loaded modules will not prevent future driver restart
2026-09-09T15:56:48.082Z ERROR entrypoint/entrypoint.go:308 kernel modules check failed {"error": "storage modules are loaded for current driver,terminating prior driver reload failure due to UNLOAD_STORAGE_MODULES not set to \"true\""}
2026-09-09T15:56:48.082Z ERROR entrypoint/entrypoint.go:103 exec preStart failed {"error": "storage modules are loaded for current driver,terminating prior driver reload failure due to UNLOAD_STORAGE_MODULES not set to \"true\""}
2026-09-09T15:56:48.082Z ERROR cmd/main.go:110 Entrypoint Run failed {"error": "storage modules are loaded for current driver,terminating prior driver reload failure due to UNLOAD_STORAGE_MODULES not set to \"true\""}
```
Resolving MOFED Storage Module Race Condition: https://support.crusoecloud.com/hc/en-us/articles/47917278400923-Resolving-MOFED-Storage-Module-Race-Condition-on-CMK-GPU-Nodes  
  
```yaml
ofedDriver:
  image: doca-driver
  repository: nvcr.io/nvidia/mellanox
  version: 25.01-0.6.0.0-0
  env:
    - name: UNLOAD_STORAGE_MODULES  # <---- add this
      value: "true"                 # <---- add this
```
Verify is that Kubernetes is advertising both the GPU and the correct RDMA resource on the nodes (The actual RDMA count depends on your `rdmaHcaMax` configuration.):
```bash
oc get nodes -o json | jq -r '
.items[] |
[
  .metadata.name,
  (.status.allocatable["nvidia.com/gpu"] // "-"),
  (.status.allocatable["rdma/rdma_shared_device_dx_bond"] // "-")
] | @tsv'
```
```bash
ocp113.localdomain      1       1k
ocp114.localdomain      1       1k
ocp115.localdomain      1       1k
```
$${\color{red}WARNING:}$$ If your `nvidia.com/gpu` is a `-` for each node, go deploy Nvidia GPU Operator operand `ClusterPolicy`.

NVIDIA documents that when a dual-port ConnectX adapter enters RoCE LAG mode using 802.3ad/LACP, the two individual RDMA devices are replaced by one RDMA device (Ports are still adm downed on the switch):
```bash
oc debug node/ocp113.localdomain -- chroot /host bash -c '
echo "===== RDMA LINKS ====="
rdma link

echo
echo "===== RDMA DEVICES ====="
ls -l /sys/class/infiniband

echo
echo "===== IBDEV -> NETDEV ====="
ibdev2netdev 2>/dev/null || true
'
```
```bash
Starting pod/ocp113localdomain-debug-94b4w ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
===== RDMA LINKS =====
link mlx5_bond_0/1 state ACTIVE physical_state LINK_UP netdev enp193s0f0np0
link mlx5_bond_1/1 state DOWN physical_state DISABLED netdev enp1s0f0np0

===== RDMA DEVICES =====
total 0
lrwxrwxrwx. 1 root root 0 Sep  9 16:19 mlx5_bond_0 -> ../../devices/pci0000:c0/0000:c0:01.1/0000:c1:00.0/infiniband/mlx5_bond_0
lrwxrwxrwx. 1 root root 0 Sep  9 16:23 mlx5_bond_1 -> ../../devices/pci0000:00/0000:00:01.1/0000:01:00.0/infiniband/mlx5_bond_1

===== IBDEV -> NETDEV =====

Removing debug pod ...
```
Check Ethernet bond state via the terminal on a node because this will tell us that both 100G Dx ports are active members, not merely that RoCE LAG was successfully instantiated:  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ It's critical that the bond for the RDMA/RoCE traffic is not connected to an `ovs`  
```bash
[root@ocp113 core]# for NODE in ocp113.localdomain ocp114.localdomain ocp115.localdomain; do
  echo "===== $NODE ====="

  oc debug node/"$NODE" -- chroot /host bash -lc '
    echo "OVS lookup:"
    ovs-vsctl iface-to-br bond1 2>/dev/null ||
      echo "bond1 is not attached to OVS"

    echo
    echo "Bond state:"
    cat /proc/net/bonding/bond1

    echo
    echo "RDMA state:"
    rdma link
  '

  echo
done
===== ocp113.localdomain =====
Starting pod/ocp113localdomain-debug-tzzrh ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
OVS lookup:
bond1 is not attached to OVS

Bond state:
Ethernet Channel Bonding Driver: v5.14.0-687.41.1.el9_8.x86_64

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 0
Down Delay (ms): 0
Peer Notification Delay (ms): 0

802.3ad info
LACP active: on
LACP rate: fast
Min links: 0
Aggregator selection policy (ad_select): stable
System priority: 65535
System MAC address: 3c:ec:ef:5c:58:30
Active Aggregator Info:
        Aggregator ID: 1
        Number of ports: 2
        Actor Key: 29
        Partner Key: 29
        Partner Mac Address: 04:f4:1c:d9:97:ce

Slave Interface: enp1s0f0np0
MII Status: up
Speed: 100000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 3c:ec:ef:5c:58:30
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Churned Count: 0
Partner Churned Count: 0
details actor lacp pdu:
    system priority: 65535
    system mac address: 3c:ec:ef:5c:58:30
    port key: 29
    port priority: 255
    port number: 1
    port state: 63
details partner lacp pdu:
    system priority: 65535
    system mac address: 04:f4:1c:d9:97:ce
    oper key: 29
    port priority: 255
    port number: 1
    port state: 62

Slave Interface: enp1s0f1np1
MII Status: up
Speed: 100000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 3c:ec:ef:5c:58:31
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Churned Count: 0
Partner Churned Count: 0
details actor lacp pdu:
    system priority: 65535
    system mac address: 3c:ec:ef:5c:58:30
    port key: 29
    port priority: 255
    port number: 2
    port state: 63
details partner lacp pdu:
    system priority: 65535
    system mac address: 04:f4:1c:d9:97:ce
    oper key: 29
    port priority: 255
    port number: 2
    port state: 62

RDMA state:
link mlx5_bond_0/1 state ACTIVE physical_state LINK_UP netdev enp193s0f0np0
link mlx5_bond_1/1 state ACTIVE physical_state LINK_UP netdev enp1s0f0np0

Removing debug pod ...

===== ocp114.localdomain =====
Starting pod/ocp114localdomain-debug-z8p29 ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
OVS lookup:
bond1 is not attached to OVS

Bond state:
Ethernet Channel Bonding Driver: v5.14.0-687.41.1.el9_8.x86_64

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 0
Down Delay (ms): 0
Peer Notification Delay (ms): 0

802.3ad info
LACP active: on
LACP rate: fast
Min links: 0
Aggregator selection policy (ad_select): stable
System priority: 65535
System MAC address: 3c:ec:ef:12:9c:5c
Active Aggregator Info:
        Aggregator ID: 1
        Number of ports: 2
        Actor Key: 29
        Partner Key: 29
        Partner Mac Address: 04:f4:1c:d9:97:c6

Slave Interface: enp1s0f0np0
MII Status: up
Speed: 100000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 3c:ec:ef:12:9c:5c
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Churned Count: 0
Partner Churned Count: 0
details actor lacp pdu:
    system priority: 65535
    system mac address: 3c:ec:ef:12:9c:5c
    port key: 29
    port priority: 255
    port number: 1
    port state: 63
details partner lacp pdu:
    system priority: 65535
    system mac address: 04:f4:1c:d9:97:c6
    oper key: 29
    port priority: 255
    port number: 1
    port state: 62

Slave Interface: enp1s0f1np1
MII Status: up
Speed: 100000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 3c:ec:ef:12:9c:5d
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Churned Count: 0
Partner Churned Count: 0
details actor lacp pdu:
    system priority: 65535
    system mac address: 3c:ec:ef:12:9c:5c
    port key: 29
    port priority: 255
    port number: 2
    port state: 63
details partner lacp pdu:
    system priority: 65535
    system mac address: 04:f4:1c:d9:97:c6
    oper key: 29
    port priority: 255
    port number: 2
    port state: 62

RDMA state:
link mlx5_bond_0/1 state ACTIVE physical_state LINK_UP netdev enp193s0f0np0
link mlx5_bond_1/1 state ACTIVE physical_state LINK_UP netdev enp1s0f0np0

Removing debug pod ...

===== ocp115.localdomain =====
Starting pod/ocp115localdomain-debug-tx2l5 ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
OVS lookup:
bond1 is not attached to OVS

Bond state:
Ethernet Channel Bonding Driver: v5.14.0-687.41.1.el9_8.x86_64

Bonding Mode: IEEE 802.3ad Dynamic link aggregation
Transmit Hash Policy: layer3+4 (1)
MII Status: up
MII Polling Interval (ms): 100
Up Delay (ms): 0
Down Delay (ms): 0
Peer Notification Delay (ms): 0

802.3ad info
LACP active: on
LACP rate: fast
Min links: 0
Aggregator selection policy (ad_select): stable
System priority: 65535
System MAC address: 3c:ec:ef:12:9c:1a
Active Aggregator Info:
        Aggregator ID: 1
        Number of ports: 2
        Actor Key: 29
        Partner Key: 29
        Partner Mac Address: 04:f4:1c:d9:97:be

Slave Interface: enp1s0f0np0
MII Status: up
Speed: 100000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 3c:ec:ef:12:9c:1a
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Churned Count: 0
Partner Churned Count: 0
details actor lacp pdu:
    system priority: 65535
    system mac address: 3c:ec:ef:12:9c:1a
    port key: 29
    port priority: 255
    port number: 1
    port state: 63
details partner lacp pdu:
    system priority: 65535
    system mac address: 04:f4:1c:d9:97:be
    oper key: 29
    port priority: 255
    port number: 2
    port state: 62

Slave Interface: enp1s0f1np1
MII Status: up
Speed: 100000 Mbps
Duplex: full
Link Failure Count: 0
Permanent HW addr: 3c:ec:ef:12:9c:1b
Slave queue ID: 0
Aggregator ID: 1
Actor Churn State: none
Partner Churn State: none
Actor Churned Count: 0
Partner Churned Count: 0
details actor lacp pdu:
    system priority: 65535
    system mac address: 3c:ec:ef:12:9c:1a
    port key: 29
    port priority: 255
    port number: 2
    port state: 63
details partner lacp pdu:
    system priority: 65535
    system mac address: 04:f4:1c:d9:97:be
    oper key: 29
    port priority: 255
    port number: 1
    port state: 62

RDMA state:
link mlx5_bond_0/1 state ACTIVE physical_state LINK_UP netdev enp193s0f0np0
link mlx5_bond_1/1 state ACTIVE physical_state LINK_UP netdev enp1s0f0np0

Removing debug pod ...
```
Verify the RoCE addressing before creating pods (Make sure to use your own correct `bond1` name):
```bash
echo "===== NODE ====="
hostname

echo
echo "===== BOND1 ADDRESS ====="
ip -br addr show bond1

echo
echo "===== BOND1 MTU ====="
ip link show bond1

echo
echo "===== ROUTES USING BOND1 ====="
ip route show dev bond1
```
```bash
===== NODE =====
ocp113.localdomain

===== BOND1 ADDRESS =====
bond1            UP

===== BOND1 MTU =====
14: bond1: <BROADCAST,MULTICAST,MASTER,UP,LOWER_UP> mtu 9100 qdisc noqueue master ovs-system state UP mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:5c:58:30 brd ff:ff:ff:ff:ff:ff

===== ROUTES USING BOND1 =====
```
Check RoCE GID (Everything after `1:` may be `10: cat: /sys/class/infiniband/mlx5_bond_0/ports/1/gid_attrs/types/10: Invalid argument`, make sure to use your own correct `mlx5_bond_1` name):
```bash
echo "===== GID TYPES ====="

for f in /sys/class/infiniband/mlx5_bond_1/ports/1/gid_attrs/types/*; do
    printf "%s: " "$(basename "$f")"
    cat "$f"
done
```
```bash
===== GID TYPES =====
0: IB/RoCE v1
1: RoCE v2
```
Or you can use (Make sure to use your own correct `mlx5_bond_1` name):
```bash
BASE=/sys/class/infiniband/mlx5_bond_1/ports/1

for INDEX in $(seq 0 15); do
    GID=$(cat "$BASE/gids/$INDEX" 2>/dev/null) || continue

    if [ "$GID" = "0000:0000:0000:0000:0000:0000:0000:0000" ]; then
        continue
    fi

    TYPE=$(cat "$BASE/gid_attrs/types/$INDEX" 2>/dev/null || echo unknown)
    NDEV=$(cat "$BASE/gid_attrs/ndevs/$INDEX" 2>/dev/null || echo unknown)

    printf 'index=%s gid=%s type=%s netdev=%s\n' \
      "$INDEX" "$GID" "$TYPE" "$NDEV"
done
```
```bash
index=0 gid=fe80:0000:0000:0000:3eec:efff:fe5c:5830 type=IB/RoCE v1 netdev=bond1
index=1 gid=fe80:0000:0000:0000:3eec:efff:fe5c:5830 type=RoCE v2 netdev=bond1
```
A workload would then request something conceptually like:  
```yaml
resources:
  requests:
    rdma/rdma_shared_device_dx_bond: 1
  limits:
    rdma/rdma_shared_device_dx_bond: 1
```
Validate RoCEv2:
Create a `rdma-test` namespace:
```bash
oc new-project rdma-test
```
Create a `MacvlanNetwork` from the Nvidia Network Operator  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ `exclude` and `range_start` / `range_end`  
- You do not inherently need those exact exclusions. The exclude list is only there to keep Whereabouts from assigning specific addresses that you want reserved for gateways, switches, static hosts, future infrastructure, or other non-pod use.
- For a `172.16.100.0/24` range, that is the broadcast address. This exclusion is redundant, because Whereabouts already excludes the network and broadcast addresses from allocation. The upstream code explicitly describes valid IPs as excluding those two addresses.
- Whereabouts coordinates addresses that it allocates to pods across the cluster. It does not automatically discover every statically configured address already present on your physical network. Therefore, if a router, switch, server, VRRP address, or manually configured device uses `.1`, `.2`, or `.3`, you should explicitly keep those addresses outside the pod allocation pool to avoid duplicate-IP conflicts. Red Hat defines exclude as an optional list of addresses or CIDR ranges that Whereabouts must not assign.
- Whereabouts supports (`range_start` and `range_end`) or (`exclude`) specifically for defining the allocatable portion of a subnet.
- For your current dedicated RDMA network, a clean configuration would likely be (That keeps `.1` through `.9` available for future infrastructure without needing a collection of CIDR exclusions.):
  - ```json
    {
      "type": "whereabouts",
      "range": "172.16.100.0/24",
      "range_start": "172.16.100.10",
      "range_end": "172.16.100.254"
    }
    ```
  - Is the same as (Whereabouts already excludes the /24 broadcast address, 172.16.100.255, so you do not need to list it. A completely explicit version, including the already-unusable broadcast address...):
    ```json
    {
      "type": "whereabouts",
      "range": "172.16.100.0/24",
      "exclude": [
        "172.16.100.0/29",
        "172.16.100.8/31",
        "172.16.100.255/32"
      ]
    }
    ```
    172.16.100.0/29    → 172.16.100.0–172.16.100.7  
    172.16.100.8/31    → 172.16.100.8–172.16.100.9  
    172.16.100.255/32  → 172.16.100.255  
  
[Source: `Sources/rdma-bond.yaml`](Sources/rdma-bond.yaml)
<!-- embed-code: ./Sources/rdma-bond.yaml -->
```yaml
apiVersion: mellanox.com/v1alpha1
kind: MacvlanNetwork
metadata:
  name: rdma-bond
spec:
  networkNamespace: rdma-test
  master: bond1
  mode: bridge
  mtu: 9000
  ipam: |
    {
      "type": "whereabouts",
      "range": "172.16.100.0/24",
      "exclude": [
        "172.16.100.0/30",
        "172.16.100.255/32"
      ]
    }
```
This will automatically create a Network Attachment Definition:
```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  annotations:
    nvidia.network-operator.revision: '3680941807'
  resourceVersion: '1791262'
  name: rdma-bond
  uid: 41e7d552-708d-4855-a33d-9034bd4626bd
  creationTimestamp: '2026-09-09T17:59:07Z'
  generation: 1
  managedFields:
    - apiVersion: k8s.cni.cncf.io/v1
      fieldsType: FieldsV1
      fieldsV1:
        'f:metadata':
          'f:annotations':
            .: {}
            'f:nvidia.network-operator.revision': {}
          'f:labels':
            .: {}
            'f:nvidia.network-operator.state': {}
          'f:ownerReferences':
            .: {}
            'k:{"uid":"d68c0a1b-2145-48eb-866c-599fab86d98f"}': {}
        'f:spec':
          .: {}
          'f:config': {}
      manager: manager
      operation: Update
      time: '2026-09-09T17:59:07Z'
  namespace: rdma-test
  ownerReferences:
    - apiVersion: mellanox.com/v1alpha1
      blockOwnerDeletion: true
      controller: true
      kind: MacvlanNetwork
      name: rdma-bond
      uid: d68c0a1b-2145-48eb-866c-599fab86d98f
  labels:
    nvidia.network-operator.state: state-Macvlan-Network
spec:
  config: '{ "cniVersion":"0.3.1", "name":"rdma-bond", "type":"macvlan","master": "bond1","mode" : "bridge","mtu" : 9000,"ipam":{"type":"whereabouts","range":"172.16.100.0/24"} }'
```

Export a few env vars to make things easier:
```bash
NS=rdma-test
NAD=rdma-bond
NODE113=ocp113.localdomain
NODE115=ocp115.localdomain
```

To Verify two pods from two nodes can ping each other over the `MacvlanNetwork`:
```bash
[root@ocp113 core]# cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: macvlan-ping-113
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/networks: >-
      [{"name":"${NAD}","namespace":"${NS}","interface":"net1"}]
spec:
  serviceAccountName: rdma-test
  nodeSelector:
    kubernetes.io/hostname: ${NODE113}
  restartPolicy: Never
  containers:
    - name: network-tools
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/bash
        - -lc
        - exec sleep infinity
      securityContext:
        capabilities:
          add:
            - NET_RAW
---
apiVersion: v1
kind: Pod
metadata:
  name: macvlan-ping-115
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/networks: >-
      [{"name":"${NAD}","namespace":"${NS}","interface":"net1"}]
spec:
  serviceAccountName: rdma-test
  nodeSelector:
    kubernetes.io/hostname: ${NODE115}
  restartPolicy: Never
  containers:
    - name: network-tools
      image: ${IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/bash
        - -lc
        - exec sleep infinity
      securityContext:
        capabilities:
          add:
            - NET_RAW
EOF
pod/macvlan-ping-113 created
pod/macvlan-ping-115 created
```
```bash
[root@ocp113 core]# for POD in macvlan-ping-113 macvlan-ping-115; do
  echo "===== $POD ====="

  oc exec -n rdma-test "$POD" -- ip -br addr
  oc exec -n rdma-test "$POD" -- ip route

  echo
done
===== macvlan-ping-113 =====
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if1616      UP             10.128.0.54/23 fe80::858:aff:fe80:36/64
net1@if1597      UP             172.16.100.4/24 fd14:231f:7507:c150:d4a2:72ff:fe82:79db/64 fe80::d4a2:72ff:fe82:79db/64
default via 10.128.0.1 dev eth0
10.128.0.0/23 dev eth0 proto kernel scope link src 10.128.0.54
10.128.0.0/14 via 10.128.0.1 dev eth0
100.64.0.0/16 via 10.128.0.1 dev eth0
169.254.0.5 via 10.128.0.1 dev eth0
172.16.100.0/24 dev net1 proto kernel scope link src 172.16.100.4
172.30.0.0/16 via 10.128.0.1 dev eth0

===== macvlan-ping-115 =====
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if462       UP             10.129.1.156/23 fe80::858:aff:fe81:19c/64
net1@if457       UP             172.16.100.5/24 fd14:231f:7507:c150:e0c2:75ff:fea5:89c6/64 fe80::e0c2:75ff:fea5:89c6/64
default via 10.129.0.1 dev eth0
10.128.0.0/14 via 10.129.0.1 dev eth0
10.129.0.0/23 dev eth0 proto kernel scope link src 10.129.1.156
100.64.0.0/16 via 10.129.0.1 dev eth0
169.254.0.5 via 10.129.0.1 dev eth0
172.16.100.0/24 dev net1 proto kernel scope link src 172.16.100.5
172.30.0.0/16 via 10.129.0.1 dev eth0
```
```bash
[root@ocp113 core]# IP113="$(
  oc get pod -n rdma-test macvlan-ping-113 -o json |
    jq -r '
      .metadata.annotations[
        "k8s.v1.cni.cncf.io/network-status"
      ]
      | fromjson
      | .[]
      | select(.interface == "net1")
      | .ips[0]
    '
)"

IP115="$(
  oc get pod -n rdma-test macvlan-ping-115 -o json |
    jq -r '
      .metadata.annotations[
        "k8s.v1.cni.cncf.io/network-status"
      ]
      | fromjson
      | .[]
      | select(.interface == "net1")
      | .ips[0]
    '
)"

echo "ocp113 net1: $IP113"
echo "ocp115 net1: $IP115"
ocp113 net1: 172.16.100.4
ocp115 net1: 172.16.100.5
```
```bash
[root@ocp113 core]# oc exec -n rdma-test macvlan-ping-113 -- \
  ping -4 -I net1 -c 5 -W 2 "$IP115"

oc exec -n rdma-test macvlan-ping-115 -- \
  ping -4 -I net1 -c 5 -W 2 "$IP113"
PING 172.16.100.5 (172.16.100.5) from 172.16.100.4 net1: 56(84) bytes of data.
64 bytes from 172.16.100.5: icmp_seq=1 ttl=64 time=0.362 ms
64 bytes from 172.16.100.5: icmp_seq=2 ttl=64 time=0.180 ms
64 bytes from 172.16.100.5: icmp_seq=3 ttl=64 time=0.158 ms
64 bytes from 172.16.100.5: icmp_seq=4 ttl=64 time=0.179 ms
64 bytes from 172.16.100.5: icmp_seq=5 ttl=64 time=0.166 ms

--- 172.16.100.5 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4113ms
rtt min/avg/max/mdev = 0.158/0.209/0.362/0.076 ms
PING 172.16.100.4 (172.16.100.4) from 172.16.100.5 net1: 56(84) bytes of data.
64 bytes from 172.16.100.4: icmp_seq=1 ttl=64 time=0.160 ms
64 bytes from 172.16.100.4: icmp_seq=2 ttl=64 time=0.152 ms
64 bytes from 172.16.100.4: icmp_seq=3 ttl=64 time=0.157 ms
64 bytes from 172.16.100.4: icmp_seq=4 ttl=64 time=0.156 ms
64 bytes from 172.16.100.4: icmp_seq=5 ttl=64 time=0.182 ms

--- 172.16.100.4 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4099ms
rtt min/avg/max/mdev = 0.152/0.161/0.182/0.010 ms
```
Test the 9000-byte path:
```bash
[root@ocp113 core]# oc exec -n rdma-test macvlan-ping-113 -- \
  ping -4 -I net1 -M do -s 8972 -c 5 -W 2 "$IP115"

oc exec -n rdma-test macvlan-ping-115 -- \
  ping -4 -I net1 -M do -s 8972 -c 5 -W 2 "$IP113"
PING 172.16.100.5 (172.16.100.5) from 172.16.100.4 net1: 8972(9000) bytes of data.
8980 bytes from 172.16.100.5: icmp_seq=1 ttl=64 time=0.167 ms
8980 bytes from 172.16.100.5: icmp_seq=2 ttl=64 time=0.191 ms
8980 bytes from 172.16.100.5: icmp_seq=3 ttl=64 time=0.182 ms
8980 bytes from 172.16.100.5: icmp_seq=4 ttl=64 time=0.179 ms
8980 bytes from 172.16.100.5: icmp_seq=5 ttl=64 time=0.188 ms

--- 172.16.100.5 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4133ms
rtt min/avg/max/mdev = 0.167/0.181/0.191/0.008 ms
PING 172.16.100.4 (172.16.100.4) from 172.16.100.5 net1: 8972(9000) bytes of data.
8980 bytes from 172.16.100.4: icmp_seq=1 ttl=64 time=0.185 ms
8980 bytes from 172.16.100.4: icmp_seq=2 ttl=64 time=0.198 ms
8980 bytes from 172.16.100.4: icmp_seq=3 ttl=64 time=0.176 ms
8980 bytes from 172.16.100.4: icmp_seq=4 ttl=64 time=0.181 ms
8980 bytes from 172.16.100.4: icmp_seq=5 ttl=64 time=0.212 ms

--- 172.16.100.4 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4111ms
rtt min/avg/max/mdev = 0.176/0.190/0.212/0.013 ms
```
```bash
[root@ocp113 core]# oc delete pod macvlan-ping-113 macvlan-ping-115 -n rdma-test --ignore-not-found
pod "macvlan-ping-113" deleted from rdma-test namespace
pod "macvlan-ping-115" deleted from rdma-test namespace
```
$${\color{yellow}CRITICAL:}$$ If you want to set up RocE / GPUDirect, go to the `Performance` section of this cheat sheet!