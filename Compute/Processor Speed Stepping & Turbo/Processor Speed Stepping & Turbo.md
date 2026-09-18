Enabling CPU speed stepping (dynamic CPU frequency scaling like Intel SpeedStep/P-states or AMD PowerNow!/P-states) on a Red Hat OpenShift 4 cluster requires configuring options at the hardware/BIOS layer, adjusting kernel parameters, and managing the OS CPU scaling governor via the Node Tuning Operator (NTO).

By default, OpenShift worker nodes often run performance-oriented profiles that pin the CPU governor to maximum frequency. Below is the step-by-step process to enable dynamic speed stepping across your cluster nodes.

**Step 1: Hardware & BIOS Settings**  
Before configuring OpenShift, ensure your underlying bare-metal hardware allows the operating system to manage CPU power states:
- Intel: Enable Intel SpeedStep (EIST) or Intel Speed Select (SST).  
- AMD: Enable AMD Cool'n'Quiet / AMD P-State.  
- Power Management Profile: Set the system BIOS profile to OS Control or Balanced. (Avoid "Maximum Performance" BIOS profiles, as they force hardware multipliers to remain static).

**Step 2: Configure CPU Governor via Node Tuning Operator**  
OpenShift manages node-level tuning through the Node Tuning Operator using Tuned custom resources. You can create a custom Tuned profile that sets the CPU scaling governor to dynamic modes like powersave (standard for modern drivers like intel_pstate and amd_pstate), schedutil, or ondemand.  
Create a manifest file named cpu-speedstepping-tuned.yaml (This is for a compact cluster, replace `master` with `worker` if needed):  
[Source: `Sources/cpu-speedstepping.yaml`](Sources/cpu-speedstepping.yaml)
<!-- embed-code: ./Sources/cpu-speedstepping.yaml -->
```yaml
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: cpu-speedstepping
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
    - name: openshift-dynamic-cpu-scaling
      data: |
        [main]
        summary=Enable dynamic CPU speed stepping / frequency scaling
        include=openshift-control-plane
        # include=openshift-node

        [cpu]
        # For intel_pstate / amd_pstate drivers, 'powersave' dynamically scales frequency with load.
        # For acpi-cpufreq drivers, 'schedutil' or 'ondemand' can be used.
        governor=powersave
        energy_perf_bias=normal
  recommend:
    - profile: openshift-dynamic-cpu-scaling
      priority: 15
      match:
        - label: node-role.kubernetes.io/master
```
**Step 3: Check Kernel Parameters (If using Performance Profiles or Newer CPUs)**  
If you are running Low Latency or Real-Time performance profiles (PerformanceProfile CRs), OpenShift may have appended kernel arguments that disable CPU idle C-states (e.g., intel_idle.max_cstate=0 or processor.max_cstate=1) or lock frequency.
  
Yes, `amd_pstate` is significantly better than `acpi-cpufreq` for modern AMD processors (AMD Zen 2 and newer, including EPYC 7002+ and Ryzen 3000+):
```text
+-----------------------+---------------------------------------------------+-------------------------------------------------------------------+
| Feature               | acpi-cpufreq (Legacy)                             | amd_pstate (Modern)                                               |
+-----------------------+---------------------------------------------------+-------------------------------------------------------------------+
| Control Mechanism     | Uses legacy ACPI P-States.                        | Uses ACPI CPPC (Collaborative Processor Performance Control).     |
|                       |                                                   |                                                                   |
| Frequency Granularity | Coarse-grained (restricted to 3 fixed P-states:   | Fine-grained & continuous (scales fluidly across the entire       |
|                       | P0, P1, P2).                                      | frequency range).                                                 |
|                       |                                                   |                                                                   |
| Latency &             | Slow state transitions managed via software AML   | Low-latency register model (MSR) communicating directly with AMD  |
| Responsiveness        | interpreter.                                      | SMU firmware.                                                     |
|                       |                                                   |                                                                   |
| Efficiency            | Higher energy consumption during mixed            | Better performance-per-watt, faster burst response, and deeper    |
|                       | workloads.                                        | power savings idle.                                               |
+-----------------------+---------------------------------------------------+-------------------------------------------------------------------+
```
  
Prerequisites Before Switching:
- CPU Support: AMD Zen 2 architecture or newer.  
- BIOS Setting: Ensure ACPI CPPC (Collaborative Processor Performance Control) is set to Enabled in the server/node BIOS.  
	<img width="320" height="141" alt="CPPC1" src="https://gist.github.com/user-attachments/assets/80010257-4f0b-4e9a-b2b3-4309314c5083" />  
	<img width="336" height="45" alt="CPPC2" src="https://gist.github.com/user-attachments/assets/1500cec3-bbcf-4a8a-b56a-79182a35f97e" />  
	<img width="879" height="155" alt="CPPC" src="https://gist.github.com/user-attachments/assets/b63eaf8c-614d-401e-9c8e-454c00963f32" />	  
    <img width="1440" height="136" alt="image" src="https://gist.github.com/user-attachments/assets/2231784d-6d4a-48e5-bcb5-c6893cd934f7" />   
- OS Version: Red Hat Enterprise Linux CoreOS (RHCOS) on OpenShift 4.12+ (RHEL 9-based kernel) natively supports amd_pstate.

To pass specific scaling driver arguments (such as amd_pstate=active for AMD CPUs) via MachineConfig (This is for a compact cluster, replace `master` with `worker` if needed):  
[Source: `Sources/99-enable-amd-pstate.yaml`](Sources/99-enable-amd-pstate.yaml)
<!-- embed-code: ./Sources/99-enable-amd-pstate.yaml -->
```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-enable-amd-pstate
spec:
  kernelArguments:
    - "amd_pstate=active"
```
Note on Modes:
- amd_pstate=active: Enables Energy Performance Preference (EPP) mode where AMD firmware handles dynamic frequency scaling autonomously based on performance hints.
- amd_pstate=passive: Allows standard Linux governors (schedutil, ondemand) to request exact target frequencies via CPPC.
- amd_pstate=guided: Linux governor requests min/max targets, and AMD hardware dynamically selects within that range.
  
**Step 4: Verify Speed Stepping on Nodes**  
To verify that CPU speed stepping is active and frequencies are dynamically fluctuating under load:
```bash
# Check current active scaling driver
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver

# Check active scaling governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# Watch live CPU core frequencies (frequencies should drop when idle and spike under load)
watch -n 1 "grep 'cpu MHz' /proc/cpuinfo"

oc get nodes
oc debug node/<worker-node-name>

sh-5.1# chroot /host

# Before changes
sh-5.1# cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
acpi-cpufreq

sh-5.1# cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
performance

sh-5.1# watch -n 1 "grep 'cpu MHz' /proc/cpuinfo | sort -nr"
cpu MHz         : 3100.000
cpu MHz         : 3100.000
cpu MHz         : 3100.000
...
# After changes
sh-5.1# cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
acpi-cpufreq

sh-5.1# cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
powersave

sh-5.1# watch -n 1 "grep 'cpu MHz' /proc/cpuinfo"
cpu MHz         : 1500.000
cpu MHz         : 1500.000
cpu MHz         : 1500.000
...
# With AMD p_state driver
sh-5.1# cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
amd-pstate-epp
# Expected output: amd-pstate or amd-pstate-epp

sh-5.1# cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
powersave

sh-5.1# watch -n 1 "grep 'cpu MHz' /proc/cpuinfo | sort -nr"
cpu MHz         : 2660.521
cpu MHz         : 2303.600
cpu MHz         : 2303.600
```