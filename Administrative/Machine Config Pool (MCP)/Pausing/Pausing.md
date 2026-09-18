Setting `spec.paused: true` on the MachineConfigPool
- While paused, the MCO does not roll the nodes in that pool. 
- You can apply multiple MachineConfig resources, then unpause the pool and let the MCO converge the nodes to the combined configuration. 
- Red Hat explicitly documents this as a way to accumulate configuration changes and apply them in a single reboot per node.
  
For example, for the master pool:
```bash
MCP=master

# Pause the pool BEFORE applying MachineConfigs
oc patch mcp "${MCP}" \
  --type=merge \
  -p '{"spec":{"paused":true}}'

# Verify
oc get mcp "${MCP}" \
  -o jsonpath='{.spec.paused}{"\n"}'
```
You should get:
```text
true
```
Now apply all of the MachineConfigs you want:
```bash
oc apply -f 50-master-rdma.yaml
oc apply -f 51-master-iommu.yaml
oc apply -f 52-master-kernel-args.yaml
oc apply -f 53-master-sysctl.yaml
```
Or, if they're all in one directory:
```bash
oc apply -f ./machineconfigs/
```
While the MCP is paused:
```bash
oc get mcp
```
You'll typically see something along these lines:
```bash
NAME     CONFIG                          UPDATED   UPDATING   DEGRADED
master   rendered-master-xxxxxxxxxxxx    False     False      False
```
`UPDATED=False` + `UPDATING=Fals`e on a paused pool indicates that there are pending changes, but the MCO is not rolling them out. Red Hat specifically describes that state as pending configuration on a paused MCP.
  
Once all your MachineConfigs are in place, unpause:
```bash
oc patch mcp "${MCP}" \
  --type=merge \
  -p '{"spec":{"paused":false}}'
```
Then watch it:
```bash
watch oc get mcp "${MCP}"
```
Or:
```bash
oc get mcp "${MCP}" -w
```
The important part is what happens next. 
- The MCO merges the applicable `MachineConfig` objects into the pool's rendered configuration and updates each node toward that combined state. 
- MachineConfigs are processed lexicographically by name and combined into a `rendered-<pool>-...` MachineConfig. 
  
So instead of:
```text
MC #1
  ↓
node1 reboot
node2 reboot
node3 reboot

MC #2
  ↓
node1 reboot
node2 reboot
node3 reboot

MC #3
  ↓
node1 reboot
node2 reboot
node3 reboot
```
You can do:
```text
Pause MCP
    ↓
MC #1
MC #2
MC #3
MC #4
    ↓
Unpause MCP
    ↓
one combined rendered MachineConfig
    ↓
node1 reboot
node2 reboot
node3 reboot
```
Assuming those changes actually require a reboot. 
  
OpenShift 4.22 also has `NodeDisruptionPolicy`, so some types of changes can be applied via service restart/reload or with no disruption instead of rebooting. But if any portion of the combined change requires a reboot, that reboot supersedes the less-disruptive actions.
  
One other useful detail: Don't try to accomplish this by setting `maxUnavailable: 0`. The 4.22 MCP API specifically says 0 cannot be used to stop updates—it defaults back to 1; paused is the supported mechanism.
  
For the changes I've been making, I can use this pattern:
```bash
MCP=master

echo "Pausing ${MCP}..."
oc patch mcp "${MCP}" \
  --type=merge \
  -p '{"spec":{"paused":true}}'

echo "Applying MachineConfigs..."
oc apply -f 50-iommu.yaml
oc apply -f 51-rdma.yaml
oc apply -f 52-nvidia.yaml
oc apply -f 53-other-node-config.yaml

echo
echo "MCP state:"
oc get mcp "${MCP}"

echo
echo "MachineConfigs:"
oc get mc

echo
echo "Ready to unpause."
```
Then, after verifying everything:
```bash
oc patch mcp master \
  --type=merge \
  -p '{"spec":{"paused":false}}'

oc get mcp master -w
```
That is much preferable when you're iterating through several low-level node settings, because otherwise each MachineConfig you apply can produce a new rendered configuration while the previous rollout is still progressing, potentially resulting in additional node updates. Red Hat's 4.22 documentation explicitly recommends pausing when applying multiple additional configurations so they can be applied together.