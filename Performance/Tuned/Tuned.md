### Tuned Profile:  
Below is a `tuned` profile that combines settings for various optimizations including:
- CPU speed stepping/turbo
- Network (RoCEv2, TCP window dynamics)
- Filesystem
- RAM
  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ Please see below!
- Some of the below is included in other areas, namely Compute/Processor Speed Stepping.  
- The profile with the highest priority (10) is openshift-control-planes and, therefore, it is considered first.
- We include it anyway, see `include=openshift-control-plane` in the `tuned` profile. 
  
[Source: `Sources/lab-combined.yaml`](Sources/lab-combined.yaml)
<!-- embed-code: ./lab-combined.yaml -->
```yaml
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: lab-combined
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
    - name: lab-combined
      data: |
        [main]
        summary=Performance optimized profile
        description=These are settings taken from other profiles, including: throughput-performance, network-throughput, latency-performance, network-latency, openshift-node.
        include=openshift-control-plane

        [cpu]
        governor=powersave
        energy_perf_bias=normal
        boost=1
        
        [sysctl]
        # If a workload mostly uses anonymous memory and it hits this limit, the entire working set is buffered for I/O, and any more write buffering would require swapping, so it's time to throttle writes until I/O can catch up. Workloads that mostly use file mappings may be able to use even higher values. The generator of dirty data starts writeback at this percentage (System default is 20%).
        vm.dirty_ratio=10
        # Start background writeback (Via writeback threads) at this percentage (System default is 10%).
        vm.dirty_background_ratio=3
        # Disable Swappiness & Local Zone Reclaims: Prevents page allocation stalls and latency spikes in multi-socket/NUMA architectures.
        vm.swappiness=0
        vm.stat_interval=10
        vm.zone_reclaim_mode=0
        # Increase Memory Map Limits: Allows applications like PyTorch or JAX to register thousands of memory allocations seamlessly.
        vm.max_map_count=1048576
        
        [sysctl-openshift-node]
        type=sysctl
        # This is required as both openshift-node and openshift-control-plane include=openshift but openshift-node has these additional settings.
        # Optimize Network Buffer Sizes: Ensures the network stack can handle huge bursts of helper traffic across high-bandwidth (100Gbps–400Gbps+) links.
        fs.inotify.max_user_watches=65536
        fs.inotify.max_user_instances=8192
        # Enable Explicit Congestion Notification (ECN): Required for DCQCN (Data Center Quantized Congestion Notification, RoCEv2) to signal network bottlenecks without dropping packets.
        net.ipv4.tcp_ecn=1
        net.ipv4.tcp_fastopen=3
        net.ipv4.tcp_slow_start_after_idle=0
        net.ipv4.tcp_rmem="4096 87380 134217728"
        net.ipv4.tcp_wmem="4096 65536 134217728"
        net.core.busy_read=50
        net.core.busy_poll=50
        net.core.netdev_max_backlog=250000
        net.core.rmem_max=134217728
        net.core.wmem_max=134217728
        kernel.hung_task_timeout_secs=120
        kernel.nmi_watchdog=0
        kernel.numa_balancing=0       
        kernel.timer_migration=0 

  recommend:
    - profile: lab-combined
      priority: 10
      match:
        - label: node-role.kubernetes.io/master
```
Some Defaults for Reference:
```bash
[root@ocp113 core]#  sysctl -a | grep net.core.rmem_max
net.core.rmem_max = 212992
[root@ocp113 core]#  sysctl -a | grep net.core.wmem_max
net.core.wmem_max = 212992
[root@ocp113 core]#  sysctl -a | grep net.core.netdev_max_backlog
net.core.netdev_max_backlog = 1000
[root@ocp113 core]#  sysctl -a | grep net.ipv4.tcp_rmem
net.ipv4.tcp_rmem = 4096        131072  6291456
[root@ocp113 core]#  sysctl -a | grep net.ipv4.tcp_wmem
net.ipv4.tcp_wmem = 4096        16384   4194304
[root@ocp113 core]#  sysctl -a | grep net.core.busy_read
net.core.busy_read = 0
[root@ocp113 core]#  sysctl -a | grep net.core.busy_poll
net.core.busy_poll = 0
[root@ocp113 core]#  sysctl -a | grep net.ipv4.tcp_fastopen
net.ipv4.tcp_fastopen = 1
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0
net.ipv4.tcp_fastopen_key = 00000000-00000000-00000000-00000000
[root@ocp113 core]#  sysctl -a | grep net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_slow_start_after_idle = 1
[root@ocp113 core]#  sysctl -a | grep kernel.numa_balancing
kernel.numa_balancing = 0
kernel.numa_balancing_promote_rate_limit_MBps = 65536
[root@ocp113 core]#  sysctl -a | grep kernel.hung_task_timeout_secs
kernel.hung_task_timeout_secs = 120
[root@ocp113 core]#  sysctl -a | grep kernel.nmi_watchdog
kernel.nmi_watchdog = 1
[root@ocp113 core]#  sysctl -a | grep vm.stat_interval
vm.stat_interval = 1
[root@ocp113 core]#  sysctl -a | grep kernel.timer_migration
kernel.timer_migration = 1
```