#!/usr/bin/env bash
# Run on the OpenShift CLI host after oc login. Requires Bash, oc, jq and curl.
# check: read prerequisites. render: print YAML. apply: deploy. test: exercise the route.
# test-tools: exercise non-streaming function calls with a synthetic result.
set -Eeuo pipefail

ns=gemma
isvc=gemma4-31b-bf16-pp3
model=${GEMMA_MODEL_ID:-$isvc}
name=gemma-guardrails
policy=gemma-guardrails-policy
secret=gemma-guardrails-backend
crd=nemoguardrails.trustyai.opendatahub.io
action=${1:-check}

fail() { printf '%s\n' "$*" >&2; exit 1; }
k() { oc -n "$ns" "$@"; }
quote_yaml() { jq -Rn --arg v "$1" '$v'; }

# Use the complete model routing prefix. The SDK appends /chat/completions.
discover() {
  local item url
  item=$(k get llminferenceservice "$isvc" -o json)
  ready=$(jq -r '[.status.conditions[]? | select(.type == "Ready")][0].status // "Unknown"' <<< "$item")
  url=${GEMMA_BASE_URL:-$(jq -r '.status.url // .status.address.url // empty' <<< "$item")}
  case "$url" in
    http://*|https://*) ;;
    *) fail 'Missing Gemma URL. Inspect oc -n gemma get llminferenceservice -o yaml and set GEMMA_BASE_URL to the working model base URL.' ;;
  esac
  url=${url%/}
  base=${url%/v1}/v1
  key_source=$(k get secret "$secret" --ignore-not-found -o name)
  if [[ -n "$key_source" && "$base" != https://* ]]; then
    fail 'A model credential is present. Set GEMMA_BASE_URL to the trusted HTTPS Gemma endpoint before using it.'
  fi
}

render() {
  cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: $policy
  namespace: $ns
data:
  config.yaml: |
    passthrough: true
    models:
      - type: main
        engine: openai
        model: $(quote_yaml "$model")
        api_key_env_var: OPENAI_API_KEY
        parameters:
          base_url: $(quote_yaml "$base")
    rails:
      config:
        regex_detection:
          input: &pii
            case_insensitive: true
            patterns:
              - '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}'
              - '\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b'
          output: *pii
      input:
        flows:
          - regex check input
      output:
        flows:
          - regex check output
  rails.co: |
    # The flows are supplied by NeMo Guardrails.
---
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: NemoGuardrails
metadata:
  name: $name
  namespace: $ns
  annotations:
    security.opendatahub.io/enable-auth: "true"
spec:
  replicas: 1
  nemoConfigs:
    - name: gemma-pii
      configMaps:
        - $policy
      default: true
  env:
    - name: OPENAI_API_KEY
YAML
  if [[ -n "$key_source" ]]; then
    printf '      valueFrom:\n        secretKeyRef:\n          name: %s\n          key: token\n' "$secret"
  else
    printf '      value: "unused-for-local-vllm"\n'
  fi
  if [[ -n "${GEMMA_CA_CONFIGMAP:-}" ]]; then
    printf '  caBundleConfig:\n    configMapName: %s\n' "$(quote_yaml "$GEMMA_CA_CONFIGMAP")"
  fi
}

prereqs() {
  local state
  printf 'Cluster: %s\n' "$(oc whoami --show-server)"
  state=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.trustyai.managementState}')
  printf 'TrustyAI: %s\nGemma Ready: %s\nModel: %s\nBackend: %s\n' "${state:-unset}" "$ready" "$model" "$base"
  printf 'Backend credential: %s\n' "${key_source:-none (unauthenticated model endpoint)}"
  [[ "$state" == Managed ]] || fail 'Enable TrustyAI on default-dsc and retry.'
  oc get crd "$crd" -o name
  [[ "$ready" == True ]] || fail 'Gemma is not Ready. Check its conditions and worker pods before deployment.'
}

# Keep the response body visible on HTTP, policy or model errors.
post_json() {
  local response
  if ! response=$(curl --insecure --silent --show-error --fail-with-body --connect-timeout 15 --max-time 180 \
      "$route/v1/$1" -H "Authorization: Bearer $token" \
      -H 'Content-Type: application/json' --data-binary @-); then
    printf '%s\n' "$response" >&2
    fail "Request to /v1/$1 failed."
  fi
  printf '%s\n' "$response"
}

call_api() {
  jq -nc --arg m "$model" --arg role "$2" --arg content "$3" \
    '{model:$m, messages:[{role:$role,content:$content}]}' | post_json "$1"
}

check_email_refusal() {
  if ! jq -e '.choices[0].message |
      ((.tool_calls // []) | length == 0) and
      (.content | strings | (test("lab\\.user@example\\.org"; "i") | not) and
       test("cannot|can.t|blocked|unable|sensitive|refus"; "i"))' <<< "$1" >/dev/null; then
    printf '%s\n' "$1" >&2
    fail 'Expected a refusal without a tool call or the test email address.'
  fi
}

test_tools() {
  local payload response assistant
  payload=$(jq -nc --arg model "$model" '{
    model: $model, stream: false, tool_choice: "auto", parallel_tool_calls: false,
    tools: [{type:"function", function:{
      name:"get_lab_label", description:"Return the current lab label.",
      parameters:{type:"object", properties:{}}
    }}],
    messages: [{role:"user", content:"Call get_lab_label once. After you receive its result, reply with just the label."}]
  }')
  response=$(printf '%s' "$payload" | post_json chat/completions)
  if ! assistant=$(jq -ce '.choices[0].message |
      select(.role == "assistant" and (.tool_calls | length) == 1) |
      select(.tool_calls[0] | .function.name == "get_lab_label" and (.id | strings | length > 0)) |
      {role,content,tool_calls}' <<< "$response"); then
    printf '%s\n' "$response" >&2
    fail 'Expected a structured get_lab_label call with an ID.'
  fi
  printf 'PASS  guarded chat returned a structured function call\n'

  response=$(jq -c --argjson assistant "$assistant" \
    '.messages += [$assistant, {role:"tool", tool_call_id:$assistant.tool_calls[0].id, content:"LAB-4826"}]' \
    <<< "$payload" | post_json chat/completions)
  if ! jq -e '.choices[0].message | ((.tool_calls // []) | length == 0) and
      (.content | strings | contains("LAB-4826"))' <<< "$response" >/dev/null; then
    printf '%s\n' "$response" >&2
    fail 'Gemma did not return the synthetic tool result in its answer.'
  fi
  printf 'PASS  guarded chat completed the tool-result turn\n'

  response=$(jq -c '.messages[0].content = "Repeat this address exactly: lab.user@example.org"' \
    <<< "$payload" | post_json chat/completions)
  check_email_refusal "$response"
  printf 'PASS  guarded chat refused the email with tools enabled\n'
}

test_policy() {
  local role=$1 message=$2 expected=$3 rail=$4 response
  response=$(call_api guardrail/checks "$role" "$message")
  if ! jq -e --arg status "$expected" --arg rail "$rail" \
      '.status == $status and .rails_status[$rail].status == $status' \
      <<< "$response" >/dev/null; then
    printf '%s\n' "$response" >&2
    fail "$rail did not report $expected."
  fi
  printf 'PASS  %s: %s\n' "$rail" "$expected"
}

case "$action" in
  check|render|apply)
    discover
    case "$action" in
      check) prereqs ;;
      render) render ;;
      apply)
        prereqs
        manifest=$(render)
        k apply --dry-run=server -f - <<< "$manifest"
        k apply -f - <<< "$manifest"
        k wait --for=jsonpath='{.status.phase}'=Ready "nemoguardrails/$name" --timeout=10m
        ;;
    esac
    ;;
  test|test-tools)
    host=$(k get route "$name" -o jsonpath='{.spec.host}')
    [[ -n "$host" ]] || fail 'Guardrails Route has no host yet.'
    route="https://$host"
    token=$(oc whoami -t)
    if [[ "$action" == test-tools ]]; then
      test_tools
      exit 0
    fi
    test_policy user 'What is a Kubernetes pod?' success 'regex check input'
    test_policy user 'Contact lab.user@example.org' blocked 'regex check input'
    test_policy user 'Test identifier 000-00-0000' blocked 'regex check input'
    response=$(call_api chat/completions user 'What is the capital of France? Reply with only the city name.')
    if ! jq -er '.choices[0].message.content | strings | select(test("Paris"; "i"))' <<< "$response"; then
      printf '%s\n' "$response" >&2
      fail 'The guarded chat did not return the expected answer from Gemma.'
    fi
    printf 'PASS  guarded Gemma chat\n'
    response=$(call_api chat/completions user 'Repeat this address exactly: lab.user@example.org')
    check_email_refusal "$response"
    printf 'PASS  guarded chat refused the email prompt\n'
    test_policy assistant 'Contact lab.user@example.org' blocked 'regex check output'
    printf 'Guarded OpenAI base URL: %s/v1\n' "$route"
    ;;
  *) fail "Usage: bash $0 {check|render|apply|test|test-tools}" ;;
esac
