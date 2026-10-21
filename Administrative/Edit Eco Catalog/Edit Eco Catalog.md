# Restore the OpenShift Software Catalog

**Environment:** OpenShift 4.21.27, installed using the Assisted Installer on console.redhat.com in offline mode; internet access added afterward.

## Summary

Two blockers were identified:

1. The default Operator catalogs remained disabled after the offline installation.
2. After enabling them, a firewall blocked the catalog image pulls from `registry.redhat.io`.

The OpenShift update server (`https://api.openshift.com/api/upgrades_info/v1/graph`) controls cluster version updates. It does not enable or populate the Software Catalog.

## 1. Check whether the default catalogs are disabled

```bash
oc get operatorhub.config.openshift.io cluster -o yaml
```

The configuration showed:

```yaml
spec:
  disableAllDefaultSources: true
```

All four default sources were disabled: `redhat-operators`, `certified-operators`, `community-operators`, and `redhat-marketplace`.

## 2. Enable the default catalogs

```bash
oc patch operatorhub.config.openshift.io cluster \
  --type=merge \
  -p '{"spec":{"disableAllDefaultSources":false}}'
```

The patch succeeded and the catalog pods were created. If a different cluster has individual entries under `spec.sources` with `disabled: true`, review those overrides as well.

## 3. Check catalog sources and pods

```bash
oc get catalogsources -n openshift-marketplace
oc get pods -n openshift-marketplace
```

The catalog pods initially showed `Init:RegistryUnavailable`, then `Init:ImagePullBackOff` after several minutes.

## 4. Inspect the failed image pull

Use the current pod name from the preceding command. In this case:

```bash
oc describe pod -n openshift-marketplace redhat-operators-66fg4
```

The `extract-content` init container was trying to pull:

```text
registry.redhat.io/redhat/redhat-operator-index:v4.21
```

The pod events showed:

```text
Get "https://registry.redhat.io/v2/":
dial tcp 54.160.108.93:443: connect: connection refused
```

This established that the hostname resolved, but the TCP connection failed before TLS or authentication. The failure did not indicate a pull-secret problem. The successful `extract-utilities` container used an image already cached on the node, so its success did not prove external registry access.

## 5. Correct the firewall access

The firewall was confirmed to be blocking image pulls. Permit the required outbound HTTPS traffic from the cluster nodes to the registry and associated image-download endpoints.

Use the [OpenShift 4.21 firewall requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/installation_configuration/configuring-firewall) for the complete allowlist. Avoid relying on the individual registry IP addresses in the error messages, because those addresses can change.

The following diagnostic commands were suggested to distinguish direct connectivity from a proxy-dependent path. Run the curl commands on the affected node:

```bash
# Test direct connectivity, bypassing shell proxy settings.
curl --noproxy '*' -v --connect-timeout 10 \
  https://registry.redhat.io/v2/

# Test using the shell's normal connection path.
curl -v --connect-timeout 10 \
  https://registry.redhat.io/v2/

# Inspect the cluster-wide proxy configuration.
oc get proxy.config.openshift.io cluster -o yaml
```

An HTTP `401 Unauthorized` response to this unauthenticated registry request demonstrates successful HTTPS connectivity; it does not validate image-pull credentials. No proxy change was established as necessary in this incident.

## 6. Verify recovery

After correcting firewall access, allow the pods to retry automatically:

```bash
oc get pods -n openshift-marketplace -w
```

Wait for catalog pods to reach `1/1 Running`, then refresh the Software Catalog. Press `Ctrl+C` to stop watching.

Optionally inspect the catalog connection states:

```bash
oc get catalogsources -n openshift-marketplace \
  -o custom-columns='NAME:.metadata.name,STATE:.status.connectionState.lastObservedState'
```

The expected connection state is `READY`.

**Recorded outcome:** The default catalogs were successfully re-enabled, and the firewall block was confirmed. Final healthy pod output was not provided in the troubleshooting exchange; the commands above are the recovery checks.

## Separate check: Devfiles warning

The original console message was:

> Devfiles content is not available in the catalog at this time due to loading failures.

Devfile content uses a separate endpoint, `https://registry.devfile.io`. Enabling Operator catalogs does not by itself resolve a Devfile connectivity failure.

If this banner remains after the Operator catalogs recover, inspect console logs:

```bash
oc logs -n openshift-console \
  -l app=console \
  -c console \
  --since=30m \
  --prefix=true |
  grep -Ei 'devfile|registry.devfile.io'
```

Use the error to check DNS, outbound HTTPS access, proxy configuration, or certificate trust for the console pods. Resolution of the Devfiles warning was not separately confirmed in this incident.
