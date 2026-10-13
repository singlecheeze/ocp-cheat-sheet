# Cleaning the OpenShift Internal Image Registry

This procedure checks registry usage and reclaims orphaned blobs left by failed image or model uploads.

**Environment:** OpenShift 4.22, registry namespace `openshift-image-registry`, deployment `image-registry`, PVC `odf-image-registry-pvc`.

> Hard pruning operates across the entire internal registry. Schedule a registry write outage and finish or stop all active image pushes and model transfers before cleanup. Do not manually delete files under `/registry`.

## 1. Inspect storage usage

Check filesystem capacity and available space:

```bash
oc exec -n openshift-image-registry deployment/image-registry -- \
  df -h /registry

oc get pvc odf-image-registry-pvc -n openshift-image-registry
```

Separate completed blobs from repository metadata and temporary uploads:

```bash
oc exec -n openshift-image-registry deployment/image-registry -- \
  du -h --max-depth=1 /registry/docker/registry/v2
```

Find the largest unfinished-upload directories:

```bash
oc exec -n openshift-image-registry deployment/image-registry -- \
  sh -c 'find /registry/docker/registry/v2/repositories \
    -type d -name _uploads -prune -exec du -sh {} \;' |
  sort -hr |
  head -20
```

| Location | Meaning |
| --- | --- |
| `blobs` | Completed layer, configuration, and manifest blobs; some may be orphaned |
| `repositories` | Repository metadata and temporary upload data |
| `_uploads` | In-progress or abandoned upload data |

Completed blobs do not necessarily mean a complete image was published. A push can upload layers and fail before publishing its final manifest.

## 2. Inspect image metadata and pruning configuration

```bash
oc get imagestreams -n ai-test

oc get imagestreamtag qwen36-35b-a3b-fp8:v1 -n ai-test

oc get imagepruner.imageregistry.operator.openshift.io cluster -o yaml
```

A missing tag does not prove all registry blobs are unused. The automatic image pruner and hard pruner address different cases: hard pruning removes orphaned blobs not referenced by OpenShift image metadata.

## 3. Grant the registry service account pruning permissions

Run as a cluster administrator. Skip this step if the binding was already added.

```bash
REGISTRY_SA=$(oc get deployment image-registry \
  -n openshift-image-registry \
  -o jsonpath='{.spec.template.spec.serviceAccountName}')

oc adm policy add-cluster-role-to-user system:image-pruner \
  -z "$REGISTRY_SA" \
  -n openshift-image-registry
```

This grants the registry service account additional cluster-level permissions required by the hard pruner.

## 4. Preview orphaned blobs

This command does not delete data:

```bash
oc exec -n openshift-image-registry deployment/image-registry -- \
  /usr/bin/dockerregistry -prune=check
```

The observed dry run reported:

```text
Would delete 61 blobs
Would free up 31.83GiB of disk space
```

These were point-in-time results, not a guarantee for subsequent runs. An online check can change while uploads are active.

## 5. Put the registry into read-only mode

Finish or stop active pushes and model transfers first. Writes to the entire internal registry will be unavailable during this maintenance window.

```bash
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type=merge -p '{"spec":{"readOnly":true}}'
```

Wait for the operator to update the deployment. Repeat this check until it prints `true`:

```bash
oc get deployment image-registry -n openshift-image-registry \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED")].value}{"\n"}'
```

Then wait for the updated deployment to finish rolling out:

```bash
oc rollout status deployment/image-registry \
  -n openshift-image-registry --timeout=300s
```

**Do not proceed to deletion if read-only mode is not confirmed or the rollout fails.**

## 6. Recheck and reclaim orphaned blobs

Run the dry check again with writes disabled:

```bash
oc exec -n openshift-image-registry deployment/image-registry -- \
  /usr/bin/dockerregistry -prune=check
```

Review the summary. If the check succeeds and the proposed cleanup is acceptable, perform the deletion:

```bash
oc exec -n openshift-image-registry deployment/image-registry -- \
  /usr/bin/dockerregistry -prune=delete
```

This deletes orphaned blobs registry-wide. It is not a general command for removing all unused images or all abandoned upload directories.

Red Hat's full maintenance procedure also includes basic image pruning before hard pruning to make additional obsolete images eligible. This focused procedure preserves existing image metadata and targets blobs already identified as orphaned.

## 7. Restore registry writes

After the prune process has exited, restore writes even if it reported an error:

```bash
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type=merge -p '{"spec":{"readOnly":false}}'
```

Repeat this check until the deployment shows `false`:

```bash
oc get deployment image-registry -n openshift-image-registry \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED")].value}{"\n"}'
```

Wait for reconciliation, then restart the registry to clear cached blob metadata:

```bash
oc rollout status deployment/image-registry \
  -n openshift-image-registry --timeout=300s

oc rollout restart deployment/image-registry -n openshift-image-registry

oc rollout status deployment/image-registry \
  -n openshift-image-registry --timeout=300s
```

## 8. Verify recovered capacity and registry health

```bash
oc exec -n openshift-image-registry deployment/image-registry -- \
  df -h /registry

oc get co image-registry
```

Confirm available space increased and the registry operator is available and not degraded before starting another transfer. If no writes occurred between measurements, the free-space increase should approximately match the pruner's reported reclaimed bytes.

## Reference

[OpenShift 4.22 — Pruning objects to reclaim resources](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/building_applications/pruning-objects), especially **Hard pruning the registry** and **Image pruning considerations**.

