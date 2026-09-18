$${\color{deeppink}\textbf{\textsf{Note:}}}$$ Mostly Deprecated  
$${\color{lime}\textbf{\textsf{TODO:}}}$$ Some of the below is deprecated!  
Ref: https://access.redhat.com/documentation/en-us/migration_toolkit_for_virtualization/2.2/html/installing_and_using_the_migration_toolkit_for_virtualization/prerequisites#creating-vddk-image_mtv   
Ref: https://access.redhat.com/documentation/en-us/migration_toolkit_for_virtualization/2.3/html/installing_and_using_the_migration_toolkit_for_virtualization/migrating-vms-web-console#adding-source-provider_vmware  

Download latest VDDK here:  
https://developer.vmware.com/web/sdk/7.0/vddk  

Upload VDDK:
```text
mkdir /tmp/vddk && cd /tmp/vddk

tar -xzf VMware-vix-disklib-7.0.3-20134304.x86_64.tar.gz

cat > Dockerfile <<EOF
FROM registry.access.redhat.com/ubi8/ubi-minimal
COPY vmware-vix-disklib-distrib /vmware-vix-disklib-distrib
RUN mkdir -p /opt
ENTRYPOINT ["cp", "-r", "/vmware-vix-disklib-distrib", "/opt"]
EOF

podman build . -t default-route-openshift-image-registry.apps.ocp4.localdomain:5000/percap/vddk:7032

podman login default-route-openshift-image-registry.apps.ocp4.localdomain:5000 -u dave -p $(oc whoami -t) --tls-verify=false

podman push default-route-openshift-image-registry.apps.ocp4.localdomain:5000/percap/vddk:7032 --tls-verify=false
```
More info depending on registry settings:  
```text
[dave@lenovo ~]$ podman login default-route-openshift-image-registry.apps.ocp4.localdomain -u dave -p $(oc whoami -t)  --tls-verify=false
Login Succeeded!
[dave@lenovo ~]$ podman push default-route-openshift-image-registry.apps.ocp4.localdomain/percap/vddk:7032 --tls-verify=false
Getting image source signatures
Copying blob 85461b6812d9 skipped: already exists  
Copying blob ac278321f2bd skipped: already exists  
Copying blob 59436ac4ccff skipped: already exists  
Copying blob 47ccc79d22f2 skipped: already exists  
Copying config d3ecdad3a8 done  
Writing manifest to image destination
Storing signatures
```
WHEN DOING MIGRATIONS:
Use the registry service in the Migration Toolkit for Virtualization Operator provider:  
`image-registry.openshift-image-registry.svc.cluster.local:5000/percap/vddk:7032`  
  
Installing QEMU Guest Agent:
```text
sudo dnf install qemu-guest-agent
sudo apt install qemu-guest-agent
```
Installing krew for virtctl:  
```text 
[dave@lenovo ~]$ sudo dnf install kubernetes-client

(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)

[dave@lenovo ~]$ nano .bashrc
Append: export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

[dave@lenovo ~]$ source .bashrc

[dave@lenovo ~]$ kubectl krew install virt
```
To create services for VMs:  
Ref: https://gist.github.com/singlecheeze/d9110b676f4372b698b7b4b952350a2a  
Ref: https://www.opensourcerers.org/2020/11/30/first-steps-with-openshift-virtualization/  
Ref: https://kubevirt.io/user-guide/network/service_objects/   

Edit VM labels:  
[Source: `Sources/postgres.yaml`](Sources/postgres.yaml)
<!-- embed-code: ./Sources/postgres.yaml -->
```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: postgres
  namespace: percap
spec:
  running: false
  template:
    metadata:
      labels:
        internalService: svc-postgres-clusterip
  domain:
    devices:
      interfaces:
        - macAddress: '00:50:56:81:35:dd'
          masquerade: {}
          model: virtio
          name: net-0
          ports:
            - port: 5432
  networks:
    - name: net-0
      pod: {}
```
And a Service to match (ClusterIP or NodePort):  
[Source: `Sources/svc-postgres-clusterip.yaml`](Sources/svc-postgres-clusterip.yaml)
<!-- embed-code: ./Sources/svc-postgres-clusterip.yaml -->
```yaml
apiVersion: v1
kind: Service
metadata:
  name: svc-postgres-clusterip
  namespace: percap
spec:
  ports:
  - protocol: TCP
    port: 5432
    targetPort: 5432
  selector:
    internalService: svc-postgres-clusterip
  type: ClusterIP
```
[Source: `Sources/svc-postgres-nodeport.yaml`](Sources/svc-postgres-nodeport.yaml)
<!-- embed-code: ./Sources/svc-postgres-nodeport.yaml -->
```yaml
apiVersion: v1
kind: Service
metadata:
  name: svc-postgres-nodeport
  namespace: percap
spec:
  ports:
  - protocol: TCP
    port: 5432
    targetPort: 5432
    nodePort: 30000
  selector:
    externalService: svc-postgres-nodeport
  type: NodePort
```
Or do via command line:
```text
[dave@lenovo ~]$ oc virt expose vm postgres --port=5432 --target-port=5432  --node-port=30000 --name=svc-postgres-nodeport --type=NodePort`
```