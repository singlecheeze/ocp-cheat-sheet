The below will run a script every five minutes to auto-approve CSRs for clusters that are powered down for more than one week.  
  
Ref: https://medium.com/@tamber/automating-kubernetes-certificate-approval-with-machineconfig-and-systemd-timers-on-openshift-4-x-45c9e23084e7  
  
Butane File:  
[Source: `Sources/99-master-certificate-approve-systemd-service.bu`](Sources/99-master-certificate-approve-systemd-service.bu)  
<!-- embed-code: ./Sources/99-master-certificate-approve-systemd-service.bu -->
```yaml
```
Resulting MachineConfig:  
[Source: `Sources/99-master-certificate-approve-systemd-service.yaml`](Sources/99-master-certificate-approve-systemd-service.yaml)  
<!-- embed-code: ./Sources/99-master-certificate-approve-systemd-service.yaml -->
```yaml
```
SSH to one of the masters, make sure the service and timer are enabled & activated:  
```bash
[Bastion]$ oc get nodes
# ---- OUTPUT ----
# NAME   STATUS   ROLES                                                        
# XXXX   Ready    master                                          
# XXXX   Ready    master
# XXXX   Ready    master
# YYYY   Ready    worker             
# YYYY   Ready    worker             
# YYYY   Ready    worker 

[Bastion]$ oc apply -f master-certificate-approve-systemd-service.yaml

[Bastion]$ oc get mcp
# ---- OUTPUT ----
# NAME                                                         UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT
# machineconfigpool.machineconfiguration.openshift.io/master   False     True       False      3              0                   0                     0                    
# machineconfigpool.machineconfiguration.openshift.io/worker   True      False      False      3              3                   3                     0                    
 

# Once all master nodes are updated:
[Bastion]$ oc get mcp
# ---- OUTPUT ----
# NAME                                                         UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT
# machineconfigpool.machineconfiguration.openshift.io/master   True      False      False      3              3                   3                     0                    
# machineconfigpool.machineconfiguration.openshift.io/worker   True      False      False      3              3                   3                     0

[Bastion]$ sudo ssh core@XXXX #Master Node

[Master]$ sudo systemctl status csr-approve.service
# ---- OUTPUT ----
#  ● csr-approve.service - This script approves pending certificates
#    Loaded: loaded (/etc/systemd/system/csr-approve.service; enabled; vendor preset: disabled)
#    Active: inactive (dead) since Wed 2023-08-09 11:30:01 UTC; 2min 48s ago
#   Process: 32160 ExecStart=/etc/scripts/csr-approve.sh (code=exited, status=0/SUCCESS)
#   Main PID: 32160 (code=exited, status=0/SUCCESS)
#        CPU: 205ms
#   systemd[1]: Started This script approves pending certificates.
#   systemd[1]: csr-approve.service: Succeeded.
#   systemd[1]: csr-approve.service: Consumed 205ms CPU time

[Master]$ sudo systemctl status csr-approve.timer
# ---- OUTPUT ----
# ● csr-approve.timer - Run csr-approve.service every 5 minutes
#    Loaded: loaded (/etc/systemd/system/csr-approve.timer; enabled; vendor preset: disabled)
#    Active: active (waiting) since Wed 2023-08-09 11:20:41 UTC; 12min ago
#    Trigger: Wed 2023-08-09 11:35:00 UTC; 2min 3s left
#    systemd[1]: Started Run csr-approve.service every 5 minutes.
```
See that the executable script is also present on the machine:  
```bash
$ cat /etc/scripts/csr-approve.sh
#!/bin/bash
export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs --no-run-if-empty oc adm certificate approve 2>&1
```
Test by creating a dummy certificate request that will be automatically approved by the service running on the master nodes (Don't forget to delete after!):  
```bash
mkdir /tmp/testuser

openssl req -new -nodes -subj "/CN=testuser" -keyout /tmp/testuser/private.key -out /tmp/testuser/request.csr

cat <<EOF | oc apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: testuser-csr
spec:
  signerName: "kubernetes.io/kube-apiserver-client"
  request: $(cat /tmp/testuser/request.csr | base64 | tr -d '\n')
  usages:
    - digital signature
    - key encipherment
    - client auth
  extra:
    scopes.authorization.openshift.io:
      - user:full
EOF

oc get csr testuser-csr
# ---- OUTPUT ----
# NAME           SIGNERNAME                           CONDITION
# testuser-csr   kubernetes.io/kube-apiserver-client  Pending


# ------- After a few minutes (Max 5min until the timer + service are activated) -------

oc get csr testuser-csr
# ---- OUTPUT ----
# NAME           SIGNERNAME                           CONDITION
# testuser-csr   kubernetes.io/kube-apiserver-client  Approved,Issued
```