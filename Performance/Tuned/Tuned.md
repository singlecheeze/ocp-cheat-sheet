### Tuned Profile:  
Below is a `tuned` profile that combines settings for various optimizations including:
- CPU speed stepping/turbo
- Network (RoCEv2, TCP window dynamics)
- Filesystem
- RAM
  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$
- Some of the below is included in other areas, namely Compute/Processor Speed Stepping.  
- The profile with the highest priority (10) is openshift-control-planes and, therefore, it is considered first.
- We include it anyway, see `include=openshift-control-plane` in the `tuned` profile. 
  
[Source: `lab-combined.yaml`](./lab-combined.yaml)
<!-- embed-code: ./lab-combined.yaml -->
```yaml
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