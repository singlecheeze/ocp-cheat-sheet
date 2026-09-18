If the NodePort service is disabled. Ask your cluster admin to enable it in cluster settings:
```text
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=json -p='[{"op": "add", "path": "/spec/permitNodePortAllocation", "value": true}]'
```