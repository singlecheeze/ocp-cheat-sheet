### Configure a VLAN on an OpenShift Node

[Source: `Sources/nvme-storage-vlan100.yaml`](Sources/nvme-storage-vlan100.yaml)
<!-- embed-code: ./Sources/nvme-storage-vlan100.yaml -->
```yaml
```
Verify VLAN 100 on each node:
```bash
for NODE in ocp113.localdomain ocp114.localdomain ocp115.localdomain; do

  echo
  echo "===== ${NODE} ====="

  oc debug node/${NODE} --quiet -- chroot /host bash -c '
    echo "--- bond1 ---"
    ip -br link show bond1

    echo
    echo "--- detailed VLAN ---"
    ip -d link show bond1.100 | head -2

    echo
    echo "--- routes ---"
    ip route show 172.16.100.0/24
  '

done
```
Output:
```bash
===== ocp113.localdomain =====
--- bond1 ---
bond1            UP             3c:ec:ef:5c:58:30 <BROADCAST,MULTICAST,MASTER,UP,LOWER_UP>

--- detailed VLAN ---
308: bond1.100@bond1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc noqueue state UP mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:5c:58:30 brd ff:ff:ff:ff:ff:ff promiscuity 0 allmulti 0 minmtu 0 maxmtu 65535

--- routes ---
172.16.100.0/24 dev bond1.100 proto kernel scope link src 172.16.100.113 metric 400

===== ocp114.localdomain =====
--- bond1 ---
bond1            UP             3c:ec:ef:12:9c:5c <BROADCAST,MULTICAST,MASTER,UP,LOWER_UP>

--- detailed VLAN ---
285: bond1.100@bond1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc noqueue state UP mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:12:9c:5c brd ff:ff:ff:ff:ff:ff promiscuity 0 allmulti 0 minmtu 0 maxmtu 65535

--- routes ---
172.16.100.0/24 dev bond1.100 proto kernel scope link src 172.16.100.114 metric 400

===== ocp115.localdomain =====
--- bond1 ---
bond1            UP             3c:ec:ef:12:9c:1a <BROADCAST,MULTICAST,MASTER,UP,LOWER_UP>

--- detailed VLAN ---
144: bond1.100@bond1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 qdisc noqueue state UP mode DEFAULT group default qlen 1000
    link/ether 3c:ec:ef:12:9c:1a brd ff:ff:ff:ff:ff:ff promiscuity 0 allmulti 0 minmtu 0 maxmtu 65535

--- routes ---
172.16.100.0/24 dev bond1.100 proto kernel scope link src 172.16.100.115 metric 400
```
### Validate Routing:
```bash
for NODE in ocp113.localdomain ocp114.localdomain ocp115.localdomain; do
  echo
  echo "===== ${NODE} ====="

  oc debug node/${NODE} --quiet -- chroot /host \
    ip route get 172.16.100.125
done
```
```bash
===== ocp113.localdomain =====
172.16.100.125 dev bond1.100 src 172.16.100.113 uid 0
    cache

===== ocp114.localdomain =====
172.16.100.125 dev bond1.100 src 172.16.100.114 uid 0
    cache

===== ocp115.localdomain =====
172.16.100.125 dev bond1.100 src 172.16.100.115 uid 0
    cache
```
### Validate the 9000-byte path:
Perform the correct Linux jumbo-frame test for a 9000-byte IP MTU:
```bash
for NODE in ocp113.localdomain ocp114.localdomain ocp115.localdomain; do
  echo
  echo "===== ${NODE} ====="

  oc debug node/${NODE} --quiet -- chroot /host \
    ping \
      -I bond1.100 \
      -M do \
      -s 8972 \
      -c 3 \
      172.16.100.125
done
```
```bash
===== ocp113.localdomain =====
PING 172.16.100.125 (172.16.100.125) from 172.16.100.113 bond1.100: 8972(9000) bytes of data.
8980 bytes from 172.16.100.125: icmp_seq=1 ttl=64 time=0.180 ms
8980 bytes from 172.16.100.125: icmp_seq=2 ttl=64 time=0.092 ms
8980 bytes from 172.16.100.125: icmp_seq=3 ttl=64 time=0.110 ms

--- 172.16.100.125 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2063ms
rtt min/avg/max/mdev = 0.092/0.127/0.180/0.037 ms

===== ocp114.localdomain =====
PING 172.16.100.125 (172.16.100.125) from 172.16.100.114 bond1.100: 8972(9000) bytes of data.
8980 bytes from 172.16.100.125: icmp_seq=1 ttl=64 time=0.175 ms
8980 bytes from 172.16.100.125: icmp_seq=2 ttl=64 time=0.103 ms
8980 bytes from 172.16.100.125: icmp_seq=3 ttl=64 time=0.106 ms

--- 172.16.100.125 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2033ms
rtt min/avg/max/mdev = 0.103/0.128/0.175/0.033 ms

===== ocp115.localdomain =====
PING 172.16.100.125 (172.16.100.125) from 172.16.100.115 bond1.100: 8972(9000) bytes of data.
8980 bytes from 172.16.100.125: icmp_seq=1 ttl=64 time=0.205 ms
8980 bytes from 172.16.100.125: icmp_seq=2 ttl=64 time=0.155 ms
8980 bytes from 172.16.100.125: icmp_seq=3 ttl=64 time=0.091 ms
```