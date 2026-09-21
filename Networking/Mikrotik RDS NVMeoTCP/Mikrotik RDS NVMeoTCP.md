### Build a RAID10 Array on Mikrotik RDS:

You need to wipe the RAID metadata from all eight physical NVMe devices before recreating the array if any array has been on the drives before. 
- MikroTik specifically documents `file-system=wipe-quick` for removing obsolete RAID/filesystem metadata.

Run these manually and answer y each time:
```bash
/disk format nvme1 file-system=wipe-quick
/disk format nvme2 file-system=wipe-quick
/disk format nvme3 file-system=wipe-quick
/disk format nvme4 file-system=wipe-quick
/disk format nvme5 file-system=wipe-quick
/disk format nvme6 file-system=wipe-quick
/disk format nvme7 file-system=wipe-quick
/disk format nvme8 file-system=wipe-quick
```
Then verify:
```bash
/disk/print detail
```
For nvme1 through nvme8, make sure you no longer see anything like:
```bash
raid-member-state="found raid superblock ..."
```
And that:
```bash
raid-master=none
```
Before rerunning the RAID creation script, remove any partially created logical RAID objects from this failed attempt:
```bash
/disk remove [find where slot="raid10-m0"]
/disk remove [find where slot="raid10-m1"]
/disk remove [find where slot="raid10-m2"]
/disk remove [find where slot="raid10-m3"]
/disk remove [find where slot="raid10"]
```
Then confirm:
```bash
/disk/print detail where slot~"raid10"
```
It should return nothing.  
  
### Build the Creation Script:  
[Source: `Sources/build-ocp-raid10.rsc`](Sources/build-ocp-raid10.rsc)  
<details><summary><b>Show Script</b></summary>

<!-- embed-code: ./Sources/build-ocp-raid10.rsc -->  
```bash
/system/script/add name=build-ocp-raid10 policy=read,write,policy,test source={
    :put "=================================================="
    :put " Building OpenShift Virtualization RAID10"
    :put "=================================================="
    :put ""

    :local disks {"nvme1";"nvme2";"nvme3";"nvme4";"nvme5";"nvme6";"nvme7";"nvme8"}
    :local mirrors {"raid10-m0";"raid10-m1";"raid10-m2";"raid10-m3"}

    # --------------------------------------------------
    # Verify RAID objects do not already exist
    # --------------------------------------------------

    :foreach r in={"raid10";"raid10-m0";"raid10-m1";"raid10-m2";"raid10-m3"} do={

        :if ([:len [/disk find where slot=$r]] > 0) do={
            :error ("RAID object already exists: " . $r)
        }
    }

    # --------------------------------------------------
    # Verify all eight NVMe devices
    # --------------------------------------------------

    :put "Checking NVMe devices..."

    :foreach d in=$disks do={

        :local rows [/disk print detail as-value where slot=$d]

        :if ([:len $rows] = 0) do={
            :error ("Required disk not found: " . $d)
        }

        :local master ($rows->0->"raid-master")
        :local memberState ($rows->0->"raid-member-state")

        :if (($master != "none") && ([:len $master] > 0)) do={
            :error ("Disk " . $d . " already belongs to RAID master " . $master)
        }

        :if ([:len $memberState] > 0) do={
            :error ("Disk " . $d . " still contains RAID metadata: " . $memberState)
        }

        :put ("  OK: " . $d)
    }

    :put ""
    :put "All NVMe devices passed validation."
    :put ""

    # --------------------------------------------------
    # Create top-level RAID0
    #
    # Four RAID1 mirror pairs
    # 256 KiB RAID0 chunk
    # 1 MiB full stripe
    # --------------------------------------------------

    :put "Creating raid10 RAID0..."

    /disk add \
        type=raid \
        slot=raid10 \
        raid-type=0 \
        raid-device-count=4 \
        raid-chunk-size=256K \
        mount-filesystem=yes \
        mount-read-only=no \
        compress=no

    :delay 2s

    # --------------------------------------------------
    # Create RAID1 mirrors
    # --------------------------------------------------

    :put "Creating raid10-m0..."

    /disk add \
        type=raid \
        slot=raid10-m0 \
        raid-type=1 \
        raid-device-count=2 \
        raid-master=raid10 \
        raid-role=0 \
        mount-filesystem=no \
        compress=no

    :delay 1s

    :put "Creating raid10-m1..."

    /disk add \
        type=raid \
        slot=raid10-m1 \
        raid-type=1 \
        raid-device-count=2 \
        raid-master=raid10 \
        raid-role=1 \
        mount-filesystem=no \
        compress=no

    :delay 1s

    :put "Creating raid10-m2..."

    /disk add \
        type=raid \
        slot=raid10-m2 \
        raid-type=1 \
        raid-device-count=2 \
        raid-master=raid10 \
        raid-role=2 \
        mount-filesystem=no \
        compress=no

    :delay 1s

    :put "Creating raid10-m3..."

    /disk add \
        type=raid \
        slot=raid10-m3 \
        raid-type=1 \
        raid-device-count=2 \
        raid-master=raid10 \
        raid-role=3 \
        mount-filesystem=no \
        compress=no

    :delay 2s

    # --------------------------------------------------
    # Assign physical disks
    # --------------------------------------------------

    :put ""
    :put "Assigning nvme1 + nvme2 -> raid10-m0"

    /disk set nvme1 raid-master=raid10-m0 raid-role=0
    /disk set nvme2 raid-master=raid10-m0 raid-role=1

    :put "Assigning nvme3 + nvme4 -> raid10-m1"

    /disk set nvme3 raid-master=raid10-m1 raid-role=0
    /disk set nvme4 raid-master=raid10-m1 raid-role=1

    :put "Assigning nvme5 + nvme6 -> raid10-m2"

    /disk set nvme5 raid-master=raid10-m2 raid-role=0
    /disk set nvme6 raid-master=raid10-m2 raid-role=1

    :put "Assigning nvme7 + nvme8 -> raid10-m3"

    /disk set nvme7 raid-master=raid10-m3 raid-role=0
    /disk set nvme8 raid-master=raid10-m3 raid-role=1

    :put ""
    :put "RAID layout created."
    :put ""

    :delay 10s

    # --------------------------------------------------
    # Monitor synchronization
    #
    # On this RDS RouterOS exposes sync status through:
    #
    # state="clean, sync:repair, resync = ..."
    #
    # Once complete:
    #
    # state="clean"
    # --------------------------------------------------

    :local allClean false
    :local loop 0
    :local maxLoops 1440

    :put "=================================================="
    :put " Waiting for RAID1 synchronization"
    :put "=================================================="
    :put ""

    :while (($allClean = false) && ($loop < $maxLoops)) do={

        :set allClean true

        # MikroTik documented RAID failure query
        :local failedMembers [/disk print count-only where raid-member-failed]

        :if ($failedMembers > 0) do={

            :put ""
            :put "ERROR: RAID member failure detected."
            :put ""

            /disk print detail where raid-member-failed

            :error "RAID member failure detected."
        }

        :put "--------------------------------------------------"

        # Check all four RAID1 mirrors
        :foreach r in=$mirrors do={

            :local rows [/disk print detail as-value where slot=$r]

            :if ([:len $rows] = 0) do={
                :error ("RAID device disappeared: " . $r)
            }

            :local raidStatus ($rows->0->"state")

            :if ([:len $raidStatus] = 0) do={
                :set raidStatus "initializing"
            }

            :put ($r . " = " . $raidStatus)

            :if ($raidStatus = "clean") do={
                # Mirror is synchronized
            } else={
                :set allClean false
            }
        }

        # Show top-level RAID0 status
        :local topRows [/disk print detail as-value where slot="raid10"]

        :if ([:len $topRows] = 0) do={
            :error "Top-level raid10 device disappeared."
        }

        :local topStatus ($topRows->0->"state")

        :put ("raid10    = " . $topStatus)

        :set loop ($loop + 1)

        :if ($allClean = false) do={

            :put ""
            :put ("Synchronization check " . $loop)
            :put "Checking again in 30 seconds..."
            :put ""

            :delay 30s
        }
    }

    # --------------------------------------------------
    # Timeout
    # --------------------------------------------------

    :if ($allClean = false) do={
        :error "RAID mirrors did not finish synchronization within 12 hours."
    }

    # --------------------------------------------------
    # Validate top-level RAID
    # --------------------------------------------------

    :local finalRows [/disk print detail as-value where slot="raid10"]
    :local finalTopStatus ($finalRows->0->"state")

    :if ($finalTopStatus = "clean") do={
        # OK
    } else={
        :error ("RAID1 mirrors are clean but raid10 reports: " . $finalTopStatus)
    }

    # --------------------------------------------------
    # Final status
    # --------------------------------------------------

    :put ""
    :put "=================================================="
    :put " RAID10 SYNCHRONIZATION COMPLETE"
    :put "=================================================="
    :put ""

    :foreach r in=$mirrors do={

        :local rows [/disk print detail as-value where slot=$r]
        :local raidStatus ($rows->0->"state")

        :put ("  " . $r . " = " . $raidStatus)
    }

    :put ("  raid10    = " . $finalTopStatus)

    :put ""
    :put "RAID geometry:"
    :put "  RAID1 pairs:       4"
    :put "  RAID0 chunk:       256 KiB"
    :put "  Full stripe width: 1 MiB"
    :put "  Compression:       disabled"
    :put ""
    :put "Next command:"
    :put ""
    :put "/disk format raid10 file-system=xfs label=ocp-storage mbr-partition-table=no"
    :put ""
}
```
</details>

### Run the Creation Script:  
```bash
/system/script/run build-ocp-raid10
```
Output:  
```bash
[admin@MikroTik-RDS] > /system/script/run build-ocp-raid10
==================================================
 Building OpenShift Virtualization RAID10
==================================================

Checking NVMe devices...
  OK: nvme1
  OK: nvme2
  OK: nvme3
  OK: nvme4
  OK: nvme5
  OK: nvme6
  OK: nvme7
  OK: nvme8

All NVMe devices passed validation.

Creating raid10 RAID0...
Creating raid10-m0...
Creating raid10-m1...
Creating raid10-m2...
Creating raid10-m3...

Assigning nvme1 + nvme2 -> raid10-m0
Assigning nvme3 + nvme4 -> raid10-m1
Assigning nvme5 + nvme6 -> raid10-m2
Assigning nvme7 + nvme8 -> raid10-m3

RAID layout created.

==================================================
 Waiting for RAID1 synchronization
==================================================

0
--------------------------------------------------
raid10-m0 = clean
raid10-m1 = clean
raid10-m2 = clean
raid10-m3 = clean
raid10    = clean

==================================================
 RAID10 SYNCHRONIZATION COMPLETE
==================================================

  raid10-m0 = clean
  raid10-m1 = clean
  raid10-m2 = clean
  raid10-m3 = clean
  raid10    = clean

RAID geometry:
  RAID1 pairs:       4
  RAID0 chunk:       256 KiB
  Full stripe width: 1 MiB
  Compression:       disabled

Next command:

/disk format raid10 file-system=xfs label=ocp-storage mbr-partition-table=no
```
### Format the RAID10 Array as XFS:  
```bash
/disk format raid10 file-system=xfs label=ocp-storage mbr-partition-table=no
```
Output:  
```bash
[admin@MikroTik-RDS] > /disk format raid10 file-system=xfs label=ocp-storage mbr-partition-table=no
All data will be lost, are you sure? [y/N]: y
Columns: OUTPUT
OUTPUT                                                                                 
raid10: file-system: xfs                                                               
raid10: mkfs.xfs -f -L ocp-storage /dev/md15                                           
raid10: meta-data=/dev/md15              isize=512    agcount=32, agsize=122094272 blks
raid10:          =                       sectsz=512   attr=2, projid32bit=1            
raid10:          =                       crc=1        finobt=1, sparse=1, rmapbt=0     
raid10:          =                       reflink=1                                     
raid10: data     =                       bsize=4096   blocks=3907016704, imaxpct=5     
raid10:          =                       sunit=64     swidth=256 blks                  
raid10: naming   =version 2              bsize=4096   ascii-ci=0, ftype=1              
raid10: log      =internal log           bsize=4096   blocks=521728, version=2         
raid10:          =                       sectsz=512   sunit=64 blks, lazy-count=1      
raid10: realtime =none                   extsz=4096   blocks=0, rtextents=0            
raid10: Discarding blocks...Done.                                                      
raid10: format done       
```
###  Build the Verify Storage Script:  
[Source: `Sources/verify-ocp-storage.rsc`](Sources/verify-ocp-storage.rsc)  
<details><summary><b>Show Script</b></summary>

<!-- embed-code: ./Sources/verify-ocp-storage.rsc -->  
```bash
/system/script/add name=verify-ocp-storage policy=read,write,policy,test source={

    :local rows [/disk print detail as-value where slot="raid10"]

    :if ([:len $rows] = 0) do={
        :error "raid10 not found."
    }

    :local state ($rows->0->"state")
    :local fs ($rows->0->"fs")
    :local mounted ($rows->0->"mounted")
    :local size ($rows->0->"size")

    :put "=================================================="
    :put " OpenShift Storage Datastore"
    :put "=================================================="
    :put ("State:      " . $state)
    :put ("Filesystem: " . $fs)
    :put ("Mounted:    " . $mounted)
    :put ("Size:       " . $size)
    :put ""

    :if ($state != "clean") do={
        :error ("raid10 is not clean: " . $state)
    }

    :if ($fs != "xfs") do={
        :error ("Expected XFS but found: " . $fs)
    }

    :if ($mounted != true) do={
        :error "raid10 is not mounted."
    }

    :put "Datastore validation successful."
}
```
</details>

Output:  
```bash
[admin@MikroTik-RDS] > /system/script/run verify-ocp-storage
==================================================
 OpenShift Storage Datastore
==================================================
State:      clean
Filesystem: xfs
Mounted:    true
Size:       16003143565312

Datastore validation successful.
```
### Build the TRIM Script:  
[Source: `Sources/trim-ocp-storage.rsc`](Sources/trim-ocp-storage.rsc)  
<details><summary><b>Show Script</b></summary>

<!-- embed-code: ./Sources/trim-ocp-storage.rsc -->  
```bash
/system/script/add name=trim-ocp-storage policy=read,write,policy,test source={

    :local rows [/disk print detail as-value where slot="raid10"]

    :if ([:len $rows] = 0) do={
        :error "raid10 does not exist."
    }

    :local state ($rows->0->"state")
    :local fs ($rows->0->"fs")
    :local mounted ($rows->0->"mounted")

    :if ($state != "clean") do={
        :error ("Skipping TRIM: raid10 state is " . $state)
    }

    :if ($fs != "xfs") do={
        :error ("Skipping TRIM: expected XFS but found " . $fs)
    }

    :if ($mounted != true) do={
        :error "Skipping TRIM: raid10 is not mounted."
    }

    :log info "Starting TRIM on OpenShift VM datastore raid10"

    /disk trim raid10

    :log info "Completed TRIM on OpenShift VM datastore raid10"
}
```
</details>

Set up the TRIM Schedule:
```bash
/system/scheduler/add \
    name=trim-ocp-storage-weekly \
    interval=7d \
    start-time=03:00:00 \
    on-event="/system/script/run trim-ocp-storage" \
    policy=read,write,policy,test
```
### Build the LUN Creation Script:  
[Source: `Sources/create-ocp-vm-lun.rsc`](Sources/create-ocp-vm-lun.rsc)  
<details><summary><b>Show Script</b></summary>
 
<!-- embed-code: ./Sources/create-ocp-vm-lun.rsc -->  
```bash
/system/script/add name=create-ocp-vm-lun policy=read,write,policy,test source={

    # ==================================================
    # EDIT THESE VALUES FOR EACH NEW VM BLOCK VOLUME
    # ==================================================

    :local volumeName "vm-storage-001"
    :local volumeSize "1T"
    :local nqn "nqn.2026-09.com.mikrotik:rds2216.vm-storage-001"

    # ==================================================

    :local backingFile ("raid10/" . $volumeName . ".img")

    :local raidRows [/disk print detail as-value where slot="raid10"]

    :if ([:len $raidRows] = 0) do={
        :error "raid10 does not exist."
    }

    :local raidState ($raidRows->0->"state")
    :local raidFs ($raidRows->0->"fs")
    :local mounted ($raidRows->0->"mounted")

    :if ($raidState != "clean") do={
        :error ("raid10 is not clean: " . $raidState)
    }

    :if ($raidFs != "xfs") do={
        :error ("raid10 is not XFS: " . $raidFs)
    }

    :if ($mounted != true) do={
        :error "raid10 is not mounted."
    }

    :if ([:len [/disk find where slot=$volumeName]] > 0) do={
        :error ("Disk object already exists: " . $volumeName)
    }

    :put "=================================================="
    :put " Creating OpenShift Virtualization block volume"
    :put "=================================================="
    :put ("Name:    " . $volumeName)
    :put ("Size:    " . $volumeSize)
    :put ("Backing: " . $backingFile)
    :put ("NQN:     " . $nqn)
    :put ""

    /disk add \
        type=file \
        slot=$volumeName \
        file-path=$backingFile \
        file-size=$volumeSize \
        mount-filesystem=no \
        mount-read-only=no \
        compress=no

    :delay 3s

    :local lun [/disk find where slot=$volumeName]

    :if ([:len $lun] = 0) do={
        :error "File-backed block volume creation failed."
    }

    /disk set $lun \
        nvme-tcp-export=yes \
        nvme-tcp-server-port=4420 \
        nvme-tcp-server-nqn=$nqn

    :delay 3s

    :local rows [/disk print detail as-value where slot=$volumeName]

    :local exported ($rows->0->"nvme-tcp-export")
    :local actualNqn ($rows->0->"nvme-tcp-server-nqn")
    :local port ($rows->0->"nvme-tcp-server-port")

    :if ($exported != true) do={
        :error "NVMe/TCP export was not enabled."
    }

    :put ""
    :put "=================================================="
    :put " VM BLOCK VOLUME READY"
    :put "=================================================="
    :put ("Target: 172.16.1.125:" . $port)
    :put ("NQN:    " . $actualNqn)
    :put ("Size:   " . $volumeSize)
    :put ("File:   " . $backingFile)
    :put ""
    :put "Discovery command:"
    :put ""
    :put "nvme discover -t tcp -a 172.16.1.125 -s 4420"
    :put ""
}
```
</details>

Create a LUN:  
```bash
[admin@MikroTik-RDS] > /system/script/run create-ocp-vm-lun
==================================================
 Creating OpenShift Virtualization block volume
==================================================
Name:    vm-storage-001
Size:    1T
Backing: raid10/vm-storage-001.img
NQN:     nqn.2026-09.com.mikrotik:rds2216.vm-storage-001


==================================================
 VM BLOCK VOLUME READY
==================================================
Target: 172.16.1.125:4420
NQN:    nqn.2026-09.com.mikrotik:rds2216.vm-storage-001
Size:   1T
File:   raid10/vm-storage-001.img

Discovery command:

nvme discover -t tcp -a 172.16.1.125 -s 4420
```
Check the RAID:  
```bash
[admin@MikroTik-RDS] > /disk/print detail where slot~"raid10"
Flags: B - BLOCK-DEVICE; M - MOUNTED; r - RAID-MEMBER
26 BM  type=raid slot="raid10" slot-default="" parent="" fs-label="ocp-storage" fs-uuid="40437dbc-2318-45dc-817b-b3bb95cf48ab" fs=xfs model="RAID0 striped" size=16 003 143 565 312 free=14 789 895 307 264 total-inodes=1 562 806 656
       free-inodes=1 562 806 652 use=8% mount-point="raid10" mount-filesystem=yes mount-read-only=no compress=no sector-size=512 raid-type=0 raid-device-count=4 raid-max-component-size=none raid-chunk-size=256K raid-master=none
       state="clean" raid-uuid="eadca0af-ecff031c-239758ad-951a47de" nvme-tcp-export=no iscsi-export=no nfs-sharing=no smb-sharing=no media-sharing=no media-interface=none swap=no
 
27 B r type=raid slot="raid10-m0" slot-default="" parent="" fs=- model="RAID1 mirrored" size=4 000 786 153 472 mount-filesystem=no mount-read-only=no compress=no sector-size=512 raid-type=1 raid-device-count=2 raid-max-component-size=none
       raid-master=raid10 raid-role=0 raid-member-failed=no raid-member-state="0:in_sync" state="clean" raid-uuid="5715669c-43873157-0ebaaa3a-7104d138" nvme-tcp-export=no iscsi-export=no nfs-sharing=no smb-sharing=no media-sharing=no
       media-interface=none swap=no
 
28 B r type=raid slot="raid10-m1" slot-default="" parent="" fs=- model="RAID1 mirrored" size=4 000 786 153 472 mount-filesystem=no mount-read-only=no compress=no sector-size=512 raid-type=1 raid-device-count=2 raid-max-component-size=none
       raid-master=raid10 raid-role=1 raid-member-failed=no raid-member-state="1:in_sync" state="clean" raid-uuid="0ad95faf-932c93bd-586c8835-8257cd88" nvme-tcp-export=no iscsi-export=no nfs-sharing=no smb-sharing=no media-sharing=no
       media-interface=none swap=no
 
29 B r type=raid slot="raid10-m2" slot-default="" parent="" fs=- model="RAID1 mirrored" size=4 000 786 153 472 mount-filesystem=no mount-read-only=no compress=no sector-size=512 raid-type=1 raid-device-count=2 raid-max-component-size=none
       raid-master=raid10 raid-role=2 raid-member-failed=no raid-member-state="2:in_sync" state="clean" raid-uuid="ebc29c04-3d2ac385-5f1a3ad1-4236381f" nvme-tcp-export=no iscsi-export=no nfs-sharing=no smb-sharing=no media-sharing=no
       media-interface=none swap=no
 
30 B r type=raid slot="raid10-m3" slot-default="" parent="" fs=- model="RAID1 mirrored" size=4 000 786 153 472 mount-filesystem=no mount-read-only=no compress=no sector-size=512 raid-type=1 raid-device-count=2 raid-max-component-size=none
       raid-master=raid10 raid-role=3 raid-member-failed=no raid-member-state="3:in_sync" state="clean" raid-uuid="e8e03b13-32cbf0e1-ba36b210-c32e0583" nvme-tcp-export=no iscsi-export=no nfs-sharing=no smb-sharing=no media-sharing=no
       media-interface=none swap=no
```
```bash
[admin@MikroTik-RDS] > :foreach r in={"raid10-m0";"raid10-m1";"raid10-m2";"raid10-m3";"raid10"} do={
{...     :local state ([/disk print detail as-value where slot=$r]->0->"state")
{...     :put ($r . " = " . $state)
{... }
raid10-m0 = clean
raid10-m1 = clean
raid10-m2 = clean
raid10-m3 = clean
raid10 = clean
```
Check the LUN:  
```bash
[admin@MikroTik-RDS] > /disk/print detail where slot="vm-storage-001"
Flags: B - BLOCK-DEVICE; t - NVME-TCP-EXPORT
31 Bt type=file slot="vm-storage-001" slot-default="" parent="" fs=- model="/raid10/vm-storage-001.img" size=1 099 511 627 776 mount-filesystem=no mount-read-only=no compress=no sector-size=512 raid-master=none nvme-tcp-export=yes
      nvme-tcp-server-port=4420 nvme-tcp-server-nqn="nqn.2026-09.com.mikrotik:rds2216.vm-storage-001" nvme-tcp-server-allow-host-name="" iscsi-export=no nfs-sharing=no smb-sharing=no media-sharing=no media-interface=none swap=no
      file-path=/raid10/vm-storage-001.img file-size=1024.0GiB file-offset=0
```