Ref: https://docs.nvidia.com/gpudirect-storage/best-practices-guide/index.html  
Ref: https://developers.redhat.com/articles/2025/04/29/accelerate-model-training-openshift-ai-nvidia-gpudirect-rdma#communication_overhead  
  
### IOMMU Pass-Through mode:  
`iommu=pt` stands for IOMMU Pass-Through mode. By default, when an Input-Output Memory Management Unit (IOMMU) is enabled, it acts as a gatekeeper between your hardware devices (like network cards or GPUs) and the system memory (RAM). It intercepts every single Direct Memory Access (DMA) request and translates the device's virtual addresses into physical system RAM addresses.  
  
Adding `iommu=pt` to your kernel boot parameters forces the Linux kernel to turn off DMA address translation for host devices, in certain cases, switching them to a 1:1 physical mapping.  
  
Why is `iommu=pt` critical for RoCE v2 & GPUDirect?  
- **It Eliminates CPU & Memory Translation Overhead**  
  Without pass-through mode, every packet transmitted over RoCE v2 or every memory frame passed via GPUDirect must wait for the IOMMU to look up and translate its memory address. At ultra-high speeds (100Gbps to 400Gbps+ per NIC), this translation layer creates a massive bottleneck, often resulting in a 10% to 15% drop in raw DMA bandwidth. `iommu=pt` allows hardware devices to write directly to system physical addresses at full native speed.  
- **It Unlocks Peer-to-Peer (P2P) PCIe Communication**  
  GPUDirect RDMA relies on a feature where a Mellanox/NVIDIA ConnectX NIC can bypass the host CPU entirely and write data directly into a GPU’s onboard VRAM over the PCIe bus. If the IOMMU is running in its default "strict" mode, it forces this traffic to loop back up through the CPU/Host root complex for validation. iommu=pt removes this restriction, allowing true peer-to-peer data transfers to function smoothly across the local PCIe switches.
- **It Preserves Virtualization Capabilities (SR-IOV / VFIO)**  
  If you are running an AI cluster on bare metal, setting `iommu=off` technically provides the absolute best performance. However, if you are using virtual machines, containers, or SR-IOV (Single Root I/O Virtualization) where NICs and GPUs must be securely sliced and passed into specific instances, you cannot turn the IOMMU completely off. 
- **`iommu=pt` represents the ideal compromise:**
  - The IOMMU hardware remains active so you can still use driver isolation (VFIO) to pass dedicated GPUs or Virtual Functions into hypervisors/virtual machines.
  - For the actual data-plane streams (the heavy RoCE v2 and GPUDirect traffic), the translation overhead is completely bypassed to maintain bare-metal line-rate throughput.

$${\color{deeppink}\textbf{\textsf{Note:}}}$$ The below items must be taken into account:  
- The Nvidia GPU/NIC Operator does NOT configure pass-through for you at this time.  
- If you have IOMMU Disabled in your BIOS, you do not need to apply this.
- Sometimes, depending on server manufacturer, you must ensure PCIe Access Control Services (ACS) is `disabled`, or set to `auto`, in your server’s BIOS to permit direct GPU-to-NIC PCIe switches. 
- `intel_iommu=on`, `amd_iommu=off`, `amd_iommu=force_enable`, `amd_iommu=force_isolation`
  - The Intel equivalent, `intel_iommu=on`, is valid, which is probably where any confusion comes from. On AMD systems, IOMMU is normally enabled automatically when the firmware exposes AMD-Vi; Red Hat’s current RHEL 9 guidance says to use only iommu=pt to select pass-through mode.

[Source: `Sources/99-enable-iommu-pass-through.yaml`](Sources/99-enable-iommu-pass-through.yaml)
<!-- embed-code: ./Sources/99-enable-iommu-pass-through.yaml -->
```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-enable-iommu-pass-through
spec:
  kernelArguments:
    - "iommu=pt"      # This enables IOMMU Pass-Through Mode
```
 To Verify:
```bash
for NODE in ocp113.localdomain ocp114.localdomain ocp115.localdomain; do
  echo "================================================"
  echo "$NODE"
  echo "================================================"

  oc debug node/"$NODE" -- chroot /host bash -lc '
    echo "===== Kernel command line ====="
    cat /proc/cmdline

    echo
    echo "===== IOMMU default domain ====="
    journalctl -k -b --no-pager |
      grep -Ei "Default domain type|IOMMU.*passthrough|AMD-Vi" |
      head -n 40
  '
  echo
done
```
```bash
================================================
ocp113.localdomain
================================================
Starting pod/ocp113localdomain-debug-r6rkc ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
===== Kernel command line =====
BOOT_IMAGE=(hd2,gpt3)/boot/ostree/rhcos-0ce367b29f6005e594fc81925e2b08921aa8c712dce21752b9082a83a3cc645f/vmlinuz-5.14.0-687.41.1.el9_8.x86_64 ignition.platform.id=metal ostree=/ostree/boot.0/rhcos/0ce367b29f6005e594fc81925e2b08921aa8c712dce21752b9082a83a3cc645f/0 root=UUID=910678ff-f77e-4a7d-8d53-86f2ac47a823 rw rootflags=prjquota boot=UUID=43b68964-63c3-4cfa-b639-73cadbf73b7d systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all amd_pstate=active iommu=pt

===== IOMMU default domain =====
Sep 11 13:34:35 localhost kernel: AMD-Vi: Using global IVHD EFR:0x25bf732fa2295afe, EFR2:0x1d
Sep 11 13:34:35 localhost kernel: iommu: Default domain type: Passthrough (set via kernel command line)
Sep 11 13:34:35 localhost kernel: pci 0000:c0:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:34:35 localhost kernel: pci 0000:80:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:34:35 localhost kernel: pci 0000:00:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:34:35 localhost kernel: pci 0000:40:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:34:35 localhost kernel: AMD-Vi: Extended features (0x25bf732fa2295afe, 0x1d): PPR X2APIC NX GT [5] IA GA PC GA_vAPIC
Sep 11 13:34:35 localhost kernel: AMD-Vi: Interrupt remapping enabled
Sep 11 13:34:35 localhost kernel: AMD-Vi: X2APIC enabled
Sep 11 13:34:35 localhost kernel: AMD-Vi: Virtual APIC enabled

Removing debug pod ...

================================================
ocp114.localdomain
================================================
Starting pod/ocp114localdomain-debug-h5dm7 ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
===== Kernel command line =====
BOOT_IMAGE=(hd2,gpt3)/boot/ostree/rhcos-0ce367b29f6005e594fc81925e2b08921aa8c712dce21752b9082a83a3cc645f/vmlinuz-5.14.0-687.41.1.el9_8.x86_64 ignition.platform.id=metal ostree=/ostree/boot.0/rhcos/0ce367b29f6005e594fc81925e2b08921aa8c712dce21752b9082a83a3cc645f/0 root=UUID=910678ff-f77e-4a7d-8d53-86f2ac47a823 rw rootflags=prjquota boot=UUID=0b83b33c-344e-4a5d-a8f4-73e91ba073e8 systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all amd_pstate=active iommu=pt

===== IOMMU default domain =====
Sep 11 13:46:37 localhost kernel: AMD-Vi: Using global IVHD EFR:0x25bf732fa2295afe, EFR2:0x1d
Sep 11 13:46:37 localhost kernel: iommu: Default domain type: Passthrough (set via kernel command line)
Sep 11 13:46:37 localhost kernel: pci 0000:c0:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:46:37 localhost kernel: pci 0000:80:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:46:37 localhost kernel: pci 0000:00:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:46:37 localhost kernel: pci 0000:40:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:46:37 localhost kernel: AMD-Vi: Extended features (0x25bf732fa2295afe, 0x1d): PPR X2APIC NX GT [5] IA GA PC GA_vAPIC
Sep 11 13:46:37 localhost kernel: AMD-Vi: Interrupt remapping enabled
Sep 11 13:46:37 localhost kernel: AMD-Vi: X2APIC enabled
Sep 11 13:46:37 localhost kernel: AMD-Vi: Virtual APIC enabled

Removing debug pod ...

================================================
ocp115.localdomain
================================================
Starting pod/ocp115localdomain-debug-t77s4 ...
To use host binaries, run `chroot /host`. Instead, if you need to access host namespaces, run `nsenter -a -t 1`.
===== Kernel command line =====
BOOT_IMAGE=(hd2,gpt3)/boot/ostree/rhcos-0ce367b29f6005e594fc81925e2b08921aa8c712dce21752b9082a83a3cc645f/vmlinuz-5.14.0-687.41.1.el9_8.x86_64 ignition.platform.id=metal ostree=/ostree/boot.0/rhcos/0ce367b29f6005e594fc81925e2b08921aa8c712dce21752b9082a83a3cc645f/0 root=UUID=910678ff-f77e-4a7d-8d53-86f2ac47a823 rw rootflags=prjquota boot=UUID=94900893-ca04-4778-b5ff-13280b34d122 systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all amd_pstate=active iommu=pt

===== IOMMU default domain =====
Sep 11 13:59:03 localhost kernel: AMD-Vi: Using global IVHD EFR:0x25bf732fa2295afe, EFR2:0x1d
Sep 11 13:59:03 localhost kernel: iommu: Default domain type: Passthrough (set via kernel command line)
Sep 11 13:59:03 localhost kernel: pci 0000:c0:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:59:03 localhost kernel: pci 0000:80:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:59:03 localhost kernel: pci 0000:00:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:59:03 localhost kernel: pci 0000:40:00.2: AMD-Vi: IOMMU performance counters supported
Sep 11 13:59:03 localhost kernel: AMD-Vi: Extended features (0x25bf732fa2295afe, 0x1d): PPR X2APIC NX GT [5] IA GA PC GA_vAPIC
Sep 11 13:59:03 localhost kernel: AMD-Vi: Interrupt remapping enabled
Sep 11 13:59:03 localhost kernel: AMD-Vi: X2APIC enabled
Sep 11 13:59:03 localhost kernel: AMD-Vi: Virtual APIC enabled

Removing debug pod ...
```