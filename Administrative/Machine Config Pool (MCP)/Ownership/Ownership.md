For compact clusters, nodes that are workers will often hold a `master` role if there is a minimum node count:
```bash
oc get mcp -o custom-columns='NAME:.metadata.name,MACHINES:.status.machineCount,READY:.status.readyMachineCount,UPDATED:.status.updatedMachineCount'
  NAME     MACHINES   READY   UPDATED
master   3          3       3
worker   0          0       0
```