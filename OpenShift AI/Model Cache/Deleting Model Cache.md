# Deleting Model Cache

Cleanup procedure for OpenShift AI 3.5 on OpenShift 4.22.

Disable model caching, remove the cache resources, and clear any files left on each node. Deleting PV/PVC objects alone does not confirm that disk space was reclaimed.

## 1. Stop or move workloads using the cache

Move any model-serving workloads that mount the cache to your replacement model source and recreate their pods before clearing the directory. Existing pods can still reference cached files.

## 2. Confirm the cache path before removing resources

```bash
oc get localmodelnodegroup -o json |
jq -r '.items[] |
  [.metadata.name, .spec.persistentVolumeSpec.local.path] | @tsv'
```

OpenShift AI 3.5 documents `/var/lib/kserve/models` as the cache path. Confirm this matches your configuration. The filesystem commands below use that path.

## 3. Delete the cache definitions

For the Llama cache in `ai-test`:

```bash
oc delete localmodelnamespacecache llama-3-3-70b-w8a8 -n ai-test
```

Check for other caches:

```bash
oc get localmodelnamespacecache -A
oc get localmodelcache
```

If you want to remove **all model caches across the cluster**, use:

```bash
oc delete localmodelnamespacecache --all -A
oc delete localmodelcache --all
```

## 4. Disable model caching in OpenShift AI

```bash
oc patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"kserve":{"modelCache":{"managementState":"Removed"}}}}}'
```

`Removed` disables model caching while leaving KServe enabled.

Verify that the cache agents and download pods have stopped before deleting files:

```bash
oc get daemonset -n redhat-ods-applications localmodelnode-agent
oc get pods -n redhat-ods-applications -o wide
```

Do not proceed while cache download or model-serving pods still use the directory. A missing agent DaemonSet after removal is expected.

## 5. Inspect storage usage on each node

```bash
for node in ocp113.localdomain ocp114.localdomain ocp115.localdomain; do
  oc debug "node/$node" -- chroot /host sh -c '
    du -sh /var/lib/kserve/models
    df -h /var/lib/kserve/models
  '
done
```

## 6. Remove remaining cache files

**This permanently deletes all contents of `/var/lib/kserve/models` on the listed nodes, including partial downloads.** Run it only after confirming that the directory is dedicated to model caching and no serving or download pods use it. The directory itself is preserved.

```bash
for node in ocp113.localdomain ocp114.localdomain ocp115.localdomain; do
  oc debug "node/$node" -- chroot /host sh -c '
    set -eu
    cache_dir=/var/lib/kserve/models
    test -d "$cache_dir"
    find "$cache_dir" -mindepth 1 -maxdepth 1 \
      -exec rm -rf -- {} +
    du -sh "$cache_dir"
    df -h "$cache_dir"
  '
done
```

Compare the `df` output before and after cleanup to confirm reclaimed filesystem space. If files remain open in a process, their space is reclaimed only after those file handles close.

## 7. Inspect leftover cache resources

```bash
oc get pv -l kserve/localmodel
oc get pvc -A -l kserve/localmodel
oc get localmodelnodegroup
oc get localmodelnode
```

Delete any remaining objects specifically belonging to the retired cache by name:

```bash
oc delete pvc <cache-pvc-name> -n <namespace>
oc delete pv <cache-pv-name>
oc delete localmodelnodegroup <cache-node-group-name>
oc delete localmodelnode <cache-node-name>
```

Replace the placeholders with verified cache resource names. Delete the PVC before its PV. Do not delete unrelated storage resources or remove protection finalizers to force deletion.

## Reference

[Red Hat OpenShift AI 3.5: Cache models on local storage](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/configuring_your_model-serving_platform/caching-models-on-local-storage_rhoai-admin)

