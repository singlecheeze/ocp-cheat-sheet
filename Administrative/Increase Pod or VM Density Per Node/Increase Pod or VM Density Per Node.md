To check current setting:
```text
[root@ocp113 core]# oc describe node ocp113.localdomain | grep -A20 Allocatable
Allocatable:
  cpu:                            127500m
  devices.kubevirt.io/kvm:        1k
  devices.kubevirt.io/tun:        1k
  devices.kubevirt.io/vhost-net:  1k
  ephemeral-storage:              430475296464
  hugepages-1Gi:                  0
  hugepages-2Mi:                  0
  memory:                         130396328Ki
  nvidia.com/gpu:                 1
  pods:                           250
  rdma/rdma_shared_device_a:      63
```
To set `maxPods` (Swap `master` for `worker` if needed, see Machine Config Pool Ownership):  
[Source: `Sources/99-set-master-max-pods.yaml`](Sources/99-set-master-max-pods.yaml)  
<!-- embed-code: ./Sources/99-set-master-max-pods.yaml -->  
```yaml
```
Then check nodes after reboots:
```text
oc get node -l node-role.kubernetes.io/master -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.pods}{"\n"}{end}'
```
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ Increasing maxPods beyond the available IP addresses in a node's pod subnet will cause Pods to fail with network allocation errors.  
  
/24 subnet: Assigns ~254 IPs per node  
/23 subnet (OpenShift Default): Assigns ~510 IPs per node  
  
Check your cluster's network hostPrefix setting:  
```text
oc get network.operator.openshift.io cluster -o jsonpath='{.spec.clusterNetwork}'

[{"cidr":"10.128.0.0/14","hostPrefix":23}]
```