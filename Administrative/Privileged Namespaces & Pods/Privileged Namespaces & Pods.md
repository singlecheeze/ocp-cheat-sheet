NVIDIA's GPUDirect test container requests IPC_LOCK / NET_RAW
- The below is pretty much applicable for any type of privileged namespace or pod
- OpenShift 4.22's normal restricted-v2 SCC does not permit that capability, so for this temporary diagnostic only, the easiest option is a dedicated service account with access to the privileged SCC.
  
Create a namespace if needed:  
```bash
oc new-project rdma-test
```
Create a dedicated service account:  
```bash
oc create serviceaccount doca-gpudirect -n rdma-test 
```

<blockquote><details><summary>Option #1:</summary>

```bash
[root@ocp113 core]# oc adm policy add-scc-to-user privileged -z doca-gpudirect -n rdma-test
clusterrole.rbac.authorization.k8s.io/system:openshift:scc:privileged added: "doca-gpudirect"
```
Another way to accomplish the same, but less secure:
```bash
# 1. Lift Pod Security restrictions for this project
oc label namespace rdma-test pod-security.kubernetes.io/enforce=privileged --overwrite
oc label namespace rdma-test pod-security.kubernetes.io/warn=privileged --overwrite

# 2. Grant the default service account permission to run privileged containers
oc adm policy add-scc-to-user privileged -z default -n rdma-test
```
</details> 
</blockquote>
<blockquote><details><summary>Option #2:</summary>

Red Hat recommends creating a custom SCC rather than modifying default SCCs for longer-lived workloads.  
  
Create a narrow test SCC:
- The test requires `IPC_LOCK`. Adding `NET_RAW` also lets you perform ICMP checks from these same pods. 
- Rather than grant the broad privileged SCC, create a test-specific SCC that denies host access and privileged containers while permitting only those capabilities. 
- OpenShift SCCs explicitly control allowed capabilities, UID strategies, privilege escalation, and host access.  
[Source: `Sources/doca-gpudirect-test.yaml`](Sources/doca-gpudirect-test.yaml)  
<!-- embed-code: ./Sources/doca-gpudirect-test.yaml -->
```yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: doca-gpudirect-test
priority: 10

allowPrivilegedContainer: false
allowPrivilegeEscalation: false
defaultAllowPrivilegeEscalation: false

allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false

readOnlyRootFilesystem: false

allowedCapabilities:
  - IPC_LOCK
    - NET_RAW

defaultAddCapabilities: []

requiredDropCapabilities:
  - ALL

runAsUser:
  type: RunAsAny

seLinuxContext:
  type: MustRunAs

fsGroup:
  type: RunAsAny

supplementalGroups:
  type: RunAsAny

seccompProfiles:
  - runtime/default

volumes:
  - configMap
  - downwardAPI
  - emptyDir
  - projected
  - secret
```
Grant it to the dedicated service account:
```bash
oc adm policy add-scc-to-user \
  doca-gpudirect-test \
  -z doca-gpudirect \
  -n rdma-test
```
Verify:
```bash
oc auth can-i use scc/doca-gpudirect-test --as=system:serviceaccount:rdma-test:doca-gpudirect
```
Expected:
```bash
yes
```
</details> 
</blockquote>