```text
oc patch -n openshift-cnv hyperconvergeds.v1beta1.hco.kubevirt.io kubevirt-hyperconverged --type=json -p='[{"op": "add", "path": "/spec/tuningPolicy", "value": "highBurst"}]'
```