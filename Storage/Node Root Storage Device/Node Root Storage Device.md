You can verify what the running node considers its root storage with:  
```bash
oc debug node/<node>
chroot /host

findmnt 
lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,WWN,HCTL,MOUNTPOINTS
multipath -ll
```
For example:
```bash
oc get nodes
oc debug node/ocp135.localdomain
Starting pod/ocp135localdomain-debug-p6rnm ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
Pod IP: 172.16.1.135
All commands and output from this session will be recorded in container logs, including credentials and sensitive information passed through the command prompt.
If you don't see a command prompt, try pressing enter.
sh-5.1# chroot /host
sh-5.1# findmnt /
TARGET SOURCE    FSTYPE  OPTIONS
/      composefs overlay ro,relatime,seclabel,lowerdir+=/run/ostree/.private/cfsroot-lower,datadir+=/sysroot/ostree/repo/objects,redirect_dir=on,metacopy=o
sh-5.1# lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,WWN,HCTL,MOUNTPOINTS
NAME   TYPE   SIZE MODEL        SERIAL                           WWN                                HCTL       MOUNTPOINTS
loop0  loop   6.1M
sda    disk   500G Virtual disk 6000c2902ed066d87a2c241ef52f64b5 0x6000c2902ed066d87a2c241ef52f64b5 0:0:0:0
|-sda1 part     1M                                               0x6000c2902ed066d87a2c241ef52f64b5
|-sda2 part   127M                                               0x6000c2902ed066d87a2c241ef52f64b5
|-sda3 part   384M                                               0x6000c2902ed066d87a2c241ef52f64b5            /boot
`-sda4 part 499.5G                                               0x6000c2902ed066d87a2c241ef52f64b5            /var
                                                                                                               /sysroot/ostree/deploy/rhcos/var
                                                                                                               /sysroot
                                                                                                               /etc
sh-5.1# multipath -ll
92116.652114 | /etc/multipath.conf does not exist, blacklisting all devices.
92116.652129 | You can run "/sbin/mpathconf --enable" to create
92116.652131 | /etc/multipath.conf. See man mpathconf(8) for more details
92116.655564 | DM multipath kernel driver not loaded
```
In OpenShift, rootDeviceHints is primarily a field on the BareMetalHost CRD from Metal³:
```yaml
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: worker-0
  namespace: openshift-machine-api
spec:
  rootDeviceHints:
    wwnWithExtension: "0x600..."
```
If you want to inspect the whole spec:
```bash
oc get baremetalhost -n openshift-machine-api

NAME                 STATE       CONSUMER                   ONLINE   ERROR   AGE
ocp133.localdomain   unmanaged   ocp4-virt-tvqfq-master-0   true             133d
ocp134.localdomain   unmanaged   ocp4-virt-tvqfq-master-1   true             133d
ocp135.localdomain   unmanaged   ocp4-virt-tvqfq-master-2   true             133d

oc get baremetalhost ocp133.localdomain -n openshift-machine-api -o yaml

apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  creationTimestamp: "2026-04-13T21:03:01Z"
  finalizers:
  - baremetalhost.metal3.io
  generation: 2
  labels:
    installer.openshift.io/role: control-plane
  name: ocp133.localdomain
  namespace: openshift-machine-api
  resourceVersion: "18691"
  uid: 5fbbe42d-b11e-4a05-9055-e9f3e994ecc5
spec:
  architecture: x86_64
  automatedCleaningMode: metadata
  bmc:
    address: ""
    credentialsName: ""
  bootMACAddress: 00:50:56:81:2c:51
  bootMode: UEFI
  consumerRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: Machine
    name: ocp4-virt-tvqfq-master-0
    namespace: openshift-machine-api
  customDeploy:
    method: install_coreos
  externallyProvisioned: true
  hardwareProfile: unknown
  online: true
  userData:
    name: master-user-data-managed
    namespace: openshift-machine-api
status:
  errorCount: 0
  errorMessage: ""
  goodCredentials: {}
  hardware:
    cpu:
      arch: x86_64
      count: 8
      flags:
      - fpu
      - vme
      - de
      - pse
      - tsc
      - msr
      - pae
      - mce
      - cx8
      - apic
      - sep
      - mtrr
      - pge
      - mca
      - cmov
      - pat
      - pse36
      - clflush
      - mmx
      - fxsr
      - sse
      - sse2
      - ht
      - syscall
      - nx
      - mmxext
      - fxsr_opt
      - pdpe1gb
      - rdtscp
      - lm
      - constant_tsc
      - rep_good
      - nopl
      - xtopology
      - tsc_reliable
      - nonstop_tsc
      - cpuid
      - extd_apicid
      - tsc_known_freq
      - pni
      - pclmulqdq
      - ssse3
      - fma
      - cx16
      - pcid
      - sse4_1
      - sse4_2
      - x2apic
      - movbe
      - popcnt
      - aes
      - xsave
      - avx
      - f16c
      - rdrand
      - hypervisor
      - lahf_lm
      - cmp_legacy
      - extapic
      - cr8_legacy
      - abm
      - sse4a
      - misalignsse
      - 3dnowprefetch
      - osvw
      - topoext
      - ibpb
      - vmmcall
      - fsgsbase
      - bmi1
      - avx2
      - smep
      - bmi2
      - erms
      - invpcid
      - avx512f
      - avx512dq
      - rdseed
      - adx
      - smap
      - avx512ifma
      - clflushopt
      - clwb
      - avx512cd
      - sha_ni
      - avx512bw
      - avx512vl
      - xsaveopt
      - xsavec
      - xgetbv1
      - xsaves
      - avx512_bf16
      - clzero
      - wbnoinvd
      - arat
      - avx512vbmi
      - umip
      - pku
      - ospke
      - avx512_vbmi2
      - gfni
      - vaes
      - vpclmulqdq
      - avx512_vnni
      - avx512_bitalg
      - avx512_vpopcntdq
      - rdpid
      - overflow_recov
      - succor
      - fsrm
      - flush_l1d
      model: AMD EPYC 9554P 64-Core Emb Processor
    firmware:
      bios: {}
    nics:
    - ip: 172.16.1.133
      mac: 00:50:56:81:2c:51
      model: "0x07b0"
      name: ens256
      speedGbps: 9
    ramMebibytes: 16384
    storage:
    - hctl: "0:0:0:0"
      model: Virtual_disk
      name: /dev/disk/by-path/pci-0000:03:00.0-scsi-0:0:0:0
      serialNumber: 6000c29ed1d9cdf00e0cce4abf5d630f
      sizeBytes: 536870912000
      vendor: VMware
      wwn: 0x6000c29ed1d9cdf00e0cce4abf5d630f
    - hctl: "3:0:0:0"
      model: VMware_Virtual_SATA_CDRW_Drive
      name: /dev/disk/by-path/pci-0000:02:00.0-ata-1.0
      serialNumber: "00000000000000000001"
      sizeBytes: 1433403392
      vendor: NECVMWar
    systemVendor:
      manufacturer: VMware, Inc.
      productName: VMware7,1
      serialNumber: VMware-42 01 7e 2b 4f c1 5f 29-7d 1a e5 b1 eb e2 71 ad
  lastUpdated: "2026-04-13T21:16:20Z"
  operationHistory:
    deprovision:
      end: null
      start: null
    inspect:
      end: null
      start: null
    provision:
      end: null
      start: null
    register:
      end: null
      start: null
  operationalStatus: discovered
  poweredOn: true
  provisioning:
    ID: ""
    image:
      url: ""
    state: unmanaged
  triedCredentials: {}
```