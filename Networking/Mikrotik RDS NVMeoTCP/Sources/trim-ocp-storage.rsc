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