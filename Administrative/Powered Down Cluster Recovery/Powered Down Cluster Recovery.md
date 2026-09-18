SSH into a node (You did set up SSH Keys at install time right?)
```bash
[core@ocp113 ~]$ sudo su

[root@ocp113 core]# export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig

[root@ocp113 core]# oc get nodes
NAME                   STATUS   ROLES                         AGE   VERSION
ocp113.localdomain   Ready    control-plane,master,worker   71d   v1.30.7
ocp114.localdomain   Ready    control-plane,master,worker   71d   v1.30.7
ocp115.localdomain   Ready    control-plane,master,worker   71d   v1.30.7

[root@ocp113 core]# oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve
certificatesigningrequest.certificates.k8s.io/csr-22cfp approved
certificatesigningrequest.certificates.k8s.io/csr-25nln approved
certificatesigningrequest.certificates.k8s.io/csr-26ggg approved

[root@ocp113 core]# oc get csr
NAME        AGE     SIGNERNAME                                    REQUESTOR                                                                   REQUESTEDDURATION   CONDITION
csr-22cfp   3h31m   kubernetes.io/kube-apiserver-client-kubelet   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   <none>              Approved,Issued
csr-25nln   3h57m   kubernetes.io/kube-apiserver-client-kubelet   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   <none>              Approved,Issued
csr-26ggg   4h49m   kubernetes.io/kube-apiserver-client-kubelet   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   <none>              Approved,Issued

[root@ocp113 core]# oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve
certificatesigningrequest.certificates.k8s.io/csr-8wlqq approved
certificatesigningrequest.certificates.k8s.io/csr-gpq86 approved
certificatesigningrequest.certificates.k8s.io/csr-mkk9r approved

[root@ocp113 core]# oc get nodes
NAME                   STATUS     ROLES                         AGE   VERSION
ocp113.localdomain   NotReady   control-plane,master,worker   71d   v1.30.7
ocp114.localdomain   NotReady   control-plane,master,worker   71d   v1.30.7
ocp115.localdomain   NotReady   control-plane,master,worker   71d   v1.30.7

[root@ocp113 core]# oc get nodes
NAME                   STATUS   ROLES                         AGE   VERSION
ocp113.localdomain   Ready    control-plane,master,worker   71d   v1.30.7
ocp114.localdomain   Ready    control-plane,master,worker   71d   v1.30.7
ocp115.localdomain   Ready    control-plane,master,worker   71d   v1.30.7
```
If you need to recover `kubeadmin` password once you're logged into the cluster with the kubeconfig:
```bash
oc get secret kubeadmin -n kube-system -o jsonpath='{.data.kubeadmin-password}' | base64 --decode 
```