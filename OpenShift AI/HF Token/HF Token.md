#### Check whether storage-config already exists:
```bash
oc get secret storage-config \
  -n redhat-ods-applications
```
If it does, don't replace it wholesale because it may contain other storage credentials.
  
#### Create your Hugging Face credential:
```bash
read -rsp "Enter Hugging Face token: " HF_TOKEN
echo

HF_JSON=$(jq -nc \
  --arg token "${HF_TOKEN}" \
  '{type:"HuggingFace",token:$token}')

HF_B64=$(printf '%s' "${HF_JSON}" | base64 -w0)

if oc get secret storage-config \
  -n redhat-ods-applications >/dev/null 2>&1; then

  oc patch secret storage-config \
    -n redhat-ods-applications \
    --type=merge \
    -p "$(jq -nc \
      --arg value "${HF_B64}" \
      '{data:{"hf-secret":$value}}')"

else

  oc create secret generic storage-config \
    -n redhat-ods-applications \
    --from-literal=hf-secret="${HF_JSON}"

fi

unset HF_TOKEN HF_JSON HF_B64
```
```bash
Enter Hugging Face token:
secret/storage-config patched (no change)
```
Verify only the keys, without exposing credentials:
```bash
oc get secret storage-config \
  -n redhat-ods-applications \
  -o json |
jq -r '.data | keys[]'
```
You should see:
```bash
hf-secret
```