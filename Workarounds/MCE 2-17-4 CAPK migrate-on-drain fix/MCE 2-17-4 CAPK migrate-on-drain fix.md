### MCE 2.17.4 CAPK migrate-on-drain fix (OCPBUGS-98217) blocked by missing VMIM RBAC and disabled MigrationPriorityQueue feature gate

https://redhat.atlassian.net/browse/OCPBUGS-140772?focusedCommentId=19611696

After upgrading to MCE 2.17.4 to pick up the OCPBUGS-98217 fix, capi-provider now attempts to create a VirtualMachineInstanceMigration (VMIM) when a VMI is marked for eviction — this is the intended new behavior. However, two separate defects prevent this from completing, and the fallback drain+delete path also stalls, leaving affected VMIs permanently stuck in `EvictionRequested=True`.

#### Workaround:  
- It will use a simple python-based webhook service using an official python image of registry.access.redhat.com/ubi9/python-312  
- No RBACs are needed for this mutating webhook since it’s not interacting with the kube-apiserver.  
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: capk-webhook
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: capk-vmim-webhook
  namespace: capk-webhook
data:
  webhook.py: |
    import base64
    import json
    import logging
    import os
    import ssl
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    LISTEN_PORT = int(os.environ.get("WEBHOOK_PORT", "8443"))
    TLS_CERT = os.environ.get("TLS_CERT", "/etc/webhook/tls/tls.crt")
    TLS_KEY = os.environ.get("TLS_KEY", "/etc/webhook/tls/tls.key")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/healthz":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok\n")
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            if path != "/mutate-vmim-priority":
                self.send_response(404)
                self.end_headers()
                return

            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length)

            try:
                review = json.loads(body)
            except Exception:
                self.send_response(400)
                self.end_headers()
                return

            request = review.get("request", {})
            uid = request.get("uid", "")
            operation = request.get("operation", "")
            obj = request.get("object", {})

            allowed = True
            patch = None

            if operation == "CREATE":
                spec = obj.get("spec", {})
                if "priority" in spec:
                    patch = json.dumps([
                        {"op": "remove", "path": "/spec/priority"}
                    ]).encode()

            response = {
                "apiVersion": "admission.k8s.io/v1",
                "kind": "AdmissionReview",
                "response": {
                    "uid": uid,
                    "allowed": allowed,
                },
            }

            if patch:
                response["response"]["patchType"] = "JSONPatch"
                response["response"]["patch"] = base64.b64encode(patch).decode()

            logging.info(
                "handled AdmissionReview uid=%s operation=%s patched=%s",
                uid,
                operation,
                patch is not None,
            )

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())

        def log_message(self, fmt, *args):
            return

    if __name__ == "__main__":
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(TLS_CERT, TLS_KEY)

        httpd = ThreadingHTTPServer(("", LISTEN_PORT), Handler)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)

        logging.info("listening on https://0.0.0.0:%s", LISTEN_PORT)
        httpd.serve_forever()
---
apiVersion: v1
kind: Service
metadata:
  name: capk-vmim-webhook
  namespace: capk-webhook
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: webhook-tls
spec:
  selector:
    app: capk-vmim-webhook
  ports:
    - name: https
      port: 443
      targetPort: 8443
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: capk-vmim-webhook
  namespace: capk-webhook
spec:
  replicas: 2
  selector:
    matchLabels:
      app: capk-vmim-webhook
  template:
    metadata:
      labels:
        app: capk-vmim-webhook
    spec:
      containers:
        - name: webhook
          image: registry.access.redhat.com/ubi9/python-312
          command: ["python", "-u", "/webhook/webhook.py"]
          ports:
            - name: https
              containerPort: 8443
          volumeMounts:
            - name: script
              mountPath: /webhook
              readOnly: true
            - name: tls
              mountPath: /etc/webhook/tls
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 10
      volumes:
        - name: script
          configMap:
            name: capk-vmim-webhook
        - name: tls
          secret:
            secretName: webhook-tls
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: capk-vmim-priority
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
webhooks:
  - name: capk-vmim-priority.hypershift.openshift.io
    admissionReviewVersions:
      - v1
    sideEffects: None
    failurePolicy: Ignore
    matchPolicy: Equivalent
    reinvocationPolicy: Never
    timeoutSeconds: 10
    namespaceSelector:
      matchExpressions:
        - key: hypershift.openshift.io/hosted-control-plane
          operator: In
          values:
            - "true"
    rules:
      - operations:
          - CREATE
        apiGroups:
          - kubevirt.io
        apiVersions:
          - v1
        resources:
          - virtualmachineinstancemigrations
        scope: Namespaced
    clientConfig:
      service:
        namespace: capk-webhook
        name: capk-vmim-webhook
        path: /mutate-vmim-priority
        port: 443
```