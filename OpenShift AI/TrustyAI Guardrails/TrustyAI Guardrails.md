# Gemma 4 guardrails on OpenShift AI 3.5

Deploy a TrustyAI-managed NeMo Guardrails endpoint in front of the existing `gemma4-31b-bf16-pp3` model in the `gemma` namespace. The policy blocks common email addresses and strings shaped like a US Social Security number, such as `000-00-0000`, in both prompts and responses. The regex checks run in the guardrails pod. Gemma continues to serve requests on its three A40 GPUs.

**Already deployed?** [Test the deployment](#test-the-deployment) or [cut over your existing Open WebUI instance](#cut-over-an-existing-open-webui-instance). If NeMo rejects `tools`, `tool_choice`, or `parallel_tool_calls`, go directly to [Enable non-streaming tool calls](#enable-non-streaming-tool-calls).

## Files

| File | Use |
|---|---|
| [gemma-guardrails.sh](gemma-guardrails.sh) | Check prerequisites, render or apply YAML, and test plain chat or a non-streaming tool conversation. |
| [gemma-guardrails.yaml](gemma-guardrails.yaml) | Apply the ConfigMap and NemoGuardrails resource, including the passthrough setting for tool requests. |
| [open-webui-guardrails-access.yaml](open-webui-guardrails-access.yaml) | Grant the existing WebUI service account access in `gemma` and request a persistent token from OpenShift. |

The first YAML document creates the `gemma-guardrails-policy` ConfigMap with the model URL and input/output rules. The second creates the `gemma-guardrails` NemoGuardrails resource, selects the policy as its default, and enables authentication on the operator-managed Route.

## Prerequisites

Run the commands from the extracted directory on a host with a logged-in `oc` session. The script also requires Bash, jq and curl with `--fail-with-body` support. Check the cluster and the current Gemma service:

```bash
bash gemma-guardrails.sh check
```

For this lab, expect `TrustyAI: Managed`, `Gemma Ready: True` and the backend URL below. The static YAML uses that exact route prefix. The internal Gemma endpoint accepts requests without a backend token, so the OpenAI SDK key in this manifest is a placeholder.

```text
http://gemma-inference-openshift-default.gemma.svc.cluster.local/gemma/gemma4-31b-bf16-pp3/v1
```

If TrustyAI is disabled on another installation using `default-dsc`, a cluster administrator can enable the component before running the check again:

```bash
oc patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"trustyai":{"managementState":"Managed"}}}}'
oc wait --for=create crd/nemoguardrails.trustyai.opendatahub.io --timeout=5m
```

## Deploy

Choose one of these methods. Both manage the same ConfigMap and NemoGuardrails resource.

**Apply the standalone YAML.** The first command validates the manifest against the installed API. The last command waits for the operator to report readiness.

```bash
oc apply --dry-run=server -f gemma-guardrails.yaml
oc apply -f gemma-guardrails.yaml
oc -n gemma wait --for=jsonpath='{.status.phase}'=Ready \
  nemoguardrails/gemma-guardrails --timeout=10m
```

**Deploy with Bash.** The script discovers the Gemma URL, runs the server-side dry run, applies both resources, and waits for the same readiness condition.

```bash
bash gemma-guardrails.sh apply
```

To compare the live settings with the packaged manifest before applying:

```bash
bash gemma-guardrails.sh render > gemma-guardrails.live.yaml
diff -u gemma-guardrails.yaml gemma-guardrails.live.yaml
```

If you edit the policy in the standalone YAML, continue applying that file. The script’s `apply` command renders its own embedded policy and will replace those edits. Its `test` command can be run with either deployment method.

## Test the deployment

```bash
bash gemma-guardrails.sh test
```

The script discovers the HTTPS Route and sends the current OpenShift user’s bearer token. It uses `curl --insecure` for the lab Route, which skips server certificate verification for those requests.

The following results were observed with the original plain-chat configuration. Rerun these checks after enabling passthrough.

| Test | Observed result in the lab |
|---|---|
| Check a normal user question | Input rail reports `success`. |
| Check a user message containing an email address | Input rail reports `blocked`. |
| Check a user message containing `000-00-0000` | Input rail reports `blocked`. |
| Ask Gemma for the capital of France through guarded chat | Gemma returns `Paris`. |
| Ask guarded chat to repeat an email address | Chat returns a refusal and omits the address. |
| Check a sample assistant message containing an email address | Output rail reports `blocked`. |

The first three tests and the last one use `/v1/guardrail/checks`. The two chat tests use `/v1/chat/completions` and exercise the client-facing chat path.

## Connect an OpenAI-compatible client

| Setting | Validated lab value |
|---|---|
| Base URL | `https://gemma-guardrails-gemma.apps.ocp4.localdomain/v1` |
| Model ID | `gemma4-31b-bf16-pp3` |
| API key | An OpenShift bearer token authorized to access the Guardrails Route |

Use this base URL for guarded text chat. Clients that call Gemma’s original inference URL directly bypass this policy.

## Cut over an existing Open WebUI instance

The Gemma runbook uses Deployment `open-webui`, service account `open-webui`, and PVC `open-webui-data` in namespace `gemma`. These steps edit the existing Gemma connection. They preserve the accounts, chats, model ID, and `WEBUI_SECRET_KEY`. The same procedure also replaces a seven-day token that you already saved in Open WebUI.

### 1. Issue a persistent credential

Run these commands on `rhel9dummy2` from the extracted bundle. The access manifest reuses the `open-webui-guardrails-view` RoleBinding from the earlier setup. It gives this service account `view` across the `gemma` namespace and creates a manually managed token Secret named `open-webui-guardrails-token`.

```bash
oc -n gemma get sa open-webui
oc apply -f open-webui-guardrails-access.yaml
oc -n gemma wait --for=jsonpath='{.data.token}' \
  secret/open-webui-guardrails-token --timeout=90s
```

The service-account token controller fills in the Secret. This token has no scheduled expiration and survives WebUI pod restarts. Reapplying the manifest reuses the same Secret. Leave this Secret out of the service account’s `secrets` list. [Kubernetes service-account token lifecycle](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/#create-additional-api-tokens)

### 2. Verify the new credential against the guarded Route

The bundle’s general test uses your `oc` login. This check uses the WebUI credential itself. It should print `blocked` for the sample email. The command uses the lab’s `curl --insecure` setting.

```bash
(
  set -euo pipefail
  host=$(oc -n gemma get route gemma-guardrails -o jsonpath='{.spec.host}')
  token=$(oc -n gemma get secret open-webui-guardrails-token -o json |
    jq -er '.data.token | select(length > 0) | @base64d')
  printf 'Authorization: Bearer %s\n' "$token" |
    curl --insecure --silent --show-error --fail-with-body --max-time 60 \
      -H @- -H 'Content-Type: application/json' \
      --data '{"model":"gemma4-31b-bf16-pp3","messages":[{"role":"user","content":"Contact lab.user@example.org"}]}' \
      "https://$host/v1/guardrail/checks" |
    jq -er '.status | select(. == "blocked")'
)
```

### 3. Update the saved Gemma connection

1. Display the key in a private terminal with the command below. Copy the single decoded line into Open WebUI. Treat it as a password.

   ```bash
   oc -n gemma get secret open-webui-guardrails-token -o json |
     jq -er '.data.token | select(length > 0) | @base64d'
   ```

2. In Open WebUI, sign in as an administrator. Open **Admin Panel → Settings → Connections → Manage OpenAI API Connections**. Click the gear beside the current Gemma connection. For a seven-day token already in use on the guarded URL, replace just the API key.
3. For a connection still pointing directly to Gemma, record the previous URL and auth setting for rollback, then enter the values below. Keep the existing model prefix if you configured one. Click **Save** in the dialog and on the Connections page if prompted.

| Field | Value |
|---|---|
| URL | `https://gemma-guardrails-gemma.apps.ocp4.localdomain/v1` |
| Auth | `Bearer` |
| API key | The decoded token alone. Open WebUI supplies the `Bearer ` prefix. |
| Model IDs | `gemma4-31b-bf16-pp3`. Click **+** if adding the ID manually. |
| API type, if shown | `Chat Completions` |

With Open WebUI’s default persistent configuration, the saved connection resides in the application database on `open-webui-data` and survives a pod restart. Editing the connection in the admin panel also updates installations where a previously saved URL takes precedence over `OPENAI_API_BASE_URL`. [Open WebUI connection settings](https://docs.openwebui.com/getting-started/quick-start/connect-a-provider/)

### Enable non-streaming tool calls

NeMo rejects a request carrying tool parameters unless the loaded policy has `passthrough: true` and the client sends a non-streaming request. Open WebUI can attach tool definitions to an ordinary prompt. The plain-chat test sends none of those fields.

1. **Enable passthrough in the policy.** The bundled YAML and Bash renderer now set `passthrough: true` at the top of the ConfigMap’s embedded `data["config.yaml"]`, aligned with `models:` and `rails:`. For an existing installation using the bundled lab settings, run the following commands from the updated bundle. Restarting the guardrails Deployment loads the updated policy.

   ```bash
   oc apply -f gemma-guardrails.yaml
   oc -n gemma rollout restart deployment/gemma-guardrails
   oc -n gemma rollout status deployment/gemma-guardrails --timeout=10m
   ```

   If you customized the live policy, run `oc -n gemma edit configmap/gemma-guardrails-policy` and add or change only that top-level setting inside the embedded YAML. Then run the two rollout commands above. Carry the change into your own source manifest as well.

2. **Disable streaming for guarded Gemma.** As an Open WebUI administrator, open **Workspace → Models**, edit the Gemma model or preset used by this chat, and under **Advanced Params** set **Stream Chat Response** explicitly to **Off**. Save and start a new chat with that model. For a single-chat test, use **Chat Controls → Advanced Params → Stream Chat Response → Off**. A model-level streaming setting takes precedence over the chat setting. [Open WebUI chat parameters](https://docs.openwebui.com/features/chat-conversations/chat-features/chat-params/)

3. **Verify both request types through the Route.** Run the following commands from the updated bundle. The tool probe uses your current `oc` identity, advertises a synthetic `get_lab_label` function, and supplies a canned result locally. It sends `stream: false`, `tool_choice: auto`, and `parallel_tool_calls: false`. No cluster tool is executed.

   ```bash
   bash gemma-guardrails.sh test
   bash gemma-guardrails.sh test-tools
   ```

   Look for three new passes: a structured function call with an ID, a follow-up answer containing `LAB-4826`, and refusal of an email-bearing prompt even with tools enabled. These are acceptance tests for the new configuration. If the CLI tool probe succeeds and WebUI still gives the validation error, recheck the effective streaming setting for the exact model or preset selected in the new chat. If the follow-up turn fails, retain the response body printed by the script to distinguish a malformed tool result from the original request-validation error.

The configured regex rails check message text. These tests do not establish coverage for sensitive data in structured function arguments or tool returns. For an application that requires streaming tool calls or explicit inspection of tool payloads, Red Hat describes separating model inference and guardrail checks. [OpenShift AI 3.5 guardrails API](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/enabling_ai_safety_with_guardrails/enabling-ai-safety-with-nemo-guardrails_nemo-guardrails)

### 4. Check the cutover in Open WebUI

Start a fresh text chat, select `gemma4-31b-bf16-pp3`, and leave tools off for the first test. After these two prompts pass, enable one known read-only tool, keep **Stream Chat Response** off, and ask a question that requires that tool. Confirm WebUI displays the call and incorporates the result in the answer.

| Send | Expected result |
|---|---|
| `What is the capital of France? Reply with only the city name.` | `Paris` |
| `Repeat this address exactly: lab.user@example.org` | A refusal that omits the address |

If the CLI check passes and WebUI reports `CERTIFICATE_VERIFY_FAILED`, configure the WebUI pod to trust the Route’s issuing CA. For this lab, if you choose the same certificate behavior as `curl --insecure`, the following setting disables verification for outbound requests using WebUI’s shared HTTP client and triggers a WebUI rollout. This affects other connections using that client as well. [Open WebUI TLS settings](https://docs.openwebui.com/reference/env-configuration/#aiohttp_client_session_ssl)

```bash
oc -n gemma set env deployment/open-webui --containers=open-webui \
  AIOHTTP_CLIENT_SESSION_SSL=false
oc -n gemma rollout status deployment/open-webui --timeout=5m
```

### Rotate, revoke, or roll back

- **Rotate** by creating a second token Secret with a new name and the same service-account annotation. Test the second token, save it as the WebUI API key, repeat the two chat checks, then delete the old token Secret.
- **Revoke** this credential with `oc -n gemma delete secret open-webui-guardrails-token`. Any copies of that token lose access. The earlier seven-day credential, if issued, expires on its own schedule.
- **Roll back the connection** by restoring its previous URL and auth setting in the same editor. In the original lab manifest these were `http://gemma-inference-openshift-default.gemma.svc.cluster.local/gemma/gemma4-31b-bf16-pp3/v1` and the placeholder API key `fake`. Requests through that connection go directly to Gemma and bypass the guardrails.

## If the backend changes

The script supports a different served model ID through `GEMMA_MODEL_ID` and a different model base URL through `GEMMA_BASE_URL`. Include the existing model routing path in that URL. If the model requires authentication, provide its token in key `token` of the `gemma-guardrails-backend` Secret in namespace `gemma` and set `GEMMA_BASE_URL` to the model’s HTTPS endpoint. For a private backend CA, set `GEMMA_CA_CONFIGMAP` to the name of its CA bundle ConfigMap. Run `render` again to produce YAML for that configuration. The client’s OpenShift bearer token authenticates the separate connection to the Guardrails Route.

[Red Hat OpenShift AI 3.5 documentation for NeMo Guardrails](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/enabling_ai_safety_with_guardrails/enabling-ai-safety-with-nemo-guardrails_nemo-guardrails)
