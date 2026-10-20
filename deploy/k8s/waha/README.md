# WAHA on DigitalOcean Kubernetes

WAHA (WhatsApp HTTP API, Core, GOWS engine) plus an nginx **mTLS proxy** sidecar, managed
by Argo CD with Kustomize.

```
deploy/
├─ argocd/waha.yaml                   Argo CD Application
└─ k8s/waha/
   ├─ base/                           Namespace, PVC, Deployment (WAHA + mtls-proxy), Service, NetworkPolicy
   └─ overlays/
      ├─ ingress-nginx/               today: TCP 9443 via ingress-nginx tcp-services
      └─ cilium-gateway/              later: TLSRoute (TLS passthrough) on the shared Gateway
```

How a request travels: Lambda → `https://waha.<domain>:9443` → DO load balancer (existing)
→ ingress-nginx TCP stream, or a Cilium Gateway TLS passthrough listener → `mtls-proxy`
(checks the client certificate, allows only `/api/*`) → WAHA on `127.0.0.1:3000`.
TLS always terminates in the pod, so the edge never needs to support client certificates.

## 1. Certificates

```bash
scripts/certs.sh waha.<your-domain>     # writes ./certs (gitignored)
```

Keep `certs/ca.key` offline (e.g. in a password manager). The Lambdas get `ca.crt`,
`client.crt` and `client.key` later as SST secrets.

## 2. Secrets (created by hand, not stored in git)

```bash
kubectl create namespace mhacs-verify   # or let Argo CD create it first

kubectl -n mhacs-verify create secret generic waha-mtls \
  --from-file=tls.crt=certs/server.crt \
  --from-file=tls.key=certs/server.key \
  --from-file=ca.crt=certs/ca.crt

kubectl -n mhacs-verify create secret generic waha-env \
  --from-literal=WAHA_API_KEY="$(openssl rand -hex 32)" \
  --from-literal=WHATSAPP_HOOK_HMAC_KEY="$(openssl rand -hex 32)"
# Add WHATSAPP_HOOK_URL=https://<webhook-lambda-url>/waha once the SST app is deployed.
```

Save the API key and HMAC key; the Lambdas need both. WAHA hashes the API key on startup.
Clients still send the plain key in the `X-Api-Key` header.

Neither secret is in git, so Argo CD doesn't manage or prune them. If you later use
Sealed Secrets or External Secrets, add the resources to `base/` with the same names.

## 3. Expose port 9443: ingress-nginx Helm values

Your controller already runs with `--tcp-services-configmap=$(POD_NAMESPACE)/ingress-nginx-tcp`,
so just add this to the ingress-nginx Helm values:

```yaml
tcp:
  "9443": "mhacs-verify/waha-mtls:9443"
```

The chart writes this to the `ingress-nginx-tcp` ConfigMap **and** adds port 9443 to the
controller's `LoadBalancer` Service. DigitalOcean then adds a forwarding rule to the
**existing** load balancer, at no extra cost.

- If the DO load balancer has PROXY protocol enabled
  (`service.beta.kubernetes.io/do-loadbalancer-enable-proxy-protocol: "true"`), use
  `"mhacs-verify/waha-mtls:9443:PROXY"` instead, so nginx strips the PROXY header first.
- If the Service has `service.beta.kubernetes.io/do-loadbalancer-protocol` set to
  `http`/`https`, check that the new 9443 rule is created as **TCP**.
- `--enable-ssl-passthrough` is **not** needed for this. It would send all TLS traffic on
  443 through an extra proxy.

## 4. DNS (Route 53)

Point `waha.<your-domain>` at the load balancer IP (an `A` record):

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## 5. Argo CD

```bash
kubectl apply -f deploy/argocd/waha.yaml
```

- **Private repo:** first add the repo to Argo CD (UI → Settings → Repositories, or
  `argocd repo add https://github.com/itachi1706/MHACS-Verification-Checker-Tool.git
  --username <user> --password <fine-grained PAT with read-only Contents>`).
- Uses `project: default`. Change it if you restrict projects. The project must allow
  namespace `mhacs-verify`, and the cluster-scoped `Namespace` kind.
- The PVC is annotated `Prune=false,Delete=false`, so Argo CD never removes the WhatsApp
  session.

## 6. Link the WhatsApp Business number

The WAHA dashboard is turned off. Until the web app's session page exists, use a port-forward.
It goes straight to WAHA, so it skips mTLS but still needs the API key:

```bash
kubectl -n mhacs-verify port-forward deploy/waha 3000:3000
export KEY=<WAHA_API_KEY>

curl -s -H "X-Api-Key: $KEY" localhost:3000/api/sessions/default        # expect SCAN_QR_CODE
curl -s -H "X-Api-Key: $KEY" "localhost:3000/api/default/auth/qr?format=image" -o qr.png
# or a pairing code (type it on the phone: Linked devices → Link with phone number):
curl -s -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"phoneNumber":"65XXXXXXXX"}' localhost:3000/api/default/auth/request-code
```

## 7. Smoke test through mTLS

```bash
curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
  -H "X-Api-Key: $KEY" https://waha.<your-domain>:9443/api/sessions/default   # 200
curl --cacert certs/ca.crt https://waha.<your-domain>:9443/api/sessions/default # 400, no client cert
```

## 8. Moving to Cilium Gateway

1. Install the Gateway API **experimental-channel** CRDs that match your Cilium version
   (`TLSRoute` is only in that channel). Check with `kubectl api-resources | grep -i tlsroute`.
   Restart the Cilium operator if it started before the CRDs existed.
   If your Gateway API version serves `TLSRoute` under a newer apiVersion, update
   `overlays/cilium-gateway/tlsroute.yaml`.
2. Add a passthrough listener to your **existing shared Gateway**. A new Gateway means a
   new DO load balancer, about US$12/month.

   ```yaml
   listeners:
     - name: waha-mtls
       protocol: TLS
       port: 9443
       hostname: waha.<your-domain>
       tls:
         mode: Passthrough
       allowedRoutes:
         kinds:
           - kind: TLSRoute
         namespaces:
           from: Selector
           selector:
             matchLabels:
               kubernetes.io/metadata.name: mhacs-verify
   ```
3. Edit `overlays/cilium-gateway/tlsroute.yaml` with your Gateway name/namespace and hostname.
4. Change the Argo CD Application `path` to `deploy/k8s/waha/overlays/cilium-gateway`.
5. Point the DNS record at the Gateway's load balancer IP if it's different, then remove
   the `tcp:` entry from the ingress-nginx values.

The port, hostname and certificates stay the same, so nothing changes on the Lambda side.

## 9. Certificate rotation (yearly)

```bash
scripts/certs.sh waha.<your-domain>     # reuses the CA, re-issues server + client certs
kubectl -n mhacs-verify create secret generic waha-mtls \
  --from-file=tls.crt=certs/server.crt --from-file=tls.key=certs/server.key \
  --from-file=ca.crt=certs/ca.crt --dry-run=client -o yaml | kubectl apply -f -
kubectl -n mhacs-verify rollout restart deployment/waha
```

Then update the client cert in SST (`sst secret set ...`).
