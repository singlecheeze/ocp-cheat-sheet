#### How to create a internal image registry pull secret 
```bash
(
  umask 077

  REGISTRY_USER="$(oc whoami)"
  REGISTRY_TOKEN="$(oc whoami -t)"
  REGISTRY_AUTH="$(printf '%s:%s' \
    "$REGISTRY_USER" "$REGISTRY_TOKEN" | base64 -w0)"

  jq -cn \
    --arg username "$REGISTRY_USER" \
    --arg password "$REGISTRY_TOKEN" \
    --arg auth "$REGISTRY_AUTH" \
    '{auths: {
      "image-registry.openshift-image-registry.svc:5000": {
        username: $username,
        password: $password,
        auth: $auth
      }
    }}' > internal-registry-auth.json
)
  
  
oc create secret generic qwen36-35b-a3b-fp8 \
  -n ai-test \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=internal-registry-auth.json \
  --dry-run=client -o yaml |
oc apply -f -
Warning: resource secrets/qwen36-35b-a3b-fp8 is missing the kubectl.kubernetes.io/last-applied-configuration annotation which is required by oc apply. oc apply should only be used on resources created declaratively by either oc create --save-config or oc apply. The missing annotation will be patched automatically.
secret/qwen36-35b-a3b-fp8 configured
```
