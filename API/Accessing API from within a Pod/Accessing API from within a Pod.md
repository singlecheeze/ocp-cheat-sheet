To read from the OCP cluster API from within a debug pod (Similar if a non-debug pod):
[Source: `Sources/read-cluster-id.yaml`](Sources/read-cluster-id.yaml)
<!-- embed-code: ./Sources/read-cluster-id.yaml -->
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: read-cluster-id
rules:
  - verbs:
      - get
    apiGroups:
      - config.openshift.io
    resources:
      - clusterversions
      - infrastructures
    resourceNames:
      - version
      - cluster
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: read-cluster-id
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: read-cluster-id
subjects:
  - kind: ServiceAccount
    name: default  #<-- or my-service-account if non debug pod
    namespace: default  #<-- or my-namespace if non debug pod
```
`oc debug node/` uses `hostNetwork: true`. Kubernetes documents that a `hostNetwork` pod with `dnsPolicy: ClusterFirst` falls back to the node's DNS behavior; cluster-service names such as `kubernetes.default.svc` may therefore not resolve. `ClusterFirstWithHostNet` is the policy intended for cluster DNS from host-networked pods.

Also, if you've already done:
```bash
chroot /host
```
Exit back out first:
```bash
exit
```
Because `/var/run/secrets/kubernetes.io/serviceaccount/` is mounted into the debug container, not necessarily the host filesystem you see after `chroot /host`. Red Hat documents that `oc debug node` mounts the host at /host and recommends `chroot /host` specifically when you want the node's filesystem/binaries.
  
The easiest workaround is to skip DNS entirely and use the Kubernetes service IP that kubelet injects into the pod:
```bash
sh-5.1# env | grep KUBERNETES_SERVICE
KUBERNETES_SERVICE_PORT_HTTPS=443
KUBERNETES_SERVICE_PORT=443
KUBERNETES_SERVICE_HOST=172.30.0.1
```
Kubernetes specifically injects these control-plane service variables into pods.
  
OpenShift describes `infrastructureName` as a human-friendly identifier that uniquely identifies the cluster, while `apiServerURL` gives its API endpoint:
```bash
API="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  "${API}/apis/config.openshift.io/v1/infrastructures/cluster"

# Infrastructure name
curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  "${API}/apis/config.openshift.io/v1/infrastructures/cluster" \
  | jq -r '.status.infrastructureName'

# API server URL
curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  "${API}/apis/config.openshift.io/v1/infrastructures/cluster" \
  | jq -r '.status.apiServerURL'

# Platform type
curl -sk \
  -H "Authorization: Bearer ${TOKEN}" \
  "${API}/apis/config.openshift.io/v1/infrastructures/cluster" \
  | jq -r '.status.platformStatus.type'
```