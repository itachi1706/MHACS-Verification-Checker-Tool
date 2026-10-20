# WAHA on DigitalOcean Kubernetes

WAHA (WhatsApp HTTP API, Core, GOWS engine) plus an nginx **mTLS proxy** sidecar, managed
by Argo CD with Kustomize.

```
deploy/
├─ argocd/waha.yaml                   Argo CD Application
└─ k8s/waha/
   ├─ base/                           Namespace, Deployment (WAHA + mtls-proxy), Service, NetworkPolicy, ServiceMonitor
   ├─ components/local-sessions/      optional: sessions on a PVC instead of Postgres
   └─ overlays/
      ├─ ingress-nginx/               today: TCP 9443 via ingress-nginx tcp-services
      └─ cilium-gateway/              later: TLSRoute (TLS passthrough) on the shared Gateway
```

How a request travels: Lambda → `https://waha.<domain>:9443` → DO load balancer (existing)
→ ingress-nginx TCP stream, or a Cilium Gateway TLS passthrough listener → `mtls-proxy`
(checks the client certificate, allows only `/api/*`) → WAHA on `127.0.0.1:3000`.
TLS always terminates in the pod, so the edge never needs to support client certificates.

## 0. Postgres (session storage)

WAHA Core stores the WhatsApp session and the GOWS message store (used for history catch-up)
in your existing **DigitalOcean managed Postgres**. MySQL isn't supported, only Postgres
and MongoDB.

WAHA creates and uses two databases: `waha_mhacs` (main) and `waha_mhacs_default` (the
`default` session). Create a dedicated user, then either give it `CREATEDB` or create the
databases yourself (WAHA checks whether they exist before creating them):

```sql
CREATE USER waha WITH PASSWORD '<strong-password>';
-- either:
ALTER USER waha CREATEDB;
-- or:
CREATE DATABASE waha_mhacs OWNER waha;
CREATE DATABASE waha_mhacs_default OWNER waha;
```

- Connect **directly** (the private VPC hostname, port 25060), not through a PgBouncer
  pool, because WAHA runs `CREATE DATABASE` and keeps its own connection pools.
- Add the DOKS cluster to the database's **Trusted sources**.
- WAHA uses TLS (`sslmode=require`) but doesn't verify the server certificate. That's
  acceptable inside the VPC.
- Plan for roughly 10–20 connections. Check that the database plan has room for them.

The URL's database part is just the main connection WAHA logs in to (DO's default is `defaultdb`):
`postgres://waha:<password>@private-<db-host>:25060/defaultdb?sslmode=require`

To use a disk volume instead, enable `components/local-sessions` in the overlay and leave
out `WHATSAPP_SESSIONS_POSTGRESQL_URL`.

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
  --from-literal=WHATSAPP_HOOK_HMAC_KEY="$(openssl rand -hex 32)" \
  --from-literal=WHATSAPP_SESSIONS_POSTGRESQL_URL='postgres://waha:<password>@private-<db-host>:25060/defaultdb?sslmode=require'
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
- The namespace (and the PVC, if you use `local-sessions`) is annotated
  `Prune=false,Delete=false`, so Argo CD never removes the hand-made secrets or the session.
- `base/servicemonitor.yaml` needs the Prometheus Operator CRDs. See section 10.

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

## 10. Prometheus / Grafana

`WAHA_PROMETHEUS_ENABLED=True` turns on WAHA's `/metrics`. The sidecar serves only that
path, on plain HTTP port **9090** (Service port `metrics`). The NetworkPolicy allows 9090
only from the `monitoring` namespace.

- **Prometheus Operator** (kube-prometheus-stack): `base/servicemonitor.yaml` is picked up
  if your Prometheus selects it. The kube-prometheus-stack default only selects
  ServiceMonitors labelled `release: <helm-release>`, unless
  `serviceMonitorSelectorNilUsesHelmValues: false` is set.
- **Plain Prometheus** (no Operator): delete `servicemonitor.yaml` from the base
  `kustomization.yaml` and add a scrape job for `waha-mtls.mhacs-verify.svc:9090`.
- If Prometheus runs in a namespace other than `monitoring`, change the
  `namespaceSelector` in `base/networkpolicy.yaml`.

Useful metrics: `waha_session_status`, `waha_session_activity_timestamp_seconds`,
`waha_messages_total`, `waha_events_total`, `waha_up`. Alert when the session isn't
`WORKING` or the pod keeps restarting. The
SES email alert covers the first one too, so Grafana alerting is optional.

