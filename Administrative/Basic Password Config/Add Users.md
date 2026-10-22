# Add Users to OpenShift

**OpenShift Container Platform 4.22 · Existing HTPasswd identity provider**

This guide adds a login to an existing HTPasswd provider, grants cluster administrator access, and verifies both the password and login. Run the commands from a Bash shell while logged in with an existing cluster administrator account.

> Authentication and authorization are separate: the HTPasswd secret provides login credentials; the `cluster-admin` role grants permissions. Granting the role alone does not create a working login.

## Prerequisites

- An existing HTPasswd identity provider.
- The `oc` CLI configured for the intended cluster.
- `jq` and `htpasswd` on your administration workstation.

On RHEL, install the utilities if needed:

```bash
sudo dnf install -y httpd-tools jq
```

Confirm your current account and cluster:

```bash
oc whoami
oc whoami --show-server
```

## 1. Identify the provider and its secret

```bash
oc get oauth cluster -o json |
jq -r '.spec.identityProviders[]
  | select(.type == "HTPasswd")
  | [.name, .htpasswd.fileData.name] | @tsv'
```

The first column is the provider name shown on the login page. The second is its secret in `openshift-config`.

Example:

```text
Basic   htpasswd-example
```

Set the following variables using your actual values. If several providers are listed, choose the intended one.

```bash
IDP_NAME='Basic'
HTPASS_SECRET='htpasswd-example'
NEW_USER='newadmin'
```

> Copy the secret name exactly. For example, `htpass-example` and `htpasswd-example` are different names.

## 2. Retrieve the existing credentials

Use a private temporary directory. Enable pipeline failure detection so a failed secret lookup is not mistaken for a successful download.

```bash
umask 077
set -o pipefail
USER_WORKDIR=$(mktemp -d)

oc get secret "$HTPASS_SECRET" -n openshift-config \
  -o jsonpath='{.data.htpasswd}' |
base64 --decode > "$USER_WORKDIR/users.htpasswd"
```

**Stop if the command reports an error.** Correct the secret name or permissions and repeat the download before continuing. Check that the file is not empty:

```bash
test -s "$USER_WORKDIR/users.htpasswd" && echo 'Existing user file retrieved.'
```

Do not proceed unless the confirmation appears. Keep the existing entries so current users retain access.

## 3. Add the user and verify the password

```bash
htpasswd -B "$USER_WORKDIR/users.htpasswd" "$NEW_USER"
```

Enter the password twice when prompted. The `-B` option generates a bcrypt hash. If the username already exists, this updates its password.

> Do not use `-c`: it recreates the file and removes its existing users. Password prompts also avoid putting the password directly in shell history.

Verify the password before uploading:

```bash
htpasswd -v "$USER_WORKDIR/users.htpasswd" "$NEW_USER"
```

Expected result:

```text
Password for user newadmin correct.
```

If verification fails, repeat the password-setting command and verify again.

## 4. Update the cluster secret

```bash
oc create secret generic "$HTPASS_SECRET" \
  -n openshift-config \
  --from-file=htpasswd="$USER_WORKDIR/users.htpasswd" \
  --dry-run=client -o yaml |
oc replace -f -
```

Expected result:

```text
secret/htpasswd-example replaced
```

Coordinate with other administrators so nobody updates the same user file between your download and upload. Allow a few minutes for authentication changes to propagate.

## 5. Grant cluster administrator access

This role grants full administrative access across the cluster.

```bash
oc adm policy add-cluster-role-to-user cluster-admin "$NEW_USER"
```

A warning such as `User 'newadmin' not found` can appear before the user's first successful login. The role binding can still be created; the warning alone does not indicate a password problem.

Check the authorization:

```bash
oc auth can-i '*' '*' --all-namespaces --as="$NEW_USER"
```

Expected output: `yes`.

**This checks permissions through impersonation. It does not test the password or prove that login works.**

## 6. Test the actual login

### Web console

1. Open the console in a private/incognito browser window.
2. Select the provider identified in step 1, such as `Basic`.
3. Enter the new username and password.
4. Confirm that the console opens with the expected administrative access.

### CLI without changing your administrator session

Use a separate temporary kubeconfig:

```bash
TEST_KUBECONFIG=$(mktemp)

oc login "$(oc whoami --show-server)" \
  --username="$NEW_USER" \
  --kubeconfig="$TEST_KUBECONFIG"
```

Enter the password when prompted. Use your organization's trusted CA if the separate kubeconfig requires certificate configuration.

After a successful login, confirm the authenticated identity and permissions:

```bash
oc --kubeconfig="$TEST_KUBECONFIG" whoami
oc --kubeconfig="$TEST_KUBECONFIG" auth can-i '*' '*' --all-namespaces
```

Expected outputs are the new username and `yes`.

## Troubleshooting

### Verify the password stored in the live secret

Download the secret again into a separate file so the check uses the cluster's current contents:

```bash
oc get secret "$HTPASS_SECRET" -n openshift-config \
  -o jsonpath='{.data.htpasswd}' |
base64 --decode > "$USER_WORKDIR/live.htpasswd"

htpasswd -v "$USER_WORKDIR/live.htpasswd" "$NEW_USER"
```

Stop if retrieval fails. If the password does not verify, repeat steps 2–4 using a fresh download of the secret, then retry login.

### Inspect authentication and identity mapping

If the live password verifies but login fails, run these commands from the existing administrator session:

```bash
oc get clusteroperator authentication
oc get pods -n openshift-authentication

oc get oauth cluster -o json |
jq --arg provider "$IDP_NAME" \
  '.spec.identityProviders[] | select(.name == $provider)'

oc get user "$NEW_USER" -o yaml
oc get identity "${IDP_NAME}:${NEW_USER}" -o yaml
```

Record the exact browser or CLI error alongside these results. A missing User or Identity can be expected before a successful first login; do not manually create or delete them solely because of `NotFound`.

| Symptom | What to check |
| --- | --- |
| Secret not found | Copy the exact secret name from the OAuth configuration. |
| Password verification error during creation | The two password entries may differ; run `htpasswd -B` again. |
| Live password verification fails | Reset the password using a fresh secret download and upload the updated file. |
| Permission check says `yes`, but login fails | Permissions are configured; investigate credentials, selected provider, and authentication status. |
| Browser fails but CLI login succeeds | Retry in a private window and select the correct provider. |
| Live password verifies but both login methods fail | Inspect the authentication operator, pods, provider configuration, and identity mapping. |

## Cleanup

After confirming successful login, remove the temporary files containing password hashes and the test kubeconfig:

```bash
rm -f "$USER_WORKDIR/users.htpasswd" "$USER_WORKDIR/live.htpasswd"
rmdir "$USER_WORKDIR"

if [ -n "${TEST_KUBECONFIG:-}" ]; then
  rm -f "$TEST_KUBECONFIG"
fi
```

## Reference

[Red Hat: How to configure an HTPasswd identity provider in OpenShift 4](https://access.redhat.com/solutions/4039941), including the procedure for updating users in an existing provider.
