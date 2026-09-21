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