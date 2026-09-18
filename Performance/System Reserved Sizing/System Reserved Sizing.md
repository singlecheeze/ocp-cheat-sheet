### System Reserved Resource Sizing:
Warnings like the below and easily be resolved by allowing OpenShift to size the right amount of system resources for the size of cluster it is:
```text
System Memory Exceeds Reservation
Severity: Warning
Description: System memory usage of 1.12G on Node ocp113.localdomain exceeds 95% of the reservation. Reserved memory ensures system processes can function even when the node is fully allocated and protects against workload out of memory events impacting the proper functioning of the node. The default reservation is expected to be sufficient for most configurations and should be increased (https://docs.openshift.com/container-platform/latest/nodes/nodes/nodes-nodes-managing.html) when running nodes with high numbers of pods (either due to rate of change or at steady state).
Summary: Alerts the user when, for 15 minutes, a specific node is using more memory than is reserved
```
`1.12G` triggering the alert strongly suggests the effective reservation is still only around the default ~1 GiB range. On OpenShift 4.22, I would use automatic system-reserved sizing rather than arbitrarily changing it to 2 GiB or 4 GiB. OpenShift 4.22 calculates an appropriate reservation based on installed memory and CPU.

To see what ocp113 is actually reserving run:
```bash
oc debug node/ocp113.localdomain -- chroot /host bash -c '
echo "=== CURRENT NODE SIZING ==="
cat /etc/node-sizing.env

echo
echo "=== SYSTEM.SLICE MEMORY ==="
systemctl show system.slice -p MemoryCurrent

echo
echo "=== HOST MEMORY ==="
free -h
'
```
```text
Starting pod/ocp113localdomain-debug-5s2m8 ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
=== CURRENT NODE SIZING ===
SYSTEM_RESERVED_MEMORY=1Gi
SYSTEM_RESERVED_CPU=500m
SYSTEM_RESERVED_ES=1Gi

=== SYSTEM.SLICE MEMORY ===
MemoryCurrent=6366224384

=== HOST MEMORY ===
               total        used        free      shared  buff/cache   available
Mem:           125Gi        42Gi        49Gi       311Mi        35Gi        83Gi
Swap:             0B          0B          0B

Removing debug pod ...
```
I'm particularly interested in:
```text
SYSTEM_RESERVED_MEMORY=...
SYSTEM_RESERVED_CPU=...
```
If you see something like:
```text
SYSTEM_RESERVED_MEMORY=1Gi
SYSTEM_RESERVED_CPU=500m
```
That's almost certainly the reason for the alert.
  
You can also preview what OpenShift's own sizing algorithm would choose without changing anything:
```bash
oc debug node/ocp113.localdomain -- chroot /host bash -c '
NODE_SIZES_ENV=/tmp/node-sizing.preview \
  /usr/local/sbin/dynamic-system-reserved-calc.sh true

cat /tmp/node-sizing.preview
rm -f /tmp/node-sizing.preview
'
```
```text
Starting pod/ocp113localdomain-debug-tj9pv ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
SYSTEM_RESERVED_MEMORY=8Gi
SYSTEM_RESERVED_CPU=1.58
SYSTEM_RESERVED_ES=1Gi

Removing debug pod ...
```
#### Check your existing KubeletConfig objects

Before creating anything:
```bash
oc get kubeletconfig
```
And:
```bash
oc get kubeletconfig -o yaml
```
Look for anything already targeting:
```text
pools.operator.machineconfiguration.openshift.io/master: ""
```
Or anything setting:
```text
systemReserved:
```
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ Red Hat recommends modifying an existing KubeletConfig for a pool rather than accumulating multiple KubeletConfig resources for the same pool.
  
Because ocp113 in the cluster you've shown me is a control-plane,master,worker node, I would target the master MCP, not just the worker MCP.
   
If you do not already have a KubeletConfig targeting master, I'd use this:
[Source: `auto-sizing-master.yaml`](./auto-sizing-master.yaml)
<!-- embed-code: ./auto-sizing-master.yaml -->
```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: auto-sizing-master
spec:
  autoSizingReserved: true
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
```
`autoSizingReserved` is specifically intended to calculate the CPU and memory reservation based on each node's capacity, and it can be applied to master/control-plane pools as well as workers.
  
#### Be aware that this rolls the nodes
A KubeletConfig becomes a MachineConfig change. The MCO normally drains, applies the configuration, and reboots affected nodes.

Before applying it, check:
```bash
oc get mcp master
```
And:
```bash
oc get mcp master -o jsonpath='{.spec.paused}{"\n"}'
```
You want the cluster healthy first:
```bash
oc get co
oc get nodes
```
Then watch the rollout:
```bash
oc get mcp master -w
```
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ If you've intentionally paused the master MCP, the configuration will render but will not actually reach the nodes until you unpause it.

#### Verify after the node returns
After ocp113 has rebooted:
```bash
oc debug node/ocp113.localdomain -- chroot /host cat /etc/node-sizing.env
```
You should now see a larger value, for example:
```text
SYSTEM_RESERVED_MEMORY=8Gi
SYSTEM_RESERVED_CPU=1.58
SYSTEM_RESERVED_ES=1Gi
```
The actual value depends on the RAM and CPU count. OpenShift 4.22 uses this memory formula:
* 25% of the first 4 GiB
* 20% of the next 4 GiB
* 10% of the next 8 GiB
* 6% from 16–128 GiB
* 2% above 128 GiB

So a large GPU server should generally have far more than 1 GiB reserved for host/system processes.