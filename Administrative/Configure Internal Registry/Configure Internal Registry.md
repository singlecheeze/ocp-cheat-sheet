Ref: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/registry/setting-up-and-configuring-the-registry#configuring-registry-storage-baremetal  
  
[Source: `Sources/odf-image-registry-pvc.yaml`](Sources/odf-image-registry-pvc.yaml)
<!-- embed-code: ./Sources/odf-image-registry-pvc.yaml -->
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odf-image-registry-pvc
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: ocs-storagecluster-cephfs
```
```text
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge --patch '{"spec":{"defaultRoute":true}}' 
oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"pvc":{"claim":"odf-image-registry-pvc"}}}}'
```

```text
oc get clusteroperator image-registry
```
Edit default route to disable TLS and map port 5000 (Allow insecure):  
   <img width="848" height="861" alt="image" src="https://gist.github.com/user-attachments/assets/145dbb1f-8afa-4c61-9e0a-5541c427134f" />
