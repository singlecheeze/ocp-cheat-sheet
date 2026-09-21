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