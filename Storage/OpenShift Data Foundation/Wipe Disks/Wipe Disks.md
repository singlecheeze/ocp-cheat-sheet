$${\color{deeppink}\textbf{\textsf{Note:}}}$$ BE CAREFUL! You've been warned...  
How to wipe disks that have been part of a prior ODF cluster:  
```bash 
[root@ocp114 core]#  wipefs -a /dev/sda &&  sgdisk --zap-all /dev/sda && dd if=/dev/zero of=/dev/sda bs=1M count=100 oflag=direct,dsync && blkid /dev/sda
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
100+0 records in
100+0 records out
104857600 bytes (105 MB, 100 MiB) copied, 0.319195 s, 329 MB/s

[root@ocp114 core]# wipefs -a /dev/sdb &&  sgdisk --zap-all /dev/sdb && dd if=/dev/zero of=/dev/sdb bs=1M count=100 oflag=direct,dsync && blkid /dev/sdb
```
More detail (In this case you can see ceph already present on `sda` `sdb`):  
```bash
[core@ocp113 ~]$ lsblk -f
NAME FSTYPE FSVER LABEL UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
loop0
     erofs
sda  ceph_b
sdb  ceph_b
nvme0n1
│
├─nvme0n1p1
│
├─nvme0n1p2
│    vfat   FAT16 EFI-SYSTEM
│                       7B77-95E7
├─nvme0n1p3
│    ext4   1.0   boot  f93b7e18-8e6d-4bfc-9156-015d23073afc  198.6M    37% /boot
└─nvme0n1p4
     xfs          root  910678ff-f77e-4a7d-8d53-86f2ac47a823  417.5G     7% /var/lib/kubelet/pods/6f265fbf-8aef-4fa5-87bb-ef62f49821dc/volume-subpaths/odf-console-nginx-conf/odf-console/1
                                                                            /var
                                                                            /sysroot/ostree/deploy/rhcos/var
                                                                            /sysroot
                                                                            /etc

[root@ocp113 core]# wipefs -a /dev/sda
/dev/sda: 22 bytes were erased at offset 0x00000000 (ceph_bluestore): 62 6c 75 65 73 74 6f 72 65 20 62 6c 6f 63 6b 20 64 65 76 69 63 65
[root@ocp113 core]# wipefs -a /dev/sdb
/dev/sdb: 22 bytes were erased at offset 0x00000000 (ceph_bluestore): 62 6c 75 65 73 74 6f 72 65 20 62 6c 6f 63 6b 20 64 65 76 69 63 65

[root@ocp113 core]# sgdisk --zap-all /dev/sda
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.
[root@ocp113 core]# sgdisk --zap-all /dev/sdb
Creating new GPT entries in memory.
GPT data structures destroyed! You may now partition the disk using fdisk or
other utilities.

[root@ocp113 core]# dd if=/dev/zero of=/dev/sda bs=1M count=100 oflag=direct,dsync
100+0 records in
100+0 records out
104857600 bytes (105 MB, 100 MiB) copied, 0.305866 s, 343 MB/s
[root@ocp113 core]# dd if=/dev/zero of=/dev/sdb bs=1M count=100 oflag=direct,dsync
100+0 records in
100+0 records out
104857600 bytes (105 MB, 100 MiB) copied, 0.283675 s, 370 MB/s

[root@ocp113 core]# blkid /dev/sda  <-- No output so it's wiped
[root@ocp113 core]# blkid /dev/sdb
[root@ocp113 core]# lsblk -f
NAME FSTYPE FSVER LABEL UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
loop0
     erofs
sda
sdb
nvme0n1
│
├─nvme0n1p1
│
├─nvme0n1p2
│    vfat   FAT16 EFI-SYSTEM
│                       7B77-95E7
├─nvme0n1p3
│    ext4   1.0   boot  cc353391-4540-462b-820f-88adfc2f83da  198.6M    37% /boot
└─nvme0n1p4
     xfs          root  910678ff-f77e-4a7d-8d53-86f2ac47a823    417G     7% /var/lib/kubelet/pods/6f33d325-8c84-46c1-a3d9-47a01b0a6fea/volume-subpaths/nginx-conf/networking-console-plugin/1
                                                                            /var
                                                                            /sysroot/ostree/deploy/rhcos/var
                                                                            /sysroot
                                                                            /etc
```