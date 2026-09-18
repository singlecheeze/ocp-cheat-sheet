$${\color{deeppink}\textbf{\textsf{Note:}}}$$ Somewhat deprecated by new https://console.redhat.com UI  
$${\color{deeppink}\textbf{\textsf{Note:}}}$$ DHCP IP reservations are required via MAC of first NIC in a bond  
```text
trt2ocp1.localdomain    172.16.1.111
enp129s0f1  ac:1f:6b:a4:c6:63
ens4  24:8a:07:bb:41:e0
ens4d1  24:8a:07:bb:41:e1

trt2ocp2.localdomain    172.16.1.112
enp129s0f1  ac:1f:6b:ab:b4:8f
ens4  24:8a:07:bb:35:d0
ens4d1  24:8a:07:bb:35:d1
```
```yaml
apiVersion: nmstate.io/v1
interfaces:
- name: eno4
  type: ethernet
  ipv4:
    dhcp: false 
    enabled: false
  ipv6:
    dhcp: false 
    enabled: false
- name: bond0
  type: bond
  lldp:
      enabled: true
  mac-address: 'MAC like: ec-0d-9a-e5-04-20'
  state: up
  ipv4:
    dhcp: true 
    enabled: true
  ipv6:
    dhcp: false 
    enabled: false
  link-aggregation:
    mode: 802.3ad 
    options:
      miimon: '100' 
    port: 
    - enp132s0
    - enp132s0d1
```
```yaml
apiVersion: nmstate.io/v1
interfaces:
- name: enp129s0f1
  type: ethernet
  ipv4:
    dhcp: false 
    enabled: false
  ipv6:
    dhcp: false 
    enabled: false
- name: bond0
  type: bond
  lldp:
      enabled: true
  mac-address: 'MAC like: ec-0d-9a-e5-04-20'
  state: up
  ipv4:
    dhcp: true 
    enabled: true
  ipv6:
    dhcp: false 
    enabled: false
  link-aggregation:
    mode: 802.3ad 
    options:
      miimon: '100' 
    port: 
    - ens4
    - ens4d1
```