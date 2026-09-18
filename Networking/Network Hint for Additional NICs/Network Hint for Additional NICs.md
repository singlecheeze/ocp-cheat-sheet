In OpenShift 4, etcd and kubelet rely on the node's primary internal IP address (the IP reported in oc get nodes -o wide). When you plug in a new physical network interface card (NIC), NetworkManager or kernel routing might inadvertently assign a new default route or lower route metric to the new interface. This can trick OpenShift into switching its primary node IP to the new NIC, breaking etcd cluster quorum.  To solve this, OpenShift 4 uses a built-in mechanism called NODEIP_HINT. By delivering a hint configuration file to your nodes using a MachineConfig, you instruct the nodeip-configuration.service to always pick the NIC connected to your preferred subnet/gateway for kubelet and etcd.  
  
The `nodeip-configuration.service` on Red Hat Enterprise Linux CoreOS (RHCOS) reads `/etc/default/nodeip-configuration`.  
  
Important Rule: Do not set the hint to a specific node's IP address (e.g., 172.16.1.115), because a single MachineConfig applies to all nodes in a MachineConfigPool. Instead, set NODEIP_HINT to an IP address within the target subnet—such as the default gateway IP (e.g., 172.16.1.1). The service will inspect the host's NICs and select the interface whose IP address falls into that gateway's subnet.  

To hint that the control plane should use the `172.16.1.1` subnet:
```text
[root@ocp113 core]# echo -n "NODEIP_HINT=172.16.1.1" | base64
Tk9ERUlQX0hJTlQ9MTcyLjE2LjEuMQ==
```
[Source: `Sources/99-master-nodeip-hint.yaml`](Sources/99-master-nodeip-hint.yaml)
<!-- embed-code: ./Sources/99-master-nodeip-hint.yaml -->
```yaml
```